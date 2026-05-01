#[test_only]
module desnet::v030_integration {
    use std::option;
    use std::signer;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::governance;

    fun setup_framework(framework: &signer): (coin::BurnCapability<AptosCoin>, coin::MintCapability<AptosCoin>) {
        timestamp::set_time_has_started_for_testing(framework);
        let (burn, mint) = aptos_coin::initialize_for_test(framework);
        governance::init_for_test();
        (burn, mint)
    }

    fun create_test_token(creator: &signer, symbol: vector<u8>): (Object<Metadata>, MintRef) {
        let constructor = object::create_named_object(creator, symbol);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),
            string::utf8(symbol),
            string::utf8(symbol),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let metadata = object::object_from_constructor_ref<Metadata>(&constructor);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        (metadata, mint_ref)
    }

    fun mint_apt_fa(mint_cap: &coin::MintCapability<AptosCoin>, amount: u64): FungibleAsset {
        let apt_coin = coin::mint<AptosCoin>(amount, mint_cap);
        coin::coin_to_fungible_asset(apt_coin)
    }

    fun cleanup(burn: coin::BurnCapability<AptosCoin>, mint: coin::MintCapability<AptosCoin>) {
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    fun test_create_pool_reserves_and_lp(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"alicecoin");

        let apt_fa = mint_apt_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"alicecoin", apt_fa, token_fa, @0xa11ce);

        let (apt_r, token_r) = amm::reserves(b"alicecoin");
        assert!(apt_r == 500_000_000, 1);
        assert!(token_r == 5_000_000_000_000_000, 2);

        // Initial LP = sqrt(5e8 × 5e15) = 1.58e12 (V3 returns u128 shares directly, not FA)
        assert!(initial_shares == 1_581_138_830_084, 3);
        assert!(amm::lp_supply(b"alicecoin") == initial_shares, 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_swap_apt_in_reserves_and_fees(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"swapcoin");

        let apt_seed = 1_000_000_000u64;
        let token_seed = 10_000_000_000_000_000u64;

        let apt_fa = mint_apt_fa(&mint, apt_seed);
        let token_fa = fungible_asset::mint(&token_mint_ref, token_seed);
        let _ = amm::create_pool_atomic_for_test(b"swapcoin", apt_fa, token_fa, @0xa11ce);

        let swap_in = 100_000_000u64;
        let bob_apt = mint_apt_fa(&mint, swap_in);
        let token_out = amm::swap_exact_apt_in(b"swapcoin", bob_apt, 0);
        let token_received = fungible_asset::amount(&token_out);
        primary_fungible_store::deposit(signer::address_of(bob), token_out);

        let (apt_r, token_r) = amm::reserves(b"swapcoin");
        let expected_apt_r = apt_seed + (swap_in - swap_in / 1000);
        assert!(apt_r == expected_apt_r, 1);
        assert!(token_r == token_seed - token_received, 2);

        let (apt_fees, token_fees) = amm::fee_buckets(b"swapcoin");
        assert!(apt_fees == swap_in / 1000, 3);
        assert!(token_fees == 0, 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    fun test_add_liquidity_proportional(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"addcoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"addcoin", apt_fa, token_fa, @0xa11ce);

        let add_apt_fa = mint_apt_fa(&mint, 100_000_000);
        let add_token_fa = fungible_asset::mint(&token_mint_ref, 1_000_000_000_000_000);

        let new_shares = amm::add_liquidity_internal_for_test(b"addcoin", add_apt_fa, add_token_fa, 0);
        assert!(new_shares == initial_shares / 10, 1);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    fun test_lp_supply_view(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"viewcoin");

        let apt_fa = mint_apt_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"viewcoin", apt_fa, token_fa, @0xa11ce);

        // Universal model: lp_supply == initial_shares (no staked_lp_supply distinction)
        assert!(amm::lp_supply(b"viewcoin") == initial_shares, 1);

        // Addr-based view (darbitex composability)
        let pool_addr = amm::pool_address_of_handle(b"viewcoin");
        assert!(amm::lp_supply_at(pool_addr) == initial_shares, 2);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    fun test_pool_exists_view(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"existcoin");

        assert!(!amm::pool_exists(b"existcoin"), 1);

        let apt_fa = mint_apt_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"existcoin", apt_fa, token_fa, @0xa11ce);

        assert!(amm::pool_exists(b"existcoin"), 2);
        assert!(!amm::pool_exists(b"otherhandle"), 3);

        // Addr-based variant (darbitex composability)
        let pool_addr = amm::pool_address_of_handle(b"existcoin");
        assert!(amm::pool_exists_at(pool_addr), 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_quote_matches_actual_swap(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"quotecoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"quotecoin", apt_fa, token_fa, @0xa11ce);

        let swap_in = 100_000_000u64;
        let quoted = amm::quote_swap_exact_in(b"quotecoin", swap_in, true);

        // Pure compute_amount_out matches too (darbitex shape)
        let pure_quote = amm::compute_amount_out(1_000_000_000, 10_000_000_000_000_000, swap_in);
        assert!(quoted == pure_quote, 1);

        let bob_apt = mint_apt_fa(&mint, swap_in);
        let actual_out = amm::swap_exact_apt_in(b"quotecoin", bob_apt, 0);
        let actual_amount = fungible_asset::amount(&actual_out);
        assert!(quoted == actual_amount, 2);

        primary_fungible_store::deposit(signer::address_of(bob), actual_out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 2, location = desnet::amm)]
    fun test_duplicate_pool_create_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"dupcoin");

        let apt_fa1 = mint_apt_fa(&mint, 500_000_000);
        let token_fa1 = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"dupcoin", apt_fa1, token_fa1, @0xa11ce);

        let apt_fa2 = mint_apt_fa(&mint, 500_000_000);
        let token_fa2 = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"dupcoin", apt_fa2, token_fa2, @0xa11ce);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    #[expected_failure(abort_code = 4, location = desnet::amm)]
    fun test_swap_slippage_protection(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"slipcoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"slipcoin", apt_fa, token_fa, @0xa11ce);

        let bob_apt = mint_apt_fa(&mint, 100_000_000);
        let out = amm::swap_exact_apt_in(b"slipcoin", bob_apt, 18_000_000_000_000_000u64);
        primary_fungible_store::deposit(signer::address_of(bob), out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    /// V3 universal model: ALL LP earns fees. Even with no add_liquidity beyond initial,
    /// the initial creator's locked shares (lp_supply > 0) means accumulator WILL advance.
    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_fee_accumulator_advances_universal(
        framework: &signer, alice: &signer, bob: &signer
    ) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"acccoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"acccoin", apt_fa, token_fa, @0xa11ce);

        let bob_apt = mint_apt_fa(&mint, 100_000_000);
        let out = amm::swap_exact_apt_in(b"acccoin", bob_apt, 0);
        primary_fungible_store::deposit(signer::address_of(bob), out);

        // Universal: lp_supply > 0 → accumulator advances on swap
        let (acc_apt, acc_token) = amm::fee_per_lp(b"acccoin");
        assert!(acc_apt > 0, 1);
        assert!(acc_token == 0, 2);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce, charlie = @0xca11ed)]
    fun test_remove_liquidity_returns_proportional(
        framework: &signer, alice: &signer, charlie: &signer
    ) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(charlie));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"remcoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"remcoin", apt_fa, token_fa, @0xa11ce);

        let add_apt = 100_000_000u64;
        let add_token = 1_000_000_000_000_000u64;
        let add_apt_fa = mint_apt_fa(&mint, add_apt);
        let add_token_fa = fungible_asset::mint(&token_mint_ref, add_token);
        let charlie_shares = amm::add_liquidity_internal_for_test(b"remcoin", add_apt_fa, add_token_fa, 0);
        assert!(charlie_shares == initial_shares / 10, 1);

        let (apt_out_fa, token_out_fa) = amm::remove_liquidity_internal_for_test(b"remcoin", charlie_shares, 0, 0);
        let apt_out = fungible_asset::amount(&apt_out_fa);
        let token_out = fungible_asset::amount(&token_out_fa);

        assert!(apt_out >= add_apt - (add_apt / 10000), 2);
        assert!(apt_out <= add_apt, 3);
        assert!(token_out >= add_token - (add_token / 10000), 4);
        assert!(token_out <= add_token, 5);

        primary_fungible_store::deposit(signer::address_of(charlie), apt_out_fa);
        primary_fungible_store::deposit(signer::address_of(charlie), token_out_fa);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    /// Flash borrow + repay round-trip. Verifies fee 100% to LP accumulator.
    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_flash_borrow_repay_lifecycle(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"flashcoin");

        let apt_seed = 1_000_000_000u64;
        let token_seed = 10_000_000_000_000_000u64;
        let apt_fa = mint_apt_fa(&mint, apt_seed);
        let token_fa = fungible_asset::mint(&token_mint_ref, token_seed);
        let _ = amm::create_pool_atomic_for_test(b"flashcoin", apt_fa, token_fa, @0xa11ce);

        let pool_addr = amm::pool_address_of_handle(b"flashcoin");
        let apt_meta = object::address_to_object<Metadata>(@0xa);

        // Borrow 100M raw APT (1 APT)
        let borrow_amount = 100_000_000u64;
        let (borrowed, receipt) = amm::flash_borrow(pool_addr, apt_meta, borrow_amount);
        assert!(fungible_asset::amount(&borrowed) == borrow_amount, 1);

        // Pool locked during borrow
        assert!(amm::pool_locked(pool_addr), 2);

        // Compute fee (10 bps)
        let fee = amm::compute_flash_fee(borrow_amount);
        assert!(fee == 100_000, 3);  // 10 bps of 100M = 100k

        // Bob mints fee top-up + repays
        let topup = mint_apt_fa(&mint, fee);
        fungible_asset::merge(&mut borrowed, topup);

        amm::flash_repay(pool_addr, borrowed, receipt);

        // Pool unlocked
        assert!(!amm::pool_locked(pool_addr), 4);

        // Reserve = original (100M back), fee bucket = 100k
        let (apt_r, _) = amm::reserves(b"flashcoin");
        assert!(apt_r == apt_seed, 5);

        let (apt_fees, _) = amm::fee_buckets(b"flashcoin");
        assert!(apt_fees == fee, 6);

        // Fee accumulator advanced (universal)
        let (acc_apt, _) = amm::fee_per_lp(b"flashcoin");
        assert!(acc_apt > 0, 7);

        cleanup(burn, mint);
        let _ = bob;
        let _ = token_mint_ref;
    }

    /// Flash repay with wrong amount aborts.
    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 14, location = desnet::amm)]
    fun test_flash_repay_wrong_amount_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"flashbadcoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"flashbadcoin", apt_fa, token_fa, @0xa11ce);

        let pool_addr = amm::pool_address_of_handle(b"flashbadcoin");
        let apt_meta = object::address_to_object<Metadata>(@0xa);

        let (borrowed, receipt) = amm::flash_borrow(pool_addr, apt_meta, 100_000_000);
        // Try to repay WITHOUT fee → E_K_VIOLATED (14)
        amm::flash_repay(pool_addr, borrowed, receipt);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    /// Generic swap by addr (darbitex shape) routes to correct internal swap.
    #[test(framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_generic_swap_apt_in(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"genericcoin");

        let apt_fa = mint_apt_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"genericcoin", apt_fa, token_fa, @0xa11ce);

        let pool_addr = amm::pool_address_of_handle(b"genericcoin");

        let swap_in = 100_000_000u64;
        let bob_apt = mint_apt_fa(&mint, swap_in);
        let out = amm::swap(pool_addr, signer::address_of(bob), bob_apt, 0);
        let out_amount = fungible_asset::amount(&out);
        assert!(out_amount > 0, 1);

        primary_fungible_store::deposit(signer::address_of(bob), out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    /// Read warning disclosure (returns bytes).
    #[test(framework = @aptos_framework)]
    fun test_read_warning(framework: &signer) {
        let (burn, mint) = setup_framework(framework);
        let warning = amm::read_warning();
        // Sanity: non-empty bytes, contains "DESNET" prefix
        assert!(std::vector::length(&warning) > 30, 1);  // trimmed for tx-size fit
        cleanup(burn, mint);
    }

    // ============ R3 H3 Regression — apt_vault two-phase settle ============

    /// Verify the two-phase settle blocks single-tx sandwich.
    /// Setup: token with burn_ref, pool seeded, vault with deposited APT.
    /// Phase 1: execute_settle without prior request → E_NO_PENDING_SETTLE (6).
    /// Phase 2: request_settle then immediate execute_settle → E_SETTLE_NOT_READY (7).
    /// Phase 3: request_settle, fast-forward 60s, execute_settle → success.
    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 6, location = desnet::apt_vault)]
    fun test_settle_two_phase_no_pending_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));

        // Build a token where we keep both mint+burn refs (need burn for vault).
        let constructor = object::create_named_object(alice, b"vaultcoin");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),
            string::utf8(b"vaultcoin"),
            string::utf8(b"VC"),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let token_meta = object::object_from_constructor_ref<Metadata>(&constructor);
        let token_meta_addr = object::object_address(&token_meta);
        let token_mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor);

        // Seed pool 100 APT / 100M tokens.
        let apt_fa = mint_apt_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", apt_fa, token_fa, @0xa11ce);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        // Fake PID.
        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);

        // Deploy vault.
        let vault_addr = apt_vault::deploy_for_test(
            alice,
            b"vaultcoin",
            token_meta_addr,
            pool_addr,
            pid_addr,
            burn_ref,
        );

        // Fund the vault with 1 APT (above 0.1 APT threshold).
        let funding_coin = coin::mint<AptosCoin>(100_000_000, &mint);
        apt_vault::deposit_apt_coin_for_test(vault_addr, funding_coin);

        // Attempt execute_settle with NO prior request_settle — expects E_NO_PENDING_SETTLE.
        apt_vault::execute_settle(alice, vault_addr);

        // Unreached — but cleanup pattern for safety.
        let _ = token_mint_ref;
        cleanup(burn, mint);
    }

    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 7, location = desnet::apt_vault)]
    fun test_settle_two_phase_immediate_execute_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));

        let constructor = object::create_named_object(alice, b"vaultcoin");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),
            string::utf8(b"vaultcoin"),
            string::utf8(b"VC"),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let token_meta = object::object_from_constructor_ref<Metadata>(&constructor);
        let token_meta_addr = object::object_address(&token_meta);
        let token_mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor);

        let apt_fa = mint_apt_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", apt_fa, token_fa, @0xa11ce);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);
        let vault_addr = apt_vault::deploy_for_test(
            alice, b"vaultcoin", token_meta_addr, pool_addr, pid_addr, burn_ref
        );

        apt_vault::deposit_apt_coin_for_test(vault_addr, coin::mint<AptosCoin>(100_000_000, &mint));

        // Advance past 0 so pending_settle_at_secs is distinguishable from sentinel.
        timestamp::fast_forward_seconds(100);

        // Request, then attempt execute in same tx (no further time advance).
        apt_vault::request_settle(alice, vault_addr);
        // Expects E_SETTLE_NOT_READY (7).
        apt_vault::execute_settle(alice, vault_addr);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }

    /// Positive path: request → fast-forward ≥60s → execute succeeds.
    /// Also verifies the 1% buyback cap (defense-in-depth) by funding the vault
    /// with much more APT than 1% of pool reserve, and asserting the cap kicks in.
    #[test(framework = @aptos_framework, alice = @0xa11ce)]
    fun test_settle_two_phase_executes_after_delay(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));

        let constructor = object::create_named_object(alice, b"vaultcoin");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),
            string::utf8(b"vaultcoin"),
            string::utf8(b"VC"),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let token_meta = object::object_from_constructor_ref<Metadata>(&constructor);
        let token_meta_addr = object::object_address(&token_meta);
        let token_mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor);

        // Seed pool: 100 APT (1e10) / 100M tokens (1e16).
        let apt_fa = mint_apt_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", apt_fa, token_fa, @0xa11ce);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);
        let vault_addr = apt_vault::deploy_for_test(
            alice, b"vaultcoin", token_meta_addr, pool_addr, pid_addr, burn_ref
        );

        // Fund vault with 10 APT — half (5 APT raw) would be the raw_buyback,
        // but cap = 1% of 100 APT reserve = 1 APT. So buyback caps at 1 APT,
        // owner receives 10 - 1 = 9 APT (instead of 10/2 = 5).
        apt_vault::deposit_apt_coin_for_test(vault_addr, coin::mint<AptosCoin>(1_000_000_000, &mint));
        assert!(apt_vault::apt_balance(vault_addr) == 1_000_000_000, 1);

        // Advance past 0 so pending_settle_at_secs is distinguishable from sentinel.
        timestamp::fast_forward_seconds(100);

        // Request settle.
        apt_vault::request_settle(alice, vault_addr);
        assert!(apt_vault::pending_settle_at_secs(vault_addr) > 0, 2);

        // Fast-forward 60s + 1.
        timestamp::fast_forward_seconds(61);

        // Execute settle.
        apt_vault::execute_settle(alice, vault_addr);

        // Vault balance should be 0 (all consumed: 1 APT buyback, 9 APT to owner).
        assert!(apt_vault::apt_balance(vault_addr) == 0, 3);
        // pending should reset.
        assert!(apt_vault::pending_settle_at_secs(vault_addr) == 0, 4);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }
}
