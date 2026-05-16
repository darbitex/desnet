/// Link — Sync action + PidSyncSet on-chain state (LOCKED 2026-05-01).
///
/// Sync = subscribe to a PID's mints. Unidirectional like node-syncs-to-chain.
/// ENDORSE removed from link_kind enum (= derived view from LP staking position).
///
/// LinkEvent { link_kind: SYNC, state: ADD/REMOVE } — kept ADD/REMOVE pattern
/// (Supra events immutable on emit; un-action emits state=REMOVE).
///
/// PidSyncSet at syncer's PID (NOT target's). Target has count only — popular
/// accounts can't afford full follower-list resource. Indexer derives "who syncs
/// me" from event stream.
///
/// sync_gate (profile-level) gates incoming Sync requests: must pass
/// ReferenceGate.check(actor, target_pid, skip_sync_check=true). Sync precondition
/// itself is skipped (chicken-egg avoidance — first sync to gated PID).
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

    // ============ CONSTANTS ============

    /// link_kind enum (LinkEvent.link_kind)
    const LINK_SYNC: u8 = 1;
    // ENDORSE removed 2026-05-01 — derived from LP staking, not on-chain link_kind.

    /// state enum (LinkEvent.state)
    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    // ============ ERROR CODES ============

    const E_NOT_PID: u64 = 1;
    const E_TARGET_NOT_PID: u64 = 2;
    const E_SYNC_GATE_FAILED: u64 = 3;
    const E_ALREADY_SYNCED: u64 = 4;
    const E_NOT_SYNCED: u64 = 5;
    const E_SELF_SYNC_DISALLOWED: u64 = 6;
    const E_SYNC_SET_NOT_INITIALIZED: u64 = 7;

    // ============ TYPES ============

    /// Per-PID sync set. Stored at syncer's PID Object addr.
    /// `syncs: SmartTable<target_pid, true>` — set semantic, value unused.
    struct PidSyncSet has key {
        syncs: SmartTable<address, bool>,
        sync_count: u64,                    // # of PIDs I sync (= len of syncs table)
        synced_by_count: u64,               // # of PIDs that sync to me (incremented externally via friend)
    }

    // ============ EVENTS ============

    /// Link record (Sync/Unsync). Replaces former #[event] — now BCS-encoded into
    /// history::Entry.payload. Struct retained for canonical encoding.
    struct LinkEvent has drop, store {
        actor_pid: address,
        target_pid: address,
        link_kind: u8,                      // LINK_SYNC only (others removed)
        state: u8,                          // STATE_ADD or STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidSyncSet at PID addr. Called from sync/unsync on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
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

    // ============ SYNC + UNSYNC ENTRIES ============

    /// Sync to target_pid. Adds to syncer's PidSyncSet, increments target's
    /// synced_by_count, emits LinkEvent { kind=SYNC, state=ADD }.
    ///
    /// Validation:
    /// - Syncer must be Named tier (Profile exists at syncer's PID)
    /// - target_pid must be Named tier
    /// - target's sync_gate (if set) must pass for syncer (skip_sync_check=true)
    /// - No self-sync
    /// - Not already synced
    public entry fun sync(
        syncer: &signer,
        syncer_pid: address,
        target_pid: address,
        syncer_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidSyncSet {
        profile::assert_authorized(syncer, syncer_pid);
        let syncer_addr = signer::address_of(syncer);

        profile::assert_pid_exists(target_pid);
        assert!(syncer_pid != target_pid, E_SELF_SYNC_DISALLOWED);

        // sync_gate check — skip_sync_check=true (chicken-egg avoidance: can't require
        // sync precondition for the action that creates sync). Sync param is irrelevant
        // when skip_sync_check=true; pass false for clarity.
        let gate_opt = profile::get_sync_gate(target_pid);
        assert!(
            reference_gate::is_open_for(&gate_opt, syncer_addr, false, true, syncer_stake_position_addr),
            E_SYNC_GATE_FAILED
        );

        // Lazy-init both syncer's + target's sync set (target needs synced_by_count counter)
        ensure_sync_set(syncer_pid);
        ensure_sync_set(target_pid);

        let set = borrow_global_mut<PidSyncSet>(syncer_pid);
        assert!(!smart_table::contains(&set.syncs, target_pid), E_ALREADY_SYNCED);
        smart_table::add(&mut set.syncs, target_pid, true);
        set.sync_count = set.sync_count + 1;

        // Target's synced_by_count (lazy-init guaranteed by ensure_sync_set above)
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

    /// Unsync from target_pid. Removes from syncer's PidSyncSet, decrements counts,
    /// emits LinkEvent { kind=SYNC, state=REMOVE }.
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

    // ============ VIEWS ============

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
