module desnet::registration {
    use std::signer;
    use std::string;

    use desnet::profile;
    use desnet::factory;
    use desnet::ipo;

    public entry fun register_handle(
        wallet: &signer,
        handle: vector<u8>,
        controller_addr: address,
        avatar_b64: vector<u8>,
        bio: vector<u8>,
        token_name: vector<u8>,
        token_symbol: vector<u8>,
        token_icon_uri: vector<u8>,
        token_project_uri: vector<u8>,
        ipo_target_tvl: u64,
        ipo_entry_price_x: u64,
        ipo_entry_price_y: u64,
    ) {
        let wallet_addr = signer::address_of(wallet);
        profile::register_handle(wallet, handle, controller_addr, avatar_b64, bio);
        let pid_addr = profile::derive_pid_address(wallet_addr);
        factory::create_token_atomic(
            handle,
            pid_addr,
            wallet_addr,
            string::utf8(token_name),
            string::utf8(token_symbol),
            string::utf8(token_icon_uri),
            string::utf8(token_project_uri),
            ipo_target_tvl,
            ipo_entry_price_x,
            ipo_entry_price_y,
        );
    }

    public entry fun register_handle_with_creator_seed(
        wallet: &signer,
        handle: vector<u8>,
        controller_addr: address,
        avatar_b64: vector<u8>,
        bio: vector<u8>,
        token_name: vector<u8>,
        token_symbol: vector<u8>,
        token_icon_uri: vector<u8>,
        token_project_uri: vector<u8>,
        ipo_target_tvl: u64,
        ipo_entry_price_x: u64,
        ipo_entry_price_y: u64,
        creator_subdomain: vector<u8>,
        creator_supra_amount: u64,
    ) {
        let wallet_addr = signer::address_of(wallet);
        profile::register_handle(wallet, handle, controller_addr, avatar_b64, bio);
        let pid_addr = profile::derive_pid_address(wallet_addr);
        factory::create_token_atomic(
            handle,
            pid_addr,
            wallet_addr,
            string::utf8(token_name),
            string::utf8(token_symbol),
            string::utf8(token_icon_uri),
            string::utf8(token_project_uri),
            ipo_target_tvl,
            ipo_entry_price_x,
            ipo_entry_price_y,
        );
        ipo::deposit_supra(wallet, handle, creator_supra_amount, creator_subdomain);
    }
}
