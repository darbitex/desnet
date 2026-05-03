// Tier-3 fixed-3-chunk depth-1 upload — bypasses vector<vector<u8>> CLI parsing limitation.
// Takes three separate vector<u8> args (chunk0, chunk1, chunk2) and finalizes a depth-1 tree.

script {
    use std::vector;
    use desnet::assets;

    fun upload_b3_3chunks(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
        master_nonce: u64,
        chunk0: vector<u8>,
        chunk1: vector<u8>,
        chunk2: vector<u8>,
    ) {
        let master_addr = assets::start_upload_v2(
            uploader, mime, total_size, creator_pid, master_nonce
        );

        let a0 = assets::deploy_chunk_v2(uploader, master_addr, chunk0, 0);
        let a1 = assets::deploy_chunk_v2(uploader, master_addr, chunk1, 1);
        let a2 = assets::deploy_chunk_v2(uploader, master_addr, chunk2, 2);

        let group = vector::empty<address>();
        vector::push_back(&mut group, a0);
        vector::push_back(&mut group, a1);
        vector::push_back(&mut group, a2);

        let root = assets::deploy_node_v2(uploader, master_addr, group, 0);
        // depth=1, root_index=0, verify_seed=true
        assets::finalize_v2(uploader, master_addr, root, 1, 0, true);
    }
}
