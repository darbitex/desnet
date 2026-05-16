/// Reaction Rewards Gauge — multi-FA permissionless rewards pool for pressers.
///
/// One pool per handle. Anyone can `notify_reward` with any FA. On every press,
/// the presser withdraws `BPS_PER_PRESS × current_balance / 10000` from every
/// registered reward token. Pool is asymptotic — multiplicative decay never
/// drives the balance to zero, so the gauge degrades gracefully and the
/// "early presser farms entire reserve" failure mode of the v0.3 sealed-
/// reserve design is gone.
///
/// Replaces the v0.3 sealed-reserve emission (5% of supply at mint, linear-
/// increasing payout × press_order). Supra mode mints 100% supply into the
/// IPO pool, so no reserve is funded at registration. The pool starts empty
/// and is funded entirely by external topups.
module desnet::reaction_emission {
    use std::signer;
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;

    use desnet::governance;

    friend desnet::press;

    // ============ CONSTANTS ============

    /// Per-press withdrawal rate against the current pool balance for each
    /// registered reward token. 25 bps = 0.25%. Pool decays multiplicatively
    /// across presses and never hits zero.
    const BPS_PER_PRESS: u64 = 25;
    const BPS_DENOM: u64 = 10_000;

    const MAX_REWARD_TOKENS: u64 = 32;

    const SEED_REACTION_REWARDS: vector<u8> = b"reaction_rewards::";

    // ============ ERROR CODES ============

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_TOO_MANY_REWARD_TOKENS: u64 = 3;

    // ============ TYPES ============

    struct ReactionRewardsPool has key {
        handle: vector<u8>,
        extend_ref: ExtendRef,
        reward_tokens: SmartTable<address, ReactionAccumulator>,
        reward_token_list: vector<address>,
    }

    struct ReactionAccumulator has store, drop {
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
        new_balance: u64,
    }

    #[event]
    struct PressDistributed has drop, store {
        pool_addr: address,
        presser: address,
        reward_token: address,
        amount: u64,
        pool_balance_before: u64,
    }

    // ============ ADDRESS DERIVATION ============

    public fun pool_address_of_handle(handle: vector<u8>): address {
        object::create_object_address(&@desnet, make_seed(&handle))
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = SEED_REACTION_REWARDS;
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ INIT — lazy on first notify ============

    fun ensure_pool(handle: vector<u8>): address {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<ReactionRewardsPool>(pool_addr)) {
            let pkg_signer = governance::derive_pkg_signer();
            let constructor_ref = object::create_named_object(&pkg_signer, make_seed(&handle));
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            object::disable_ungated_transfer(&transfer_ref);
            let pool_signer = object::generate_signer(&constructor_ref);
            move_to(&pool_signer, ReactionRewardsPool {
                handle,
                extend_ref,
                reward_tokens: smart_table::new(),
                reward_token_list: vector::empty(),
            });
            event::emit(PoolInitialized { pool_addr, handle });
        };
        pool_addr
    }

    // ============ NOTIFY — permissionless topup ============

    public entry fun notify_reward(
        depositor: &signer,
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ) acquires ReactionRewardsPool {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let pool_addr = ensure_pool(handle);
        let pool = borrow_global_mut<ReactionRewardsPool>(pool_addr);
        let token_addr = object::object_address(&reward_token_meta);

        if (!smart_table::contains(&pool.reward_tokens, token_addr)) {
            assert!(
                vector::length(&pool.reward_token_list) < MAX_REWARD_TOKENS,
                E_TOO_MANY_REWARD_TOKENS,
            );
            let slot = vector::length(&pool.reward_token_list);
            vector::push_back(&mut pool.reward_token_list, token_addr);
            smart_table::add(&mut pool.reward_tokens, token_addr, ReactionAccumulator {
                total_topped_up: 0,
                total_distributed: 0,
            });
            event::emit(RewardTokenRegistered { pool_addr, reward_token: token_addr, slot_index: slot });
        };

        let fa = primary_fungible_store::withdraw(depositor, reward_token_meta, amount);
        primary_fungible_store::deposit(pool_addr, fa);

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        acc.total_topped_up = acc.total_topped_up + (amount as u128);

        let new_balance = primary_fungible_store::balance(pool_addr, reward_token_meta);
        event::emit(RewardNotified {
            pool_addr,
            depositor: signer::address_of(depositor),
            reward_token: token_addr,
            amount,
            new_balance,
        });
    }

    // ============ FRIEND: distribute per press ============

    /// Withdraw `BPS_PER_PRESS × balance / 10_000` from each registered reward
    /// token's pool balance and deposit to the presser. Returns the total
    /// amount distributed across all tokens. Tokens with zero balance or
    /// zero-quantized payout are skipped.
    ///
    /// Safe to call when pool doesn't exist — returns 0 and is a no-op so
    /// press still succeeds before anyone has funded the gauge.
    public(friend) fun distribute_to_presser(
        handle: vector<u8>,
        presser: address,
    ): u64 acquires ReactionRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<ReactionRewardsPool>(pool_addr)) return 0;

        let pool = borrow_global_mut<ReactionRewardsPool>(pool_addr);
        let tokens = pool.reward_token_list;
        let n = vector::length(&tokens);
        let total_distributed = 0u64;
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);

        let i = 0;
        while (i < n) {
            let token_addr = *vector::borrow(&tokens, i);
            let token_meta = object::address_to_object<Metadata>(token_addr);
            let balance_before = primary_fungible_store::balance(pool_addr, token_meta);
            if (balance_before > 0) {
                let payout = (((balance_before as u128) * (BPS_PER_PRESS as u128))
                    / (BPS_DENOM as u128)) as u64;
                if (payout > 0) {
                    let fa = primary_fungible_store::withdraw(&pool_signer, token_meta, payout);
                    primary_fungible_store::deposit(presser, fa);
                    let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
                    acc.total_distributed = acc.total_distributed + (payout as u128);
                    total_distributed = total_distributed + payout;
                    event::emit(PressDistributed {
                        pool_addr,
                        presser,
                        reward_token: token_addr,
                        amount: payout,
                        pool_balance_before: balance_before,
                    });
                };
            };
            i = i + 1;
        };

        total_distributed
    }

    // ============ VIEWS ============

    #[view]
    public fun pool_exists(handle: vector<u8>): bool {
        exists<ReactionRewardsPool>(pool_address_of_handle(handle))
    }

    #[view]
    public fun reward_tokens_of(handle: vector<u8>): vector<address> acquires ReactionRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<ReactionRewardsPool>(pool_addr)) return vector::empty();
        borrow_global<ReactionRewardsPool>(pool_addr).reward_token_list
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
    public fun bps_per_press(): u64 { BPS_PER_PRESS }

    #[view]
    public fun bps_denom(): u64 { BPS_DENOM }

    #[view]
    public fun max_reward_tokens(): u64 { MAX_REWARD_TOKENS }
}
