# DeSNet v0.3.3 — Source Bundle (PART 3 social verbs)

**PRE-DEPLOY (LOCAL SOURCE) — not yet on chain. R6 audit submission.**

This is **3 of 3** parts. Each part covers a domain-grouped subset of modules.

## Package metadata

```json
{
  "tag": "v0.3.3-pre-deploy-r2",
  "commit": "93a05a2b418259cf6858169e9ebf45a082c5645c",
  "parent_deployed": "v0.3.2-mainnet-live (commit 31765c2, mainnet upgrade_number 4)",
  "total_lines": 8869,
  "total_bytes": 351447,
  "source_concat_sha3_256": "77f1831c265acbfac8712aeebe56aecd4548b82694a0866c5e29555e6cd7beb0"
}
```

## Modules in this part

| module | lines | bytes | sha3_256 |
|---|---:|---:|---|
| `assets` | 527 | 18,568 | `c11f3c5e493b13db59267d2b652db60c7c2ea91c0efc879bd22935a6eed4bed2` |
| `reference_gate` | 177 | 8,048 | `0c23c711f4e7f10755c5b1a16a0eb3724d657f45634a9c708d0494b2dd4c511d` |
| `history` | 454 | 17,672 | `f30d3aa7a629d7d1b97835fd46d9f82e137700e3be72f21797a933e959076f4e` |
| `link` | 214 | 8,246 | `eedf981f87182bb820a98c5bc074c782b335e20dc53bace4e36f872499649437` |
| `mint` | 605 | 22,601 | `915644007bcc28b9701b7d5e40e35ac179b5d9079874a7308873e029b54a4abd` |
| `giveaway` | 524 | 21,665 | `ec5e2bfba9bd8346a275e3c02f18b61c326fa662932c56814548b5442b6e65ad` |
| `press` | 471 | 19,784 | `cd4f08b938eaee1b9e148e4594bc7b6ac176f49d94f0be209364d140bd84dc4c` |
| `pulse` | 261 | 9,959 | `73576c3dc4fbc207ba94d3a9e123b1100ede18baab35c34d6ea2a612010d321f` |

To verify each module's sha3 matches:
```bash
sha3sum sources/<name>.move
```

---


## Module `assets` (527 lines, 18568 bytes)

`sha3_256: c11f3c5e493b13db59267d2b652db60c7c2ea91c0efc879bd22935a6eed4bed2`

```move
/// Assets — fractal-tree on-chain storage for media >8KB (LOCKED 2026-05-01).
///
/// Class-A primitive: bytes are stored on-chain so client loaders can reassemble,
/// but Move runtime never reads payload bytes (only references via Master addr).
///
/// Storage model: file split into ≤30KB Chunks. Single chunk → depth=0, root=chunk_addr.
/// Multiple chunks → grouped under Node(s), recursively until single root Node.
/// Master records (root, depth, total_size, mime). After finalize() Master.sealed=true,
/// no further mutation allowed via this module.
///
/// MIME whitelist (aligned with mint.move): PNG/JPEG/GIF/WebP/SVG. SVG INCLUDED
/// 2026-05-01 for on-chain generative art — XSS = frontend responsibility via
/// <img>-tag sandbox.
/// MAX_TOTAL_SIZE = 5MB hard cap. CHUNK_SIZE_MAX = 30000 bytes.
///
/// Asset ownership = anyone-can-reference (sealed Master is public good — Echo/Remix
/// can attach any sealed Master regardless of creator). Defamation/illegal-content
/// moderation = frontend responsibility, not protocol.
module desnet::assets {
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::timestamp;

    // ============ CONSTANTS ============

    const CHUNK_SIZE_MAX: u64 = 30000;
    const MAX_TOTAL_SIZE: u64 = 5_000_000;     // 5MB

    /// MIME enum (aligned with mint.move).
    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    // ============ ERROR CODES ============

    const E_INVALID_MIME: u64 = 1;
    const E_TOTAL_SIZE_EXCEEDED: u64 = 2;
    const E_TOTAL_SIZE_ZERO: u64 = 3;
    const E_CHUNK_TOO_LARGE: u64 = 4;
    const E_CHUNK_EMPTY: u64 = 5;
    const E_MASTER_SEALED: u64 = 6;
    const E_MASTER_NOT_FOUND: u64 = 7;
    const E_CHUNK_NOT_FOUND: u64 = 8;
    const E_NODE_NOT_FOUND: u64 = 9;
    const E_NODE_EMPTY: u64 = 10;
    const E_NOT_CREATOR: u64 = 11;

    // ============ TYPES ============

    /// Master record at Master Object addr. Tracks asset metadata + sealed status.
    /// After finalize(), sealed=true and root/depth set; module mutators abort.
    /// **anyone-can-REFERENCE** semantic applies POST-FINALIZE only (sealed Master is
    /// public good for Echo/Remix). DURING upload, only `creator_addr` may deploy
    /// chunks/nodes and finalize — prevents asymmetric DoS griefing where an attacker
    /// finalizes another's unsealed master with bogus root.
    struct Master has key {
        root: address,                // 0x0 until finalize; then chunk_addr (depth=0) or node_addr (depth>=1)
        depth: u8,                    // 0 = single chunk; 1+ = tree
        total_size: u64,              // declared at start_upload; informational
        mime: u8,                     // MIME_*
        creator_pid: address,         // informational; not enforced for engagement-side
        creator_addr: address,        // ENFORCED: only this address may deploy_chunk/deploy_node/finalize pre-seal
        sealed: bool,                 // false during upload, true after finalize
        created_at_secs: u64,
    }

    /// Leaf chunk — bytes payload ≤30KB. Created via deploy_chunk.
    struct Chunk has key {
        data: vector<u8>,
    }

    /// Internal node (tree depth ≥1) — vector of child addresses (chunks or sub-nodes).
    struct Node has key {
        children: vector<address>,
    }

    // ============ EVENTS ============

    #[event]
    struct AssetMasterCreated has drop, store {
        master_addr: address,
        creator_pid: address,
        mime: u8,
        total_size: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetChunkDeployed has drop, store {
        master_addr: address,
        chunk_addr: address,
        data_len: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetNodeDeployed has drop, store {
        master_addr: address,
        node_addr: address,
        children_count: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetFinalized has drop, store {
        master_addr: address,
        root: address,
        depth: u8,
        timestamp_secs: u64,
    }

    // ============ ENTRY: start_upload ============

    /// Allocate a new Master Object. Returns master_addr via emitted event
    /// (entry fns can't return values; frontend reads AssetMasterCreated).
    public entry fun start_upload(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ) {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        let uploader_addr = signer::address_of(uploader);
        let constructor_ref = object::create_object(uploader_addr);
        let master_signer = object::generate_signer(&constructor_ref);
        let master_addr = signer::address_of(&master_signer);

        let now_secs = timestamp::now_seconds();
        move_to(&master_signer, Master {
            root: @0x0,
            depth: 0,
            total_size,
            mime,
            creator_pid,
            creator_addr: uploader_addr,
            sealed: false,
            created_at_secs: now_secs,
        });

        event::emit(AssetMasterCreated {
            master_addr,
            creator_pid,
            mime,
            total_size,
            timestamp_secs: now_secs,
        });
    }

    // ============ ENTRY: deploy_chunk ============

    /// Deploy a leaf chunk (≤30KB). Master must exist and not be sealed.
    /// Returns chunk_addr via emitted event.
    public entry fun deploy_chunk(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ) acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let constructor_ref = object::create_object(uploader_addr);
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);

        move_to(&chunk_signer, Chunk { data });

        event::emit(AssetChunkDeployed {
            master_addr,
            chunk_addr,
            data_len: len,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ENTRY: deploy_node ============

    /// Deploy an internal Node pointing to children (chunk addrs or sub-node addrs).
    /// Used for tree depth ≥1. Master must not be sealed.
    /// Returns node_addr via emitted event.
    public entry fun deploy_node(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ) acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let n = vector::length(&children);
        assert!(n > 0, E_NODE_EMPTY);

        let constructor_ref = object::create_object(uploader_addr);
        let node_signer = object::generate_signer(&constructor_ref);
        let node_addr = signer::address_of(&node_signer);

        move_to(&node_signer, Node { children });

        event::emit(AssetNodeDeployed {
            master_addr,
            node_addr,
            children_count: n,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ENTRY: finalize ============

    /// Finalize Master: set root + depth, mark sealed=true. After this, the asset
    /// is permanently immutable from this module's perspective.
    /// Caller is responsible for having deployed root chunk/node beforehand.
    public entry fun finalize(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global_mut<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        // CRITICAL auth: only the master's creator may finalize. Without this check,
        // any address could seal another's unsealed master with bogus root → permanent
        // grief (asymmetric DoS, low-cost-attacker vs high-cost-victim).
        assert!(master.creator_addr == signer::address_of(uploader), E_NOT_CREATOR);

        // Sanity: root must point to existing Chunk (depth=0) or Node (depth>=1)
        if (depth == 0) {
            assert!(exists<Chunk>(root), E_CHUNK_NOT_FOUND);
        } else {
            assert!(exists<Node>(root), E_NODE_NOT_FOUND);
        };

        master.root = root;
        master.depth = depth;
        master.sealed = true;

        event::emit(AssetFinalized {
            master_addr,
            root,
            depth,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ INTERNAL ============

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

    // ============ VIEWS ============

    #[view]
    public fun master_exists(addr: address): bool {
        exists<Master>(addr)
    }

    #[view]
    public fun is_sealed(addr: address): bool acquires Master {
        if (!exists<Master>(addr)) return false;
        borrow_global<Master>(addr).sealed
    }

    #[view]
    public fun mime_of(addr: address): u8 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).mime
    }

    #[view]
    public fun root_of(addr: address): address acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).root
    }

    #[view]
    public fun depth_of(addr: address): u8 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).depth
    }

    #[view]
    public fun total_size_of(addr: address): u64 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).total_size
    }

    #[view]
    public fun creator_pid_of(addr: address): address acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).creator_pid
    }

    #[view]
    public fun read_chunk(chunk_addr: address): vector<u8> acquires Chunk {
        assert!(exists<Chunk>(chunk_addr), E_CHUNK_NOT_FOUND);
        borrow_global<Chunk>(chunk_addr).data
    }

    #[view]
    public fun chunk_size(chunk_addr: address): u64 acquires Chunk {
        if (!exists<Chunk>(chunk_addr)) return 0;
        vector::length(&borrow_global<Chunk>(chunk_addr).data)
    }

    #[view]
    public fun read_node(node_addr: address): vector<address> acquires Node {
        assert!(exists<Node>(node_addr), E_NODE_NOT_FOUND);
        borrow_global<Node>(node_addr).children
    }

    #[view]
    public fun chunk_size_max(): u64 { CHUNK_SIZE_MAX }

    #[view]
    public fun max_total_size(): u64 { MAX_TOTAL_SIZE }

    #[view]
    public fun mime_png(): u8 { MIME_PNG }

    #[view]
    public fun mime_jpeg(): u8 { MIME_JPEG }

    #[view]
    public fun mime_gif(): u8 { MIME_GIF }

    #[view]
    public fun mime_webp(): u8 { MIME_WEBP }

    #[view]
    public fun mime_svg(): u8 { MIME_SVG }

    // ============ TEST-ONLY WRAPPERS ============

    /// Test wrapper: returns master_addr (entry fns can't return values).
    #[test_only]
    public fun start_upload_for_test(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ): address {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        let uploader_addr = signer::address_of(uploader);
        let constructor_ref = object::create_object(uploader_addr);
        let master_signer = object::generate_signer(&constructor_ref);
        let master_addr = signer::address_of(&master_signer);
        let now_secs = timestamp::now_seconds();
        move_to(&master_signer, Master {
            root: @0x0,
            depth: 0,
            total_size,
            mime,
            creator_pid,
            creator_addr: uploader_addr,
            sealed: false,
            created_at_secs: now_secs,
        });
        master_addr
    }

    /// Test wrapper: returns chunk_addr.
    #[test_only]
    public fun deploy_chunk_for_test(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let constructor_ref = object::create_object(uploader_addr);
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);
        move_to(&chunk_signer, Chunk { data });
        chunk_addr
    }

    // ============ TESTS ============

    #[test]
    fun test_assert_valid_mime_accepts_all_five() {
        assert_valid_mime(MIME_PNG);
        assert_valid_mime(MIME_JPEG);
        assert_valid_mime(MIME_GIF);
        assert_valid_mime(MIME_WEBP);
        assert_valid_mime(MIME_SVG);   // SVG re-included 2026-05-01
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_zero() {
        assert_valid_mime(0);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_six() {
        assert_valid_mime(6);
    }

    #[test]
    fun test_constants_match_views() {
        assert!(mime_png() == MIME_PNG, 1);
        assert!(mime_svg() == MIME_SVG, 2);
        assert!(chunk_size_max() == 30000, 3);
        assert!(max_total_size() == 5_000_000, 4);
    }

    // ============ INTEGRATION TESTS (lifecycle) ============

    #[test_only]
    fun setup_test_env(framework: &signer, uploader: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        aptos_framework::account::create_account_for_test(signer::address_of(uploader));
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    fun test_lifecycle_single_chunk_seal(framework: &signer, uploader: &signer)
        acquires Master, Chunk
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_for_test(uploader, MIME_PNG, 1024, @0xfeed);
        assert!(!is_sealed(master_addr), 1);
        assert!(mime_of(master_addr) == MIME_PNG, 2);

        let data = vector::empty<u8>();
        let i = 0;
        while (i < 1024) { vector::push_back(&mut data, 0xAB); i = i + 1; };

        let chunk_addr = deploy_chunk_for_test(uploader, master_addr, data);
        assert!(chunk_size(chunk_addr) == 1024, 3);

        finalize(uploader, master_addr, chunk_addr, 0);
        assert!(is_sealed(master_addr), 4);
        assert!(root_of(master_addr) == chunk_addr, 5);
        assert!(depth_of(master_addr) == 0, 6);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_finalize_rejects_non_creator_A2_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        aptos_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_JPEG, 100, @0xfeed);
        // Attacker tries to finalize with bogus root — must fail per A2 fix.
        finalize(attacker, master_addr, @0xdeadbeef, 0);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_deploy_chunk_rejects_non_creator_A3_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        aptos_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_GIF, 100, @0xfeed);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x42);
        // Attacker deploys chunk for victim's master — must fail.
        deploy_chunk_for_test(attacker, master_addr, data);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_MASTER_SEALED, location = Self)]
    fun test_deploy_chunk_after_seal_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_for_test(uploader, MIME_WEBP, 50, @0xfeed);
        let data1 = vector::empty<u8>();
        vector::push_back(&mut data1, 0x42);
        let chunk_addr = deploy_chunk_for_test(uploader, master_addr, data1);
        finalize(uploader, master_addr, chunk_addr, 0);

        // After seal, deploy_chunk should abort.
        let data2 = vector::empty<u8>();
        vector::push_back(&mut data2, 0x42);
        deploy_chunk_for_test(uploader, master_addr, data2);
    }

    #[test(uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_TOTAL_SIZE_EXCEEDED, location = Self)]
    fun test_start_upload_total_size_cap(uploader: &signer) {
        // 5MB+1 byte → reject
        start_upload_for_test(uploader, MIME_SVG, 5_000_001, @0xfeed);
    }
}
```

---

## Module `reference_gate` (177 lines, 8048 bytes)

`sha3_256: 0c23c711f4e7f10755c5b1a16a0eb3724d657f45634a9c708d0494b2dd4c511d`

```move
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
```

---

## Module `history` (454 lines, 17672 bytes)

`sha3_256: f30d3aa7a629d7d1b97835fd46d9f82e137700e3be72f21797a933e959076f4e`

```move
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

    // ============ CONSTANTS ============

    /// Verb enum (history Entry.verb).
    const VERB_MINT: u8 = 0;
    const VERB_SPARK: u8 = 1;
    const VERB_VOICE: u8 = 2;
    const VERB_ECHO: u8 = 3;
    const VERB_REMIX: u8 = 4;
    const VERB_PRESS: u8 = 5;
    const VERB_SYNC: u8 = 6;

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
        assert!(verb <= VERB_SYNC, E_INVALID_VERB);
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
        let _e = new_entry(7, 0, std::option::none<address>(), vector::empty(), std::option::none<address>());
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
```

---

## Module `link` (214 lines, 8246 bytes)

`sha3_256: eedf981f87182bb820a98c5bc074c782b335e20dc53bace4e36f872499649437`

```move
/// Link — Sync action + PidSyncSet on-chain state (LOCKED 2026-05-01).
///
/// Sync = subscribe to a PID's mints. Unidirectional like node-syncs-to-chain.
/// ENDORSE removed from link_kind enum (= derived view from LP staking position).
///
/// LinkEvent { link_kind: SYNC, state: ADD/REMOVE } — kept ADD/REMOVE pattern
/// (Aptos events immutable on emit; un-action emits state=REMOVE).
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
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::reference_gate::{Self, ReferenceGate};
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
        target_pid: address,
        syncer_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidSyncSet {
        let syncer_addr = signer::address_of(syncer);
        let syncer_pid = profile::derive_pid_address(syncer_addr);

        profile::assert_pid_exists(syncer_pid);
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
        target_pid: address,
    ) acquires PidSyncSet {
        let syncer_addr = signer::address_of(syncer);
        let syncer_pid = profile::derive_pid_address(syncer_addr);

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
```

---

## Module `mint` (605 lines, 22601 bytes)

`sha3_256: 915644007bcc28b9701b7d5e40e35ac179b5d9079874a7308873e029b54a4abd`

```move
/// Mint — the creation primitive (LOCKED 2026-05-01).
///
/// MintEvent is the single emission for: Mint (original), Voice (reply), Remix (quote).
/// Mode determined by parent_mint_id + quote_mint_id fields:
///   - Mint:  parent=None, quote=None
///   - Voice: parent=Some, quote=None
///   - Remix: parent=None, quote=Some
///   (parent+quote both Some = invalid, abort)
///
/// Validation rules (LOCKED, on-chain enforced):
/// - author MUST have Profile (Named tier; guests can't mint)
/// - content_text ≤ 333 bytes
/// - media: if Inline, data ≤ 8KB hard cap
/// - mentions ≤ 10 (any Aptos addr — flexible: PID/hex/ANS-resolved)
/// - tags ≤ 5, each 1-32 bytes lowercase a-z/0-9/-
/// - tickers ≤ 5, each MUST be factory-spawned FA (factory::is_factory_token assert)
/// - tips ≤ 10, each token MUST be FA-standard (no legacy coin)
///
/// Tags = ownerless folksonomy permanently. Tickers = factory-only scope (every $X
/// resolves to a PID). Mentions = flexible (implicit-then-named magic preserved).
///
/// Self-exempt for ReferenceGate: post creator always passes own mint-level gate.
module desnet::mint {
    use std::bcs;
    use std::signer;
    use std::option::{Self, Option};
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::reference_gate::{Self, ReferenceGate};
    use desnet::history;
    use desnet::assets;
    use desnet::factory;

    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS — caps locked 2026-05-01 ============

    const CONTENT_TEXT_MAX_BYTES: u64 = 333;
    const MEDIA_INLINE_MAX_BYTES: u64 = 8192;     // 8KB hard cap
    const MENTIONS_MAX: u64 = 10;
    const TAGS_MAX: u64 = 5;
    const TAG_MAX_BYTES: u64 = 32;
    const TAG_MIN_BYTES: u64 = 1;
    const TICKERS_MAX: u64 = 5;
    const TIPS_MAX: u64 = 10;

    /// MintMedia variant tags
    const MEDIA_KIND_INLINE: u8 = 1;
    const MEDIA_KIND_REF: u8 = 2;

    /// MIME u8 enum. SVG INCLUDED 2026-05-01 (on-chain generative art ethos;
    /// XSS = frontend responsibility via <img>-tag sandbox).
    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    /// Storage backend tags for MintMedia::Ref
    const BACKEND_SHELBY: u8 = 0;
    const BACKEND_WALRUS: u8 = 1;
    const BACKEND_IPFS: u8 = 2;
    const BACKEND_DESNET_ASSETS: u8 = 3;

    // ============ ERROR CODES ============

    const E_GUEST_CANNOT_MINT: u64 = 1;
    const E_BOTH_PARENT_AND_QUOTE: u64 = 2;
    const E_CONTENT_TOO_LONG: u64 = 3;
    const E_INLINE_MEDIA_TOO_LARGE: u64 = 4;
    const E_TOO_MANY_MENTIONS: u64 = 5;
    const E_TOO_MANY_TAGS: u64 = 6;
    const E_TAG_TOO_SHORT: u64 = 7;
    const E_TAG_TOO_LONG: u64 = 8;
    const E_TAG_INVALID_CHAR: u64 = 9;
    const E_TOO_MANY_TICKERS: u64 = 10;
    const E_TICKER_NOT_FACTORY_TOKEN: u64 = 11;
    const E_TOO_MANY_TIPS: u64 = 12;
    const E_INVALID_MIME: u64 = 13;
    const E_INVALID_BACKEND: u64 = 14;
    const E_PARENT_MINT_NOT_FOUND: u64 = 15;
    const E_QUOTE_MINT_NOT_FOUND: u64 = 16;
    const E_GATE_FAILED: u64 = 17;
    const E_MINT_META_NOT_INITIALIZED: u64 = 18;
    const E_MINT_NOT_FOUND: u64 = 20;
    const E_ASSET_NOT_SEALED: u64 = 19;

    // ============ TYPES ============

    /// Per-PID mint sequence + counters. Stored at PID Object addr.
    struct PidMintMeta has key {
        next_seq: u64,
        mint_count: u64,
    }

    /// Per-PID extras storage (PressConfig, Giveaway, MintGate per mint seq).
    /// Lazy-grown SmartTable<seq, MintExtras>.
    struct PidMintExtras has key {
        extras: SmartTable<u64, MintExtras>,
    }

    /// Per-mint optional extras. Stored in PidMintExtras.extras[seq].
    /// Press, Giveaway, ReferenceGate all live HERE (not in event for size reasons).
    struct MintExtras has store {
        gate: Option<ReferenceGate>,
        // Note: PressConfig + Giveaway stored separately in their own modules' resources
        // via mint_id key (= (author_pid, seq) tuple). Kept extensible here for future fields.
    }

    /// MintId compound key: (author_pid, seq). Used as parent_mint_id / quote_mint_id ref.
    struct MintId has copy, drop, store {
        author: address,
        seq: u64,
    }

    /// MintMedia tagged variant (Inline OR Ref, never both).
    struct MintMedia has copy, drop, store {
        kind: u8,                          // MEDIA_KIND_INLINE | MEDIA_KIND_REF
        mime: u8,                          // MIME_PNG | MIME_JPEG | MIME_GIF | MIME_WEBP
        // Inline path
        inline_data: vector<u8>,           // if kind=Inline, ≤8KB
        // Ref path
        ref_backend: u8,                   // if kind=Ref, BACKEND_*
        ref_blob_id: vector<u8>,
        ref_hash: vector<u8>,
    }

    /// Atomic tip embedded in mint.
    struct Tip has copy, drop, store {
        recipient: address,
        token_metadata: address,           // FA-only (legacy coin excluded)
        amount: u64,
    }

    // ============ EVENTS ============

    /// THE creation record (LOCKED).
    /// Modes: Mint (parent=None, quote=None) | Voice (parent=Some) | Remix (quote=Some).
    /// Replaces former #[event] — now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct MintEvent has drop, store {
        author: address,                            // PID Object addr
        seq: u64,
        timestamp_us: u64,
        content_kind: u8,                           // type discriminator (text/etc)
        content_text: vector<u8>,                   // ≤333 bytes
        media: Option<MintMedia>,                   // optional inline OR ref
        parent_mint_id: Option<MintId>,             // Voice mode if Some
        root_mint_id: Option<MintId>,               // thread-head jump optimization
        quote_mint_id: Option<MintId>,              // Remix mode if Some
        mentions: vector<address>,                  // ≤10
        tags: vector<vector<u8>>,                   // ≤5, lowercase a-z/0-9/-
        tickers: vector<address>,                   // ≤5 factory-spawned FA addrs
        tips: vector<Tip>,                          // ≤10 atomic transfers
    }

    /// Atomic tip executed during mint creation (paired with MintEvent).
    #[event]
    struct TipExecuted has drop, store {
        from_pid: address,
        to_addr: address,
        token_metadata: address,
        amount: u64,
        mint_seq: u64,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidMintMeta + PidMintExtras at PID addr.
    /// Called from entry fns on first-write per PID. Idempotent.
    /// Uses profile::derive_pid_signer friend helper (cycle-safe pattern).
    fun ensure_mint_storage(pid_addr: address) {
        if (!exists<PidMintMeta>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintMeta { next_seq: 0, mint_count: 0 });
        };
        if (!exists<PidMintExtras>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintExtras { extras: smart_table::new() });
        };
    }

    // ============ CREATE MINT — main entry ============

    /// Atomic mint creation with all optional extensions.
    /// Mode determined by parent_mint_id + quote_mint_id (caller passes None for unused).
    ///
    /// Tips (if any): each tip transfers from author's primary store to recipient
    /// in same tx. Tx aborts if any tip lacks balance — atomic all-or-nothing.
    public entry fun create_mint(
        author: &signer,
        content_kind: u8,
        content_text: vector<u8>,
        // Media (optional, packed as 4 args; caller passes empty vec for unused)
        media_kind: u8,                             // 0 = no media, else MEDIA_KIND_*
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        // Threading (caller passes 0/empty for None)
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        // Engagement vectors
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        // Tips (parallel arrays for Move 1.x compat — vector<Tip> at frontend builds)
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        // desnet::assets attached media (>8KB). When asset_master_set=true, overrides
        // media_* args: media auto-built with kind=Ref, backend=BACKEND_DESNET_ASSETS,
        // mime=assets::mime_of(asset_master_addr), ref_blob_id=bcs(asset_master_addr).
        asset_master_addr: address,
        asset_master_set: bool,
    ) acquires PidMintMeta {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // ============ Validate content + media ============

        assert!(vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES, E_CONTENT_TOO_LONG);

        let media: Option<MintMedia> = if (asset_master_set) {
            // desnet::assets path — Master must be sealed (immutable). MIME read from Master.
            assert!(assets::is_sealed(asset_master_addr), E_ASSET_NOT_SEALED);
            let asset_mime = assets::mime_of(asset_master_addr);
            assert_valid_mime(asset_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: asset_mime,
                inline_data: vector::empty(),
                ref_backend: BACKEND_DESNET_ASSETS,
                ref_blob_id: bcs::to_bytes(&asset_master_addr),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == 0) {
            option::none()
        } else if (media_kind == MEDIA_KIND_INLINE) {
            assert!(vector::length(&media_inline_data) <= MEDIA_INLINE_MAX_BYTES, E_INLINE_MEDIA_TOO_LARGE);
            assert_valid_mime(media_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_INLINE,
                mime: media_mime,
                inline_data: media_inline_data,
                ref_backend: 0,
                ref_blob_id: vector::empty(),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == MEDIA_KIND_REF) {
            assert_valid_mime(media_mime);
            assert_valid_backend(media_ref_backend);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: media_mime,
                inline_data: vector::empty(),
                ref_backend: media_ref_backend,
                ref_blob_id: media_ref_blob_id,
                ref_hash: media_ref_hash,
            })
        } else {
            abort E_INVALID_MIME
        };

        // ============ Validate threading ============

        assert!(!(parent_set && quote_set), E_BOTH_PARENT_AND_QUOTE);

        let parent_mint_id: Option<MintId> = if (parent_set) {
            option::some(MintId { author: parent_author, seq: parent_seq })
        } else {
            option::none()
        };

        let quote_mint_id: Option<MintId> = if (quote_set) {
            option::some(MintId { author: quote_author, seq: quote_seq })
        } else {
            option::none()
        };

        // root_mint_id: derive via parent's root if Voice, else None for Mint/Remix
        let root_mint_id: Option<MintId> = option::none();
        // PRODUCTION: query parent's MintEvent root (or compute via indexer hint)

        // ============ Validate vectors ============

        assert!(vector::length(&mentions) <= MENTIONS_MAX, E_TOO_MANY_MENTIONS);
        // Mentions = flexible (no Profile-existence assert; indexer differentiates)

        validate_tags(&tags);
        validate_tickers(&tickers);

        let tips_len = vector::length(&tip_recipients);
        assert!(tips_len == vector::length(&tip_tokens), E_TOO_MANY_TIPS);
        assert!(tips_len == vector::length(&tip_amounts), E_TOO_MANY_TIPS);
        assert!(tips_len <= TIPS_MAX, E_TOO_MANY_TIPS);

        // ============ Allocate seq + execute tips ============

        let meta = borrow_global_mut<PidMintMeta>(author_pid);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.mint_count = meta.mint_count + 1;

        // Execute tips atomically — abort whole mint if any fails
        let tips_vec = execute_tips(author, &tip_recipients, &tip_tokens, &tip_amounts, seq);

        // ============ Build canonical MintEvent + write to history ============

        let now_secs = timestamp::now_seconds();
        let event_record = MintEvent {
            author: author_pid,
            seq,
            timestamp_us: now_secs * 1_000_000,    // microseconds (frontend convention)
            content_kind,
            content_text,
            media,
            parent_mint_id,
            root_mint_id,
            quote_mint_id,
            mentions,
            tags,
            tickers,
            tips: tips_vec,
        };

        // Verb dispatch: Mint=0 (no parent/quote), Voice=2 (parent_set), Remix=4 (quote_set).
        // parent_set + quote_set are mutually exclusive (asserted earlier).
        let verb = if (parent_set) {
            history::verb_voice()
        } else if (quote_set) {
            history::verb_remix()
        } else {
            history::verb_mint()
        };

        let target = if (parent_set) {
            option::some(parent_author)
        } else if (quote_set) {
            option::some(quote_author)
        } else {
            option::none<address>()
        };

        let asset_ref = if (asset_master_set) {
            option::some(asset_master_addr)
        } else {
            option::none<address>()
        };

        let payload = bcs::to_bytes(&event_record);
        history::append(
            author_pid,
            history::new_entry(verb, now_secs, target, payload, asset_ref),
        );
    }

    // ============ INTERNAL — tip execution ============

    fun execute_tips(
        author: &signer,
        recipients: &vector<address>,
        tokens: &vector<address>,
        amounts: &vector<u64>,
        seq: u64,
    ): vector<Tip> {
        let tips = vector::empty<Tip>();
        let n = vector::length(recipients);
        let i = 0;
        while (i < n) {
            let recipient = *vector::borrow(recipients, i);
            let token_addr = *vector::borrow(tokens, i);
            let amount = *vector::borrow(amounts, i);

            // Withdraw FA from author's primary store + deposit to recipient
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let fa_in = primary_fungible_store::withdraw(author, token_metadata, amount);
            primary_fungible_store::deposit(recipient, fa_in);

            event::emit(TipExecuted {
                from_pid: profile::derive_pid_address(signer::address_of(author)),
                to_addr: recipient,
                token_metadata: token_addr,
                amount,
                mint_seq: seq,
                timestamp_secs: timestamp::now_seconds(),
            });

            vector::push_back(&mut tips, Tip {
                recipient,
                token_metadata: token_addr,
                amount,
            });

            i = i + 1;
        };
        tips
    }

    // ============ INTERNAL — validators ============

    fun validate_tags(tags: &vector<vector<u8>>) {
        assert!(vector::length(tags) <= TAGS_MAX, E_TOO_MANY_TAGS);
        let i = 0;
        let n = vector::length(tags);
        while (i < n) {
            let t = vector::borrow(tags, i);
            let len = vector::length(t);
            assert!(len >= TAG_MIN_BYTES, E_TAG_TOO_SHORT);
            assert!(len <= TAG_MAX_BYTES, E_TAG_TOO_LONG);

            let j = 0;
            while (j < len) {
                let ch = *vector::borrow(t, j);
                let ok = (ch >= 0x61 && ch <= 0x7A)
                      || (ch >= 0x30 && ch <= 0x39)
                      || (ch == 0x2D);
                assert!(ok, E_TAG_INVALID_CHAR);
                j = j + 1;
            };
            i = i + 1;
        };
    }

    /// Tickers must be factory-spawned FAs (DeSNet ticker spec lock 2026-05-01).
    /// Calls factory::is_factory_token view fn for each addr.
    fun validate_tickers(tickers: &vector<address>) {
        assert!(vector::length(tickers) <= TICKERS_MAX, E_TOO_MANY_TICKERS);
        let i = 0;
        let n = vector::length(tickers);
        while (i < n) {
            let addr = *vector::borrow(tickers, i);
            assert!(factory::is_factory_token(addr), E_TICKER_NOT_FACTORY_TOKEN);
            i = i + 1;
        };
    }

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

    fun assert_valid_backend(backend: u8) {
        assert!(
            backend == BACKEND_SHELBY || backend == BACKEND_WALRUS
                || backend == BACKEND_IPFS || backend == BACKEND_DESNET_ASSETS,
            E_INVALID_BACKEND
        );
    }

    // ============ MINT-LEVEL GATE ATTACHMENT ============

    /// Attach ReferenceGate to a specific mint. Gates Voice/Spark/Echo/Remix/Press
    /// of this mint. Immutable post-attach.
    /// Args flattened to primitives — Aptos entry fns can't take struct params.
    public entry fun attach_mint_gate(
        author: &signer,
        seq: u64,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires PidMintMeta, PidMintExtras {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // Validate seq corresponds to a real mint by author
        assert!(seq < next_seq(author_pid), E_MINT_NOT_FOUND);

        let gate = reference_gate::new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
        let extras_store = borrow_global_mut<PidMintExtras>(author_pid);
        if (smart_table::contains(&extras_store.extras, seq)) {
            let entry = smart_table::borrow_mut(&mut extras_store.extras, seq);
            entry.gate = option::some(gate);
        } else {
            smart_table::add(&mut extras_store.extras, seq, MintExtras {
                gate: option::some(gate),
            });
        };
    }

    // ============ INTERNAL — gate evaluation for friend modules ============

    /// Friend access for pulse/press/giveaway to check mint-level gate before
    /// allowing engagement.
    public(friend) fun get_mint_gate(author_pid: address, seq: u64): Option<ReferenceGate>
        acquires PidMintExtras
    {
        if (!exists<PidMintExtras>(author_pid)) return option::none();
        let extras_store = borrow_global<PidMintExtras>(author_pid);
        if (!smart_table::contains(&extras_store.extras, seq)) return option::none();
        smart_table::borrow(&extras_store.extras, seq).gate
    }

    // ============ VIEWS ============

    #[view]
    public fun mint_count(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).mint_count
    }

    #[view]
    public fun next_seq(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).next_seq
    }

    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }

    #[view]
    public fun media_inline_max_bytes(): u64 { MEDIA_INLINE_MAX_BYTES }

    #[view]
    public fun mentions_max(): u64 { MENTIONS_MAX }

    #[view]
    public fun tags_max(): u64 { TAGS_MAX }

    #[view]
    public fun tickers_max(): u64 { TICKERS_MAX }

    #[view]
    public fun tips_max(): u64 { TIPS_MAX }

    // ============ TESTS ============

    #[test]
    fun test_assert_valid_mime_accepts_five() {
        assert_valid_mime(MIME_PNG);
        assert_valid_mime(MIME_JPEG);
        assert_valid_mime(MIME_GIF);
        assert_valid_mime(MIME_WEBP);
        assert_valid_mime(MIME_SVG);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_zero() {
        assert_valid_mime(0);
    }

    #[test]
    fun test_assert_valid_backend_accepts_all_four() {
        assert_valid_backend(BACKEND_SHELBY);
        assert_valid_backend(BACKEND_WALRUS);
        assert_valid_backend(BACKEND_IPFS);
        assert_valid_backend(BACKEND_DESNET_ASSETS);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_BACKEND, location = Self)]
    fun test_assert_valid_backend_rejects_unknown() {
        assert_valid_backend(99);
    }

    #[test]
    fun test_validate_tags_accept_valid() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"defi");
        vector::push_back(&mut tags, b"aptos-move");
        vector::push_back(&mut tags, b"web3-2026");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_INVALID_CHAR, location = Self)]
    fun test_validate_tags_reject_uppercase() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"DeFi");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_TOO_LONG, location = Self)]
    fun test_validate_tags_reject_too_long() {
        let tags = vector::empty<vector<u8>>();
        // 33 bytes (cap = 32)
        vector::push_back(&mut tags, b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        validate_tags(&tags);
    }
}
```

---

## Module `giveaway` (524 lines, 21665 bytes)

`sha3_256: ec5e2bfba9bd8346a275e3c02f18b61c326fa662932c56814548b5442b6e65ad`

```move
/// Giveaway — opt-in attached giveaway primitive (LOCKED 2026-05-01).
///
/// Two types: FA (fungible token, fixed amount per claim) + NFT (FCFS sequential).
/// Token scope = AGNOSTIC (any FA, any NFT collection — NOT factory-only).
///
/// Three optional gates (independent opt-in):
/// - follower_only: synced to sponsor
/// - nft_gate: NFT collection holder
/// - lp_stake_gate: LP staker in target_pid's pool (Endorse-tier integration)
///
/// Default = PID-only claim (tier model enforces guest exclusion — claim = write action).
/// NO citizen_only / guest_allowed field (redundant).
/// NO min_reputation field v1 (deferred until reputation primitive lands).
///
/// Refund flow: post-deadline permissionless `settle_giveaway(mint_id)` destroys
/// SmartTable, refunds unclaimed budget to sponsor, pays caller 5 bps bounty (FA mode)
/// or no bounty (NFT mode — sponsor incentive enough).
module desnet::giveaway {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object, ObjectCore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::link;
    use desnet::mint;
    use desnet::lp_staking;
    use aptos_token_objects::token;

    // ============ CONSTANTS ============

    /// Bounty for permissionless settler (FA mode) = 5 bps of refunded amount.
    const SETTLE_BOUNTY_BPS: u64 = 5;

    /// GiveawayKind variant tags
    const KIND_FA: u8 = 1;
    const KIND_NFT: u8 = 2;

    // ============ ERROR CODES ============

    const E_GIVEAWAY_NOT_FOUND: u64 = 1;
    const E_GIVEAWAY_EXPIRED: u64 = 2;
    const E_GIVEAWAY_EXHAUSTED: u64 = 3;
    const E_ALREADY_CLAIMED: u64 = 4;
    const E_FOLLOWER_GATE_FAILED: u64 = 5;
    const E_NFT_GATE_FAILED: u64 = 6;
    const E_LP_STAKE_GATE_FAILED: u64 = 7;
    const E_NOT_DEADLINE: u64 = 8;
    const E_INVALID_KIND: u64 = 9;
    const E_GUEST_CANNOT_CLAIM: u64 = 10;
    const E_GIVEAWAY_ALREADY_EXISTS: u64 = 11;
    const E_NOT_SPONSOR: u64 = 12;
    const E_MINT_NOT_FOUND: u64 = 13;

    // ============ TYPES ============

    /// Per-mint Giveaway. Stored at sponsor PID, keyed by mint_seq.
    /// Single Giveaway per mint v1 (multi-prize deferred v2).
    struct Giveaway has key, store {
        sponsor_pid: address,
        sponsor_wallet: address,             // wallet that funded the giveaway; refund recipient
        kind: u8,                            // KIND_FA | KIND_NFT
        deadline_secs: u64,
        // FA fields (used when kind=KIND_FA)
        fa_token_metadata: address,          // ANY FA addr (agnostic)
        fa_amount_per_claim: u64,
        fa_total_budget: u64,
        // NFT fields (used when kind=KIND_NFT)
        nft_collection_addr: address,
        nft_addrs: vector<address>,          // FCFS pop_front, vector::length = remaining
        // Common counters
        claims_made: u64,
        // Optional gates (3 independent)
        follower_only: bool,
        nft_gate: Option<address>,
        lp_stake_gate: Option<address>,
        // Per-actor dedup (PID Object addr → true)
        claimers: SmartTable<address, bool>,
        // Object signer (escrow holds funds for FA mode at this Object's primary store)
        extend_ref: ExtendRef,
    }

    /// Per-PID giveaway storage. SmartTable<mint_seq, Giveaway addr>.
    /// Each Giveaway lives at its own Object addr (escrow holds funds).
    struct PidGiveawayStorage has key {
        giveaways: SmartTable<u64, address>,  // mint_seq → giveaway Object addr
    }

    // ============ EVENTS ============

    #[event]
    struct GiveawayCreated has drop, store {
        sponsor_pid: address,
        mint_seq: u64,
        giveaway_addr: address,
        kind: u8,
        deadline_secs: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct GiveawayClaimed has drop, store {
        giveaway_addr: address,
        claimer_pid: address,
        claim_index: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct GiveawaySettled has drop, store {
        giveaway_addr: address,
        sponsor_pid: address,
        settler: address,
        refund_amount: u64,
        bounty_paid: u64,
        timestamp_secs: u64,
    }

    // ============ CREATE — FA mode ============

    /// Sponsor creates FA giveaway attached to their mint. Atomic: deposits
    /// total_budget into giveaway escrow, registers under PidGiveawayStorage.
    public entry fun create_fa_giveaway(
        sponsor: &signer,
        mint_seq: u64,
        token_metadata: Object<Metadata>,
        amount_per_claim: u64,
        total_budget: u64,
        deadline_secs: u64,
        follower_only: bool,
        nft_gate_addr: address,
        nft_gate_set: bool,
        lp_stake_gate_addr: address,
        lp_stake_gate_set: bool,
    ) acquires PidGiveawayStorage {
        let sponsor_addr = signer::address_of(sponsor);
        let sponsor_pid = profile::derive_pid_address(sponsor_addr);
        profile::assert_pid_exists(sponsor_pid);

        // Validate mint_seq corresponds to a real mint by sponsor
        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        // Withdraw total_budget from sponsor's primary store (atomic; aborts if no balance)
        let escrow_fa = primary_fungible_store::withdraw(sponsor, token_metadata, total_budget);

        // Create giveaway Object (escrow holds funds at its primary store)
        let constructor_ref = object::create_object(sponsor_addr);
        let giveaway_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        primary_fungible_store::deposit(giveaway_addr, escrow_fa);

        let giveaway = Giveaway {
            sponsor_pid,
            sponsor_wallet: sponsor_addr,
            kind: KIND_FA,
            deadline_secs,
            fa_token_metadata: object::object_address(&token_metadata),
            fa_amount_per_claim: amount_per_claim,
            fa_total_budget: total_budget,
            nft_collection_addr: @0x0,
            nft_addrs: vector::empty(),
            claims_made: 0,
            follower_only,
            nft_gate: if (nft_gate_set) option::some(nft_gate_addr) else option::none(),
            lp_stake_gate: if (lp_stake_gate_set) option::some(lp_stake_gate_addr) else option::none(),
            claimers: smart_table::new(),
            extend_ref,
        };

        move_to(&object_signer, giveaway);

        // Register in sponsor's giveaway storage (lazy-init if first time)
        ensure_giveaway_storage(sponsor_pid);
        let storage = borrow_global_mut<PidGiveawayStorage>(sponsor_pid);
        smart_table::add(&mut storage.giveaways, mint_seq, giveaway_addr);

        event::emit(GiveawayCreated {
            sponsor_pid,
            mint_seq,
            giveaway_addr,
            kind: KIND_FA,
            deadline_secs,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ CREATE — NFT mode ============

    /// Sponsor creates NFT giveaway. Sponsor passes pre-collected NFT Object addrs
    /// in FCFS order. Each claim transfers next NFT in vector to claimer.
    /// **ATOMIC ESCROW (LOCKED 2026-05-01)**: at create-time, sponsor must own ALL NFTs
    /// in `nft_addrs`. Each is verified + transferred to `giveaway_addr` in this tx.
    /// Aborts whole tx if any NFT not owned by sponsor (no partial-escrow state).
    public entry fun create_nft_giveaway(
        sponsor: &signer,
        mint_seq: u64,
        collection_addr: address,
        nft_addrs: vector<address>,
        deadline_secs: u64,
        follower_only: bool,
        nft_gate_addr: address,
        nft_gate_set: bool,
        lp_stake_gate_addr: address,
        lp_stake_gate_set: bool,
    ) acquires PidGiveawayStorage {
        let sponsor_addr = signer::address_of(sponsor);
        let sponsor_pid = profile::derive_pid_address(sponsor_addr);
        profile::assert_pid_exists(sponsor_pid);

        // Validate mint_seq corresponds to a real mint by sponsor
        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        let constructor_ref = object::create_object(sponsor_addr);
        let giveaway_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        // Atomic escrow: verify each NFT owned by sponsor + transfer to giveaway_addr.
        // Closes race window where sponsor "promises" NFTs but never transfers,
        // leaving claimers in broken state.
        let n_nfts = vector::length(&nft_addrs);
        assert!(n_nfts > 0, E_GIVEAWAY_EXHAUSTED);    // empty giveaway = misuse, reject upfront
        let i = 0;
        while (i < n_nfts) {
            let nft_addr = *vector::borrow(&nft_addrs, i);
            let nft_obj = object::address_to_object<ObjectCore>(nft_addr);
            assert!(object::owner(nft_obj) == sponsor_addr, E_NOT_SPONSOR);
            object::transfer(sponsor, nft_obj, giveaway_addr);
            i = i + 1;
        };

        let giveaway = Giveaway {
            sponsor_pid,
            sponsor_wallet: sponsor_addr,
            kind: KIND_NFT,
            deadline_secs,
            fa_token_metadata: @0x0,
            fa_amount_per_claim: 0,
            fa_total_budget: 0,
            nft_collection_addr: collection_addr,
            nft_addrs,
            claims_made: 0,
            follower_only,
            nft_gate: if (nft_gate_set) option::some(nft_gate_addr) else option::none(),
            lp_stake_gate: if (lp_stake_gate_set) option::some(lp_stake_gate_addr) else option::none(),
            claimers: smart_table::new(),
            extend_ref,
        };

        move_to(&object_signer, giveaway);

        ensure_giveaway_storage(sponsor_pid);
        let storage = borrow_global_mut<PidGiveawayStorage>(sponsor_pid);
        smart_table::add(&mut storage.giveaways, mint_seq, giveaway_addr);

        event::emit(GiveawayCreated {
            sponsor_pid,
            mint_seq,
            giveaway_addr,
            kind: KIND_NFT,
            deadline_secs,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ CLAIM ============

    /// Permissionless claim. Validates gates + dedup + deadline + supply.
    /// FA mode: transfers amount_per_claim from escrow to claimer's primary store.
    /// NFT mode: pop_front nft_addrs (FCFS sequential), transfer NFT Object to claimer.
    ///
    /// `claimer_nft_proof_addr`: caller-supplied NFT Object addr for nft_gate verification.
    /// Must be owned by claimer's wallet AND in the gate-required collection. Pass `@0x0`
    /// if giveaway has no nft_gate.
    /// `claimer_stake_position_addr`: caller-supplied `desnet::lp_staking::Position` addr for
    /// lp_stake_gate verification. Pass `@0x0` if giveaway has no lp_stake_gate.
    public entry fun claim_giveaway(
        claimer: &signer,
        giveaway_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) acquires Giveaway {
        let claimer_addr = signer::address_of(claimer);
        let claimer_pid = profile::derive_pid_address(claimer_addr);
        profile::assert_pid_exists(claimer_pid);

        let giveaway = borrow_global_mut<Giveaway>(giveaway_addr);

        // Deadline + dedup
        let now = timestamp::now_seconds();
        assert!(now < giveaway.deadline_secs, E_GIVEAWAY_EXPIRED);
        assert!(!smart_table::contains(&giveaway.claimers, claimer_pid), E_ALREADY_CLAIMED);

        // Gate checks (3 independent, each opt-in via giveaway config)
        check_gates(giveaway, claimer_pid, claimer_addr, claimer_nft_proof_addr, claimer_stake_position_addr);

        // Derive giveaway escrow signer once (immutable ref through mut borrow is OK)
        let giveaway_signer = object::generate_signer_for_extending(&giveaway.extend_ref);

        // Mode-dispatch claim
        if (giveaway.kind == KIND_FA) {
            let token_metadata = object::address_to_object<Metadata>(giveaway.fa_token_metadata);
            let remaining = primary_fungible_store::balance(giveaway_addr, token_metadata);
            assert!(remaining >= giveaway.fa_amount_per_claim, E_GIVEAWAY_EXHAUSTED);

            // Withdraw from giveaway escrow + deposit to claimer
            let claim_fa = primary_fungible_store::withdraw(
                &giveaway_signer,
                token_metadata,
                giveaway.fa_amount_per_claim,
            );
            primary_fungible_store::deposit(claimer_addr, claim_fa);
        } else if (giveaway.kind == KIND_NFT) {
            assert!(!vector::is_empty(&giveaway.nft_addrs), E_GIVEAWAY_EXHAUSTED);
            // FCFS sequential: pop front, transfer to claimer
            let next_nft_addr = vector::remove(&mut giveaway.nft_addrs, 0);
            let nft_object = object::address_to_object<ObjectCore>(next_nft_addr);
            object::transfer(&giveaway_signer, nft_object, claimer_addr);
        } else {
            abort E_INVALID_KIND
        };

        smart_table::add(&mut giveaway.claimers, claimer_pid, true);
        giveaway.claims_made = giveaway.claims_made + 1;

        event::emit(GiveawayClaimed {
            giveaway_addr,
            claimer_pid,
            claim_index: giveaway.claims_made,
            timestamp_secs: now,
        });
    }

    // ============ SETTLE — permissionless post-deadline ============

    /// Anyone can call after deadline. Refunds unclaimed budget to sponsor's wallet,
    /// pays caller 5 bps bounty (FA mode) or no bounty (NFT mode).
    /// Idempotent on already-settled (re-call refunds 0 / transfers 0 NFTs, gas-only).
    public entry fun settle_giveaway(
        settler: &signer,
        giveaway_addr: address,
    ) acquires Giveaway {
        let giveaway = borrow_global_mut<Giveaway>(giveaway_addr);
        let now = timestamp::now_seconds();
        assert!(now >= giveaway.deadline_secs, E_NOT_DEADLINE);

        let settler_addr = signer::address_of(settler);
        let sponsor_wallet = giveaway.sponsor_wallet;
        let giveaway_signer = object::generate_signer_for_extending(&giveaway.extend_ref);

        let refund_amount: u64 = 0;
        let bounty: u64 = 0;

        if (giveaway.kind == KIND_FA) {
            let token_metadata = object::address_to_object<Metadata>(giveaway.fa_token_metadata);
            let remaining = primary_fungible_store::balance(giveaway_addr, token_metadata);
            if (remaining > 0) {
                bounty = (remaining * SETTLE_BOUNTY_BPS) / 10000;
                refund_amount = remaining - bounty;

                // Withdraw bounty + refund from escrow, deposit to settler + sponsor_wallet
                if (bounty > 0) {
                    let bounty_fa = primary_fungible_store::withdraw(
                        &giveaway_signer, token_metadata, bounty
                    );
                    primary_fungible_store::deposit(settler_addr, bounty_fa);
                };
                if (refund_amount > 0) {
                    let refund_fa = primary_fungible_store::withdraw(
                        &giveaway_signer, token_metadata, refund_amount
                    );
                    primary_fungible_store::deposit(sponsor_wallet, refund_fa);
                };
            };
        } else if (giveaway.kind == KIND_NFT) {
            // Refund remaining NFTs to sponsor_wallet (no bounty for NFT mode v1)
            let count = vector::length(&giveaway.nft_addrs);
            refund_amount = count;
            while (!vector::is_empty(&giveaway.nft_addrs)) {
                let nft_addr = vector::pop_back(&mut giveaway.nft_addrs);
                let nft_object = object::address_to_object<ObjectCore>(nft_addr);
                object::transfer(&giveaway_signer, nft_object, sponsor_wallet);
            };
        };

        // Note: giveaway resource NOT destroyed (preserves audit trail + claimers history).
        // Storage refund deferred — minor cost, idempotent re-settle returns 0/0.

        event::emit(GiveawaySettled {
            giveaway_addr,
            sponsor_pid: giveaway.sponsor_pid,
            settler: settler_addr,
            refund_amount,
            bounty_paid: bounty,
            timestamp_secs: now,
        });
    }

    // ============ INTERNAL — gate checks ============

    /// Three independent gates (LOCKED 2026-05-01: BUKAN unified ReferenceGate — different
    /// scope: giveaway = sponsor-defined eligibility per-mint, ReferenceGate = sync/balance/LP
    /// for verb engagement. Kept separate intentionally).
    ///
    /// Wallet-addr semantic (locked 2026-05-01): nft_gate + lp_stake_gate verify ownership
    /// at claimer's wallet (default custody for NFTs and stake positions).
    fun check_gates(
        giveaway: &Giveaway,
        claimer_pid: address,
        claimer_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) {
        // 1. follower_only — claimer must be synced to sponsor's PID
        if (giveaway.follower_only) {
            assert!(
                link::is_synced(claimer_pid, giveaway.sponsor_pid),
                E_FOLLOWER_GATE_FAILED
            );
        };

        // 2. nft_gate — claimer must hold ≥1 NFT in the required collection
        if (option::is_some(&giveaway.nft_gate)) {
            let required_collection = *option::borrow(&giveaway.nft_gate);
            assert!(claimer_nft_proof_addr != @0x0, E_NFT_GATE_FAILED);
            assert!(
                object::object_exists<token::Token>(claimer_nft_proof_addr),
                E_NFT_GATE_FAILED
            );
            let nft_obj = object::address_to_object<token::Token>(claimer_nft_proof_addr);
            assert!(object::owner(nft_obj) == claimer_addr, E_NFT_GATE_FAILED);
            // Verify NFT belongs to the required collection
            let collection_obj = token::collection_object(nft_obj);
            assert!(
                object::object_address(&collection_obj) == required_collection,
                E_NFT_GATE_FAILED
            );
        };

        // 3. lp_stake_gate — claimer must hold a Position on the required pool with shares > 0.
        // Ownership: free/time-locked → staker == claimer_addr; locked (creator's perma-lock) →
        // current PID owner of recipient_pid == claimer_addr.
        if (option::is_some(&giveaway.lp_stake_gate)) {
            let required_pool = *option::borrow(&giveaway.lp_stake_gate);
            assert!(claimer_stake_position_addr != @0x0, E_LP_STAKE_GATE_FAILED);
            assert!(
                lp_staking::has_position(claimer_stake_position_addr),
                E_LP_STAKE_GATE_FAILED
            );
            assert!(
                lp_staking::position_pool(claimer_stake_position_addr) == required_pool,
                E_LP_STAKE_GATE_FAILED
            );
            let recipient_pid = lp_staking::position_recipient_pid(claimer_stake_position_addr);
            if (recipient_pid == @0x0) {
                assert!(
                    lp_staking::position_owner(claimer_stake_position_addr) == claimer_addr,
                    E_LP_STAKE_GATE_FAILED
                );
            } else {
                let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
                assert!(object::owner(pid_obj) == claimer_addr, E_LP_STAKE_GATE_FAILED);
            };
            assert!(
                lp_staking::position_shares(claimer_stake_position_addr) > 0,
                E_LP_STAKE_GATE_FAILED
            );
        };
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidGiveawayStorage at PID addr. Called from create_*_giveaway
    /// on first-write. Idempotent. Cycle-safe via profile::derive_pid_signer.
    fun ensure_giveaway_storage(pid_addr: address) {
        if (!exists<PidGiveawayStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidGiveawayStorage {
                giveaways: smart_table::new(),
            });
        };
    }

    // ============ VIEWS ============

    #[view]
    public fun giveaway_addr_for_mint(sponsor_pid: address, mint_seq: u64): address
        acquires PidGiveawayStorage
    {
        let storage = borrow_global<PidGiveawayStorage>(sponsor_pid);
        *smart_table::borrow(&storage.giveaways, mint_seq)
    }

    #[view]
    public fun claims_made(giveaway_addr: address): u64 acquires Giveaway {
        borrow_global<Giveaway>(giveaway_addr).claims_made
    }

    #[view]
    public fun deadline_secs(giveaway_addr: address): u64 acquires Giveaway {
        borrow_global<Giveaway>(giveaway_addr).deadline_secs
    }

    #[view]
    public fun has_claimed(giveaway_addr: address, claimer_pid: address): bool acquires Giveaway {
        smart_table::contains(&borrow_global<Giveaway>(giveaway_addr).claimers, claimer_pid)
    }

    #[view]
    public fun kind_fa(): u8 { KIND_FA }

    #[view]
    public fun kind_nft(): u8 { KIND_NFT }

    #[view]
    public fun settle_bounty_bps(): u64 { SETTLE_BOUNTY_BPS }
}
```

---

## Module `press` (471 lines, 19784 bytes)

`sha3_256: cd4f08b938eaee1b9e148e4594bc7b6ac176f49d94f0be209364d140bd84dc4c`

```move
/// Press — NFT collectible wrapping a Mint (LOCKED 2026-05-01).
///
/// Vinyl-pressing metaphor: original recording (Mint) → physical vinyl (Press NFT).
/// Press IS technically a mint, but at NFT layer (different scope from Mint event).
///
/// Per-mint opt-in PressConfig (LOCKED):
///   - supply_cap: u16 (1-1000, no unlimited v1)
///   - window_days: u8 (1-7, no permanent open)
///   - emission curve: linear INCREASING per press order (anti-FOMO design):
///       emission(n) = n  (press #1 = 1 token, press #1000 = 1000 tokens)
///       Total per post: cap × (cap+1) / 2 (= 500,500 at cap=1000)
///
/// Per-actor uniqueness: each wallet can press a given mint ONLY once.
/// Author may self-press own mint, max 1 (same one-per-actor rule).
///
/// Royalty: 5% Aptos NFT v2 native, payee = PID Object addr (current owner).
/// Marketplace patuh otomatis. Future Press royalty 10% routed to vault (v2 spec).
///
/// First press = FREE (gas only). v1 tidak ada paid press; monetization = secondary market.
module desnet::press {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::event;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;
    use desnet::factory;

    // ============ CONSTANTS ============

    const SUPPLY_CAP_MIN: u16 = 1;
    const SUPPLY_CAP_MAX: u16 = 1000;
    const WINDOW_DAYS_MIN: u8 = 1;
    const WINDOW_DAYS_MAX: u8 = 7;
    const ROYALTY_BPS: u64 = 500;            // 5% Aptos NFT v2 native

    // ============ ERROR CODES ============

    const E_PRESS_NOT_ENABLED: u64 = 1;
    const E_PRESS_WINDOW_EXPIRED: u64 = 2;
    const E_PRESS_SUPPLY_EXHAUSTED: u64 = 3;
    const E_ALREADY_PRESSED: u64 = 4;
    const E_GATE_FAILED: u64 = 5;
    const E_INVALID_SUPPLY_CAP: u64 = 6;
    const E_INVALID_WINDOW_DAYS: u64 = 7;
    const E_PRESS_REGISTRY_NOT_FOUND: u64 = 8;
    const E_NOT_AUTHOR: u64 = 9;
    const E_PRESS_ALREADY_CONFIGURED: u64 = 10;
    const E_MINT_NOT_FOUND: u64 = 11;

    // ============ TYPES ============

    /// Per-mint Press configuration. Stored at author's PID, keyed by mint seq.
    struct PressConfig has store, copy, drop {
        supply_cap: u16,                     // 1-1000
        window_us: u64,                      // creation_ts + window_us = deadline
        pressed_count: u16,                  // mutable counter
        emission_consumed_total: u64,        // running sum of emissions
        deadline_us: u64,                    // creation_ts + window
    }

    /// Per-mint pressed registry (per-actor uniqueness check).
    /// Lives at author_pid, keyed by mint seq.
    struct PressedRegistry has store {
        pressed_by: SmartTable<address, bool>,  // actor → true after press
    }

    /// Per-author Press storage. SmartTable<seq, (PressConfig, PressedRegistry)>.
    struct PidPressStorage has key {
        configs: SmartTable<u64, PressConfig>,
        registries: SmartTable<u64, PressedRegistry>,
    }

    /// Per-author Press NFT Collection. Lazy-init at first press of any of author's mints.
    /// β-pattern (LOCKED 2026-04-30): "<handle>'s Presses" collection, all of author's
    /// Press NFTs minted into this single collection. Marketplaces auto-list them
    /// under author's brand.
    struct PressCollection has key {
        collection_addr: address,
        extend_ref: ExtendRef,                // for minting child tokens via Collection signer
        name: String,                          // e.g., "alice's Presses"
    }

    // ============ EVENTS ============

    #[event]
    struct PressEnabled has drop, store {
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_us: u64,
        deadline_us: u64,
        timestamp_secs: u64,
    }

    /// Press record. Replaces former #[event] — now BCS-encoded into
    /// history::Entry.payload at presser's PID. Struct retained for canonical encoding.
    struct PressMinted has drop, store {
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        press_order: u16,                    // n-th press (1-indexed)
        emission_amount: u64,                // = press_order (linear increasing)
        nft_object_addr: address,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidPressStorage at PID addr. Called from enable_press on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
    fun ensure_press_storage(pid_addr: address) {
        if (!exists<PidPressStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidPressStorage {
                configs: smart_table::new(),
                registries: smart_table::new(),
            });
        };
    }

    /// Lazy-create PressCollection at PID addr. Called from press() on first press of
    /// any of author's mints. Creates "<handle>'s Presses" collection with 5% royalty
    /// to author_pid.
    fun ensure_press_collection(author_pid: address): address acquires PressCollection {
        if (exists<PressCollection>(author_pid)) {
            return borrow_global<PressCollection>(author_pid).collection_addr
        };

        let pid_signer = profile::derive_pid_signer(author_pid);
        let handle = profile::handle_of(author_pid);
        let collection_name = build_collection_name(&handle);

        // 5% royalty payee = author's Vault addr → marketplace royalties land at vault,
        // triggering the 50/50 buyback-burn + PID-owner split flow on settle.
        let payee = factory::vault_addr_of_pid(author_pid);
        let r = royalty::create(ROYALTY_BPS, 10000, payee);

        let constructor_ref = collection::create_unlimited_collection(
            &pid_signer,
            build_collection_description(&handle),
            collection_name,
            option::some(r),
            build_collection_uri(&handle),
        );

        let collection_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(&pid_signer, PressCollection {
            collection_addr,
            extend_ref,
            name: collection_name,
        });

        collection_addr
    }

    fun build_collection_name(handle: &String): String {
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s Presses");
        s
    }

    fun build_collection_description(handle: &String): String {
        let s = string::utf8(b"Press NFTs collected from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mints on DeSNet.");
        s
    }

    fun build_collection_uri(_handle: &String): String {
        // Empty URI — frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    fun build_token_name(handle: &String, mint_seq: u64, press_order: u16): String {
        // Format: "<handle> #<mint_seq> press #<press_order>"
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b" #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b" press #");
        string::append(&mut s, u64_to_string((press_order as u64)));
        s
    }

    fun build_token_description(handle: &String, mint_seq: u64): String {
        let s = string::utf8(b"Pressed from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mint #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b".");
        s
    }

    fun build_token_uri(_handle: &String, _mint_seq: u64): String {
        // Empty URI — frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    /// Simple u64 → decimal String. Aptos stdlib doesn't have utoa, hand-roll.
    fun u64_to_string(n: u64): String {
        if (n == 0) return string::utf8(b"0");
        let buf = std::vector::empty<u8>();
        while (n > 0) {
            let d = ((n % 10) as u8) + 0x30;  // '0' = 0x30
            std::vector::push_back(&mut buf, d);
            n = n / 10;
        };
        std::vector::reverse(&mut buf);
        string::utf8(buf)
    }

    // ============ ENABLE PRESS — author opt-in per mint ============

    /// Author opts in to Press for a specific mint. Sets supply_cap + window.
    /// One-time per mint; cannot reconfigure after first press.
    public entry fun enable_press(
        author: &signer,
        mint_seq: u64,
        supply_cap: u16,
        window_days: u8,
    ) acquires PidPressStorage {
        assert!(supply_cap >= SUPPLY_CAP_MIN && supply_cap <= SUPPLY_CAP_MAX, E_INVALID_SUPPLY_CAP);
        assert!(window_days >= WINDOW_DAYS_MIN && window_days <= WINDOW_DAYS_MAX, E_INVALID_WINDOW_DAYS);

        let author_pid = profile::derive_pid_address(signer::address_of(author));
        profile::assert_pid_exists(author_pid);

        // Validate mint_seq corresponds to a real mint. Without this, author can
        // enable_press on bogus seqs and farm reaction emission via secondary wallets.
        assert!(mint_seq < mint::next_seq(author_pid), E_MINT_NOT_FOUND);

        ensure_press_storage(author_pid);

        let storage = borrow_global_mut<PidPressStorage>(author_pid);
        assert!(!smart_table::contains(&storage.configs, mint_seq), E_PRESS_ALREADY_CONFIGURED);

        let now_us = timestamp::now_seconds() * 1_000_000;
        let window_us = (window_days as u64) * 86_400 * 1_000_000;
        let deadline_us = now_us + window_us;

        let config = PressConfig {
            supply_cap,
            window_us,
            pressed_count: 0,
            emission_consumed_total: 0,
            deadline_us,
        };

        smart_table::add(&mut storage.configs, mint_seq, config);
        smart_table::add(&mut storage.registries, mint_seq, PressedRegistry {
            pressed_by: smart_table::new(),
        });

        event::emit(PressEnabled {
            author_pid,
            mint_seq,
            supply_cap,
            window_us,
            deadline_us,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ PRESS — anyone can press, gates checked ============

    /// Press a mint. Mints Aptos NFT v2 collectible to presser's wallet.
    /// Atomic: register press → mint NFT → emit event → emission bonus (if pool seeded).
    ///
    /// Validation chain:
    /// 1. PressConfig exists for (author_pid, mint_seq) — author opted in
    /// 2. Window not expired
    /// 3. Supply not exhausted
    /// 4. Per-actor uniqueness — presser hasn't pressed this mint before
    /// 5. Mint-level ReferenceGate (if any) passes for presser
    ///
    /// Emission bonus path: if author's $TOKEN/D pool seeded → mint emission(n) tokens
    /// to presser. If pool not seeded → press succeeds without emission. (LOCKED.)
    public entry fun press(
        presser: &signer,
        author_pid: address,
        mint_seq: u64,
        presser_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidPressStorage, PressCollection {
        let presser_addr = signer::address_of(presser);
        let presser_pid = profile::derive_pid_address(presser_addr);
        profile::assert_pid_exists(presser_pid);

        assert!(exists<PidPressStorage>(author_pid), E_PRESS_NOT_ENABLED);

        // Mint-level ReferenceGate (self-exempt: author always passes own gate).
        // Done before mut-borrow phase to keep storage scope pure.
        // Self-exempt via PID; gate check via wallet addr (presser_addr) per locked semantic
        // 2026-05-01: balance + LP-stake ownership at wallet that holds PID NFT.
        if (presser_pid != author_pid) {
            let gate_opt = mint::get_mint_gate(author_pid, mint_seq);
            if (option::is_some(&gate_opt)) {
                let target_pid = reference_gate::target_pid(option::borrow(&gate_opt));
                let synced = link::is_synced(presser_pid, target_pid);
                let gate = option::extract(&mut gate_opt);
                assert!(
                    reference_gate::check(&gate, presser_addr, synced, false, presser_stake_position_addr),
                    E_GATE_FAILED
                );
            };
        };

        // Validation phase — check + bump counters in mut-borrow scope
        let press_order: u16;
        let supply_cap: u16;        // captured for emission call below
        {
            let storage = borrow_global_mut<PidPressStorage>(author_pid);
            assert!(smart_table::contains(&storage.configs, mint_seq), E_PRESS_NOT_ENABLED);

            let config = smart_table::borrow_mut(&mut storage.configs, mint_seq);
            let now_us = timestamp::now_seconds() * 1_000_000;
            assert!(now_us < config.deadline_us, E_PRESS_WINDOW_EXPIRED);
            assert!(config.pressed_count < config.supply_cap, E_PRESS_SUPPLY_EXHAUSTED);

            // Per-actor uniqueness
            let registry = smart_table::borrow_mut(&mut storage.registries, mint_seq);
            assert!(!smart_table::contains(&registry.pressed_by, presser_pid), E_ALREADY_PRESSED);

            // Register press + bump counters
            smart_table::add(&mut registry.pressed_by, presser_pid, true);
            config.pressed_count = config.pressed_count + 1;
            press_order = config.pressed_count;
            supply_cap = config.supply_cap;
            let emission_amount_local = press_order as u64;
            config.emission_consumed_total = config.emission_consumed_total + emission_amount_local;
        };  // PidPressStorage borrow released here

        // ============ NFT v2 mint ============

        // Lazy-init "<handle>'s Presses" Collection (β-pattern locked 2026-04-30).
        // Collection is created with pid_signer (= creator addr = author_pid).
        let _collection_addr = ensure_press_collection(author_pid);

        let handle = profile::handle_of(author_pid);
        let token_name = build_token_name(&handle, mint_seq, press_order);
        let token_description = build_token_description(&handle, mint_seq);
        let token_uri = build_token_uri(&handle, mint_seq);

        let collection_state = borrow_global<PressCollection>(author_pid);
        let collection_name = collection_state.name;

        // CRITICAL: token::create derives Collection address from (creator_addr, name).
        // Must use pid_signer (the SAME signer that created the Collection in
        // ensure_press_collection), not collection_signer — otherwise derivation
        // mismatches and aborts EOBJECT_DOES_NOT_EXIST.
        let pid_signer = profile::derive_pid_signer(author_pid);

        // Mint Token Object inside collection. None royalty = inherit from collection (5%).
        let token_constructor_ref = token::create(
            &pid_signer,
            collection_name,
            token_description,
            token_name,
            option::none(),
            token_uri,
        );

        let nft_object_addr = object::address_from_constructor_ref(&token_constructor_ref);
        let token_object = object::object_from_constructor_ref<token::Token>(&token_constructor_ref);

        // Transfer to presser. token::create with pid_signer → token owned by author_pid.
        // pid_signer authorizes transfer to presser.
        object::transfer(&pid_signer, token_object, presser_addr);

        // ============ Emission bonus ============
        // Call factory wrapper which proxies to reaction_emission::emit_to_presser.
        // Returns actual amount distributed (≤ press_order × REACTION_BASE_VALUE; capped
        // at remaining reserve balance). Reserve depletion = emission 0 but press still
        // succeeds (graceful degradation).
        //
        // BLOCK self-press emission. NFT mint allowed (author can collect own work) but
        // emission to author's own wallet is denied — would let author drain their own
        // reaction reserve via single self-press. Per-actor uniqueness prevents multi-press
        // by same wallet; mint_seq validation above prevents bogus-seq farming.
        let emission_amount = if (presser_pid == author_pid) {
            0
        } else {
            // post_id encoding: bcs(author_pid) || bcs(mint_seq) — opaque to factory,
            // used for indexer correlation in ReactionEmitted event.
            let post_id = bcs::to_bytes(&author_pid);
            std::vector::append(&mut post_id, bcs::to_bytes(&mint_seq));
            factory::emit_press_to_presser(
                &pid_signer,
                presser_addr,
                post_id,
                (press_order as u64),
                (supply_cap as u64),
            )
        };

        let now_secs = timestamp::now_seconds();
        let record = PressMinted {
            presser_pid,
            author_pid,
            mint_seq,
            press_order,
            emission_amount,
            nft_object_addr,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        // History at presser's PID (the actor performing the verb), target = author_pid.
        history::append(
            presser_pid,
            history::new_entry(history::verb_press(), now_secs, option::some(author_pid), payload, option::none<address>()),
        );
    }

    // ============ VIEWS ============

    #[view]
    public fun is_press_enabled(author_pid: address, mint_seq: u64): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        smart_table::contains(&borrow_global<PidPressStorage>(author_pid).configs, mint_seq)
    }

    #[view]
    public fun pressed_count(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return 0;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.configs, mint_seq)) return 0;
        smart_table::borrow(&storage.configs, mint_seq).pressed_count
    }

    #[view]
    public fun supply_cap(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).supply_cap
    }

    #[view]
    public fun deadline_us(author_pid: address, mint_seq: u64): u64 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).deadline_us
    }

    #[view]
    public fun has_pressed(
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
    ): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.registries, mint_seq)) return false;
        let registry = smart_table::borrow(&storage.registries, mint_seq);
        smart_table::contains(&registry.pressed_by, presser_pid)
    }

    #[view]
    public fun royalty_bps(): u64 { ROYALTY_BPS }
}
```

---

## Module `pulse` (261 lines, 9959 bytes)

`sha3_256: 73576c3dc4fbc207ba94d3a9e123b1100ede18baab35c34d6ea2a612010d321f`

```move
/// Pulse — reactions umbrella event (Spark + Echo) (LOCKED 2026-05-01).
///
/// Spark = like → reaction_kind=SPARK
/// Echo = repost forward-as-is → reaction_kind=ECHO
/// Voice (reply) and Remix (quote) live in mint.move (they create new MintEvents).
/// Press (NFT collectible) lives in press.move (different scope: NFT mint).
///
/// State pattern: PulseEvent { reaction_kind, state: ADD/REMOVE }. Aptos events
/// are append-only on emit — un-action emits state=REMOVE same kind. Asymmetric
/// "abort" pattern rejected (events immutable).
///
/// Mint-level gate (ReferenceGate) checked here before allowing reaction.
/// Self-exempt: mint creator always allowed (e.g., self-spark on own mint).
module desnet::pulse {
    use std::bcs;
    use std::signer;
    use std::option;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;

    // ============ CONSTANTS ============

    /// reaction_kind enum
    const REACTION_SPARK: u8 = 1;
    const REACTION_ECHO: u8 = 2;

    /// state enum
    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    // ============ ERROR CODES ============

    const E_GUEST_CANNOT_REACT: u64 = 1;
    const E_INVALID_REACTION_KIND: u64 = 2;
    const E_GATE_FAILED: u64 = 3;
    const E_ALREADY_REACTED: u64 = 4;
    const E_NOT_REACTED: u64 = 5;
    const E_REACTION_REGISTRY_NOT_INITIALIZED: u64 = 6;

    // ============ TYPES ============

    /// Per-PID reaction registry. Stored at actor's PID Object addr.
    /// Keyed by (target_author, target_seq, reaction_kind) tuple → bool (ADD).
    /// SmartTable key encoded as packed bytes for compound key.
    struct PidReactionRegistry has key {
        // (target_author || target_seq || reaction_kind) bytes → true if currently active
        active: SmartTable<vector<u8>, bool>,
        spark_count_given: u64,
        echo_count_given: u64,
    }

    // ============ EVENTS ============

    /// Unified Pulse record for Spark + Echo. State ADD on first emit, REMOVE on un-action.
    /// Replaces former #[event] — now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct PulseEvent has drop, store {
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,                // REACTION_SPARK | REACTION_ECHO
        state: u8,                        // STATE_ADD | STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidReactionRegistry at PID addr. Called from spark/echo on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
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

    // ============ SPARK + UNSPARK ============

    public entry fun spark(
        actor: &signer,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        let actor_addr = signer::address_of(actor);
        let actor_pid = profile::derive_pid_address(actor_addr);
        profile::assert_pid_exists(actor_pid);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, true);
    }

    public entry fun unspark(
        actor: &signer,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        let actor_pid = profile::derive_pid_address(signer::address_of(actor));
        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, false);
    }

    // ============ ECHO + UNECHO ============

    public entry fun echo(
        actor: &signer,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        let actor_addr = signer::address_of(actor);
        let actor_pid = profile::derive_pid_address(actor_addr);
        profile::assert_pid_exists(actor_pid);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, true);
    }

    public entry fun unecho(
        actor: &signer,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        let actor_pid = profile::derive_pid_address(signer::address_of(actor));
        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, false);
    }

    // ============ INTERNAL — gate + toggle ============

    /// Self-exempt comparison via PID (target_author is a PID addr).
    /// Sync check uses PID-space (link::is_synced takes PIDs).
    /// reference_gate::check uses WALLET addr (actor_addr) — semantic locked 2026-05-01:
    /// balance + LP-stake ownership both expected at wallet address that holds PID NFT.
    fun check_mint_gate_or_self_exempt(
        actor_addr: address,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,
    ) {
        // Self-exempt: actor IS author of target mint
        if (actor_pid == target_author) return;

        let gate_opt = mint::get_mint_gate(target_author, target_seq);
        if (option::is_none(&gate_opt)) return;  // no gate, open access

        // Pre-compute sync state via link (cycle-safe: pulse uses link, link doesn't use pulse).
        let target_pid = reference_gate::target_pid(option::borrow(&gate_opt));
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

        // Verb dispatch: Spark=1, Echo=3. Both ADD and REMOVE are written to history
        // (each toggle is a distinct user action with its own timestamp).
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

    // ============ VIEWS ============

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
```

---
