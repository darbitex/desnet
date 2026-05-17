module desnet::pulse {
    use std::bcs;
    use std::signer;
    use std::option;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;

    const REACTION_SPARK: u8 = 1;
    const REACTION_ECHO: u8 = 2;

    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    const E_GUEST_CANNOT_REACT: u64 = 1;
    const E_INVALID_REACTION_KIND: u64 = 2;
    const E_GATE_FAILED: u64 = 3;
    const E_ALREADY_REACTED: u64 = 4;
    const E_NOT_REACTED: u64 = 5;
    const E_REACTION_REGISTRY_NOT_INITIALIZED: u64 = 6;

    struct PidReactionRegistry has key {
        active: SmartTable<vector<u8>, bool>,
        spark_count_given: u64,
        echo_count_given: u64,
    }

    struct PulseEvent has drop, store {
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,
        state: u8,
        timestamp_secs: u64,
    }

    fun ensure_reaction_registry(pid_addr: address) {
        if (!exists<PidReactionRegistry>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidReactionRegistry {
                active: smart_table::new(),
                spark_count_given: 0,
                echo_count_given: 0,
            });
        };
    }

    public entry fun spark(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let actor_addr = signer::address_of(actor);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, true);
    }

    public entry fun unspark(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, false);
    }

    public entry fun echo(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let actor_addr = signer::address_of(actor);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, true);
    }

    public entry fun unecho(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, false);
    }

    fun check_mint_gate_or_self_exempt(
        actor_addr: address,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,
    ) {
        if (actor_pid == target_author) return;

        let gate_opt = mint::get_mint_gate(target_author, target_seq);
        if (option::is_none(&gate_opt)) return;

        let target_pid = profile::reference_gate_target_pid(option::borrow(&gate_opt));
        let synced = link::is_synced(actor_pid, target_pid);

        let gate = option::extract(&mut gate_opt);
        assert!(
            reference_gate::check(&gate, actor_addr, synced, false, actor_stake_position_addr),
            E_GATE_FAILED
        );
    }

    fun toggle_reaction(
        actor_pid: address,
        key: &vector<u8>,
        reaction_kind: u8,
        target_author: address,
        target_seq: u64,
        adding: bool,
    ) acquires PidReactionRegistry {
        assert!(exists<PidReactionRegistry>(actor_pid), E_REACTION_REGISTRY_NOT_INITIALIZED);
        let reg = borrow_global_mut<PidReactionRegistry>(actor_pid);

        if (adding) {
            assert!(!smart_table::contains(&reg.active, *key), E_ALREADY_REACTED);
            smart_table::add(&mut reg.active, *key, true);
            if (reaction_kind == REACTION_SPARK) {
                reg.spark_count_given = reg.spark_count_given + 1;
            } else {
                reg.echo_count_given = reg.echo_count_given + 1;
            };
        } else {
            assert!(smart_table::contains(&reg.active, *key), E_NOT_REACTED);
            smart_table::remove(&mut reg.active, *key);
            if (reaction_kind == REACTION_SPARK) {
                if (reg.spark_count_given > 0) reg.spark_count_given = reg.spark_count_given - 1;
            } else {
                if (reg.echo_count_given > 0) reg.echo_count_given = reg.echo_count_given - 1;
            };
        };

        let now_secs = timestamp::now_seconds();
        let record = PulseEvent {
            actor_pid,
            target_author,
            target_seq,
            reaction_kind,
            state: if (adding) STATE_ADD else STATE_REMOVE,
            timestamp_secs: now_secs,
        };

        let verb = if (reaction_kind == REACTION_SPARK) {
            history::verb_spark()
        } else {
            history::verb_echo()
        };

        let payload = bcs::to_bytes(&record);
        history::append(
            actor_pid,
            history::new_entry(verb, now_secs, option::some(target_author), payload, option::none<address>()),
        );
    }

    fun make_key(target_author: address, target_seq: u64, reaction_kind: u8): vector<u8> {
        let key = std::bcs::to_bytes(&target_author);
        std::vector::append(&mut key, std::bcs::to_bytes(&target_seq));
        std::vector::push_back(&mut key, reaction_kind);
        key
    }

    #[view]
    public fun has_reacted(
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,
    ): bool acquires PidReactionRegistry {
        if (!exists<PidReactionRegistry>(actor_pid)) return false;
        let key = make_key(target_author, target_seq, reaction_kind);
        smart_table::contains(&borrow_global<PidReactionRegistry>(actor_pid).active, key)
    }

    #[view]
    public fun spark_kind(): u8 { REACTION_SPARK }

    #[view]
    public fun echo_kind(): u8 { REACTION_ECHO }

    #[view]
    public fun state_add(): u8 { STATE_ADD }

    #[view]
    public fun state_remove(): u8 { STATE_REMOVE }
}
