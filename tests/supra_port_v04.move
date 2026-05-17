/// Unit + property tests for the Supra-specific v0.4 surfaces:
///   - per-PID reaction pool isolation (no collision via handle_of())
///   - reaction notify lazy-init + zero-amount guard
///   - reaction reward_token slot cap behavior
///
/// IPO + locked-LP-on-subdomain + Y-1 anti-wash + Y-2 slippage are covered
/// at the contract level by structural invariants; their integration tests
/// require the full registration -> factory -> ipo create scaffold which
/// is not yet wired in test mode (TODO: add a setup_test_ipo helper that
/// stubs factory + supra_fee_vault enough to call participate_ipo from a
/// pure test signer). Stubs at the end of this file mark those gaps.
#[test_only]
module desnet::supra_port_v04_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use supra_framework::account;
    use supra_framework::fungible_asset::{Self, Metadata, MintRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::governance;
    use desnet::profile;
    use desnet::reaction_emission;

    // ============ HELPERS ============

    fun setup(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        governance::init_for_test();
    }

    fun mint_test_fa(creator: &signer, symbol: vector<u8>): (Object<Metadata>, MintRef) {
        let constructor = object::create_named_object(creator, symbol);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor, option::none<u128>(),
            string::utf8(symbol), string::utf8(symbol),
            8, string::utf8(b""), string::utf8(b""),
        );
        let meta = object::object_from_constructor_ref<Metadata>(&constructor);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        (meta, mint_ref)
    }

    fun fund_signer(funder: &signer, mint_ref: &MintRef, amount: u64) {
        let fa = fungible_asset::mint(mint_ref, amount);
        primary_fungible_store::deposit(signer::address_of(funder), fa);
    }

    // ============ PER-PID REACTION POOL ISOLATION ============

    /// Core property of the 2026-05-17 rekey: two distinct PIDs must get
    /// distinct reaction pools, even if their Profile.handle string would
    /// otherwise collide via profile::handle_of() (the collision hazard
    /// that motivated the rekey - main "alice" and subdomain "alice@bob"
    /// both resolve handle_of() to "alice"). Pool address is derived from
    /// `bcs::to_bytes(author_pid)` so the property holds structurally.
    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b, funder = @0xfeed)]
    fun test_per_pid_reaction_pools_are_isolated(
        framework: &signer, alice: &signer, bob: &signer, funder: &signer,
    ) {
        setup(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));
        account::create_account_for_test(signer::address_of(funder));

        let pid_a = profile::setup_test_pid(alice);
        let pid_b = profile::setup_test_pid(bob);
        assert!(pid_a != pid_b, 100);

        let pool_a = reaction_emission::pool_address_of(pid_a);
        let pool_b = reaction_emission::pool_address_of(pid_b);
        assert!(pool_a != pool_b, 101);

        assert!(!reaction_emission::pool_exists(pid_a), 102);
        assert!(!reaction_emission::pool_exists(pid_b), 103);

        let (reward_meta, reward_mint_ref) = mint_test_fa(alice, b"RWRD");
        fund_signer(funder, &reward_mint_ref, 10_000);

        // Fund only pool A.
        reaction_emission::notify_reward(funder, pid_a, reward_meta, 1_000);

        // Pool A exists with the deposit; pool B remains uninitialized.
        assert!(reaction_emission::pool_exists(pid_a), 104);
        assert!(!reaction_emission::pool_exists(pid_b), 105);

        // Balances confirm no cross-PID leakage.
        assert!(reaction_emission::reward_balance(pid_a, reward_meta) == 1_000, 106);
        assert!(reaction_emission::reward_balance(pid_b, reward_meta) == 0, 107);

        let _ = reward_mint_ref;
    }

    /// Lazy-init: first notify_reward creates the pool; second notify reuses.
    #[test(framework = @supra_framework, alice = @0xa11ce, funder = @0xfeed)]
    fun test_reaction_notify_lazy_init_and_accumulate(
        framework: &signer, alice: &signer, funder: &signer,
    ) {
        setup(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(funder));

        let pid = profile::setup_test_pid(alice);
        assert!(!reaction_emission::pool_exists(pid), 200);

        let (reward_meta, reward_mint_ref) = mint_test_fa(alice, b"RWRD2");
        fund_signer(funder, &reward_mint_ref, 5_000);

        reaction_emission::notify_reward(funder, pid, reward_meta, 1_500);
        assert!(reaction_emission::pool_exists(pid), 201);
        assert!(reaction_emission::reward_balance(pid, reward_meta) == 1_500, 202);

        // Second top-up - same token, same pool, balance grows.
        reaction_emission::notify_reward(funder, pid, reward_meta, 2_500);
        assert!(reaction_emission::reward_balance(pid, reward_meta) == 4_000, 203);

        // reward_token_list should still hold only 1 entry (slot not re-allocated).
        let tokens = reaction_emission::reward_tokens_of(pid);
        assert!(vector::length(&tokens) == 1, 204);

        let _ = reward_mint_ref;
    }

    /// Two distinct reward tokens land in distinct slots, both balances
    /// retrievable, slot list length grows.
    #[test(framework = @supra_framework, alice = @0xa11ce, funder = @0xfeed)]
    fun test_reaction_multiple_reward_tokens_per_pool(
        framework: &signer, alice: &signer, funder: &signer,
    ) {
        setup(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(funder));

        let pid = profile::setup_test_pid(alice);
        let (rew1_meta, rew1_mint) = mint_test_fa(alice, b"REW1");
        let (rew2_meta, rew2_mint) = mint_test_fa(alice, b"REW2");
        fund_signer(funder, &rew1_mint, 1_000);
        fund_signer(funder, &rew2_mint, 2_000);

        reaction_emission::notify_reward(funder, pid, rew1_meta, 500);
        reaction_emission::notify_reward(funder, pid, rew2_meta, 1_500);

        assert!(reaction_emission::reward_balance(pid, rew1_meta) == 500, 300);
        assert!(reaction_emission::reward_balance(pid, rew2_meta) == 1_500, 301);
        let tokens = reaction_emission::reward_tokens_of(pid);
        assert!(vector::length(&tokens) == 2, 302);

        let _ = rew1_mint;
        let _ = rew2_mint;
    }

    /// notify with zero amount must abort (E_ZERO_AMOUNT = 2).
    #[test(framework = @supra_framework, alice = @0xa11ce, funder = @0xfeed)]
    #[expected_failure(abort_code = 2, location = desnet::reaction_emission)]
    fun test_reaction_notify_zero_amount_aborts(
        framework: &signer, alice: &signer, funder: &signer,
    ) {
        setup(framework);
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(funder));

        let pid = profile::setup_test_pid(alice);
        let (reward_meta, reward_mint_ref) = mint_test_fa(alice, b"RWRZ");
        fund_signer(funder, &reward_mint_ref, 100);

        // amount=0 -> abort.
        reaction_emission::notify_reward(funder, pid, reward_meta, 0);
        let _ = reward_mint_ref;
    }

    /// Views on a non-existent pool: pool_exists=false, reward_tokens_of=[],
    /// reward_balance=0. Important because distribute_to_presser also reads
    /// reward_balance on potentially-empty pools and must degrade gracefully.
    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_reaction_views_on_uninitialized_pool(
        framework: &signer, alice: &signer,
    ) {
        setup(framework);
        account::create_account_for_test(signer::address_of(alice));

        let pid = profile::setup_test_pid(alice);
        let (reward_meta, reward_mint_ref) = mint_test_fa(alice, b"RWRV");

        assert!(!reaction_emission::pool_exists(pid), 400);
        let tokens = reaction_emission::reward_tokens_of(pid);
        assert!(vector::length(&tokens) == 0, 401);
        assert!(reaction_emission::reward_balance(pid, reward_meta) == 0, 402);

        let _ = reward_mint_ref;
    }

    // ============ TODO: IPO INTEGRATION TESTS (BLOCKED ON SCAFFOLD) ============
    //
    // The following surfaces are covered structurally in code but need an
    // integration test that exercises participate_ipo + burn_for_refund:
    //
    //   - Y-1 anti-wash: depositor_totals only decrements when caller ==
    //     pos.depositor. Setup: register_handle_with_creator_seed to create
    //     IPO + creator subdomain, transfer the subdomain Profile NFT to a
    //     proxy wallet, have proxy call burn_for_refund, assert that
    //     ipo::depositor_totals[creator_wallet] stays at its pre-refund value.
    //
    //   - Y-2 slippage: burn_for_refund with min_supra_out > actual aborts
    //     with E_SLIPPAGE_EXCEEDED. Setup as above + force the AMM into
    //     a state where actual < min via a same-block participate_ipo
    //     before the refund.
    //
    //   - Locked-LP follows NFT transfer: deposit_supra(alice), transfer
    //     subdomain NFT to bob, fast-forward, claim_lp_rewards, assert
    //     reward FA lands at bob's primary store.
    //
    //   - creator_seed atomic: register_handle_with_creator_seed in one tx
    //     with creator_supra_amount = 10% of target_tvl, assert
    //     depositor_totals[creator] == 10%-cap. Out-of-range amounts
    //     (>10%) abort with E_EXCEEDS_MAX_ALLOCATION.
    //
    //   - complete_ipo target guard: complete_ipo with raised < target_tvl
    //     aborts with E_BELOW_TARGET. Trivial unit test once scaffold exists.
    //
    // Setup gap to fill before these can run: a `setup_test_ipo(handle)`
    // helper that initializes factory::FactoryState + governance singletons
    // + a stub supra_fee_vault (or makes supra_fee_vault::deposit_supra_fa
    // a no-op in test mode) and returns the IPOPool address. Once that
    // exists, each test above is ~30 LoC.
}
