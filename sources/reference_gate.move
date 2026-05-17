module desnet::reference_gate {
    use std::option::{Self, Option};
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::Self;
    use supra_framework::primary_fungible_store;

    use desnet::factory;
    use desnet::profile;
    use desnet::profile::ReferenceGate;

    const E_TARGET_HAS_NO_TOKEN: u64 = 2;

    public fun check(
        gate: &ReferenceGate,
        actor_addr: address,
        actor_synced_to_target: bool,
        skip_sync_check: bool,
        actor_stake_position_addr: address,
    ): bool {
        if (!skip_sync_check && !actor_synced_to_target) {
            return false
        };

        let no_min = profile::reference_gate_min_token_balance(gate) == 0;
        let no_max = profile::reference_gate_max_token_balance(gate) == 18446744073709551615u64;
        if (!(no_min && no_max)) {
            if (!factory::owner_has_token(profile::reference_gate_target_pid(gate))) {
                return false
            };
            let token_addr = factory::token_metadata_of_owner(profile::reference_gate_target_pid(gate));
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let balance = primary_fungible_store::balance(actor_addr, token_metadata);
            if (balance < profile::reference_gate_min_token_balance(gate)) return false;
            if (balance > profile::reference_gate_max_token_balance(gate)) return false;
        };

        true
    }

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
        let none_gate = option::none<ReferenceGate>();
        assert!(is_open_for(&none_gate, @0x1, false, false, @0x0), 1);
        assert!(is_open_for(&none_gate, @0x1, false, true, @0x0), 2);
    }

    #[test]
    fun test_check_sync_required_fails_when_not_synced() {
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(!check(&g, @0x1, false, false, @0x0), 1);
    }

    #[test]
    fun test_check_sync_skipped_passes_no_other_constraints() {
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(check(&g, @0x1, false, true, @0x0), 1);
    }
}
