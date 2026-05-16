/// Registration — atomic handle + token + IPO orchestration.
///
/// Single-entry wrapper around profile::register_handle + factory::create_token_atomic.
/// Breaks the module dependency cycle (profile → factory → ipo → profile) by lifting
/// the orchestration into its own module. Callers use this entry instead of calling
/// profile::register_handle directly when they need token + IPO creation.
module desnet::registration {
    use std::signer;
    use std::string;

    use desnet::profile;
    use desnet::factory;

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
            string::utf8(token_name),
            string::utf8(token_symbol),
            string::utf8(token_icon_uri),
            string::utf8(token_project_uri),
            ipo_target_tvl,
            ipo_entry_price_x,
            ipo_entry_price_y,
        );
    }
}
