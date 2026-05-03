// asset_upload_b2.move — Tier-2 bundled asset upload script.
//
// Bundles start_upload_pub + deploy_chunk_pub × N + (deploy_node_pub × M)
// + finalize_pub into one Move transaction script. Frontend submits this
// as a single tx with all chunk bytes inline. Caller signs ONCE.
//
// Tree shape encoded by `node_chunk_counts`:
//   depth=0, n=1 chunk:    node_chunk_counts = []        (root = the single chunk)
//   depth=1, n≤16 chunks:  node_chunk_counts = [n]       (single node holds all)
//   depth=2, n>16 chunks:  node_chunk_counts = [c1,c2…]  (M leaf nodes, then root)
//
// Per-tx limits to keep in mind from the caller:
//   - Aptos tx payload size cap (~1 MB raw) — limits chunks per script call
//   - Per-tx gas cap — ~30 chunks ≈ 900 KB is a comfortable ceiling
//   - Larger uploads: split into 2–3 script calls, last one includes finalize
//
// Caller responsibility: pre-validate that node_chunk_counts sums to
// vector::length(&chunks), and that depth matches the layout. Script
// aborts with assets::E_NODE_EMPTY / E_CHUNK_EMPTY for malformed shapes.

script {
    use std::vector;
    use desnet::assets;

    fun upload_b2(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
        chunks: vector<vector<u8>>,
        node_chunk_counts: vector<u64>,
        depth: u8,
    ) {
        // Depth is bounded by assets.move semantics (single chunk, single
        // node, or root-over-leaves). Higher depths aren't reachable through
        // the existing tree shape, so reject up-front rather than failing
        // mid-script with confusing assertion codes.
        assert!(depth <= 2, 99);
        let master_addr = assets::start_upload_pub(uploader, mime, total_size, creator_pid);

        // ============ Deploy all chunks (pop-from-back + reverse) ============
        // Move's vector<vector<u8>> can't be borrowed-and-passed directly to
        // a function that consumes vector<u8>, so we drain via pop_back and
        // reverse the result to restore caller's original ordering.
        let n = vector::length(&chunks);
        let chunk_addrs = vector::empty<address>();
        let i = 0;
        while (i < n) {
            let data = vector::pop_back(&mut chunks);
            let chunk_addr = assets::deploy_chunk_pub(uploader, master_addr, data);
            vector::push_back(&mut chunk_addrs, chunk_addr);
            i = i + 1;
        };
        vector::reverse(&mut chunk_addrs);
        // chunks is now empty; explicit destroy keeps the borrow checker happy.
        vector::destroy_empty(chunks);

        // ============ depth = 0: root IS the single chunk ============
        if (depth == 0) {
            assert!(n == 1, 1);
            let root = *vector::borrow(&chunk_addrs, 0);
            assets::finalize_pub(uploader, master_addr, root, 0);
            return
        };

        // ============ depth = 1: single root node holds all chunks ============
        if (depth == 1) {
            assert!(vector::length(&node_chunk_counts) == 1, 2);
            assert!(*vector::borrow(&node_chunk_counts, 0) == n, 3);
            // chunk_addrs is exactly the children list for this node.
            let root = assets::deploy_node_pub(uploader, master_addr, chunk_addrs);
            assets::finalize_pub(uploader, master_addr, root, 1);
            return
        };

        // ============ depth = 2: M leaf nodes, then a root node over them ============
        // depth == 2 from here on. (caller should not pass higher; tree caps at 5MB ≈ 167 chunks)
        let m = vector::length(&node_chunk_counts);
        assert!(m > 0, 4);
        let leaf_node_addrs = vector::empty<address>();

        // Walk node_chunk_counts: slice chunk_addrs into groups of size c.
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
            let leaf_addr = assets::deploy_node_pub(uploader, master_addr, group);
            vector::push_back(&mut leaf_node_addrs, leaf_addr);
            cursor = cursor + c;
            g = g + 1;
        };
        assert!(cursor == n, 5);

        // Root node aggregates the M leaf nodes.
        let root = assets::deploy_node_pub(uploader, master_addr, leaf_node_addrs);
        assets::finalize_pub(uploader, master_addr, root, 2);
    }
}
