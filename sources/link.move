module desnet::link {
    use std::bcs;
    use std::signer;
    use std::option;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::profile::ReferenceGate;
    use desnet::reference_gate;
    use desnet::history;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    const LINK_SYNC: u8 = 1;

    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    const E_NOT_PID: u64 = 1;
    const E_TARGET_NOT_PID: u64 = 2;
    const E_SYNC_GATE_FAILED: u64 = 3;
    const E_ALREADY_SYNCED: u64 = 4;
    const E_NOT_SYNCED: u64 = 5;
    const E_SELF_SYNC_DISALLOWED: u64 = 6;
    const E_SYNC_SET_NOT_INITIALIZED: u64 = 7;

    struct PidSyncSet has key {
        syncs: SmartTable<address, bool>,
        sync_count: u64,
        synced_by_count: u64,
    }

    struct LinkEvent has drop, store {
        actor_pid: address,
        target_pid: address,
        link_kind: u8,
        state: u8,
        timestamp_secs: u64,
    }

    fun ensure_sync_set(pid_addr: address) {
        if (!exists<PidSyncSet>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidSyncSet {
                syncs: smart_table::new(),
                sync_count: 0,
                synced_by_count: 0,
            });
        };
    }

    public entry fun sync(
        syncer: &signer,
        syncer_pid: address,
        target_pid: address,
        syncer_stake_position_addr: address,
    ) acquires PidSyncSet {
        profile::assert_authorized(syncer, syncer_pid);
        let syncer_addr = signer::address_of(syncer);

        profile::assert_pid_exists(target_pid);
        assert!(syncer_pid != target_pid, E_SELF_SYNC_DISALLOWED);

        let gate_opt = profile::get_sync_gate(target_pid);
        assert!(
            reference_gate::is_open_for(&gate_opt, syncer_addr, false, true, syncer_stake_position_addr),
            E_SYNC_GATE_FAILED
        );

        ensure_sync_set(syncer_pid);
        ensure_sync_set(target_pid);

        let set = borrow_global_mut<PidSyncSet>(syncer_pid);
        assert!(!smart_table::contains(&set.syncs, target_pid), E_ALREADY_SYNCED);
        smart_table::add(&mut set.syncs, target_pid, true);
        set.sync_count = set.sync_count + 1;

        let target_set = borrow_global_mut<PidSyncSet>(target_pid);
        target_set.synced_by_count = target_set.synced_by_count + 1;

        let now_secs = timestamp::now_seconds();
        let record = LinkEvent {
            actor_pid: syncer_pid,
            target_pid,
            link_kind: LINK_SYNC,
            state: STATE_ADD,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        history::append(
            syncer_pid,
            history::new_entry(history::verb_sync(), now_secs, option::some(target_pid), payload, option::none<address>()),
        );
    }

    public entry fun unsync(
        syncer: &signer,
        syncer_pid: address,
        target_pid: address,
    ) acquires PidSyncSet {
        profile::assert_authorized(syncer, syncer_pid);

        assert!(exists<PidSyncSet>(syncer_pid), E_SYNC_SET_NOT_INITIALIZED);
        let set = borrow_global_mut<PidSyncSet>(syncer_pid);
        assert!(smart_table::contains(&set.syncs, target_pid), E_NOT_SYNCED);
        smart_table::remove(&mut set.syncs, target_pid);
        set.sync_count = set.sync_count - 1;

        if (exists<PidSyncSet>(target_pid)) {
            let target_set = borrow_global_mut<PidSyncSet>(target_pid);
            if (target_set.synced_by_count > 0) {
                target_set.synced_by_count = target_set.synced_by_count - 1;
            };
        };

        let now_secs = timestamp::now_seconds();
        let record = LinkEvent {
            actor_pid: syncer_pid,
            target_pid,
            link_kind: LINK_SYNC,
            state: STATE_REMOVE,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        history::append(
            syncer_pid,
            history::new_entry(history::verb_sync(), now_secs, option::some(target_pid), payload, option::none<address>()),
        );
    }

    #[view]
    public fun is_synced(syncer_pid: address, target_pid: address): bool acquires PidSyncSet {
        if (!exists<PidSyncSet>(syncer_pid)) return false;
        smart_table::contains(&borrow_global<PidSyncSet>(syncer_pid).syncs, target_pid)
    }

    #[view]
    public fun sync_count(pid_addr: address): u64 acquires PidSyncSet {
        if (!exists<PidSyncSet>(pid_addr)) return 0;
        borrow_global<PidSyncSet>(pid_addr).sync_count
    }

    #[view]
    public fun synced_by_count(pid_addr: address): u64 acquires PidSyncSet {
        if (!exists<PidSyncSet>(pid_addr)) return 0;
        borrow_global<PidSyncSet>(pid_addr).synced_by_count
    }

    #[view]
    public fun sync_kind(): u8 { LINK_SYNC }

    #[view]
    public fun state_add(): u8 { STATE_ADD }

    #[view]
    public fun state_remove(): u8 { STATE_REMOVE }
}
