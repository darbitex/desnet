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
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::timestamp;

    // ============ CONSTANTS ============

    const CHUNK_SIZE_MAX: u64 = 30000;
    const MAX_TOTAL_SIZE: u64 = 5_000_000;     // 5MB

    // v0.3.4 Tier-3 deterministic-addr seeds. Seeds are domain-separated by
    // a constant prefix so master/chunk/node namespaces never collide. Two
    // uploaders cannot collide either — `create_named_object` mixes the
    // uploader's address into the hash before the seed bytes.
    const SEED_PREFIX_MASTER: vector<u8> = b"desnet/asset/master/";
    const SEED_PREFIX_CHUNK: vector<u8>  = b"desnet/asset/chunk/";
    const SEED_PREFIX_NODE: vector<u8>   = b"desnet/asset/node/";

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
    /// v0.3.4 Tier-3: caller's chosen nonce/index already used. Pick a fresh value.
    const E_SEED_TAKEN: u64 = 12;
    /// v0.3.4 Tier-3 finalize_v2: the depth/root pair caller passed doesn't match
    /// what the deterministic addresses prove. Fail-fast — callers should use the
    /// `derive_*_addr_v2` views to build a consistent root.
    const E_ROOT_MISMATCH: u64 = 13;

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
    /// v0.3.4: body delegates to `start_upload_internal`; `start_upload_pub`
    /// is the address-returning sibling for Move-script bundling (Tier-2
    /// orchestrator). Existing ABI is unchanged.
    public entry fun start_upload(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ) {
        let _master_addr = start_upload_internal(uploader, mime, total_size, creator_pid);
    }

    /// v0.3.4 (Tier-2 orchestrator support): same as the entry above, but
    /// returns master_addr so a Move script can chain it directly into
    /// `deploy_chunk_pub` / `finalize` without round-tripping the address
    /// through an event. ABI is purely additive.
    public fun start_upload_pub(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ): address {
        start_upload_internal(uploader, mime, total_size, creator_pid)
    }

    fun start_upload_internal(
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

        event::emit(AssetMasterCreated {
            master_addr,
            creator_pid,
            mime,
            total_size,
            timestamp_secs: now_secs,
        });

        master_addr
    }

    // ============ ENTRY: deploy_chunk ============

    /// Deploy a leaf chunk (≤30KB). Master must exist and not be sealed.
    /// Returns chunk_addr via emitted event. v0.3.4 delegates body to
    /// `deploy_chunk_internal`.
    public entry fun deploy_chunk(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ) acquires Master {
        let _chunk_addr = deploy_chunk_internal(uploader, master_addr, data);
    }

    /// v0.3.4 (Tier-2): same body but returns chunk_addr.
    public fun deploy_chunk_pub(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ): address acquires Master {
        deploy_chunk_internal(uploader, master_addr, data)
    }

    fun deploy_chunk_internal(
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

        event::emit(AssetChunkDeployed {
            master_addr,
            chunk_addr,
            data_len: len,
            timestamp_secs: timestamp::now_seconds(),
        });

        chunk_addr
    }

    // ============ ENTRY: deploy_node ============

    /// Deploy an internal Node pointing to children (chunk addrs or sub-node addrs).
    /// Used for tree depth ≥1. Master must not be sealed.
    /// Returns node_addr via emitted event. v0.3.4 delegates to
    /// `deploy_node_internal`.
    public entry fun deploy_node(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ) acquires Master {
        let _node_addr = deploy_node_internal(uploader, master_addr, children);
    }

    /// v0.3.4 (Tier-2): same body but returns node_addr.
    public fun deploy_node_pub(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ): address acquires Master {
        deploy_node_internal(uploader, master_addr, children)
    }

    fun deploy_node_internal(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ): address acquires Master {
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

        node_addr
    }

    // ============ ENTRY: finalize ============

    /// Finalize Master: set root + depth, mark sealed=true. After this, the asset
    /// is permanently immutable from this module's perspective.
    /// Caller is responsible for having deployed root chunk/node beforehand.
    /// v0.3.4 delegates body to `finalize_internal`.
    public entry fun finalize(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        finalize_internal(uploader, master_addr, root, depth);
    }

    /// v0.3.4 (Tier-2): script-callable finalize. Returns nothing because
    /// finalize is purely state-mutation; scripts can call it as the last
    /// step of a bundled upload after `start_upload_pub` + `deploy_chunk_pub`
    /// chain.
    public fun finalize_pub(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        finalize_internal(uploader, master_addr, root, depth);
    }

    fun finalize_internal(
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

    // ============ v0.3.4 TIER-3 — deterministic-address `*_v2` entries ============
    //
    // These mirror the v1 entries but use `object::create_named_object` with
    // caller-supplied indices, so the resulting addresses are predictable
    // off-chain via `derive_*_addr_v2` views. JS can pre-compute every chunk
    // address before submitting any tx — the entire upload + the final
    // `create_mint` collapse into one Move script transaction.
    //
    // Compat: v1 entries are untouched. Existing uploads via the v1 path keep
    // working bit-for-bit. v2 entries are ABI-additive.
    //
    // Seed scope: `create_named_object(creator, seed)` mixes `signer::address_of(creator)`
    // into the SHA3-256, so the per-creator seed namespace is isolated. Two
    // different uploaders cannot collide even with the same nonce.

    /// v0.3.4 (Tier-3): deterministic-addr Master allocation. Caller picks
    /// any u64 nonce — addr = sha3(uploader || SEED_PREFIX_MASTER || bcs(nonce) || 0xFE).
    /// Aborts E_SEED_TAKEN if (uploader, nonce) was used before. Common pattern:
    /// nonce = `timestamp::now_microseconds()` to make collisions impossible
    /// in practice; or a per-uploader counter the frontend tracks locally.
    public fun start_upload_v2(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
        nonce: u64,
    ): address {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        let seed = master_seed(nonce);
        let uploader_addr = signer::address_of(uploader);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Master>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, master_seed(nonce));
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

        master_addr
    }

    /// v0.3.4 (Tier-3): deterministic-addr Chunk allocation. `chunk_index`
    /// must be unique per (uploader, master). Convention: 0-indexed from the
    /// frontend's chunking pass.
    public fun deploy_chunk_v2(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
        chunk_index: u64,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let seed = chunk_seed(master_addr, chunk_index);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Chunk>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, chunk_seed(master_addr, chunk_index));
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);

        move_to(&chunk_signer, Chunk { data });

        event::emit(AssetChunkDeployed {
            master_addr,
            chunk_addr,
            data_len: len,
            timestamp_secs: timestamp::now_seconds(),
        });

        chunk_addr
    }

    /// v0.3.4 (Tier-3): deterministic-addr Node. `node_index` must be unique
    /// per (uploader, master). Frontend convention: 0..N-1 for leaf-grouping
    /// nodes, then N for the root in a depth-2 tree.
    public fun deploy_node_v2(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
        node_index: u64,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let n = vector::length(&children);
        assert!(n > 0, E_NODE_EMPTY);

        let seed = node_seed(master_addr, node_index);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Node>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, node_seed(master_addr, node_index));
        let node_signer = object::generate_signer(&constructor_ref);
        let node_addr = signer::address_of(&node_signer);

        move_to(&node_signer, Node { children });

        event::emit(AssetNodeDeployed {
            master_addr,
            node_addr,
            children_count: n,
            timestamp_secs: timestamp::now_seconds(),
        });

        node_addr
    }

    /// v0.3.4 (Tier-3): finalize variant that double-checks `root` matches a
    /// derivable seed. Mostly redundant with v1 finalize (which only verifies
    /// the resource exists), but worth having for callers that derive `root`
    /// JS-side and want belt-and-suspenders confidence the addr they pass
    /// matches an `*_v2`-deployed object.
    ///
    /// `root_index_opt = none` → caller passes the raw root addr and we just
    /// verify resource existence (same as v1 finalize, but reachable from
    /// scripts without `entry`).
    /// `root_index_opt = some(idx)` → we recompute the seed and assert the
    /// hash matches `root` before sealing.
    public fun finalize_v2(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
        root_index: u64,
        verify_seed: bool,
    ) acquires Master {
        if (verify_seed) {
            let uploader_addr = signer::address_of(uploader);
            let seed = if (depth == 0) {
                chunk_seed(master_addr, root_index)
            } else {
                node_seed(master_addr, root_index)
            };
            let expected = object::create_object_address(&uploader_addr, seed);
            assert!(expected == root, E_ROOT_MISMATCH);
        };
        finalize_internal(uploader, master_addr, root, depth);
    }

    // ============ Tier-3 seed helpers + JS-derivation views ============

    fun master_seed(nonce: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_MASTER);
        vector::append(&mut s, bcs::to_bytes(&nonce));
        s
    }

    fun chunk_seed(master_addr: address, chunk_index: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_CHUNK);
        vector::append(&mut s, bcs::to_bytes(&master_addr));
        vector::append(&mut s, bcs::to_bytes(&chunk_index));
        s
    }

    fun node_seed(master_addr: address, node_index: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_NODE);
        vector::append(&mut s, bcs::to_bytes(&master_addr));
        vector::append(&mut s, bcs::to_bytes(&node_index));
        s
    }

    /// JS-callable: pre-compute a Tier-3 master addr for (uploader, nonce)
    /// before any tx is signed. Lets the frontend bundle start_upload_v2 +
    /// deploy_chunk_v2 × N + finalize_v2 in one Move script with all addrs
    /// known up front.
    #[view]
    public fun derive_master_addr_v2(uploader: address, nonce: u64): address {
        object::create_object_address(&uploader, master_seed(nonce))
    }

    #[view]
    public fun derive_chunk_addr_v2(uploader: address, master_addr: address, chunk_index: u64): address {
        object::create_object_address(&uploader, chunk_seed(master_addr, chunk_index))
    }

    #[view]
    public fun derive_node_addr_v2(uploader: address, master_addr: address, node_index: u64): address {
        object::create_object_address(&uploader, node_seed(master_addr, node_index))
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

    /// v0.3.4: capability marker for the asset-upload orchestrator tier the
    /// frontend can use against THIS bytecode version. Returns:
    ///   1 = only original entries (multi-tx, address from events)
    ///   2 = `*_pub` mirrors live (Move script bundling possible, fewer txs)
    ///   3 = deterministic-address `*_v2` entries live (B3 single-tx upload)
    /// Frontend calls this to auto-enable higher tiers in the picker. v0.3.3
    /// did NOT have this view, so frontends fall back to tier 1 on the call
    /// failing — no breakage. v0.3.4 ships BOTH B2 (`*_pub` mirrors) AND B3
    /// (`*_v2` deterministic-addr entries) so this returns 3.
    #[view]
    public fun orchestrator_tier(): u8 { 3 }

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

    // ============ v0.3.4 TIER-2 (B2) tests ============

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    fun test_b2_pub_returns_addresses(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_pub(uploader, MIME_PNG, 1024, @0xfeed);
        assert!(exists<Master>(master_addr), 1);
        assert!(!is_sealed(master_addr), 2);

        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0xAA);
        let chunk_addr = deploy_chunk_pub(uploader, master_addr, data);
        assert!(exists<Chunk>(chunk_addr), 3);

        finalize_pub(uploader, master_addr, chunk_addr, 0);
        assert!(is_sealed(master_addr), 4);
        assert!(root_of(master_addr) == chunk_addr, 5);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    fun test_orchestrator_tier_is_3_in_v034(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        assert!(orchestrator_tier() == 3, 1);
    }

    // ============ v0.3.4 TIER-3 (B3) tests ============

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    fun test_b3_lifecycle_single_chunk(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let uploader_addr = signer::address_of(uploader);

        // Pre-compute master addr off-chain (the JS-equivalent path).
        let predicted_master = derive_master_addr_v2(uploader_addr, 42);
        let master_addr = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 42);
        assert!(predicted_master == master_addr, 1);

        // Pre-compute chunk addr.
        let predicted_chunk = derive_chunk_addr_v2(uploader_addr, master_addr, 0);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x99);
        let chunk_addr = deploy_chunk_v2(uploader, master_addr, data, 0);
        assert!(predicted_chunk == chunk_addr, 2);

        // finalize_v2 with verify_seed=true must accept the matching root.
        finalize_v2(uploader, master_addr, chunk_addr, 0, 0, true);
        assert!(is_sealed(master_addr), 3);
        assert!(root_of(master_addr) == chunk_addr, 4);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    fun test_b3_depth1_node_predictable(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let uploader_addr = signer::address_of(uploader);

        let master = start_upload_v2(uploader, MIME_PNG, 200, @0xfeed, 1);

        let d1 = vector::empty<u8>(); vector::push_back(&mut d1, 0x01);
        let d2 = vector::empty<u8>(); vector::push_back(&mut d2, 0x02);
        let c1 = deploy_chunk_v2(uploader, master, d1, 0);
        let c2 = deploy_chunk_v2(uploader, master, d2, 1);

        let predicted_node = derive_node_addr_v2(uploader_addr, master, 0);
        let children = vector::empty<address>();
        vector::push_back(&mut children, c1);
        vector::push_back(&mut children, c2);
        let node = deploy_node_v2(uploader, master, children, 0);
        assert!(predicted_node == node, 1);

        finalize_v2(uploader, master, node, 1, 0, true);
        assert!(depth_of(master) == 1, 2);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_master_nonce_collision_aborts(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        // Same nonce twice from same uploader → collision → abort.
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_chunk_index_collision_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 8);
        let d1 = vector::empty<u8>(); vector::push_back(&mut d1, 0x11);
        let d2 = vector::empty<u8>(); vector::push_back(&mut d2, 0x22);
        deploy_chunk_v2(uploader, master, d1, 0);
        // Same chunk_index → collision.
        deploy_chunk_v2(uploader, master, d2, 0);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_ROOT_MISMATCH, location = Self)]
    fun test_b3_finalize_v2_root_mismatch_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 9);
        let d = vector::empty<u8>(); vector::push_back(&mut d, 0x33);
        let c = deploy_chunk_v2(uploader, master, d, 0);
        // Pass a bogus root with verify_seed=true → must abort.
        let _ = c;
        finalize_v2(uploader, master, @0xdeadbeef, 0, 0, true);
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_b3_per_uploader_seed_isolation(
        framework: &signer,
        alice: &signer,
        bob: &signer,
    ) {
        setup_test_env(framework, alice);
        aptos_framework::account::create_account_for_test(signer::address_of(bob));

        // Same nonce across different uploaders → distinct addresses, both succeed.
        let master_alice = start_upload_v2(alice, MIME_PNG, 100, @0xfeed, 5);
        let master_bob = start_upload_v2(bob, MIME_PNG, 100, @0xfeed, 5);
        assert!(master_alice != master_bob, 1);
    }
}
