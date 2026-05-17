module desnet::reaction_emission {
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;

    use desnet::governance;

    friend desnet::press;

    const BPS_PER_PRESS: u64 = 25;
    const BPS_DENOM: u64 = 10_000;

    const MAX_REWARD_TOKENS: u64 = 32;

    const SEED_REACTION_REWARDS: vector<u8> = b"reaction_rewards::";

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_TOO_MANY_REWARD_TOKENS: u64 = 3;
    const E_DISPATCHABLE_FA_REJECTED: u64 = 4;

    struct ReactionRewardsPool has key {
        author_pid: address,
        extend_ref: ExtendRef,
        reward_tokens: SmartTable<address, ReactionAccumulator>,
        reward_token_list: vector<address>,
    }

    struct ReactionAccumulator has store, drop {
        total_topped_up: u128,
        total_distributed: u128,
    }

    #[event]
    struct PoolInitialized has drop, store {
        pool_addr: address,
        author_pid: address,
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
        author_pid: address,
        depositor: address,
        reward_token: address,
        amount: u64,
        new_balance: u64,
    }

    #[event]
    struct PressDistributed has drop, store {
        pool_addr: address,
        author_pid: address,
        presser: address,
        reward_token: address,
        amount: u64,
        pool_balance_before: u64,
    }

    public fun pool_address_of(author_pid: address): address {
        object::create_object_address(&@desnet, make_seed(author_pid))
    }

    fun make_seed(author_pid: address): vector<u8> {
        let seed = SEED_REACTION_REWARDS;
        vector::append(&mut seed, bcs::to_bytes(&author_pid));
        seed
    }

    fun ensure_pool(author_pid: address): address {
        let pool_addr = pool_address_of(author_pid);
        if (!exists<ReactionRewardsPool>(pool_addr)) {
            let pkg_signer = governance::derive_pkg_signer();
            let constructor_ref = object::create_named_object(&pkg_signer, make_seed(author_pid));
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            object::disable_ungated_transfer(&transfer_ref);
            let pool_signer = object::generate_signer(&constructor_ref);
            move_to(&pool_signer, ReactionRewardsPool {
                author_pid,
                extend_ref,
                reward_tokens: smart_table::new(),
                reward_token_list: vector::empty(),
            });
            event::emit(PoolInitialized { pool_addr, author_pid });
        };
        pool_addr
    }

    public entry fun notify_reward(
        depositor: &signer,
        author_pid: address,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ) acquires ReactionRewardsPool {
        assert!(amount > 0, E_ZERO_AMOUNT);

        let depositor_addr = signer::address_of(depositor);
        let depositor_store = primary_fungible_store::ensure_primary_store_exists(
            depositor_addr, reward_token_meta,
        );
        assert!(
            std::option::is_none(&fungible_asset::deposit_dispatch_function(depositor_store))
                && std::option::is_none(&fungible_asset::withdraw_dispatch_function(depositor_store)),
            E_DISPATCHABLE_FA_REJECTED,
        );

        let pool_addr = ensure_pool(author_pid);
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
            author_pid,
            depositor: signer::address_of(depositor),
            reward_token: token_addr,
            amount,
            new_balance,
        });
    }

    public(friend) fun distribute_to_presser(
        author_pid: address,
        presser: address,
    ): u64 acquires ReactionRewardsPool {
        let pool_addr = pool_address_of(author_pid);
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
                let payout = ((((balance_before as u128) * (BPS_PER_PRESS as u128))
                    / (BPS_DENOM as u128)) as u64);
                if (payout > 0) {
                    let fa = primary_fungible_store::withdraw(&pool_signer, token_meta, payout);
                    primary_fungible_store::deposit(presser, fa);
                    let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
                    acc.total_distributed = acc.total_distributed + (payout as u128);
                    total_distributed = total_distributed + payout;
                    event::emit(PressDistributed {
                        pool_addr,
                        author_pid,
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

    #[view]
    public fun pool_exists(author_pid: address): bool {
        exists<ReactionRewardsPool>(pool_address_of(author_pid))
    }

    #[view]
    public fun reward_tokens_of(author_pid: address): vector<address> acquires ReactionRewardsPool {
        let pool_addr = pool_address_of(author_pid);
        if (!exists<ReactionRewardsPool>(pool_addr)) return vector::empty();
        borrow_global<ReactionRewardsPool>(pool_addr).reward_token_list
    }

    #[view]
    public fun reward_balance(
        author_pid: address,
        reward_token_meta: Object<Metadata>,
    ): u64 {
        let pool_addr = pool_address_of(author_pid);
        primary_fungible_store::balance(pool_addr, reward_token_meta)
    }

    #[view]
    public fun bps_per_press(): u64 { BPS_PER_PRESS }

    #[view]
    public fun bps_denom(): u64 { BPS_DENOM }

    #[view]
    public fun max_reward_tokens(): u64 { MAX_REWARD_TOKENS }
}
