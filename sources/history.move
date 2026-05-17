module desnet::history {
    use std::option::Option;
    use std::signer;
    use std::vector;
    use supra_framework::object;

    use desnet::profile;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::link;
    friend desnet::press;
    friend desnet::opinion;

    const VERB_MINT: u8 = 0;
    const VERB_SPARK: u8 = 1;
    const VERB_VOICE: u8 = 2;
    const VERB_ECHO: u8 = 3;
    const VERB_REMIX: u8 = 4;
    const VERB_PRESS: u8 = 5;
    const VERB_SYNC: u8 = 6;
    const VERB_OPINION: u8 = 7;

    const CHUNK_ROTATE_THRESHOLD: u64 = 30000;

    const MAX_PAYLOAD_BYTES: u64 = 12000;

    const ENTRY_OVERHEAD_BYTES: u64 = 64;

    const E_PAYLOAD_TOO_LARGE: u64 = 1;
    const E_HISTORY_NOT_INITIALIZED: u64 = 3;
    const E_CHUNK_NOT_FOUND: u64 = 4;
    const E_INVALID_VERB: u64 = 5;

    struct HistoryLog has key {
        head_chunk: address,
        sealed_chunks: vector<address>,
        entry_count: u64,
        total_bytes: u64,
        head_chunk_bytes: u64,
        mint_count: u64,
        spark_count: u64,
        voice_count: u64,
        echo_count: u64,
        remix_count: u64,
        press_count: u64,
        sync_count: u64,
    }

    struct HistoryChunk has key {
        entries: vector<Entry>,
        sealed: bool,
    }

    struct Entry has store, copy, drop {
        verb: u8,
        timestamp_secs: u64,
        target: Option<address>,
        payload: vector<u8>,
        asset: Option<address>,
    }

    public(friend) fun new_entry(
        verb: u8,
        timestamp_secs: u64,
        target: Option<address>,
        payload: vector<u8>,
        asset: Option<address>,
    ): Entry {
        assert!(verb <= VERB_OPINION, E_INVALID_VERB);
        assert!(vector::length(&payload) <= MAX_PAYLOAD_BYTES, E_PAYLOAD_TOO_LARGE);
        Entry { verb, timestamp_secs, target, payload, asset }
    }

    fun ensure_history_log(pid_addr: address) {
        if (exists<HistoryLog>(pid_addr)) return;

        let pid_signer = profile::derive_pid_signer(pid_addr);

        let chunk_constructor = object::create_object(pid_addr);
        let chunk_signer = object::generate_signer(&chunk_constructor);
        let chunk_addr = signer::address_of(&chunk_signer);
        move_to(&chunk_signer, HistoryChunk {
            entries: vector::empty(),
            sealed: false,
        });

        move_to(&pid_signer, HistoryLog {
            head_chunk: chunk_addr,
            sealed_chunks: vector::empty(),
            entry_count: 0,
            total_bytes: 0,
            head_chunk_bytes: 0,
            mint_count: 0,
            spark_count: 0,
            voice_count: 0,
            echo_count: 0,
            remix_count: 0,
            press_count: 0,
            sync_count: 0,
        });
    }

    public(friend) fun append(pid_addr: address, entry: Entry)
        acquires HistoryLog, HistoryChunk
    {
        ensure_history_log(pid_addr);

        let entry_size = vector::length(&entry.payload) + ENTRY_OVERHEAD_BYTES;

        let log = borrow_global_mut<HistoryLog>(pid_addr);
        if (log.head_chunk_bytes + entry_size > CHUNK_ROTATE_THRESHOLD) {
            let old_head = log.head_chunk;
            {
                let head_chunk = borrow_global_mut<HistoryChunk>(old_head);
                head_chunk.sealed = true;
            };
            vector::push_back(&mut log.sealed_chunks, old_head);

            let new_chunk_constructor = object::create_object(pid_addr);
            let new_chunk_signer = object::generate_signer(&new_chunk_constructor);
            let new_chunk_addr = signer::address_of(&new_chunk_signer);
            move_to(&new_chunk_signer, HistoryChunk {
                entries: vector::empty(),
                sealed: false,
            });

            log.head_chunk = new_chunk_addr;
            log.head_chunk_bytes = 0;
        };

        let verb = entry.verb;
        {
            let head = borrow_global_mut<HistoryChunk>(log.head_chunk);
            vector::push_back(&mut head.entries, entry);
        };

        log.entry_count = log.entry_count + 1;
        log.total_bytes = log.total_bytes + entry_size;
        log.head_chunk_bytes = log.head_chunk_bytes + entry_size;

        if (verb == VERB_MINT) {
            log.mint_count = log.mint_count + 1;
        } else if (verb == VERB_SPARK) {
            log.spark_count = log.spark_count + 1;
        } else if (verb == VERB_VOICE) {
            log.voice_count = log.voice_count + 1;
        } else if (verb == VERB_ECHO) {
            log.echo_count = log.echo_count + 1;
        } else if (verb == VERB_REMIX) {
            log.remix_count = log.remix_count + 1;
        } else if (verb == VERB_PRESS) {
            log.press_count = log.press_count + 1;
        } else if (verb == VERB_SYNC) {
            log.sync_count = log.sync_count + 1;
        };
    }

    #[view]
    public fun history_exists(pid_addr: address): bool {
        exists<HistoryLog>(pid_addr)
    }

    #[view]
    public fun total_entries(pid_addr: address): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        borrow_global<HistoryLog>(pid_addr).entry_count
    }

    #[view]
    public fun total_bytes(pid_addr: address): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        borrow_global<HistoryLog>(pid_addr).total_bytes
    }

    #[view]
    public fun head_chunk_addr(pid_addr: address): address acquires HistoryLog {
        assert!(exists<HistoryLog>(pid_addr), E_HISTORY_NOT_INITIALIZED);
        borrow_global<HistoryLog>(pid_addr).head_chunk
    }

    #[view]
    public fun sealed_chunks_list(pid_addr: address): vector<address> acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return vector::empty();
        borrow_global<HistoryLog>(pid_addr).sealed_chunks
    }

    #[view]
    public fun chunk_entries_count(chunk_addr: address): u64 acquires HistoryChunk {
        if (!exists<HistoryChunk>(chunk_addr)) return 0;
        vector::length(&borrow_global<HistoryChunk>(chunk_addr).entries)
    }

    #[view]
    public fun chunk_is_sealed(chunk_addr: address): bool acquires HistoryChunk {
        if (!exists<HistoryChunk>(chunk_addr)) return false;
        borrow_global<HistoryChunk>(chunk_addr).sealed
    }

    #[view]
    public fun chunk_entry_at(
        chunk_addr: address,
        idx: u64,
    ): (u8, u64, Option<address>, vector<u8>, Option<address>)
        acquires HistoryChunk
    {
        assert!(exists<HistoryChunk>(chunk_addr), E_CHUNK_NOT_FOUND);
        let entries = &borrow_global<HistoryChunk>(chunk_addr).entries;
        let e = vector::borrow(entries, idx);
        (e.verb, e.timestamp_secs, e.target, e.payload, e.asset)
    }

    #[view]
    public fun count_verb(pid_addr: address, verb: u8): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        let log = borrow_global<HistoryLog>(pid_addr);
        if (verb == VERB_MINT) log.mint_count
        else if (verb == VERB_SPARK) log.spark_count
        else if (verb == VERB_VOICE) log.voice_count
        else if (verb == VERB_ECHO) log.echo_count
        else if (verb == VERB_REMIX) log.remix_count
        else if (verb == VERB_PRESS) log.press_count
        else if (verb == VERB_SYNC) log.sync_count
        else 0
    }

    #[view]
    public fun verb_mint(): u8 { VERB_MINT }

    #[view]
    public fun verb_spark(): u8 { VERB_SPARK }

    #[view]
    public fun verb_voice(): u8 { VERB_VOICE }

    #[view]
    public fun verb_echo(): u8 { VERB_ECHO }

    #[view]
    public fun verb_remix(): u8 { VERB_REMIX }

    #[view]
    public fun verb_press(): u8 { VERB_PRESS }

    #[view]
    public fun verb_sync(): u8 { VERB_SYNC }

    #[view]
    public fun verb_opinion(): u8 { VERB_OPINION }

    #[view]
    public fun max_payload_bytes(): u64 { MAX_PAYLOAD_BYTES }

    #[view]
    public fun chunk_rotate_threshold(): u64 { CHUNK_ROTATE_THRESHOLD }

    #[test]
    fun test_new_entry_payload_at_cap() {
        let payload = vector::empty<u8>();
        let i = 0;
        while (i < MAX_PAYLOAD_BYTES) {
            vector::push_back(&mut payload, 0x42);
            i = i + 1;
        };
        let _e = new_entry(VERB_MINT, 1000, std::option::none<address>(), payload, std::option::none<address>());
    }

    #[test]
    #[expected_failure(abort_code = E_PAYLOAD_TOO_LARGE, location = Self)]
    fun test_new_entry_payload_over_cap() {
        let payload = vector::empty<u8>();
        let i = 0;
        while (i < MAX_PAYLOAD_BYTES + 1) {
            vector::push_back(&mut payload, 0x42);
            i = i + 1;
        };
        let _e = new_entry(VERB_SPARK, 0, std::option::none<address>(), payload, std::option::none<address>());
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_VERB, location = Self)]
    fun test_new_entry_invalid_verb() {
        let _e = new_entry(8, 0, std::option::none<address>(), vector::empty(), std::option::none<address>());
    }

    #[test]
    fun test_verb_constants() {
        assert!(verb_mint() == 0, 1);
        assert!(verb_spark() == 1, 2);
        assert!(verb_voice() == 2, 3);
        assert!(verb_press() == 5, 6);
        assert!(verb_echo() == 3, 4);
        assert!(verb_remix() == 4, 5);
        assert!(verb_sync() == 6, 7);
    }

    #[test_only]
    use supra_framework::timestamp;
    #[test_only]
    use supra_framework::account;
    #[test_only]
    use std::option;

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_first_append_lazy_init(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));

        let pid_addr = profile::setup_test_pid(creator);
        assert!(!history_exists(pid_addr), 1);

        let entry = new_entry(VERB_MINT, 1, option::none(), vector::empty(), option::none());
        append(pid_addr, entry);

        assert!(history_exists(pid_addr), 2);
        assert!(total_entries(pid_addr) == 1, 3);
        assert!(count_verb(pid_addr, VERB_MINT) == 1, 4);
        assert!(count_verb(pid_addr, VERB_SPARK) == 0, 5);
    }

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_verb_counters_independent(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        append(pid_addr, new_entry(VERB_SPARK, 1, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_SPARK, 2, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_SPARK, 3, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_VOICE, 4, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_ECHO, 5, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_ECHO, 6, option::none(), vector::empty(), option::none()));

        assert!(total_entries(pid_addr) == 6, 1);
        assert!(count_verb(pid_addr, VERB_SPARK) == 3, 2);
        assert!(count_verb(pid_addr, VERB_VOICE) == 1, 3);
        assert!(count_verb(pid_addr, VERB_ECHO) == 2, 4);
        assert!(count_verb(pid_addr, VERB_MINT) == 0, 5);
        assert!(count_verb(pid_addr, VERB_REMIX) == 0, 6);
    }

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_chunk_rotates_at_threshold(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        let big_payload = vector::empty<u8>();
        let i = 0;
        while (i < 8000) { vector::push_back(&mut big_payload, 0xAA); i = i + 1; };

        let j = 0;
        while (j < 3) {
            append(pid_addr, new_entry(VERB_MINT, j, option::none(), big_payload, option::none()));
            j = j + 1;
        };
        let sealed_before = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_before) == 0, 1);
        let head_before = head_chunk_addr(pid_addr);

        append(pid_addr, new_entry(VERB_MINT, 99, option::none(), big_payload, option::none()));

        let sealed_after = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_after) == 1, 2);
        let old_head = *vector::borrow(&sealed_after, 0);
        assert!(old_head == head_before, 3);
        assert!(chunk_is_sealed(old_head), 4);
        let new_head = head_chunk_addr(pid_addr);
        assert!(new_head != old_head, 5);
        assert!(!chunk_is_sealed(new_head), 6);
        assert!(count_verb(pid_addr, VERB_MINT) == 4, 7);
        assert!(total_entries(pid_addr) == 4, 8);
    }
}
