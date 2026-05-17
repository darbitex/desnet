module desnet::assets {
    use std::bcs;
    use std::signer;
    use std::vector;
    use supra_framework::event;
    use supra_framework::object;
    use supra_framework::timestamp;

    const CHUNK_SIZE_MAX: u64 = 30000;
    const MAX_TOTAL_SIZE: u64 = 5_000_000;

    const SEED_PREFIX_MASTER: vector<u8> = b"desnet/asset/master/";
    const SEED_PREFIX_CHUNK: vector<u8>  = b"desnet/asset/chunk/";
    const SEED_PREFIX_NODE: vector<u8>   = b"desnet/asset/node/";

    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

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
    const E_SEED_TAKEN: u64 = 12;
    const E_ROOT_MISMATCH: u64 = 13;

    struct Master has key {
        root: address,
        depth: u8,
        total_size: u64,
        mime: u8,
        creator_pid: address,
        creator_addr: address,
        sealed: bool,
        created_at_secs: u64,
    }

    struct Chunk has key {
        data: vector<u8>,
    }

    struct Node has key {
        children: vector<address>,
    }

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

    public entry fun start_upload(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ) {
        let _master_addr = start_upload_internal(uploader, mime, total_size, creator_pid);
    }

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

    public entry fun deploy_chunk(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ) acquires Master {
        let _chunk_addr = deploy_chunk_internal(uploader, master_addr, data);
    }

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

    public entry fun deploy_node(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ) acquires Master {
        let _node_addr = deploy_node_internal(uploader, master_addr, children);
    }

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

    public entry fun finalize(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        finalize_internal(uploader, master_addr, root, depth);
    }

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
        assert!(master.creator_addr == signer::address_of(uploader), E_NOT_CREATOR);

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

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

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

    #[test]
    fun test_assert_valid_mime_accepts_all_five() {
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

    #[test_only]
    fun setup_test_env(framework: &signer, uploader: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        supra_framework::account::create_account_for_test(signer::address_of(uploader));
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
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

    #[test(framework = @supra_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_finalize_rejects_non_creator_A2_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        supra_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_JPEG, 100, @0xfeed);
        finalize(attacker, master_addr, @0xdeadbeef, 0);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_deploy_chunk_rejects_non_creator_A3_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        supra_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_GIF, 100, @0xfeed);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x42);
        deploy_chunk_for_test(attacker, master_addr, data);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
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

        let data2 = vector::empty<u8>();
        vector::push_back(&mut data2, 0x42);
        deploy_chunk_for_test(uploader, master_addr, data2);
    }

    #[test(uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_TOTAL_SIZE_EXCEEDED, location = Self)]
    fun test_start_upload_total_size_cap(uploader: &signer) {
        start_upload_for_test(uploader, MIME_SVG, 5_000_001, @0xfeed);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
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

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_orchestrator_tier_is_3_in_v034(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        assert!(orchestrator_tier() == 3, 1);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_b3_lifecycle_single_chunk(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let uploader_addr = signer::address_of(uploader);

        let predicted_master = derive_master_addr_v2(uploader_addr, 42);
        let master_addr = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 42);
        assert!(predicted_master == master_addr, 1);

        let predicted_chunk = derive_chunk_addr_v2(uploader_addr, master_addr, 0);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x99);
        let chunk_addr = deploy_chunk_v2(uploader, master_addr, data, 0);
        assert!(predicted_chunk == chunk_addr, 2);

        finalize_v2(uploader, master_addr, chunk_addr, 0, 0, true);
        assert!(is_sealed(master_addr), 3);
        assert!(root_of(master_addr) == chunk_addr, 4);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
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

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_master_nonce_collision_aborts(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_chunk_index_collision_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 8);
        let d1 = vector::empty<u8>(); vector::push_back(&mut d1, 0x11);
        let d2 = vector::empty<u8>(); vector::push_back(&mut d2, 0x22);
        deploy_chunk_v2(uploader, master, d1, 0);
        deploy_chunk_v2(uploader, master, d2, 0);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_ROOT_MISMATCH, location = Self)]
    fun test_b3_finalize_v2_root_mismatch_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 9);
        let d = vector::empty<u8>(); vector::push_back(&mut d, 0x33);
        let c = deploy_chunk_v2(uploader, master, d, 0);
        let _ = c;
        finalize_v2(uploader, master, @0xdeadbeef, 0, 0, true);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_b3_per_uploader_seed_isolation(
        framework: &signer,
        alice: &signer,
        bob: &signer,
    ) {
        setup_test_env(framework, alice);
        supra_framework::account::create_account_for_test(signer::address_of(bob));

        let master_alice = start_upload_v2(alice, MIME_PNG, 100, @0xfeed, 5);
        let master_bob = start_upload_v2(bob, MIME_PNG, 100, @0xfeed, 5);
        assert!(master_alice != master_bob, 1);
    }
}
