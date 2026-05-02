/// LP Position NFT — V3-style position management + emission + fee claims (LOCKED 2026-05-02).
///
/// LP repr: each position = an Object (NFT-style). NO LP FA exists.
/// Auth model: `object::owner(position)` — V3 NFT semantics. Position transferable.
/// Three position kinds via `unlock_at_secs` marker on unified `Position` struct:
///   1. **LockedPosition (creator atomic)** — unlock_at_secs = u64::MAX (never).
///      Stored AT pid_addr. Recipient at claim = object::owner(pid_obj) [auto-follows NFT transfer].
///   2. **FreePosition** — unlock_at_secs = 0 (anytime withdraw). Recipient = object::owner(position).
///   3. **TimeLockedPosition** — unlock_at_secs > 0 (withdraw after t). Recipient = object::owner(position).
///
/// Universal yield (LOCKED 2026-05-02): ALL positions earn:
///   - **Swap fees (APT + TOKEN)** — proportional to shares / amm.lp_supply
///   - **Emission ($TOKEN from 900M reserve)** — C-variant, 10/sec, denominator = amm.lp_supply
///
/// No "raw LP forfeits" mechanic. No staked-vs-unstaked distinction. Free, time-locked,
/// locked all earn identically. The only difference is exit option (unlock_at).
///
/// Forever-lock invariant (structural): for unlock_at=u64::MAX, `unstake` aborts before
/// calling `amm::remove_liquidity_internal`. LP reserves never returned. Forever-locked.
module desnet::lp_staking {
    use std::signer;
    use std::vector;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, ObjectCore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use desnet::amm;
    use desnet::governance;
    use desnet::lp_emission;
    use desnet::voter_history;

    friend desnet::factory;

    // ============ CONSTANTS ============

    /// Default emission rate: 10 $TOKEN/sec at 8 dec = 1e9 raw/sec.
    const DEFAULT_RATE_PER_SEC: u64 = 1_000_000_000;

    const ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    /// Forever marker.
    const UNLOCK_FOREVER: u64 = 18446744073709551615;

    const SEED_STAKING_POOL: vector<u8> = b"desnet::lp_staking::pool::";

    // ============ ERROR CODES ============

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

    // ============ TYPES ============

    /// Per-handle staking emission state. C-variant: rate fixed per pool,
    /// accumulated_per_share advances on every stake/unstake/claim.
    /// Denominator = amm::lp_supply(handle) (universal — all Position.shares contribute).
    struct StakingPool has key {
        handle: vector<u8>,
        token_metadata_addr: address,
        rate_per_sec: u64,
        accumulated_per_share: u128,
        last_update_secs: u64,
        emission_reserve_addr: address,
        extend_ref: ExtendRef,
    }

    /// Unified Position. NFT-style (Object with object::owner-based auth).
    /// Stored at pid_addr (creator-locked) OR staker-derived addr (free/time-locked).
    struct Position has key {
        pool_addr: address,
        handle: vector<u8>,
        shares: u128,                                 // logical LP units
        last_acc_per_share: u128,                     // emission snapshot
        last_fee_per_lp_apt: u128,                    // APT fee snapshot
        last_fee_per_lp_token: u128,                  // TOKEN fee snapshot
        unlock_at_secs: u64,                          // 0=free, t=until-t, MAX=forever
        recipient_pid: address,                       // @0x0 → pay object::owner(position); else → object::owner(pid)
    }

    // ============ EVENTS ============

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
        kind: u8,                                     // 1=locked-creator, 2=free, 3=time-locked
    }

    #[event]
    struct PositionRemoved has drop, store {
        handle: vector<u8>,
        position_addr: address,
        owner: address,
        shares: u128,
        apt_returned: u64,
        token_returned: u64,
    }

    #[event]
    struct Claimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        emission_amount: u64,
        apt_fee_amount: u64,
        token_fee_amount: u64,
    }

    // ============ ADDR DERIVATION ============

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

    // ============ CREATE — friend-only (factory atomic at register) ============

    /// Create StakingPool + LockedPosition at pid_addr with creator's initial LP.
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

        // Snapshot fee accumulators at creation
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);

        move_to(pid_signer, Position {
            pool_addr,
            handle,
            shares: initial_shares,
            last_acc_per_share: 0,
            last_fee_per_lp_apt: fee_per_apt,
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

    // ============ ADD LIQUIDITY — public entries ============

    /// Public add liquidity. Withdraws APT + TOKEN from caller, calls amm::add_liquidity_internal,
    /// creates Position (kind = free, unlock_at = 0). Returns nothing — Position is at caller-derived addr.
    /// Frontend reads PositionCreated event for position_addr.
    public entry fun add_liquidity(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
    ) acquires StakingPool {
        let unlock_at_secs = 0u64;
        add_liquidity_with_lock_internal(caller, handle, apt_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    /// Public add liquidity with time-lock. Position cannot be removed until unlock_at_secs.
    public entry fun add_liquidity_with_lock(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let now = timestamp::now_seconds();
        assert!(unlock_at_secs > now, E_LOCK_DURATION_INVALID);
        add_liquidity_with_lock_internal(caller, handle, apt_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    fun add_liquidity_with_lock_internal(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let caller_addr = signer::address_of(caller);
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);

        // Withdraw APT (Coin → FA)
        let apt_coin = coin::withdraw<AptosCoin>(caller, apt_amount);
        let apt_fa = coin::coin_to_fungible_asset(apt_coin);

        // Withdraw TOKEN (FA from primary store)
        let pool = borrow_global<StakingPool>(pool_addr);
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        let token_fa = primary_fungible_store::withdraw(caller, token_meta, token_amount);

        // Mint LP shares via amm. M1 fix (audit R1): refund surplus on ratio mismatch.
        let (lp_minted, apt_refund, token_refund) =
            amm::add_liquidity_internal(handle, apt_fa, token_fa, min_lp_out);
        assert!(lp_minted > 0, E_ZERO_SHARES);
        if (fungible_asset::amount(&apt_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, apt_refund);
        } else {
            fungible_asset::destroy_zero(apt_refund);
        };
        if (fungible_asset::amount(&token_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, token_refund);
        } else {
            fungible_asset::destroy_zero(token_refund);
        };

        // Update emission accumulator BEFORE snapshotting position
        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let snapshot_acc = pool.accumulated_per_share;
        let pool_handle = pool.handle;

        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);

        // Create Position object owned by caller (NFT-style)
        let constructor = object::create_object(caller_addr);
        let pos_signer = object::generate_signer(&constructor);
        let pos_addr = signer::address_of(&pos_signer);

        move_to(&pos_signer, Position {
            pool_addr,
            handle,
            shares: lp_minted,
            last_acc_per_share: snapshot_acc,
            last_fee_per_lp_apt: fee_per_apt,
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

    // ============ REMOVE LIQUIDITY — public, gated by unlock_at ============

    /// Caller must be Position object owner (NFT semantics — Position is transferable).
    /// Forever-locked positions can NEVER unstake. Auto-claims pending before destroy.
    public entry fun remove_liquidity(
        caller: &signer,
        position_addr: address,
        min_apt_out: u64,
        min_token_out: u64,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let position = borrow_global<Position>(position_addr);
        let unlock_at = position.unlock_at_secs;
        let pool_addr = position.pool_addr;
        let handle = position.handle;
        let position_obj = object::address_to_object<Position>(position_addr);
        let position_owner = object::owner(position_obj);

        // Auth: caller must be current owner of Position object
        assert!(signer::address_of(caller) == position_owner, E_NOT_POSITION_OWNER);

        // Forever-lock check
        assert!(unlock_at != UNLOCK_FOREVER, E_LOCKED_FOREVER);
        let now = timestamp::now_seconds();
        assert!(now >= unlock_at, E_LOCKED_NOT_YET_UNLOCKED);

        // Auto-claim before destroy
        claim_internal(position_addr);

        // Now destroy position + return reserves
        let Position {
            pool_addr: _,
            handle: _,
            shares,
            last_acc_per_share: _,
            last_fee_per_lp_apt: _,
            last_fee_per_lp_token: _,
            unlock_at_secs: _,
            recipient_pid: _,
        } = move_from<Position>(position_addr);

        let (apt_fa, token_fa) = amm::remove_liquidity_internal(handle, shares, min_apt_out, min_token_out);
        let apt_returned = fungible_asset::amount(&apt_fa);
        let token_returned = fungible_asset::amount(&token_fa);

        primary_fungible_store::deposit(position_owner, apt_fa);
        primary_fungible_store::deposit(position_owner, token_fa);

        let pool_handle_dummy = handle;
        event::emit(PositionRemoved {
            handle: pool_handle_dummy,
            position_addr,
            owner: position_owner,
            shares,
            apt_returned,
            token_returned,
        });
    }

    // ============ CLAIM — permissionless triple-settle ============

    /// Anyone can poke. Recipient resolved at claim:
    /// - recipient_pid != @0x0 → object::owner(pid) [auto-follows NFT transfer]
    /// - recipient_pid == @0x0 → object::owner(position) [Position transfer = recipient transfer]
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

        // 1. Update + read emission accumulator
        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let acc = pool.accumulated_per_share;
        let pending_emission_u128 = ((acc - position.last_acc_per_share) * shares_u128) / ACC_SCALE;
        position.last_acc_per_share = acc;

        // 2. Read amm fee accumulators
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt_u128 = ((fee_per_apt - position.last_fee_per_lp_apt) * shares_u128) / amm_scale;
        let pending_token_u128 = ((fee_per_token - position.last_fee_per_lp_token) * shares_u128) / amm_scale;
        position.last_fee_per_lp_apt = fee_per_apt;
        position.last_fee_per_lp_token = fee_per_token;

        let pending_emission = (pending_emission_u128 as u64);
        let pending_apt = (pending_apt_u128 as u64);
        let pending_token = (pending_token_u128 as u64);

        // 3. Resolve recipient
        let recipient = resolve_recipient(position.recipient_pid, position_addr);

        // 4. Pull emission ($TOKEN) from lp_emission reserve.
        //    H2 fix (audit R1): record voting power for ACTUAL paid amount, not requested.
        //    pull_for_claim caps at reserve balance (graceful depletion); recording
        //    pending_emission would inflate voting power post-depletion at zero cost.
        if (pending_emission > 0) {
            let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
            let emission_fa = lp_emission::pull_for_claim(
                pool.emission_reserve_addr,
                token_meta,
                pending_emission,
            );
            let actual_paid = fungible_asset::amount(&emission_fa);
            primary_fungible_store::deposit(recipient, emission_fa);

            if (actual_paid > 0) {
                let pkg_signer = governance::derive_pkg_signer();
                // v0.3.2 (F7): record per-token (also writes legacy mixed for compat).
                // Token addr is the pool's emission token = current pool.token_metadata_addr.
                voter_history::record_reward_received_for_token(
                    &pkg_signer,
                    recipient,
                    pool.token_metadata_addr,
                    actual_paid,
                );
                // v0.3.2 (F6): feed the 30d auto-tracker so DAO threshold/quorum
                // become driven by actual emission flow (eliminates manipulation
                // surface of multisig::update_total_30d_emission).
                governance::record_emission_for_window(actual_paid);
            };
        };

        // 5. Pull LP fees (APT + TOKEN)
        if (pending_apt > 0 || pending_token > 0) {
            let (apt_fa, token_fa) = amm::extract_fees_for_claim(handle, pending_apt, pending_token);
            if (fungible_asset::amount(&apt_fa) > 0) {
                primary_fungible_store::deposit(recipient, apt_fa);
            } else {
                fungible_asset::destroy_zero(apt_fa);
            };
            if (fungible_asset::amount(&token_fa) > 0) {
                primary_fungible_store::deposit(recipient, token_fa);
            } else {
                fungible_asset::destroy_zero(token_fa);
            };
        };

        if (pending_emission == 0 && pending_apt == 0 && pending_token == 0) return;

        event::emit(Claimed {
            handle: pool.handle,
            position_addr,
            recipient,
            emission_amount: pending_emission,
            apt_fee_amount: pending_apt,
            token_fee_amount: pending_token,
        });
    }

    fun resolve_recipient(recipient_pid: address, position_addr: address): address {
        if (recipient_pid == @0x0) {
            // Free / time-locked: recipient = current Position object owner
            let pos_obj = object::address_to_object<Position>(position_addr);
            object::owner(pos_obj)
        } else {
            // Locked-creator: recipient = current PID NFT owner
            let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
            object::owner(pid_obj)
        }
    }

    // ============ INTERNAL — emission accumulator (C-variant) ============

    /// Universal denominator: amm::lp_supply(handle) — ALL positions (locked + free + time-locked).
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

    // ============ VIEWS ============

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

    /// NFT owner of position (= effective claimer for free/time-locked).
    #[view]
    public fun position_owner(position_addr: address): address {
        let pos_obj = object::address_to_object<Position>(position_addr);
        object::owner(pos_obj)
    }

    // ============ DARBITEX-SHAPE COMPOSABILITY VIEWS (Object<Position>-based) ============

    /// Pool addr containing this position. Matches darbitex `position_pool_addr(pos)`.
    #[view]
    public fun position_pool_addr(pos: Object<Position>): address acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).pool_addr
    }

    /// Per-position fee snapshots (last claim point). Matches darbitex `position_fee_debt(pos)`.
    /// Returns (last_fee_per_lp_apt, last_fee_per_lp_token).
    #[view]
    public fun position_fee_debt(pos: Object<Position>): (u128, u128) acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        let p = borrow_global<Position>(pos_addr);
        (p.last_fee_per_lp_apt, p.last_fee_per_lp_token)
    }

    /// Pending claimable LP fees only (excluding emission). Matches darbitex
    /// `position_pending_fees(pos): (u64, u64)`.
    /// For triple-settle (emission + fees), use `position_pending_all`.
    #[view]
    public fun position_pending_fees(pos: Object<Position>): (u64, u64) acquires Position {
        let pos_addr = object::object_address(&pos);
        if (!exists<Position>(pos_addr)) return (0, 0);
        let p = borrow_global<Position>(pos_addr);
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(p.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt = (((fee_per_apt - p.last_fee_per_lp_apt) * p.shares) / amm_scale) as u64;
        let pending_token = (((fee_per_token - p.last_fee_per_lp_token) * p.shares) / amm_scale) as u64;
        (pending_apt, pending_token)
    }

    /// Position shares as Object input (Object-shape for darbitex parity).
    #[view]
    public fun position_shares_obj(pos: Object<Position>): u128 acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).shares
    }

    /// Returns (pending_emission, pending_apt_fee, pending_token_fee).
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

        let pending_emission = (((acc - position.last_acc_per_share) * position.shares) / ACC_SCALE) as u64;

        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(position.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt = (((fee_per_apt - position.last_fee_per_lp_apt) * position.shares) / amm_scale) as u64;
        let pending_token = (((fee_per_token - position.last_fee_per_lp_token) * position.shares) / amm_scale) as u64;

        (pending_emission, pending_apt, pending_token)
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

    // ============ UNIT TESTS ============

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
