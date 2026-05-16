/// Registration — atomic handle + token + IPO orchestration.
///
/// Single-entry wrapper around profile::register_handle + factory::create_token_atomic
/// (and optionally ipo::deposit_supra for atomic creator self-IPO with elevated 10% cap).
/// Breaks the module dependency cycle (profile → factory → ipo → profile) by lifting
/// the orchestration into its own module.
module desnet::registration {
    use std::signer;
    use std::string;

    use desnet::profile;
    use desnet::factory;
    use desnet::ipo;

    /// Plain registration. Creator gets handle + token + empty IPO pool. Anyone
    /// (including creator later) can deposit_supra to participate.
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

    /// Atomic: register handle + create token + IPO + creator self-deposit
    /// at the elevated 10% cap + claim creator's own subdomain — all in one tx.
    /// Creator picks `creator_subdomain` like any other depositor.
    /// `creator_supra_amount` must be > 0 (else use plain `register_handle`).
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
        // Creator self-deposit. ipo::deposit_supra branches on caller_addr ==
        // creator_wallet to apply the 10% cap (vs 1% for everyone else).
        ipo::deposit_supra(wallet, handle, creator_supra_amount, creator_subdomain);
    }
}
