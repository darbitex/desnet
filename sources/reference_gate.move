/// ReferenceGate - opt-in engagement policy primitive (LOCKED 2026-05-01).
///
/// Single primitive, 4 fields. Used by:
/// - Mint-level: gates Voice/Spark/Echo/Remix/Press of specific mint
/// - Profile-level (sync_gate): gates incoming Sync requests
///
/// Logic at gate check (ALL conditions must hold):
/// 1. actor.synced_to(target_pid) - sync precondition (SKIPPED for sync_gate itself, chicken-egg)
/// 2. min_token_balance <= actor.token_balance(target_pid_token) <= max_token_balance
/// 3. LP stake check - removed in IPO model
///
/// Self-exemption: post creator always passes own gate (intuitive, prevents lock-out).
/// Sentinels for "no check": min=0, max=u64::MAX, lp_stake=0.
///
/// Cycle-safe API: caller pre-computes sync state (via link::is_synced) and passes
/// as param. reference_gate doesn't import link (would create cycle since link uses
/// reference_gate for sync_gate evaluation). Pure function design - caller orchestrates queries.
///
/// Naming consistency: ReferenceGate + MintGate + sync_gate = unified gate-family.
module desnet::reference_gate {
    use std::option::{Self, Option};
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::Self;
    use supra_framework::primary_fungible_store;

    use desnet::factory;
    use desnet::profile;
    use desnet::profile::ReferenceGate;

    // ============ ERROR CODES ============

    const E_TARGET_HAS_NO_TOKEN: u64 = 2;

    /// Evaluate gate against an actor.
    ///
    /// `actor_synced_to_target` must be pre-computed by caller via `link::is_synced(actor_pid, gate.target_pid)`.
    /// reference_gate doesn't query link directly (would cycle since link uses reference_gate for sync_gate).
    ///
    /// `skip_sync_check=true` for profile sync_gate path (chicken-egg avoidance: gating Sync
    /// itself can't require sync precondition). For mint-level engagement gates, false.
    ///
    /// `actor_stake_position_addr`: unused in IPO model (LP stake check removed). Pass `@0x0`.
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
        let no_min = profile::reference_gate_min_token_balance(gate) == 0;
        let no_max = profile::reference_gate_max_token_balance(gate) == 18446744073709551615u64;  // u64::MAX
        if (!(no_min && no_max)) {
            // Resolve target's token via factory reverse lookup
            if (!factory::owner_has_token(profile::reference_gate_target_pid(gate))) {
                // Target PID has no factory-spawned token -> balance check impossible
                return false
            };
            let token_addr = factory::token_metadata_of_owner(profile::reference_gate_target_pid(gate));
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let balance = primary_fungible_store::balance(actor_addr, token_metadata);
            if (balance < profile::reference_gate_min_token_balance(gate)) return false;
            if (balance > profile::reference_gate_max_token_balance(gate)) return false;
        };

        // 3. LP stake check - removed in IPO model (LP is locked in AMM pool, no staking)

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
        let g = profile::reference_gate_new(@0xfeed, 100, 1000, 50);
        assert!(profile::reference_gate_target_pid(&g) == @0xfeed, 1);
        assert!(profile::reference_gate_min_token_balance(&g) == 100, 2);
        assert!(profile::reference_gate_max_token_balance(&g) == 1000, 3);
        assert!(profile::reference_gate_min_lp_stake(&g) == 50, 4);
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
        // Gate with sentinel min/max balance + zero lp_stake -> only sync matters
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        // Actor not synced + skip_sync_check=false -> fail
        assert!(!check(&g, @0x1, false, false, @0x0), 1);
    }

    #[test]
    fun test_check_sync_skipped_passes_no_other_constraints() {
        // skip_sync_check=true (sync_gate path) + sentinels for balance + 0 lp_stake -> pass
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(check(&g, @0x1, false, true, @0x0), 1);
    }
}
