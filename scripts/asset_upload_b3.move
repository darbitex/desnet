// asset_upload_b3.move — Tier-3 deterministic-addr asset upload script.
//
// Same shape as asset_upload_b2.move but uses the *_v2 entries that take
// caller-supplied indices/nonces and produce deterministic addresses.
// Frontend pre-computes every address in JS via sha3-256, so by the time
// the script runs every chunk + node addr is already known up-front. No
// event reads required to plumb the next call's input.
//
// Tree shape encoding identical to b2: node_chunk_counts = [] (depth 0),
// [n] (depth 1), [c1,c2,...] (depth 2).
//
// Caller passes a u64 master_nonce (typically a high-resolution timestamp
// or per-uploader counter) — the same nonce can be reused with the
// derive_master_addr_v2 view to pre-compute the master_addr off-chain.

script {
    use std::vector;
    use desnet::assets;

    fun upload_b3(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
        master_nonce: u64,
        chunks: vector<vector<u8>>,
        node_chunk_counts: vector<u64>,
        depth: u8,
    ) {
        // Script-side abort codes are in the 100-range to avoid visual
        // collision with assets.move module errors (1-13).
        assert!(depth <= 2, 100);
        let master_addr = assets::start_upload_v2(
            uploader, mime, total_size, creator_pid, master_nonce
        );

        // Deploy chunks with explicit 0..N-1 indices. Pop-from-back drains
        // the vector; we recover order via reverse before slicing into nodes.
        let n = vector::length(&chunks);
        let chunk_addrs = vector::empty<address>();
        let i = 0;
        while (i < n) {
            let data = vector::pop_back(&mut chunks);
            // Index = original position before reverse. Track it as `n - 1 - i`.
            let chunk_index = n - 1 - i;
            let chunk_addr = assets::deploy_chunk_v2(
                uploader, master_addr, data, chunk_index
            );
            vector::push_back(&mut chunk_addrs, chunk_addr);
            i = i + 1;
        };
        vector::reverse(&mut chunk_addrs);
        vector::destroy_empty(chunks);

        if (depth == 0) {
            assert!(n == 1, 101);
            let root = *vector::borrow(&chunk_addrs, 0);
            // verify_seed=true: assets.move recomputes seed and double-checks root.
            // root_index for depth=0 == 0 (the lone chunk's index).
            assets::finalize_v2(uploader, master_addr, root, 0, 0, true);
            return
        };

        if (depth == 1) {
            assert!(vector::length(&node_chunk_counts) == 1, 102);
            assert!(*vector::borrow(&node_chunk_counts, 0) == n, 103);
            let root = assets::deploy_node_v2(uploader, master_addr, chunk_addrs, 0);
            assets::finalize_v2(uploader, master_addr, root, 1, 0, true);
            return
        };

        // depth == 2
        let m = vector::length(&node_chunk_counts);
        assert!(m > 0, 104);
        let leaf_node_addrs = vector::empty<address>();

        let cursor = 0u64;
        let g = 0;
        while (g < m) {
            let c = *vector::borrow(&node_chunk_counts, g);
            let group = vector::empty<address>();
            let k = 0;
            while (k < c) {
                let addr = *vector::borrow(&chunk_addrs, cursor + k);
                vector::push_back(&mut group, addr);
                k = k + 1;
            };
            // Leaf nodes use indices 0..M-1; root uses index M.
            let leaf_addr = assets::deploy_node_v2(
                uploader, master_addr, group, g
            );
            vector::push_back(&mut leaf_node_addrs, leaf_addr);
            cursor = cursor + c;
            g = g + 1;
        };
        assert!(cursor == n, 105);

        let root_index = m;
        let root = assets::deploy_node_v2(uploader, master_addr, leaf_node_addrs, root_index);
        assets::finalize_v2(uploader, master_addr, root, 2, root_index, true);
    }
}
