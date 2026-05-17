#[test_only]
module desnet::v030_integration {
    use std::option;
    use std::signer;
    use std::string;
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use supra_framework::coin;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata, MintRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::supra_vault;
    use desnet::governance;

    fun setup_framework(framework: &signer): (coin::BurnCapability<SupraCoin>, coin::MintCapability<SupraCoin>) {
        timestamp::set_time_has_started_for_testing(framework);
        let (burn, mint) = supra_coin::initialize_for_test(framework);
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

    fun mint_supra_fa(mint_cap: &coin::MintCapability<SupraCoin>, amount: u64): FungibleAsset {
        let supra_coin = coin::mint<SupraCoin>(amount, mint_cap);
        coin::coin_to_fungible_asset(supra_coin)
    }

    fun cleanup(burn: coin::BurnCapability<SupraCoin>, mint: coin::MintCapability<SupraCoin>) {
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_create_pool_reserves_and_lp(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"alicecoin");

        let supra_fa = mint_supra_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"alicecoin", supra_fa, token_fa, @0xa11ce, false);

        let (supra_r, token_r) = amm::reserves(b"alicecoin");
        assert!(supra_r == 500_000_000, 1);
        assert!(token_r == 5_000_000_000_000_000, 2);

        assert!(initial_shares == 1_581_138_830_084, 3);
        assert!(amm::lp_supply(b"alicecoin") == initial_shares, 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_swap_supra_in_reserves_and_fees(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"swapcoin");

        let supra_seed = 1_000_000_000u64;
        let token_seed = 10_000_000_000_000_000u64;

        let supra_fa = mint_supra_fa(&mint, supra_seed);
        let token_fa = fungible_asset::mint(&token_mint_ref, token_seed);
        let _ = amm::create_pool_atomic_for_test(b"swapcoin", supra_fa, token_fa, @0xa11ce, true);

        let swap_in = 100_000_000u64;
        let bob_supra = mint_supra_fa(&mint, swap_in);
        let token_out = amm::swap_exact_supra_in(b"swapcoin", bob_supra, 0);
        let token_received = fungible_asset::amount(&token_out);
        primary_fungible_store::deposit(signer::address_of(bob), token_out);

        let (supra_r, token_r) = amm::reserves(b"swapcoin");
        let expected_supra_r = supra_seed + (swap_in - swap_in / 100);
        assert!(supra_r == expected_supra_r, 1);
        assert!(token_r == token_seed - token_received, 2);

        let (supra_fees, token_fees) = amm::fee_buckets(b"swapcoin");
        assert!(supra_fees == swap_in / 100, 3);
        assert!(token_fees == 0, 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_add_liquidity_proportional(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"addcoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"addcoin", supra_fa, token_fa, @0xa11ce, false);

        let add_supra_fa = mint_supra_fa(&mint, 100_000_000);
        let add_token_fa = fungible_asset::mint(&token_mint_ref, 1_000_000_000_000_000);

        let new_shares = amm::add_liquidity_internal_for_test(b"addcoin", add_supra_fa, add_token_fa, 0);
        assert!(new_shares == initial_shares / 10, 1);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_lp_supply_view(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"viewcoin");

        let supra_fa = mint_supra_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"viewcoin", supra_fa, token_fa, @0xa11ce, false);

        assert!(amm::lp_supply(b"viewcoin") == initial_shares, 1);

        let pool_addr = amm::pool_address_of_handle(b"viewcoin");
        assert!(amm::lp_supply_at(pool_addr) == initial_shares, 2);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_pool_exists_view(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"existcoin");

        assert!(!amm::pool_exists(b"existcoin"), 1);

        let supra_fa = mint_supra_fa(&mint, 500_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"existcoin", supra_fa, token_fa, @0xa11ce, false);

        assert!(amm::pool_exists(b"existcoin"), 2);
        assert!(!amm::pool_exists(b"otherhandle"), 3);

        let pool_addr = amm::pool_address_of_handle(b"existcoin");
        assert!(amm::pool_exists_at(pool_addr), 4);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_quote_matches_actual_swap(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"quotecoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"quotecoin", supra_fa, token_fa, @0xa11ce, true);

        let swap_in = 100_000_000u64;
        let quoted = amm::quote_swap_exact_in(b"quotecoin", swap_in, true);

        let pure_quote = amm::compute_amount_out(1_000_000_000, 10_000_000_000_000_000, swap_in);
        assert!(quoted == pure_quote, 1);

        let bob_supra = mint_supra_fa(&mint, swap_in);
        let actual_out = amm::swap_exact_supra_in(b"quotecoin", bob_supra, 0);
        let actual_amount = fungible_asset::amount(&actual_out);
        assert!(quoted == actual_amount, 2);

        primary_fungible_store::deposit(signer::address_of(bob), actual_out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 2, location = desnet::amm)]
    fun test_duplicate_pool_create_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"dupcoin");

        let supra_fa1 = mint_supra_fa(&mint, 500_000_000);
        let token_fa1 = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"dupcoin", supra_fa1, token_fa1, @0xa11ce, false);

        let supra_fa2 = mint_supra_fa(&mint, 500_000_000);
        let token_fa2 = fungible_asset::mint(&token_mint_ref, 5_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"dupcoin", supra_fa2, token_fa2, @0xa11ce, false);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    #[expected_failure(abort_code = 4, location = desnet::amm)]
    fun test_swap_slippage_protection(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"slipcoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"slipcoin", supra_fa, token_fa, @0xa11ce, true);

        let bob_supra = mint_supra_fa(&mint, 100_000_000);
        let out = amm::swap_exact_supra_in(b"slipcoin", bob_supra, 18_000_000_000_000_000u64);
        primary_fungible_store::deposit(signer::address_of(bob), out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_fee_accumulator_advances_universal(
        framework: &signer, alice: &signer, bob: &signer
    ) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"acccoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"acccoin", supra_fa, token_fa, @0xa11ce, true);

        let bob_supra = mint_supra_fa(&mint, 100_000_000);
        let out = amm::swap_exact_supra_in(b"acccoin", bob_supra, 0);
        primary_fungible_store::deposit(signer::address_of(bob), out);

        let (acc_supra, acc_token) = amm::fee_per_lp(b"acccoin");
        assert!(acc_supra > 0, 1);
        assert!(acc_token == 0, 2);

        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, charlie = @0xca11ed)]
    fun test_remove_liquidity_returns_proportional(
        framework: &signer, alice: &signer, charlie: &signer
    ) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(charlie));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"remcoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let initial_shares = amm::create_pool_atomic_for_test(b"remcoin", supra_fa, token_fa, @0xa11ce, false);

        let add_supra = 100_000_000u64;
        let add_token = 1_000_000_000_000_000u64;
        let add_supra_fa = mint_supra_fa(&mint, add_supra);
        let add_token_fa = fungible_asset::mint(&token_mint_ref, add_token);
        let charlie_shares = amm::add_liquidity_internal_for_test(b"remcoin", add_supra_fa, add_token_fa, 0);
        assert!(charlie_shares == initial_shares / 10, 1);

        let (supra_out_fa, token_out_fa) = amm::remove_liquidity_internal_for_test(b"remcoin", charlie_shares, 0, 0);
        let supra_out = fungible_asset::amount(&supra_out_fa);
        let token_out = fungible_asset::amount(&token_out_fa);

        assert!(supra_out >= add_supra - (add_supra / 10000), 2);
        assert!(supra_out <= add_supra, 3);
        assert!(token_out >= add_token - (add_token / 10000), 4);
        assert!(token_out <= add_token, 5);

        primary_fungible_store::deposit(signer::address_of(charlie), supra_out_fa);
        primary_fungible_store::deposit(signer::address_of(charlie), token_out_fa);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_flash_borrow_repay_lifecycle(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"flashcoin");

        let supra_seed = 1_000_000_000u64;
        let token_seed = 10_000_000_000_000_000u64;
        let supra_fa = mint_supra_fa(&mint, supra_seed);
        let token_fa = fungible_asset::mint(&token_mint_ref, token_seed);
        let _ = amm::create_pool_atomic_for_test(b"flashcoin", supra_fa, token_fa, @0xa11ce, true);

        let pool_addr = amm::pool_address_of_handle(b"flashcoin");
        let supra_meta = object::address_to_object<Metadata>(@0xa);

        let borrow_amount = 100_000_000u64;
        let (borrowed, receipt) = amm::flash_borrow(pool_addr, supra_meta, borrow_amount);
        assert!(fungible_asset::amount(&borrowed) == borrow_amount, 1);

        assert!(amm::pool_locked(pool_addr), 2);

        let fee = amm::compute_flash_fee(borrow_amount);
        assert!(fee == 1_000_000, 3);

        let topup = mint_supra_fa(&mint, fee);
        fungible_asset::merge(&mut borrowed, topup);

        amm::flash_repay(pool_addr, borrowed, receipt);

        assert!(!amm::pool_locked(pool_addr), 4);

        let (supra_r, _) = amm::reserves(b"flashcoin");
        assert!(supra_r == supra_seed, 5);

        let (supra_fees, _) = amm::fee_buckets(b"flashcoin");
        assert!(supra_fees == fee, 6);

        let (acc_supra, _) = amm::fee_per_lp(b"flashcoin");
        assert!(acc_supra > 0, 7);

        cleanup(burn, mint);
        let _ = bob;
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 14, location = desnet::amm)]
    fun test_flash_repay_wrong_amount_aborts(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"flashbcoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"flashbadcoin", supra_fa, token_fa, @0xa11ce, false);

        let pool_addr = amm::pool_address_of_handle(b"flashbadcoin");
        let supra_meta = object::address_to_object<Metadata>(@0xa);

        let (borrowed, receipt) = amm::flash_borrow(pool_addr, supra_meta, 100_000_000);
        amm::flash_repay(pool_addr, borrowed, receipt);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_generic_swap_supra_in(framework: &signer, alice: &signer, bob: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        let (_token_meta, token_mint_ref) = create_test_token(alice, b"genrccoin");

        let supra_fa = mint_supra_fa(&mint, 1_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"genericcoin", supra_fa, token_fa, @0xa11ce, true);

        let pool_addr = amm::pool_address_of_handle(b"genericcoin");

        let swap_in = 100_000_000u64;
        let bob_supra = mint_supra_fa(&mint, swap_in);
        let out = amm::swap(pool_addr, signer::address_of(bob), bob_supra, 0);
        let out_amount = fungible_asset::amount(&out);
        assert!(out_amount > 0, 1);

        primary_fungible_store::deposit(signer::address_of(bob), out);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework)]
    fun test_read_warning(framework: &signer) {
        let (burn, mint) = setup_framework(framework);
        let warning = amm::read_warning();
        assert!(std::vector::length(&warning) > 30, 1);
        cleanup(burn, mint);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 6, location = desnet::supra_vault)]
    fun test_settle_two_phase_no_pending_aborts(framework: &signer, alice: &signer) {
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

        let supra_fa = mint_supra_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", supra_fa, token_fa, @0xa11ce, false);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);

        let vault_addr = supra_vault::deploy_for_test(
            alice,
            b"vaultcoin",
            token_meta_addr,
            pool_addr,
            pid_addr,
            burn_ref,
        );

        let funding_coin = coin::mint<SupraCoin>(100_000_000, &mint);
        supra_vault::deposit_supra_coin_for_test(vault_addr, funding_coin);

        supra_vault::execute_settle(alice, vault_addr);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 7, location = desnet::supra_vault)]
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

        let supra_fa = mint_supra_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", supra_fa, token_fa, @0xa11ce, false);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);
        let vault_addr = supra_vault::deploy_for_test(
            alice, b"vaultcoin", token_meta_addr, pool_addr, pid_addr, burn_ref
        );

        supra_vault::deposit_supra_coin_for_test(vault_addr, coin::mint<SupraCoin>(100_000_000, &mint));

        timestamp::fast_forward_seconds(100);

        supra_vault::request_settle(alice, vault_addr);
        supra_vault::execute_settle(alice, vault_addr);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_settle_two_phase_executes_after_delay(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        coin::register<SupraCoin>(alice);

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

        let supra_fa = mint_supra_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", supra_fa, token_fa, @0xa11ce, true);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);
        let vault_addr = supra_vault::deploy_for_test(
            alice, b"vaultcoin", token_meta_addr, pool_addr, pid_addr, burn_ref
        );

        supra_vault::deposit_supra_coin_for_test(vault_addr, coin::mint<SupraCoin>(1_000_000_000, &mint));
        assert!(supra_vault::supra_balance(vault_addr) == 1_000_000_000, 1);

        timestamp::fast_forward_seconds(100);

        supra_vault::request_settle(alice, vault_addr);
        assert!(supra_vault::pending_settle_at_secs(vault_addr) > 0, 2);

        timestamp::fast_forward_seconds(61);

        supra_vault::execute_settle(alice, vault_addr);

        assert!(supra_vault::supra_balance(vault_addr) == 0, 3);
        assert!(supra_vault::pending_settle_at_secs(vault_addr) == 0, 4);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }
}
