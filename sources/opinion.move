module desnet::opinion {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleStore, Metadata, MintRef, BurnRef};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::string_utils;

    use desnet::supra_vault;
    use desnet::factory;
    use desnet::history;
    use desnet::profile;

    friend desnet::mint;

    const CONTENT_TEXT_MAX_BYTES: u64 = 333;

    const SIDE_NONE: u8 = 0;
    const SIDE_YAY: u8 = 1;
    const SIDE_NAY: u8 = 2;

    const KIND_CREATE: u8 = 0;
    const KIND_DEPOSIT: u8 = 1;
    const KIND_SWAP_YAY_FOR_NAY: u8 = 2;
    const KIND_SWAP_NAY_FOR_YAY: u8 = 3;
    const KIND_REDEEM: u8 = 4;
    const KIND_DEPOSIT_BALANCED: u8 = 5;

    const OPN_DECIMALS: u8 = 8;

    const MIN_INITIAL_MC: u64 = 10_000_000_000_000;
    const MAX_INITIAL_MC: u64 = 10_000_000_000_000_000;

    const DEFAULT_TAX_BPS: u64 = 10;
    const MAX_TAX_BPS: u64 = 1000;
    const BPS_DENOM: u64 = 10000;

    const MAX_OPINIONS_PER_PID: u64 = 10_000;

    const SEED_MARKET_PREFIX: vector<u8> = b"opinion_market::";
    const SEED_YAY: vector<u8> = b"YAY";
    const SEED_NAY: vector<u8> = b"NAY";

    const E_CONTENT_TOO_LONG: u64 = 1;
    const E_PROFILE_REQUIRED: u64 = 2;
    const E_MARKET_NOT_FOUND: u64 = 3;
    const E_INVALID_SIDE: u64 = 4;
    const E_AMOUNT_ZERO: u64 = 5;
    const E_POOL_NOT_ACTIVE: u64 = 6;
    const E_SLIPPAGE_EXCEEDED: u64 = 7;
    const E_CONSERVATION_BROKEN: u64 = 8;
    const E_INSUFFICIENT_VAULT: u64 = 9;
    const E_NO_FACTORY_TOKEN: u64 = 10;
    const E_INITIAL_MC_OUT_OF_RANGE: u64 = 11;
    const E_TAX_BPS_TOO_HIGH: u64 = 12;
    const E_OPINION_LIMIT_REACHED: u64 = 13;
    const E_ZERO_OUTPUT: u64 = 14;
    const E_TAX_EXCEEDS_AMOUNT: u64 = 15;
    const E_TAX_DRIFT: u64 = 16;
    const E_MARKET_ALREADY_EXISTS: u64 = 17;

    struct PidOpinionMeta has key {
        next_seq: u64,
        opinion_count: u64,
    }

    struct PidOpinionIndex has key {
        markets: SmartTable<u64, address>,
    }

    struct OpinionMarket has key {
        author_pid: address,
        seq: u64,
        creator_wallet: address,
        creator_token: address,
        creator_initial_mc: u64,
        tax_bps: u64,
        yay_metadata: address,
        nay_metadata: address,
        yay_mint_ref: MintRef,
        yay_burn_ref: BurnRef,
        nay_mint_ref: MintRef,
        nay_burn_ref: BurnRef,
        pool_yay: Object<FungibleStore>,
        pool_nay: Object<FungibleStore>,
        vault_token: Object<FungibleStore>,
        total_yay_supply: u64,
        total_nay_supply: u64,
        created_at_secs: u64,
        market_extend_ref: ExtendRef,
    }

    #[event]
    struct OpinionAction has drop, store {
        is_opinion: bool,
        kind: u8,
        actor_pid: address,
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,
        new_pool_yay: u64,
        new_pool_nay: u64,
        new_total_yay_supply: u64,
        new_total_nay_supply: u64,
        timestamp_secs: u64,
    }

    struct OpinionFeedAction has copy, drop, store {
        is_opinion: bool,
        kind: u8,
        actor_pid: address,
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,
        new_pool_yay: u64,
        new_pool_nay: u64,
        new_total_yay_supply: u64,
        new_total_nay_supply: u64,
        timestamp_secs: u64,
    }

    fun ensure_opinion_storage(pid_addr: address) {
        if (!exists<PidOpinionMeta>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidOpinionMeta { next_seq: 0, opinion_count: 0 });
        };
        if (!exists<PidOpinionIndex>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidOpinionIndex { markets: smart_table::new() });
        };
    }

    public(friend) fun bootstrap_market_for_mint(
        author: &signer,
        author_pid: address,
        mint_seq: u64,
        initial_mc: u64,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let author_wallet = signer::address_of(author);
        assert!(
            initial_mc >= MIN_INITIAL_MC && initial_mc <= MAX_INITIAL_MC,
            E_INITIAL_MC_OUT_OF_RANGE,
        );

        assert!(factory::owner_has_token(author_pid), E_NO_FACTORY_TOKEN);
        let creator_token = factory::token_metadata_of_owner(author_pid);

        ensure_opinion_storage(author_pid);

        let meta = borrow_global_mut<PidOpinionMeta>(author_pid);
        assert!(meta.opinion_count < MAX_OPINIONS_PER_PID, E_OPINION_LIMIT_REACHED);
        meta.opinion_count = meta.opinion_count + 1;

        let seq = mint_seq;
        let tax_bps = DEFAULT_TAX_BPS;

        let pid_signer = profile::derive_pid_signer(author_pid);
        let market_seed = make_market_seed(seq);
        let predicted_market_addr = object::create_object_address(&author_pid, market_seed);
        assert!(!exists<OpinionMarket>(predicted_market_addr), E_MARKET_ALREADY_EXISTS);
        let market_constructor = object::create_named_object(&pid_signer, market_seed);
        let market_addr = object::address_from_constructor_ref(&market_constructor);
        let market_signer = object::generate_signer(&market_constructor);
        let market_extend_ref = object::generate_extend_ref(&market_constructor);
        let mkt_transfer = object::generate_transfer_ref(&market_constructor);
        object::disable_ungated_transfer(&mkt_transfer);

        let seq_str = string_utils::to_string<u64>(&seq);

        let yay_constructor = object::create_named_object(&market_signer, SEED_YAY);
        let yay_metadata = object::address_from_constructor_ref(&yay_constructor);
        let yay_name = string::utf8(b"Opinion YAY Share #");
        string::append(&mut yay_name, seq_str);
        let yay_symbol = string::utf8(b"OPN-YAY#");
        string::append(&mut yay_symbol, seq_str);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &yay_constructor,
            option::none<u128>(),
            yay_name,
            yay_symbol,
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let yay_mint_ref = fungible_asset::generate_mint_ref(&yay_constructor);
        let yay_burn_ref = fungible_asset::generate_burn_ref(&yay_constructor);

        let nay_constructor = object::create_named_object(&market_signer, SEED_NAY);
        let nay_metadata = object::address_from_constructor_ref(&nay_constructor);
        let nay_name = string::utf8(b"Opinion NAY Share #");
        string::append(&mut nay_name, seq_str);
        let nay_symbol = string::utf8(b"OPN-NAY#");
        string::append(&mut nay_symbol, seq_str);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &nay_constructor,
            option::none<u128>(),
            nay_name,
            nay_symbol,
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let nay_mint_ref = fungible_asset::generate_mint_ref(&nay_constructor);
        let nay_burn_ref = fungible_asset::generate_burn_ref(&nay_constructor);

        let yay_metadata_obj = object::address_to_object<Metadata>(yay_metadata);
        let nay_metadata_obj = object::address_to_object<Metadata>(nay_metadata);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token);
        let pool_yay_store = create_store_at_market(market_addr, yay_metadata_obj);
        let pool_nay_store = create_store_at_market(market_addr, nay_metadata_obj);
        let vault_token_store = create_store_at_market(market_addr, creator_token_obj);

        let collateral_in = primary_fungible_store::withdraw(
            author, creator_token_obj, initial_mc,
        );
        fungible_asset::deposit(vault_token_store, collateral_in);

        let yay_seed = fungible_asset::mint(&yay_mint_ref, initial_mc);
        let nay_seed = fungible_asset::mint(&nay_mint_ref, initial_mc);
        fungible_asset::deposit(pool_yay_store, yay_seed);
        fungible_asset::deposit(pool_nay_store, nay_seed);

        let now_secs = timestamp::now_seconds();
        move_to(&market_signer, OpinionMarket {
            author_pid,
            seq,
            creator_wallet: author_wallet,
            creator_token,
            creator_initial_mc: initial_mc,
            tax_bps,
            yay_metadata,
            nay_metadata,
            yay_mint_ref,
            yay_burn_ref,
            nay_mint_ref,
            nay_burn_ref,
            pool_yay: pool_yay_store,
            pool_nay: pool_nay_store,
            vault_token: vault_token_store,
            total_yay_supply: initial_mc,
            total_nay_supply: initial_mc,
            created_at_secs: now_secs,
            market_extend_ref,
        });

        let mkt_ref = borrow_global<OpinionMarket>(market_addr);
        assert_conservation(mkt_ref);

        let idx = borrow_global_mut<PidOpinionIndex>(author_pid);
        smart_table::add(&mut idx.markets, seq, market_addr);

    }

    public entry fun deposit_balanced(
        user: &signer,
        actor_pid: address,
        author_pid: address,
        seq: u64,
        amount: u64,
    ) acquires OpinionMarket {
        profile::assert_authorized(user, actor_pid);
        assert!(amount > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let user_addr = signer::address_of(user);

        let creator_token_obj = object::address_to_object<Metadata>(mkt.creator_token);
        let token_in = primary_fungible_store::withdraw(user, creator_token_obj, amount);
        fungible_asset::deposit(mkt.vault_token, token_in);

        let yay_minted = fungible_asset::mint(&mkt.yay_mint_ref, amount);
        let nay_minted = fungible_asset::mint(&mkt.nay_mint_ref, amount);
        mkt.total_yay_supply = mkt.total_yay_supply + amount;
        mkt.total_nay_supply = mkt.total_nay_supply + amount;
        primary_fungible_store::deposit(user_addr, yay_minted);
        primary_fungible_store::deposit(user_addr, nay_minted);

        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            actor_pid,
            user_addr,
            KIND_DEPOSIT_BALANCED,
            SIDE_NONE,
            amount,
            amount,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    public entry fun deposit_pick_side(
        user: &signer,
        actor_pid: address,
        author_pid: address,
        seq: u64,
        side: u8,
        amount_token: u64,
    ) acquires OpinionMarket {
        profile::assert_authorized(user, actor_pid);
        assert!(amount_token > 0, E_AMOUNT_ZERO);
        assert!(side == SIDE_YAY || side == SIDE_NAY, E_INVALID_SIDE);

        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        assert!(
            fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0,
            E_POOL_NOT_ACTIVE,
        );

        let user_addr = signer::address_of(user);

        let creator_token_obj = object::address_to_object<Metadata>(mkt.creator_token);
        let token_in = primary_fungible_store::withdraw(user, creator_token_obj, amount_token);
        fungible_asset::deposit(mkt.vault_token, token_in);

        let yay_minted = fungible_asset::mint(&mkt.yay_mint_ref, amount_token);
        let nay_minted = fungible_asset::mint(&mkt.nay_mint_ref, amount_token);
        mkt.total_yay_supply = mkt.total_yay_supply + amount_token;
        mkt.total_nay_supply = mkt.total_nay_supply + amount_token;

        if (side == SIDE_YAY) {
            primary_fungible_store::deposit(user_addr, yay_minted);
            fungible_asset::deposit(mkt.pool_nay, nay_minted);
        } else {
            primary_fungible_store::deposit(user_addr, nay_minted);
            fungible_asset::deposit(mkt.pool_yay, yay_minted);
        };

        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_token, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            actor_pid,
            user_addr,
            KIND_DEPOSIT,
            side,
            amount_token,
            amount_token,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    public entry fun swap_yay_for_nay(
        user: &signer,
        actor_pid: address,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        profile::assert_authorized(user, actor_pid);
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_yay_r, pool_nay_r, amount_in);
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_yay, yay_in);

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let nay_out = fungible_asset::withdraw(&market_signer, mkt.pool_nay, amount_out);
        primary_fungible_store::deposit(user_addr, nay_out);

        let amount_in_token_equiv = ((((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            actor_pid,
            user_addr,
            KIND_SWAP_YAY_FOR_NAY,
            SIDE_NONE,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    public entry fun swap_nay_for_yay(
        user: &signer,
        actor_pid: address,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        profile::assert_authorized(user, actor_pid);
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_nay_r, pool_yay_r, amount_in);
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_nay, nay_in);

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let yay_out = fungible_asset::withdraw(&market_signer, mkt.pool_yay, amount_out);
        primary_fungible_store::deposit(user_addr, yay_out);

        let amount_in_token_equiv = ((((amount_in as u128) * (pool_yay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            actor_pid,
            user_addr,
            KIND_SWAP_NAY_FOR_YAY,
            SIDE_NONE,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    public entry fun redeem_complete_set(
        user: &signer,
        actor_pid: address,
        author_pid: address,
        seq: u64,
        amount: u64,
    ) acquires OpinionMarket {
        profile::assert_authorized(user, actor_pid);
        assert!(amount > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        assert!(fungible_asset::balance(mkt.vault_token) >= amount, E_INSUFFICIENT_VAULT);

        let user_addr = signer::address_of(user);

        let tax_amount = compute_tax(amount, mkt.tax_bps);
        assert!(tax_amount <= amount, E_TAX_EXCEEDS_AMOUNT);

        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount);
        fungible_asset::burn(&mkt.yay_burn_ref, yay_in);
        fungible_asset::burn(&mkt.nay_burn_ref, nay_in);
        mkt.total_yay_supply = mkt.total_yay_supply - amount;
        mkt.total_nay_supply = mkt.total_nay_supply - amount;

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let user_out_amount = amount - tax_amount;

        if (user_out_amount > 0) {
            let user_fa = fungible_asset::withdraw(&market_signer, mkt.vault_token, user_out_amount);
            primary_fungible_store::deposit(user_addr, user_fa);
        };

        let tax_burned = if (tax_amount > 0) {
            let tax_fa = fungible_asset::withdraw(&market_signer, mkt.vault_token, tax_amount);
            let vault_addr = factory::vault_addr_of_pid(mkt.author_pid);
            supra_vault::burn_via_vault(vault_addr, tax_fa);
            tax_amount
        } else {
            0
        };

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            actor_pid,
            user_addr,
            KIND_REDEEM,
            SIDE_NONE,
            amount,
            amount,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    #[view]
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
    ): u64 {
        if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;
        let amount_in_u128 = (amount_in as u128);
        let numerator = amount_in_u128 * (reserve_out as u128);
        let denominator = (reserve_in as u128) + amount_in_u128;
        ((numerator / denominator) as u64)
    }

    #[view]
    public fun compute_tax(amount: u64, tax_bps: u64): u64 {
        assert!(tax_bps <= MAX_TAX_BPS, E_TAX_BPS_TOO_HIGH);
        if (tax_bps == 0 || amount == 0) return 0;
        let numerator = (amount as u128) * (tax_bps as u128) + (BPS_DENOM as u128) - 1;
        ((numerator / (BPS_DENOM as u128)) as u64)
    }

    fun assert_conservation(mkt: &OpinionMarket) {
        let vault_amt = fungible_asset::balance(mkt.vault_token);
        assert!(mkt.total_yay_supply == mkt.total_nay_supply, E_CONSERVATION_BROKEN);
        assert!(vault_amt == mkt.total_yay_supply, E_CONSERVATION_BROKEN);

        let yay_meta = object::address_to_object<Metadata>(mkt.yay_metadata);
        let nay_meta = object::address_to_object<Metadata>(mkt.nay_metadata);
        let yay_supply_opt = fungible_asset::supply(yay_meta);
        let nay_supply_opt = fungible_asset::supply(nay_meta);
        if (option::is_some(&yay_supply_opt)) {
            let yay_fa_supply = option::extract(&mut yay_supply_opt);
            assert!(yay_fa_supply == (mkt.total_yay_supply as u128), E_CONSERVATION_BROKEN);
        };
        if (option::is_some(&nay_supply_opt)) {
            let nay_fa_supply = option::extract(&mut nay_supply_opt);
            assert!(nay_fa_supply == (mkt.total_nay_supply as u128), E_CONSERVATION_BROKEN);
        };
    }

    fun burn_tax(
        user: &signer,
        creator_token_addr: address,
        author_pid: address,
        amount: u64,
        tax_bps: u64,
    ): u64 {
        let tax_amount = compute_tax(amount, tax_bps);
        if (tax_amount == 0) return 0;
        assert!(tax_bps == DEFAULT_TAX_BPS, E_TAX_DRIFT);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token_addr);
        let tax_fa = primary_fungible_store::withdraw(user, creator_token_obj, tax_amount);
        let vault_addr = factory::vault_addr_of_pid(author_pid);
        supra_vault::burn_via_vault(vault_addr, tax_fa);
        tax_amount
    }

    fun emit_action(
        mkt: &OpinionMarket,
        actor_pid: address,
        actor_wallet: address,
        kind: u8,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,
        new_pool_yay: u64,
        new_pool_nay: u64,
        now_secs: u64,
    ) {
        let market_addr = market_addr_of(mkt.author_pid, mkt.seq);
        let feed_payload = OpinionFeedAction {
            is_opinion: true,
            kind,
            actor_pid,
            actor_wallet,
            author_pid: mkt.author_pid,
            seq: mkt.seq,
            market_addr,
            side,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            new_total_yay_supply: mkt.total_yay_supply,
            new_total_nay_supply: mkt.total_nay_supply,
            timestamp_secs: now_secs,
        };
        history::append(
            actor_pid,
            history::new_entry(
                history::verb_opinion(),
                now_secs,
                option::some(mkt.author_pid),
                bcs::to_bytes(&feed_payload),
                option::some(market_addr),
            ),
        );

        event::emit(OpinionAction {
            is_opinion: true,
            kind,
            actor_pid,
            actor_wallet,
            author_pid: mkt.author_pid,
            seq: mkt.seq,
            market_addr,
            side,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            new_total_yay_supply: mkt.total_yay_supply,
            new_total_nay_supply: mkt.total_nay_supply,
            timestamp_secs: now_secs,
        });
    }

    fun make_market_seed(seq: u64): vector<u8> {
        let s = SEED_MARKET_PREFIX;
        vector::append(&mut s, bcs::to_bytes(&seq));
        s
    }

    fun create_store_at_market(market_addr: address, metadata: Object<Metadata>): Object<FungibleStore> {
        let store_constructor = object::create_object(market_addr);
        fungible_asset::create_store<Metadata>(&store_constructor, metadata)
    }

    #[view]
    public fun market_addr_of(author_pid: address, seq: u64): address {
        object::create_object_address(&author_pid, make_market_seed(seq))
    }

    #[view]
    public fun market_exists(author_pid: address, seq: u64): bool {
        exists<OpinionMarket>(market_addr_of(author_pid, seq))
    }

    #[view]
    public fun next_seq(author_pid: address): u64 acquires PidOpinionMeta {
        if (!exists<PidOpinionMeta>(author_pid)) return 0;
        borrow_global<PidOpinionMeta>(author_pid).next_seq
    }

    #[view]
    public fun opinion_count(author_pid: address): u64 acquires PidOpinionMeta {
        if (!exists<PidOpinionMeta>(author_pid)) return 0;
        borrow_global<PidOpinionMeta>(author_pid).opinion_count
    }

    #[view]
    public fun pool_reserves(author_pid: address, seq: u64): (u64, u64)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (fungible_asset::balance(mkt.pool_yay), fungible_asset::balance(mkt.pool_nay))
    }

    #[view]
    public fun total_supplies(author_pid: address, seq: u64): (u64, u64)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.total_yay_supply, mkt.total_nay_supply)
    }

    #[view]
    public fun vault_balance(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.vault_token)
    }

    #[view]
    public fun token_addrs(author_pid: address, seq: u64): (address, address)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.yay_metadata, mkt.nay_metadata)
    }

    #[view]
    public fun creator_token_of(author_pid: address, seq: u64): address
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.creator_token
    }

    #[view]
    public fun creator_initial_mc(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.creator_initial_mc
    }

    #[view]
    public fun tax_bps_of(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.tax_bps
    }

    #[view]
    public fun is_pool_active(author_pid: address, seq: u64): bool
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        if (!exists<OpinionMarket>(market_addr)) return false;
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0
    }

    #[view]
    public fun yay_price_token_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (yay_r, nay_r) = pool_reserves(author_pid, seq);
        assert!(yay_r > 0 && nay_r > 0, E_POOL_NOT_ACTIVE);
        (((nay_r as u128) * 100_000_000u128) / ((yay_r as u128) + (nay_r as u128)) as u64)
    }

    #[view]
    public fun nay_price_token_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (yay_r, nay_r) = pool_reserves(author_pid, seq);
        assert!(yay_r > 0 && nay_r > 0, E_POOL_NOT_ACTIVE);
        (((yay_r as u128) * 100_000_000u128) / ((yay_r as u128) + (nay_r as u128)) as u64)
    }

    #[view]
    public fun side_yay(): u8 { SIDE_YAY }
    #[view]
    public fun side_nay(): u8 { SIDE_NAY }
    #[view]
    public fun side_none(): u8 { SIDE_NONE }
    #[view]
    public fun kind_create(): u8 { KIND_CREATE }
    #[view]
    public fun kind_deposit(): u8 { KIND_DEPOSIT }
    #[view]
    public fun kind_swap_yay_for_nay(): u8 { KIND_SWAP_YAY_FOR_NAY }
    #[view]
    public fun kind_swap_nay_for_yay(): u8 { KIND_SWAP_NAY_FOR_YAY }
    #[view]
    public fun kind_redeem(): u8 { KIND_REDEEM }
    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }
    #[view]
    public fun min_initial_mc(): u64 { MIN_INITIAL_MC }
    #[view]
    public fun max_initial_mc(): u64 { MAX_INITIAL_MC }
    #[view]
    public fun default_tax_bps(): u64 { DEFAULT_TAX_BPS }
    #[view]
    public fun max_tax_bps(): u64 { MAX_TAX_BPS }

    #[test]
    fun test_compute_amount_out_no_fee() {
        let out = compute_amount_out(100, 10, 100);
        assert!(out == 5, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        let out = compute_amount_out(100, 10, 0);
        assert!(out == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_symmetric_pool() {
        let out = compute_amount_out(100, 100, 10);
        assert!(out == 9, 1);
    }

    #[test]
    fun test_make_market_seed_deterministic() {
        let s1 = make_market_seed(0);
        let s2 = make_market_seed(0);
        let s3 = make_market_seed(1);
        assert!(s1 == s2, 1);
        assert!(s1 != s3, 2);
    }

    #[test]
    fun test_market_addr_deterministic() {
        let a1 = market_addr_of(@0xCAFE, 5);
        let a2 = market_addr_of(@0xCAFE, 5);
        let b1 = market_addr_of(@0xCAFE, 6);
        let c1 = market_addr_of(@0xBEEF, 5);
        assert!(a1 == a2, 1);
        assert!(a1 != b1, 2);
        assert!(a1 != c1, 3);
    }

    #[test]
    fun test_constants_distinct() {
        assert!(SIDE_YAY != SIDE_NAY, 1);
        assert!(SIDE_YAY != SIDE_NONE, 2);
        assert!(SIDE_NAY != SIDE_NONE, 3);
        assert!(KIND_CREATE != KIND_DEPOSIT, 4);
        assert!(KIND_DEPOSIT != KIND_SWAP_YAY_FOR_NAY, 5);
        assert!(KIND_SWAP_YAY_FOR_NAY != KIND_SWAP_NAY_FOR_YAY, 6);
        assert!(KIND_SWAP_NAY_FOR_YAY != KIND_REDEEM, 7);
    }

    #[test]
    fun test_initial_mc_bounds() {
        assert!(MIN_INITIAL_MC == 10_000_000_000_000, 1);
        assert!(MAX_INITIAL_MC == 10_000_000_000_000_000, 2);
        assert!(MAX_INITIAL_MC * 10 == 100_000_000_000_000_000, 3);
    }

    #[test]
    fun test_tax_bps_constants() {
        assert!(DEFAULT_TAX_BPS == 10, 1);
        assert!(MAX_TAX_BPS == 1000, 2);
        assert!(BPS_DENOM == 10000, 3);
        let tax = (((MIN_INITIAL_MC as u128) * (DEFAULT_TAX_BPS as u128) / (BPS_DENOM as u128)) as u64);
        assert!(tax == 10_000_000_000, 4);
    }

    #[test]
    fun test_compute_tax_zero_inputs() {
        assert!(compute_tax(1_000_000_000, 0) == 0, 1);
        assert!(compute_tax(0, 30) == 0, 2);
        assert!(compute_tax(0, 0) == 0, 3);
    }

    #[test]
    fun test_compute_tax_ceiling_dust_protection() {
        assert!(compute_tax(99, 10) == 1, 1);
        assert!(compute_tax(1, 1) == 1, 2);
        assert!(compute_tax(500, 10) == 1, 3);
        assert!(compute_tax(999, 10) == 1, 4);
        assert!(compute_tax(1000, 10) == 1, 5);
        assert!(compute_tax(1001, 10) == 2, 6);
    }

    #[test]
    fun test_compute_tax_normal_amounts() {
        assert!(compute_tax(100_000_000_000_000, 10) == 100_000_000_000, 1);
        assert!(compute_tax(10_000_000_000_000_000, 30) == 30_000_000_000_000, 2);
        assert!(compute_tax(100_000_000, 1000) == 10_000_000, 3);
    }

    #[test]
    fun test_compute_tax_max_bounds_no_overflow() {
        let max_amt = 18_446_744_073_709_551_615u64;
        let tax = compute_tax(max_amt, MAX_TAX_BPS);
        assert!(tax > max_amt / 10 - 1, 1);
        assert!(tax <= max_amt / 10 + 1, 2);
    }

    #[test_only]
    use supra_framework::account;

    #[test_only]
    fun setup_mock_creator_token(creator: &signer, symbol: vector<u8>): (address, MintRef) {
        let constructor = object::create_named_object(creator, symbol);
        let metadata_addr = object::address_from_constructor_ref(&constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),
            string::utf8(symbol),
            string::utf8(symbol),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        (metadata_addr, mint_ref)
    }

    #[test_only]
    fun mint_test_balance(mint_ref: &MintRef, to: address, amount: u64) {
        let fa = fungible_asset::mint(mint_ref, amount);
        primary_fungible_store::deposit(to, fa);
    }

    #[test_only]
    fun setup_test_opinion_market(
        creator: &signer,
        creator_token_addr: address,
        creator_token_mint_ref: &MintRef,
        initial_mc: u64,
    ): (address, address) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let creator_addr = signer::address_of(creator);
        let pid_addr = profile::setup_test_pid(creator);

        ensure_opinion_storage(pid_addr);

        let meta = borrow_global_mut<PidOpinionMeta>(pid_addr);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.opinion_count = meta.opinion_count + 1;

        let pid_signer = profile::derive_pid_signer(pid_addr);
        let market_seed = make_market_seed(seq);
        let market_constructor = object::create_named_object(&pid_signer, market_seed);
        let market_addr = object::address_from_constructor_ref(&market_constructor);
        let market_signer = object::generate_signer(&market_constructor);
        let market_extend_ref = object::generate_extend_ref(&market_constructor);
        let mkt_transfer = object::generate_transfer_ref(&market_constructor);
        object::disable_ungated_transfer(&mkt_transfer);

        let yay_constructor = object::create_named_object(&market_signer, SEED_YAY);
        let yay_metadata = object::address_from_constructor_ref(&yay_constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &yay_constructor, option::none<u128>(),
            string::utf8(b"OPN-YAY-test"), string::utf8(b"OPN-YAY-T"),
            OPN_DECIMALS, string::utf8(b""), string::utf8(b""),
        );
        let yay_mint_ref = fungible_asset::generate_mint_ref(&yay_constructor);
        let yay_burn_ref = fungible_asset::generate_burn_ref(&yay_constructor);

        let nay_constructor = object::create_named_object(&market_signer, SEED_NAY);
        let nay_metadata = object::address_from_constructor_ref(&nay_constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &nay_constructor, option::none<u128>(),
            string::utf8(b"OPN-NAY-test"), string::utf8(b"OPN-NAY-T"),
            OPN_DECIMALS, string::utf8(b""), string::utf8(b""),
        );
        let nay_mint_ref = fungible_asset::generate_mint_ref(&nay_constructor);
        let nay_burn_ref = fungible_asset::generate_burn_ref(&nay_constructor);

        let yay_meta_obj = object::address_to_object<Metadata>(yay_metadata);
        let nay_meta_obj = object::address_to_object<Metadata>(nay_metadata);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token_addr);
        let pool_yay_store = create_store_at_market(market_addr, yay_meta_obj);
        let pool_nay_store = create_store_at_market(market_addr, nay_meta_obj);
        let vault_token_store = create_store_at_market(market_addr, creator_token_obj);

        mint_test_balance(creator_token_mint_ref, creator_addr, initial_mc);

        let collateral_in = primary_fungible_store::withdraw(
            creator, creator_token_obj, initial_mc,
        );
        fungible_asset::deposit(vault_token_store, collateral_in);
        let yay_seed = fungible_asset::mint(&yay_mint_ref, initial_mc);
        let nay_seed = fungible_asset::mint(&nay_mint_ref, initial_mc);
        fungible_asset::deposit(pool_yay_store, yay_seed);
        fungible_asset::deposit(pool_nay_store, nay_seed);

        let now_secs = timestamp::now_seconds();
        move_to(&market_signer, OpinionMarket {
            author_pid: pid_addr,
            seq,
            creator_wallet: creator_addr,
            creator_token: creator_token_addr,
            creator_initial_mc: initial_mc,
            tax_bps: 0,
            yay_metadata, nay_metadata,
            yay_mint_ref, yay_burn_ref,
            nay_mint_ref, nay_burn_ref,
            pool_yay: pool_yay_store, pool_nay: pool_nay_store,
            vault_token: vault_token_store,
            total_yay_supply: initial_mc, total_nay_supply: initial_mc,
            created_at_secs: now_secs,
            market_extend_ref,
        });

        let mkt_ref = borrow_global<OpinionMarket>(market_addr);
        assert_conservation(mkt_ref);

        let idx = borrow_global_mut<PidOpinionIndex>(pid_addr);
        smart_table::add(&mut idx.markets, seq, market_addr);

        (pid_addr, market_addr)
    }

    #[test_only]
    fun setup_full_market(framework: &signer, creator: &signer): (address, address, address, MintRef)
        acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket
    {
        timestamp::set_time_has_started_for_testing(framework);
        let creator_addr = signer::address_of(creator);
        account::create_account_for_test(creator_addr);

        let (token_addr, token_mint_ref) = setup_mock_creator_token(creator, b"SMK");
        let (pid_addr, market_addr) = setup_test_opinion_market(
            creator, token_addr, &token_mint_ref, MIN_INITIAL_MC,
        );
        (pid_addr, market_addr, token_addr, token_mint_ref)
    }

    #[test(framework = @supra_framework, creator = @0xCAFE)]
    fun test_integration_market_setup(framework: &signer, creator: &signer)
        acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket
    {
        let (pid, market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);

        assert!(market_exists(pid, 0), 1);
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 2);
        assert!(nay_r == MIN_INITIAL_MC, 3);
        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC, 4);
        let (total_y, total_n) = total_supplies(pid, 0);
        assert!(total_y == MIN_INITIAL_MC, 5);
        assert!(total_n == MIN_INITIAL_MC, 6);
        assert!(creator_initial_mc(pid, 0) == MIN_INITIAL_MC, 7);
        assert!(market_addr == market_addr_of(pid, 0), 8);

        let mkt_for_clean = borrow_global<OpinionMarket>(market_addr);
        assert_conservation(mkt_for_clean);
        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_deposit_pick_side_yay(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_YAY, deposit_amt);

        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 1);
        assert!(nay_r == MIN_INITIAL_MC + deposit_amt, 2);
        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 3);
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt, 4);
        assert!(tn == MIN_INITIAL_MC + deposit_amt, 5);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_deposit_pick_side_nay(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_NAY, deposit_amt);

        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC + deposit_amt, 1);
        assert!(nay_r == MIN_INITIAL_MC, 2);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_deposit_balanced(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        deposit_balanced(bob, bob_pid, pid, 0, deposit_amt);

        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 1);
        assert!(nay_r == MIN_INITIAL_MC, 2);

        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 3);
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt, 4);
        assert!(tn == MIN_INITIAL_MC + deposit_amt, 5);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_swap_yay_for_nay(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);
        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_YAY, deposit_amt);

        let swap_in: u64 = 100_000_000_000;
        swap_yay_for_nay(bob, bob_pid, pid, 0, swap_in, 1);

        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 1);
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt, 2);
        assert!(tn == MIN_INITIAL_MC + deposit_amt, 3);
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC + swap_in, 4);
        assert!(nay_r < MIN_INITIAL_MC + deposit_amt, 5);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_redeem_complete_set_full_cycle(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);
        deposit_balanced(bob, bob_pid, pid, 0, deposit_amt);

        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 1);

        let redeem_amt: u64 = deposit_amt / 2;
        redeem_complete_set(bob, bob_pid, pid, 0, redeem_amt);

        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt - redeem_amt, 2);
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt - redeem_amt, 3);
        assert!(tn == MIN_INITIAL_MC + deposit_amt - redeem_amt, 4);
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 5);
        assert!(nay_r == MIN_INITIAL_MC, 6);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B, carol = @0xCA401)]
    fun test_integration_conservation_across_full_cycle(
        framework: &signer, creator: &signer, bob: &signer, carol: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        let carol_addr = signer::address_of(carol);
        account::create_account_for_test(bob_addr);
        account::create_account_for_test(carol_addr);
        let bob_pid = profile::setup_test_pid(bob);
        let carol_pid = profile::setup_test_pid(carol);

        let amt: u64 = 1_000_000_000_000;

        mint_test_balance(&token_mint_ref, bob_addr, amt);
        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_YAY, amt);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        mint_test_balance(&token_mint_ref, carol_addr, amt);
        deposit_pick_side(carol, carol_pid, pid, 0, SIDE_NAY, amt);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        mint_test_balance(&token_mint_ref, bob_addr, amt / 2);
        deposit_balanced(bob, bob_pid, pid, 0, amt / 2);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        swap_nay_for_yay(carol, carol_pid, pid, 0, amt / 4, 1);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        redeem_complete_set(bob, bob_pid, pid, 0, amt / 4);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        let (final_y, final_n) = total_supplies(pid, 0);
        assert!(final_y == final_n, 1);
        assert!(vault_balance(pid, 0) == final_y, 2);

        let _ = token_mint_ref;
    }

    #[test]
    fun test_max_opinions_per_pid_constant() {
        assert!(MAX_OPINIONS_PER_PID == 10_000, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_reserve_in() {
        assert!(compute_amount_out(0, 100, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_reserve_out() {
        assert!(compute_amount_out(100, 0, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_all_zero() {
        assert!(compute_amount_out(0, 0, 0) == 0, 1);
    }

    #[test]
    #[expected_failure(abort_code = E_TAX_BPS_TOO_HIGH, location = Self)]
    fun test_compute_tax_rejects_excessive_tax_bps() {
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS + 1);
    }

    #[test]
    fun test_compute_tax_accepts_max_tax_bps() {
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS);
    }

    #[test]
    fun test_swap_tax_spot_value_correctness() {
        let pool_yay_r = 10u64;
        let pool_nay_r = 100u64;
        let amount_in = 11u64;
        let amount_in_token_equiv = ((((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        assert!(amount_in_token_equiv == 10, 1);
        assert!(compute_tax(amount_in_token_equiv, 10) == 1, 2);
    }

    #[test]
    fun test_swap_tax_extreme_skew_value() {
        let v = ((((1000u128) * (999u128)) / ((1u128) + (999u128))) as u64);
        assert!(v == 999, 1);
    }

    #[test]
    fun test_redeem_skim_math() {
        let amount = 1000u64;
        let tax_amount = compute_tax(amount, 10);
        assert!(tax_amount == 1, 1);
        let user_out = amount - tax_amount;
        assert!(user_out == 999, 2);
        let dust_tax = compute_tax(1, 10);
        assert!(dust_tax == 1, 3);
        assert!(1 - dust_tax == 0, 4);
    }

    #[test]
    fun test_zero_output_detection_math() {
        let huge_reserve_in = 1_000_000_000_000_000_000u64;
        let amount_in = 1u64;
        let amount_out = compute_amount_out(huge_reserve_in, 1, amount_in);
        assert!(amount_out == 0, 1);
        assert!(E_ZERO_OUTPUT == 14, 2);
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    #[expected_failure(abort_code = E_ZERO_OUTPUT, location = Self)]
    fun test_rc4_m1_swap_nay_for_yay_zero_output_aborts(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        let bob_pid = profile::setup_test_pid(bob);

        mint_test_balance(&token_mint_ref, bob_addr, 2);
        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_YAY, 1);
        deposit_pick_side(bob, bob_pid, pid, 0, SIDE_NAY, 1);

        swap_nay_for_yay(bob, bob_pid, pid, 0, 1, 0);
        let _ = token_mint_ref;
    }

    #[test(user = @0xB0B)]
    #[expected_failure(abort_code = E_TAX_DRIFT, location = Self)]
    fun test_rc4_l1_burn_tax_drift_aborts(user: &signer) {
        burn_tax(user, @0xCAFE, @0xC4FE, 1000, 20);
    }

    #[test(user = @0xB0B)]
    fun test_rc4_l1_burn_tax_zero_short_circuits(user: &signer) {
        let burned = burn_tax(user, @0xCAFE, @0xC4FE, 1000, 0);
        assert!(burned == 0, 1);
    }

    #[test]
    fun test_rc4_l2_constants() {
        assert!(E_MARKET_ALREADY_EXISTS == 17, 1);
        assert!(E_MARKET_ALREADY_EXISTS != E_MARKET_NOT_FOUND, 2);
        assert!(E_TAX_DRIFT == 16, 3);
        assert!(E_TAX_DRIFT != E_TAX_BPS_TOO_HIGH, 4);
    }
}
