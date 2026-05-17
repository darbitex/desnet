module desnet::lp_staking {
    use std::signer;
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef, ObjectCore};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::governance;

    friend desnet::factory;

    const DEFAULT_RATE_PER_SEC: u64 = 1_000_000_000;

    const ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    const UNLOCK_FOREVER: u64 = 18446744073709551615;

    const SEED_STAKING_POOL: vector<u8> = b"desnet::lp_staking::pool::";

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_POOL_ALREADY_EXISTS: u64 = 2;
    const E_POSITION_NOT_FOUND: u64 = 3;
    const E_NOT_POSITION_OWNER: u64 = 4;
    const E_ZERO_SHARES: u64 = 5;
    const E_LOCKED_NOT_YET_UNLOCKED: u64 = 6;
    const E_LOCKED_FOREVER: u64 = 7;
    const E_LOCK_DURATION_INVALID: u64 = 8;
    const E_LOCKED_POSITION_EXISTS: u64 = 9;
    const E_INVALID_PID_SIGNER: u64 = 10;

    struct StakingPool has key {
        handle: vector<u8>,
        token_metadata_addr: address,
        rate_per_sec: u64,
        accumulated_per_share: u128,
        last_update_secs: u64,
        emission_reserve_addr: address,
        extend_ref: ExtendRef,
    }

    struct Position has key {
        pool_addr: address,
        handle: vector<u8>,
        shares: u128,
        last_acc_per_share: u128,
        last_fee_per_lp_supra: u128,
        last_fee_per_lp_token: u128,
        unlock_at_secs: u64,
        recipient_pid: address,
    }

    #[event]
    struct StakingPoolCreated has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        token_metadata_addr: address,
        emission_reserve_addr: address,
        rate_per_sec: u64,
    }

    #[event]
    struct PositionCreated has drop, store {
        handle: vector<u8>,
        position_addr: address,
        owner: address,
        shares: u128,
        unlock_at_secs: u64,
        recipient_pid: address,
        kind: u8,
    }

    #[event]
    struct PositionRemoved has drop, store {
        handle: vector<u8>,
        position_addr: address,
        owner: address,
        shares: u128,
        supra_returned: u64,
        token_returned: u64,
    }

    #[event]
    struct Claimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        emission_amount: u64,
        supra_fee_amount: u64,
        token_fee_amount: u64,
    }

    public fun staking_pool_address_of_handle(handle: vector<u8>): address {
        let seed = pool_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    public fun staking_pool_exists(handle: vector<u8>): bool {
        exists<StakingPool>(staking_pool_address_of_handle(handle))
    }

    fun pool_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_STAKING_POOL;
        vector::append(&mut s, *handle);
        s
    }

    public(friend) fun create_pool_and_lock(
        handle: vector<u8>,
        token_metadata_addr: address,
        emission_reserve_addr: address,
        creator_pid: address,
        pid_signer: &signer,
        initial_shares: u128,
    ): address {
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(!exists<StakingPool>(pool_addr), E_POOL_ALREADY_EXISTS);
        assert!(initial_shares > 0, E_ZERO_SHARES);
        assert!(signer::address_of(pid_signer) == creator_pid, E_INVALID_PID_SIGNER);
        assert!(!exists<Position>(creator_pid), E_LOCKED_POSITION_EXISTS);

        let pkg_signer = governance::derive_pkg_signer();
        let constructor = object::create_named_object(&pkg_signer, pool_seed(&handle));
        let pool_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        let now = timestamp::now_seconds();

        move_to(&pool_signer, StakingPool {
            handle,
            token_metadata_addr,
            rate_per_sec: DEFAULT_RATE_PER_SEC,
            accumulated_per_share: 0,
            last_update_secs: now,
            emission_reserve_addr,
            extend_ref,
        });

        event::emit(StakingPoolCreated {
            handle,
            pool_addr,
            token_metadata_addr,
            emission_reserve_addr,
            rate_per_sec: DEFAULT_RATE_PER_SEC,
        });

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);

        move_to(pid_signer, Position {
            pool_addr,
            handle,
            shares: initial_shares,
            last_acc_per_share: 0,
            last_fee_per_lp_supra: fee_per_supra,
            last_fee_per_lp_token: fee_per_token,
            unlock_at_secs: UNLOCK_FOREVER,
            recipient_pid: creator_pid,
        });

        event::emit(PositionCreated {
            handle,
            position_addr: creator_pid,
            owner: object::owner(object::address_to_object<ObjectCore>(creator_pid)),
            shares: initial_shares,
            unlock_at_secs: UNLOCK_FOREVER,
            recipient_pid: creator_pid,
            kind: 1,
        });

        pool_addr
    }

    public entry fun add_liquidity(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
    ) acquires StakingPool {
        let unlock_at_secs = 0u64;
        add_liquidity_with_lock_internal(caller, handle, supra_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    public entry fun add_liquidity_with_lock(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let now = timestamp::now_seconds();
        assert!(unlock_at_secs > now, E_LOCK_DURATION_INVALID);
        add_liquidity_with_lock_internal(caller, handle, supra_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    fun add_liquidity_with_lock_internal(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let caller_addr = signer::address_of(caller);
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);

        let supra_coin = coin::withdraw<SupraCoin>(caller, supra_amount);
        let supra_fa = coin::coin_to_fungible_asset(supra_coin);

        let pool = borrow_global<StakingPool>(pool_addr);
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        let token_fa = primary_fungible_store::withdraw(caller, token_meta, token_amount);

        let (lp_minted, supra_refund, token_refund) =
            amm::add_liquidity_internal(handle, supra_fa, token_fa, min_lp_out);
        assert!(lp_minted > 0, E_ZERO_SHARES);
        if (fungible_asset::amount(&supra_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, supra_refund);
        } else {
            fungible_asset::destroy_zero(supra_refund);
        };
        if (fungible_asset::amount(&token_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, token_refund);
        } else {
            fungible_asset::destroy_zero(token_refund);
        };

        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let snapshot_acc = pool.accumulated_per_share;
        let pool_handle = pool.handle;

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);

        let constructor = object::create_object(caller_addr);
        let pos_signer = object::generate_signer(&constructor);
        let pos_addr = signer::address_of(&pos_signer);

        move_to(&pos_signer, Position {
            pool_addr,
            handle,
            shares: lp_minted,
            last_acc_per_share: snapshot_acc,
            last_fee_per_lp_supra: fee_per_supra,
            last_fee_per_lp_token: fee_per_token,
            unlock_at_secs,
            recipient_pid: @0x0,
        });

        let kind: u8 = if (unlock_at_secs == 0) 2 else 3;
        event::emit(PositionCreated {
            handle: pool_handle,
            position_addr: pos_addr,
            owner: caller_addr,
            shares: lp_minted,
            unlock_at_secs,
            recipient_pid: @0x0,
            kind,
        });
    }

    public entry fun remove_liquidity(
        caller: &signer,
        position_addr: address,
        min_supra_out: u64,
        min_token_out: u64,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let position = borrow_global<Position>(position_addr);
        let unlock_at = position.unlock_at_secs;
        let handle = position.handle;
        let position_obj = object::address_to_object<Position>(position_addr);
        let position_owner = object::owner(position_obj);

        assert!(signer::address_of(caller) == position_owner, E_NOT_POSITION_OWNER);

        assert!(unlock_at != UNLOCK_FOREVER, E_LOCKED_FOREVER);
        let now = timestamp::now_seconds();
        assert!(now >= unlock_at, E_LOCKED_NOT_YET_UNLOCKED);

        claim_internal(position_addr);

        let Position {
            pool_addr: _,
            handle: _,
            shares,
            last_acc_per_share: _,
            last_fee_per_lp_supra: _,
            last_fee_per_lp_token: _,
            unlock_at_secs: _,
            recipient_pid: _,
        } = move_from<Position>(position_addr);

        let (supra_fa, token_fa) = amm::remove_liquidity_internal(handle, shares, min_supra_out, min_token_out);
        let supra_returned = fungible_asset::amount(&supra_fa);
        let token_returned = fungible_asset::amount(&token_fa);

        primary_fungible_store::deposit(position_owner, supra_fa);
        primary_fungible_store::deposit(position_owner, token_fa);

        let pool_handle_dummy = handle;
        event::emit(PositionRemoved {
            handle: pool_handle_dummy,
            position_addr,
            owner: position_owner,
            shares,
            supra_returned,
            token_returned,
        });
    }

    public entry fun claim(
        _caller: &signer,
        position_addr: address,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        claim_internal(position_addr);
    }

    fun claim_internal(position_addr: address) acquires Position, StakingPool {
        let position = borrow_global_mut<Position>(position_addr);
        let pool_addr = position.pool_addr;
        let handle = position.handle;
        let shares_u128 = position.shares;

        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let acc = pool.accumulated_per_share;
        position.last_acc_per_share = acc;

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra_u128 = ((fee_per_supra - position.last_fee_per_lp_supra) * shares_u128) / amm_scale;
        let pending_token_u128 = ((fee_per_token - position.last_fee_per_lp_token) * shares_u128) / amm_scale;
        position.last_fee_per_lp_supra = fee_per_supra;
        position.last_fee_per_lp_token = fee_per_token;

        let pending_supra = (pending_supra_u128 as u64);
        let pending_token = (pending_token_u128 as u64);

        let recipient = resolve_recipient(position.recipient_pid, position_addr);

        if (pending_supra > 0 || pending_token > 0) {
            let (supra_fa, token_fa) = amm::extract_fees_for_claim(handle, pending_supra, pending_token);
            if (fungible_asset::amount(&supra_fa) > 0) {
                primary_fungible_store::deposit(recipient, supra_fa);
            } else {
                fungible_asset::destroy_zero(supra_fa);
            };
            if (fungible_asset::amount(&token_fa) > 0) {
                primary_fungible_store::deposit(recipient, token_fa);
            } else {
                fungible_asset::destroy_zero(token_fa);
            };
        };

        let pending_emission: u64 = 0;
        if (pending_emission == 0 && pending_supra == 0 && pending_token == 0) return;

        event::emit(Claimed {
            handle: pool.handle,
            position_addr,
            recipient,
            emission_amount: pending_emission,
            supra_fee_amount: pending_supra,
            token_fee_amount: pending_token,
        });
    }

    fun resolve_recipient(recipient_pid: address, position_addr: address): address {
        if (recipient_pid == @0x0) {
            let pos_obj = object::address_to_object<Position>(position_addr);
            object::owner(pos_obj)
        } else {
            let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
            object::owner(pid_obj)
        }
    }

    fun update_pool(pool_addr: address) acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(pool_addr);
        let now = timestamp::now_seconds();
        if (now <= pool.last_update_secs) return;

        let lp_supply = amm::lp_supply(pool.handle);
        if (lp_supply == 0) {
            pool.last_update_secs = now;
            return
        };

        let elapsed = now - pool.last_update_secs;
        let new_emission = (elapsed as u128) * (pool.rate_per_sec as u128);
        let delta_per_share = (new_emission * ACC_SCALE) / lp_supply;
        pool.accumulated_per_share = pool.accumulated_per_share + delta_per_share;
        pool.last_update_secs = now;
    }

    #[view]
    public fun has_position(position_addr: address): bool {
        exists<Position>(position_addr)
    }

    #[view]
    public fun position_pool(position_addr: address): address acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).pool_addr
    }

    #[view]
    public fun position_shares(position_addr: address): u128 acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).shares
    }

    #[view]
    public fun position_unlock_at(position_addr: address): u64 acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).unlock_at_secs
    }

    #[view]
    public fun position_recipient_pid(position_addr: address): address acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).recipient_pid
    }

    #[view]
    public fun position_owner(position_addr: address): address {
        let pos_obj = object::address_to_object<Position>(position_addr);
        object::owner(pos_obj)
    }

    #[view]
    public fun position_pool_addr(pos: Object<Position>): address acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).pool_addr
    }

    #[view]
    public fun position_fee_debt(pos: Object<Position>): (u128, u128) acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        let p = borrow_global<Position>(pos_addr);
        (p.last_fee_per_lp_supra, p.last_fee_per_lp_token)
    }

    #[view]
    public fun position_pending_fees(pos: Object<Position>): (u64, u64) acquires Position {
        let pos_addr = object::object_address(&pos);
        if (!exists<Position>(pos_addr)) return (0, 0);
        let p = borrow_global<Position>(pos_addr);
        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(p.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra = ((((fee_per_supra - p.last_fee_per_lp_supra) * p.shares) / amm_scale) as u64);
        let pending_token = ((((fee_per_token - p.last_fee_per_lp_token) * p.shares) / amm_scale) as u64);
        (pending_supra, pending_token)
    }

    #[view]
    public fun position_shares_obj(pos: Object<Position>): u128 acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).shares
    }

    #[view]
    public fun position_pending_all(position_addr: address): (u64, u64, u64)
        acquires Position, StakingPool
    {
        if (!exists<Position>(position_addr)) return (0, 0, 0);
        let position = borrow_global<Position>(position_addr);
        let pool_addr = position.pool_addr;
        if (!exists<StakingPool>(pool_addr)) return (0, 0, 0);
        let pool = borrow_global<StakingPool>(pool_addr);
        let lp_supply = amm::lp_supply(position.handle);

        let now = timestamp::now_seconds();
        let acc = pool.accumulated_per_share;
        if (now > pool.last_update_secs && lp_supply > 0) {
            let elapsed = now - pool.last_update_secs;
            let new_emission = (elapsed as u128) * (pool.rate_per_sec as u128);
            let delta = (new_emission * ACC_SCALE) / lp_supply;
            acc = acc + delta;
        };

        let pending_emission = ((((acc - position.last_acc_per_share) * position.shares) / ACC_SCALE) as u64);

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(position.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra = ((((fee_per_supra - position.last_fee_per_lp_supra) * position.shares) / amm_scale) as u64);
        let pending_token = ((((fee_per_token - position.last_fee_per_lp_token) * position.shares) / amm_scale) as u64);

        (pending_emission, pending_supra, pending_token)
    }

    #[view]
    public fun pool_acc_per_share(pool_addr: address): u128 acquires StakingPool {
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<StakingPool>(pool_addr).accumulated_per_share
    }

    #[view]
    public fun pool_rate_per_sec(pool_addr: address): u64 acquires StakingPool {
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<StakingPool>(pool_addr).rate_per_sec
    }

    #[view]
    public fun unlock_forever_marker(): u64 { UNLOCK_FOREVER }

    #[view]
    public fun default_rate_per_sec(): u64 { DEFAULT_RATE_PER_SEC }

    #[view]
    public fun acc_scale(): u128 { ACC_SCALE }

    #[test]
    fun test_unlock_forever_marker_is_u64_max() {
        assert!(unlock_forever_marker() == 18446744073709551615u64, 1);
    }

    #[test]
    fun test_default_rate_per_sec_is_10_token_per_sec() {
        assert!(default_rate_per_sec() == 1_000_000_000, 1);
    }

    #[test]
    fun test_acc_scale_is_1e18() {
        assert!(acc_scale() == 1_000_000_000_000_000_000, 1);
    }

    #[test]
    fun test_staking_pool_address_deterministic() {
        assert!(
            staking_pool_address_of_handle(b"alice") == staking_pool_address_of_handle(b"alice"),
            1
        );
    }

    #[test]
    fun test_staking_pool_addr_unique_per_handle() {
        assert!(
            staking_pool_address_of_handle(b"alice") != staking_pool_address_of_handle(b"bob"),
            1
        );
    }

    #[test]
    fun test_pool_seed_differs_per_handle() {
        assert!(pool_seed(&b"alice") != pool_seed(&b"alice2"), 1);
    }

    #[test]
    fun test_emission_depletion_eta_calculation() {
        let total_emission = 90_000_000_000_000_000u64;
        let secs_to_deplete = total_emission / default_rate_per_sec();
        assert!(secs_to_deplete == 90_000_000, 1);
    }

    #[test]
    fun test_staking_pool_seed_differs_from_amm_pool_seed() {
        assert!(
            staking_pool_address_of_handle(b"alice") != amm::pool_address_of_handle(b"alice"),
            1
        );
    }
}
