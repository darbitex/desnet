/// History — per-PID append-only on-chain log (LOCKED 2026-05-01).
///
/// Replaces event::emit for the 7-verb palette (Mint/Spark/Voice/Echo/Remix/Press/Sync).
/// Class-B primitive: Move runtime CAN read entries via view fns for gating logic
/// (Endorse, ReferenceGate cross-checks) without indexer dependency.
///
/// Storage: HistoryLog at PID Object addr (lazy-init via profile::derive_pid_signer).
/// Entries grouped into HistoryChunks (separate Objects owned by PID); current chunk
/// rotates when ~30KB threshold reached. Sealed chunks immutable from this module.
///
/// Cached counters per verb (O(1) view) — count_verb(pid, verb) for gating.
///
/// Encoding: Entry.payload = BCS-encoded verb-specific data (e.g., bcs::to_bytes(&MintEvent{..})).
/// Frontend / indexer decodes payload via Move struct definitions in respective modules.
module desnet::history {
    use std::option::Option;
    use std::signer;
    use std::vector;
    use aptos_framework::object;

    use desnet::profile;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::link;
    friend desnet::press;
    friend desnet::opinion;

    // ============ CONSTANTS ============

    /// Verb enum (history Entry.verb).
    const VERB_MINT: u8 = 0;
    const VERB_SPARK: u8 = 1;
    const VERB_VOICE: u8 = 2;
    const VERB_ECHO: u8 = 3;
    const VERB_REMIX: u8 = 4;
    const VERB_PRESS: u8 = 5;
    const VERB_SYNC: u8 = 6;
    /// Opinion verb: covers both opinion-mint creation and opinion-vote (deposit/swap/redeem).
    /// Payload struct distinguishes sub-action; appended to actor's PID history.
    const VERB_OPINION: u8 = 7;

    /// Chunk rotation threshold: when current chunk's tracked size exceeds this,
    /// seal it and allocate a new one. ~30KB ≈ 375 small entries.
    const CHUNK_ROTATE_THRESHOLD: u64 = 30000;

    /// Per-Entry payload hard cap (BCS bytes only; Entry.asset is separate ref).
    /// Sized to fit worst-case BCS-encoded MintEvent: inline media (8192) + content (333) +
    /// 5 tags + 10 mentions + 5 tickers + 10 tips + Option overhead ≈ 10075 bytes. 12000
    /// gives 1925-byte headroom. CHUNK_ROTATE_THRESHOLD (30000) still > 2× this so chunk
    /// rotation calculus remains sane.
    const MAX_PAYLOAD_BYTES: u64 = 12000;

    /// Per-entry overhead estimate (verb + ts + target option + asset option +
    /// vector length headers). Used for chunk size accounting.
    const ENTRY_OVERHEAD_BYTES: u64 = 64;

    // ============ ERROR CODES ============

    const E_PAYLOAD_TOO_LARGE: u64 = 1;
    // E_PID_NOT_FOUND removed (was unused — profile module owns PID-existence checks).
    const E_HISTORY_NOT_INITIALIZED: u64 = 3;
    const E_CHUNK_NOT_FOUND: u64 = 4;
    const E_INVALID_VERB: u64 = 5;

    // ============ TYPES ============

    /// Per-PID history log root. Lives at PID Object addr.
    /// head_chunk is always set after ensure_history_log (initialized lazily on first append).
    struct HistoryLog has key {
        head_chunk: address,
        sealed_chunks: vector<address>,
        entry_count: u64,
        total_bytes: u64,                  // running sum of (payload + overhead) across all chunks
        head_chunk_bytes: u64,             // bytes accumulated in current head_chunk
        // Cached per-verb counters (O(1) reads for gating)
        mint_count: u64,
        spark_count: u64,
        voice_count: u64,
        echo_count: u64,
        remix_count: u64,
        press_count: u64,
        sync_count: u64,
    }

    /// Append-only chunk holding a vector of Entry. Sealed=true after rotate.
    /// Module mutators check `sealed == false` before appending; sealed chunks
    /// are read-only from Move runtime perspective.
    struct HistoryChunk has key {
        entries: vector<Entry>,
        sealed: bool,
    }

    /// Single history entry. BCS-encoded into payload by the verb module.
    /// Has store + copy + drop so it can be vec-pushed and copy-read by views.
    struct Entry has store, copy, drop {
        verb: u8,
        timestamp_secs: u64,
        target: Option<address>,           // referenced PID/post for Echo/Sync/Voice/Remix
        payload: vector<u8>,               // BCS-encoded verb-specific data, ≤MAX_PAYLOAD_BYTES
        asset: Option<address>,            // optional desnet::assets::Master ref (>8KB media)
    }

    // ============ FRIEND CONSTRUCTORS ============

    /// Build an Entry for friend module to pass into append.
    /// Validates payload size cap.
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

    // ============ LAZY-INIT ============

    /// Lazy-create HistoryLog + first HistoryChunk at PID addr. Idempotent.
    /// Called from append on first-write per PID. Cycle-safe via
    /// profile::derive_pid_signer friend pattern (history is friend of profile).
    fun ensure_history_log(pid_addr: address) {
        if (exists<HistoryLog>(pid_addr)) return;

        let pid_signer = profile::derive_pid_signer(pid_addr);

        // First chunk Object owned by PID addr
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

    // ============ APPEND (friend-only) ============

    /// Append an Entry to PID's history. Lazy-init on first call.
    /// Auto-rotates chunk when threshold exceeded: seals current head, allocates new.
    public(friend) fun append(pid_addr: address, entry: Entry)
        acquires HistoryLog, HistoryChunk
    {
        ensure_history_log(pid_addr);

        let entry_size = vector::length(&entry.payload) + ENTRY_OVERHEAD_BYTES;

        // Check rotate condition
        let log = borrow_global_mut<HistoryLog>(pid_addr);
        if (log.head_chunk_bytes + entry_size > CHUNK_ROTATE_THRESHOLD) {
            // Seal current head (mark immutable; sealed chunks not mutated by this module)
            let old_head = log.head_chunk;
            {
                let head_chunk = borrow_global_mut<HistoryChunk>(old_head);
                head_chunk.sealed = true;
            };
            vector::push_back(&mut log.sealed_chunks, old_head);

            // Allocate new chunk Object owned by PID addr
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

        // Append entry to head chunk
        let verb = entry.verb;
        {
            let head = borrow_global_mut<HistoryChunk>(log.head_chunk);
            vector::push_back(&mut head.entries, entry);
        };

        // Bump global counters
        log.entry_count = log.entry_count + 1;
        log.total_bytes = log.total_bytes + entry_size;
        log.head_chunk_bytes = log.head_chunk_bytes + entry_size;

        // Bump per-verb counter
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

    // ============ VIEWS ============

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

    /// Read a specific entry from a chunk by local index. Aborts if out of range.
    /// Returns (verb, timestamp_secs, target, payload, asset) tuple.
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

    /// Cached per-verb counter — O(1) for gating logic.
    /// E.g., Endorse gate: count_verb(target_pid, VERB_SPARK) >= threshold.
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

    // Verb constant getters (for cross-module + frontend use)

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

    // ============ TESTS ============

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
    fun test_new_entry_opinion_verb_accepted() {
        let _e = new_entry(VERB_OPINION, 0, std::option::none<address>(), vector::empty(), std::option::none<address>());
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

    // ============ INTEGRATION TESTS (append + rotate) ============

    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use std::option;

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
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

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
    fun test_history_verb_counters_independent(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        // Append 3 sparks, 1 voice, 2 echoes
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

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
    fun test_history_chunk_rotates_at_threshold(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        // Each entry: 8000B payload + 64B overhead = 8064B. Threshold = 30000B.
        // 3 entries: 24192B (under). 4th append: would-be 32256B > 30000 → rotate fires.
        let big_payload = vector::empty<u8>();
        let i = 0;
        while (i < 8000) { vector::push_back(&mut big_payload, 0xAA); i = i + 1; };

        // First 3 appends: no rotate
        let j = 0;
        while (j < 3) {
            append(pid_addr, new_entry(VERB_MINT, j, option::none(), big_payload, option::none()));
            j = j + 1;
        };
        let sealed_before = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_before) == 0, 1);
        let head_before = head_chunk_addr(pid_addr);

        // 4th append triggers rotation (24192 + 8064 = 32256 > 30000)
        append(pid_addr, new_entry(VERB_MINT, 99, option::none(), big_payload, option::none()));

        let sealed_after = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_after) == 1, 2);
        // Old head sealed + matches what we observed before rotate
        let old_head = *vector::borrow(&sealed_after, 0);
        assert!(old_head == head_before, 3);
        assert!(chunk_is_sealed(old_head), 4);
        // New head exists, distinct, not sealed
        let new_head = head_chunk_addr(pid_addr);
        assert!(new_head != old_head, 5);
        assert!(!chunk_is_sealed(new_head), 6);
        // Mint counter tracks across chunks (3 in old + 1 in new)
        assert!(count_verb(pid_addr, VERB_MINT) == 4, 7);
        assert!(total_entries(pid_addr) == 4, 8);
    }
}
