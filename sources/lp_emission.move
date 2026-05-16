/// LP Rewards Gauge — multi-FA permissionless rewards pool for LP positions.
///
/// One pool per handle. Anyone can `notify_reward` with ANY FA. Each notify
/// bumps a MasterChef-style `acc_per_share` accumulator for that reward token.
/// Positions (held by `ipo::Position`) carry per-token reward debt and claim
/// by walking the pool's reward-token list.
///
/// Total-share bookkeeping is push-driven: ipo calls `on_share_increase` /
/// `on_share_decrease` whenever a Position is created or destroyed. This keeps
/// the module dependency one-way (ipo → lp_emission) — lp_emission never reads
/// from ipo.
///
/// Replaces the v0.3 sealed-reserve design: Supra mode mints 100% supply into
/// the IPO pool, so the old "deploy 90% reserve at registration" path is gone.
/// The pool starts empty and is funded entirely by external topups.
module desnet::lp_emission {
    use std::signer;
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;

    use desnet::governance;

    friend desnet::ipo;

    // ============ CONSTANTS ============

    /// Fixed-point scale for acc_per_share — picked at 1e18 so even sub-microunit
    /// rewards per share don't quantize to zero on a 1B-share total.
    const ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    /// Anti-bloat: each pool can register at most this many distinct reward
    /// tokens. Once full, new tokens are rejected to keep iteration cheap.
    const MAX_REWARD_TOKENS: u64 = 32;

    const SEED_LP_REWARDS: vector<u8> = b"lp_rewards::";

    // ============ ERROR CODES ============

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_NO_SHARES: u64 = 3;
    const E_TOO_MANY_REWARD_TOKENS: u64 = 4;
    const E_REWARD_TOKEN_NOT_REGISTERED: u64 = 5;
    const E_SHARE_UNDERFLOW: u64 = 6;

    // ============ TYPES ============

    struct LpRewardsPool has key {
        handle: vector<u8>,
        extend_ref: ExtendRef,
        total_share: u128,
        reward_tokens: SmartTable<address, RewardAccumulator>,
        reward_token_list: vector<address>,
    }

    struct RewardAccumulator has store, drop {
        acc_per_share: u128,        // raw FA units × ACC_SCALE per LP share
        total_topped_up: u128,
        total_distributed: u128,
    }

    // ============ EVENTS ============

    #[event]
    struct PoolInitialized has drop, store {
        pool_addr: address,
        handle: vector<u8>,
    }

    #[event]
    struct RewardTokenRegistered has drop, store {
        pool_addr: address,
        reward_token: address,
        slot_index: u64,
    }

    #[event]
    struct RewardNotified has drop, store {
        pool_addr: address,
        depositor: address,
        reward_token: address,
        amount: u64,
        total_share_at_notify: u128,
        acc_per_share_after: u128,
    }

    #[event]
    struct RewardPulled has drop, store {
        pool_addr: address,
        reward_token: address,
        amount: u64,
    }

    #[event]
    struct ShareChanged has drop, store {
        pool_addr: address,
        delta: u128,
        increased: bool,
        total_share_after: u128,
    }

    // ============ ADDRESS DERIVATION ============

    public fun pool_address_of_handle(handle: vector<u8>): address {
        object::create_object_address(&@desnet, make_seed(&handle))
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = SEED_LP_REWARDS;
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ INIT — lazy, auto-fires on first share increase or notify ============

    fun ensure_pool(handle: vector<u8>): address {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) {
            let pkg_signer = governance::derive_pkg_signer();
            let constructor_ref = object::create_named_object(&pkg_signer, make_seed(&handle));
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            object::disable_ungated_transfer(&transfer_ref);
            let pool_signer = object::generate_signer(&constructor_ref);
            move_to(&pool_signer, LpRewardsPool {
                handle,
                extend_ref,
                total_share: 0,
                reward_tokens: smart_table::new(),
                reward_token_list: vector::empty(),
            });
            event::emit(PoolInitialized { pool_addr, handle });
        };
        pool_addr
    }

    // ============ FRIEND: share-tracking hooks from ipo ============

    public(friend) fun on_share_increase(handle: vector<u8>, delta: u128)
        acquires LpRewardsPool
    {
        let pool_addr = ensure_pool(handle);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        pool.total_share = pool.total_share + delta;
        event::emit(ShareChanged {
            pool_addr,
            delta,
            increased: true,
            total_share_after: pool.total_share,
        });
    }

    public(friend) fun on_share_decrease(handle: vector<u8>, delta: u128)
        acquires LpRewardsPool
    {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<LpRewardsPool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        assert!(pool.total_share >= delta, E_SHARE_UNDERFLOW);
        pool.total_share = pool.total_share - delta;
        event::emit(ShareChanged {
            pool_addr,
            delta,
            increased: false,
            total_share_after: pool.total_share,
        });
    }

    // ============ NOTIFY — permissionless topup ============

    /// Anyone deposits any FA into the pool. Caller funds, accumulator bumps,
    /// existing positions earn pro-rata from this point forward.
    ///
    /// Aborts:
    /// - amount == 0
    /// - total_share == 0 (no positions to share with)
    /// - pool already tracks MAX_REWARD_TOKENS and this token isn't one of them
    public entry fun notify_reward(
        depositor: &signer,
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ) acquires LpRewardsPool {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let pool_addr = ensure_pool(handle);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        assert!(pool.total_share > 0, E_NO_SHARES);
        let total_share = pool.total_share;
        let token_addr = object::object_address(&reward_token_meta);

        if (!smart_table::contains(&pool.reward_tokens, token_addr)) {
            assert!(
                vector::length(&pool.reward_token_list) < MAX_REWARD_TOKENS,
                E_TOO_MANY_REWARD_TOKENS,
            );
            let slot = vector::length(&pool.reward_token_list);
            vector::push_back(&mut pool.reward_token_list, token_addr);
            smart_table::add(&mut pool.reward_tokens, token_addr, RewardAccumulator {
                acc_per_share: 0,
                total_topped_up: 0,
                total_distributed: 0,
            });
            event::emit(RewardTokenRegistered { pool_addr, reward_token: token_addr, slot_index: slot });
        };

        let fa = primary_fungible_store::withdraw(depositor, reward_token_meta, amount);
        primary_fungible_store::deposit(pool_addr, fa);

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        let delta = ((amount as u128) * ACC_SCALE) / total_share;
        acc.acc_per_share = acc.acc_per_share + delta;
        acc.total_topped_up = acc.total_topped_up + (amount as u128);
        let acc_after = acc.acc_per_share;

        event::emit(RewardNotified {
            pool_addr,
            depositor: signer::address_of(depositor),
            reward_token: token_addr,
            amount,
            total_share_at_notify: total_share,
            acc_per_share_after: acc_after,
        });

        // Feed governance's 30d rolling emission bucket for DESNET-denominated
        // topups only. DAO threshold/quorum reads this in lieu of a manual
        // multisig-bumped counter (v0.3.2 F6 design). Non-DESNET reward tokens
        // are silent to governance.
        if (token_addr == governance::desnet_fa_addr()) {
            governance::record_emission_for_window(amount);
        };
    }

    // ============ FRIEND: claim path called by ipo ============

    /// Snapshot acc_per_share for a token (debt-init + pending calc).
    /// Returns 0 if pool doesn't exist or token isn't registered.
    public fun acc_per_share_of(handle: vector<u8>, reward_token: address): u128
        acquires LpRewardsPool
    {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        let pool = borrow_global<LpRewardsPool>(pool_addr);
        if (!smart_table::contains(&pool.reward_tokens, reward_token)) return 0;
        smart_table::borrow(&pool.reward_tokens, reward_token).acc_per_share
    }

    /// Token list for ipo claim iteration. Empty vec if pool doesn't exist.
    public fun reward_tokens_of(handle: vector<u8>): vector<address> acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return vector::empty();
        borrow_global<LpRewardsPool>(pool_addr).reward_token_list
    }

    /// Friend-only: ipo claim path computes `pending` and pulls that amount as
    /// a hot-potato FA. ipo is responsible for depositing to the position owner.
    public(friend) fun withdraw_reward(
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ): FungibleAsset acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<LpRewardsPool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        let token_addr = object::object_address(&reward_token_meta);
        assert!(
            smart_table::contains(&pool.reward_tokens, token_addr),
            E_REWARD_TOKEN_NOT_REGISTERED,
        );

        if (amount == 0) {
            return fungible_asset::zero(reward_token_meta)
        };

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        acc.total_distributed = acc.total_distributed + (amount as u128);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = primary_fungible_store::withdraw(&pool_signer, reward_token_meta, amount);

        event::emit(RewardPulled { pool_addr, reward_token: token_addr, amount });
        fa
    }

    // ============ VIEWS ============

    #[view]
    public fun pool_exists(handle: vector<u8>): bool {
        exists<LpRewardsPool>(pool_address_of_handle(handle))
    }

    #[view]
    public fun total_share_of(handle: vector<u8>): u128 acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        borrow_global<LpRewardsPool>(pool_addr).total_share
    }

    #[view]
    public fun reward_token_count(handle: vector<u8>): u64 acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        vector::length(&borrow_global<LpRewardsPool>(pool_addr).reward_token_list)
    }

    #[view]
    public fun reward_balance(
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
    ): u64 {
        let pool_addr = pool_address_of_handle(handle);
        primary_fungible_store::balance(pool_addr, reward_token_meta)
    }

    #[view]
    public fun acc_scale(): u128 { ACC_SCALE }

    #[view]
    public fun max_reward_tokens(): u64 { MAX_REWARD_TOKENS }
}
