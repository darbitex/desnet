/// ReferenceGate — opt-in engagement policy primitive (LOCKED 2026-05-01).
///
/// Single primitive, 4 fields. Used by:
/// - Mint-level: gates Voice/Spark/Echo/Remix/Press of specific mint
/// - Profile-level (sync_gate): gates incoming Sync requests
///
/// Logic at gate check (ALL conditions must hold):
/// 1. actor.synced_to(target_pid) — sync precondition (SKIPPED for sync_gate itself, chicken-egg)
/// 2. min_token_balance ≤ actor.token_balance(target_pid_token) ≤ max_token_balance
/// 3. actor.lp_stake_balance(target_pid_lp_pool) ≥ min_lp_stake
///
/// Self-exemption: post creator always passes own gate (intuitive, prevents lock-out).
/// Sentinels for "no check": min=0, max=u64::MAX, lp_stake=0.
///
/// Cycle-safe API: caller pre-computes sync state (via link::is_synced) and passes
/// as param. reference_gate doesn't import link (would create cycle since link uses
/// reference_gate for sync_gate evaluation). Pure function design — caller orchestrates queries.
///
/// Naming consistency: ReferenceGate + MintGate + sync_gate = unified gate-family.
module desnet::reference_gate {
    use std::option::{Self, Option};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ObjectCore};
    use aptos_framework::primary_fungible_store;

    use desnet::factory;
    use desnet::lp_staking;

    // ============ ERROR CODES ============

    const E_TARGET_HAS_NO_TOKEN: u64 = 2;

    /// Single 4-field primitive struct. Stored as Option<ReferenceGate> at attach points.
    struct ReferenceGate has copy, drop, store {
        target_pid: address,           // PID whose sync + token + LP-stake to check
        min_token_balance: u64,        // 0 = no spot-balance check
        max_token_balance: u64,        // u64::MAX = no max
        min_lp_stake: u64,             // 0 = no LP-stake check
    }

    /// Constructor — frontend assembles before attach call.
    public fun new(
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ): ReferenceGate {
        ReferenceGate {
            target_pid,
            min_token_balance,
            max_token_balance,
            min_lp_stake,
        }
    }

    public fun target_pid(gate: &ReferenceGate): address { gate.target_pid }
    public fun min_token_balance(gate: &ReferenceGate): u64 { gate.min_token_balance }
    public fun max_token_balance(gate: &ReferenceGate): u64 { gate.max_token_balance }
    public fun min_lp_stake(gate: &ReferenceGate): u64 { gate.min_lp_stake }

    /// Evaluate gate against an actor.
    ///
    /// `actor_synced_to_target` must be pre-computed by caller via `link::is_synced(actor_pid, gate.target_pid)`.
    /// reference_gate doesn't query link directly (would cycle since link uses reference_gate for sync_gate).
    ///
    /// `skip_sync_check=true` for profile sync_gate path (chicken-egg avoidance: gating Sync
    /// itself can't require sync precondition). For mint-level engagement gates, false.
    ///
    /// `actor_stake_position_addr`: caller-supplied `desnet::lp_staking::Position` addr. Pass `@0x0`
    /// when gate has no LP requirement OR actor has no position. When `gate.min_lp_stake > 0`
    /// and actor passes `@0x0`, gate fails (returns false). Multi-position holders pass their
    /// largest single position; protocol does not enumerate or sum across positions.
    public fun check(
        gate: &ReferenceGate,
        actor_addr: address,
        actor_synced_to_target: bool,
        skip_sync_check: bool,
        actor_stake_position_addr: address,
    ): bool {
        // 1. Sync check
        if (!skip_sync_check && !actor_synced_to_target) {
            return false
        };

        // 2. Token balance check (skip if both bounds are sentinels = no check)
        let no_min = gate.min_token_balance == 0;
        let no_max = gate.max_token_balance == 18446744073709551615u64;  // u64::MAX
        if (!(no_min && no_max)) {
            // Resolve target's token via factory reverse lookup
            if (!factory::owner_has_token(gate.target_pid)) {
                // Target PID has no factory-spawned token → balance check impossible
                return false
            };
            let token_addr = factory::token_metadata_of_owner(gate.target_pid);
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let balance = primary_fungible_store::balance(actor_addr, token_metadata);
            if (balance < gate.min_token_balance) return false;
            if (balance > gate.max_token_balance) return false;
        };

        // 3. LP stake check (via desnet::lp_staking::Position)
        // Caller-supplied evidence pattern: actor passes their Position addr.
        // Trust-but-verify: we check pool linkage + ownership/recipient + shares.
        if (gate.min_lp_stake > 0) {
            if (actor_stake_position_addr == @0x0) return false;
            if (!lp_staking::has_position(actor_stake_position_addr)) return false;

            // Pool linkage: position's pool must match target_pid's lp_staking_pool
            if (!factory::owner_has_token(gate.target_pid)) return false;
            let expected_pool = factory::lp_staking_pool_of_owner(gate.target_pid);
            let pos_pool = lp_staking::position_pool(actor_stake_position_addr);
            if (pos_pool != expected_pool) return false;

            // Ownership: free/time-locked → object::owner(position) == actor.
            // Locked (recipient_pid != @0x0) → current PID owner == actor.
            let recipient_pid = lp_staking::position_recipient_pid(actor_stake_position_addr);
            if (recipient_pid == @0x0) {
                if (lp_staking::position_owner(actor_stake_position_addr) != actor_addr) return false;
            } else {
                let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
                if (object::owner(pid_obj) != actor_addr) return false;
            };

            // Shares ≥ threshold (u128 to u64 comparison)
            let shares = lp_staking::position_shares(actor_stake_position_addr);
            if (shares < (gate.min_lp_stake as u128)) return false;
        };

        true
    }

    /// Convenience wrapper for Option<ReferenceGate>: None = open access (always pass).
    public fun is_open_for(
        gate_opt: &Option<ReferenceGate>,
        actor_addr: address,
        actor_synced_to_target: bool,
        skip_sync_check: bool,
        actor_stake_position_addr: address,
    ): bool {
        if (option::is_none(gate_opt)) return true;
        check(option::borrow(gate_opt), actor_addr, actor_synced_to_target, skip_sync_check, actor_stake_position_addr)
    }

    // ============ TESTS ============

    #[test]
    fun test_new_and_getters() {
        let g = new(@0xfeed, 100, 1000, 50);
        assert!(target_pid(&g) == @0xfeed, 1);
        assert!(min_token_balance(&g) == 100, 2);
        assert!(max_token_balance(&g) == 1000, 3);
        assert!(min_lp_stake(&g) == 50, 4);
    }

    #[test]
    fun test_is_open_for_none_gate_passes() {
        // No gate set = always open
        let none_gate = option::none<ReferenceGate>();
        assert!(is_open_for(&none_gate, @0x1, false, false, @0x0), 1);
        assert!(is_open_for(&none_gate, @0x1, false, true, @0x0), 2);
    }

    #[test]
    fun test_check_sync_required_fails_when_not_synced() {
        // Gate with sentinel min/max balance + zero lp_stake → only sync matters
        let g = new(@0xfeed, 0, 18446744073709551615u64, 0);
        // Actor not synced + skip_sync_check=false → fail
        assert!(!check(&g, @0x1, false, false, @0x0), 1);
    }

    #[test]
    fun test_check_sync_skipped_passes_no_other_constraints() {
        // skip_sync_check=true (sync_gate path) + sentinels for balance + 0 lp_stake → pass
        let g = new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(check(&g, @0x1, false, true, @0x0), 1);
    }
}
