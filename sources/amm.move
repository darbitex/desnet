module desnet::amm {
    use std::signer;
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use aptos_std::math128;

    use desnet::governance;

    friend desnet::factory;
    friend desnet::lp_staking;
    friend desnet::supra_vault;
    friend desnet::ipo;

    const FEE_BPS: u64 = 100;
    const FLASH_FEE_BPS: u64 = 100;
    const FEE_DENOM: u64 = 10000;
    const MIN_INITIAL_LP: u128 = 1000;
    const FEE_ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    const SEED_POOL: vector<u8> = b"desnet::amm::pool::";

    const WARNING: vector<u8> = b"DESNET AMM x*y=k. Multi-LLM audited (R1-R5, mainnet live). Use at own risk.";

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_POOL_ALREADY_EXISTS: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_SLIPPAGE_EXCEEDED: u64 = 4;
    const E_ZERO_AMOUNT: u64 = 5;
    const E_INVALID_FA_TYPE: u64 = 6;
    const E_INVALID_HANDLE: u64 = 7;
    const E_INSUFFICIENT_LP_BURN: u64 = 8;
    const E_INITIAL_LP_BELOW_MIN: u64 = 9;
    const E_INSUFFICIENT_FEE_BUCKET: u64 = 11;
    const E_LOCKED: u64 = 12;
    const E_WRONG_POOL: u64 = 13;
    const E_K_VIOLATED: u64 = 14;
    const E_WRONG_TOKEN: u64 = 15;
    const E_SWAPS_DISABLED: u64 = 16;

    struct Pool has key {
        handle: vector<u8>,
        supra_reserve: Object<FungibleStore>,
        token_reserve: Object<FungibleStore>,
        supra_fees: Object<FungibleStore>,
        token_fees: Object<FungibleStore>,
        token_metadata_addr: address,
        lp_supply: u128,
        fee_per_lp_supra: u128,
        fee_per_lp_token: u128,
        creator_pid: address,
        locked: bool,
        swaps_enabled: bool,
        extend_ref: ExtendRef,
    }

    struct FlashReceipt {
        pool_addr: address,
        metadata_addr: address,
        amount: u64,
        fee: u64,
    }

    #[event]
    struct PoolCreated has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        token_metadata_addr: address,
        supra_in: u64,
        token_in: u64,
        lp_minted: u128,
        creator_pid: address,
    }

    #[event]
    struct LiquidityAdded has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        supra_in: u64,
        token_in: u64,
        lp_minted: u128,
        new_supra_reserve: u64,
        new_token_reserve: u64,
        new_lp_supply: u128,
    }

    #[event]
    struct LiquidityRemoved has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        lp_burned: u128,
        supra_out: u64,
        token_out: u64,
        new_supra_reserve: u64,
        new_token_reserve: u64,
        new_lp_supply: u128,
    }

    #[event]
    struct Swapped has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        actor: address,
        supra_to_token: bool,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64,
        new_supra_reserve: u64,
        new_token_reserve: u64,
    }

    #[event]
    struct FeesExtractedForClaim has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        supra_extracted: u64,
        token_extracted: u64,
    }

    #[event]
    struct FlashBorrowed has drop, store {
        pool_addr: address,
        metadata_addr: address,
        amount: u64,
        fee: u64,
    }

    #[event]
    struct FlashRepaid has drop, store {
        pool_addr: address,
        metadata_addr: address,
        repaid: u64,
    }

    public fun pool_address_of_handle(handle: vector<u8>): address {
        let seed = pool_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    public fun pool_exists(handle: vector<u8>): bool {
        exists<Pool>(pool_address_of_handle(handle))
    }

    public fun pool_exists_at(pool_addr: address): bool {
        exists<Pool>(pool_addr)
    }

    fun pool_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_POOL;
        vector::append(&mut s, *handle);
        s
    }

    public(friend) fun create_pool_atomic(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        token_in: FungibleAsset,
        creator_pid: address,
        swaps_enabled: bool,
    ): u128 {
        assert!(!vector::is_empty(&handle), E_INVALID_HANDLE);
        let pool_addr = pool_address_of_handle(handle);
        assert!(!exists<Pool>(pool_addr), E_POOL_ALREADY_EXISTS);

        let supra_amount = fungible_asset::amount(&supra_in);
        let token_amount = fungible_asset::amount(&token_in);
        assert!(supra_amount > 0 && token_amount > 0, E_ZERO_AMOUNT);

        let supra_meta = fungible_asset::metadata_from_asset(&supra_in);
        assert!(object::object_address(&supra_meta) == governance::native_fa_metadata(), E_INVALID_FA_TYPE);

        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        let token_meta_addr = object::object_address(&token_meta);

        let pkg_signer = governance::derive_pkg_signer();
        let pool_constructor = object::create_named_object(&pkg_signer, pool_seed(&handle));
        let pool_signer = object::generate_signer(&pool_constructor);
        let pool_extend_ref = object::generate_extend_ref(&pool_constructor);
        let pool_transfer_ref = object::generate_transfer_ref(&pool_constructor);
        object::disable_ungated_transfer(&pool_transfer_ref);

        let supra_reserve = create_store_at_pool(pool_addr, supra_meta);
        let token_reserve = create_store_at_pool(pool_addr, token_meta);
        let supra_fees = create_store_at_pool(pool_addr, supra_meta);
        let token_fees = create_store_at_pool(pool_addr, token_meta);

        let initial_lp = mint_lp_initial(supra_amount, token_amount);
        assert!(initial_lp >= MIN_INITIAL_LP, E_INITIAL_LP_BELOW_MIN);

        fungible_asset::deposit(supra_reserve, supra_in);
        fungible_asset::deposit(token_reserve, token_in);

        move_to(&pool_signer, Pool {
            handle: handle,
            supra_reserve,
            token_reserve,
            supra_fees,
            token_fees,
            token_metadata_addr: token_meta_addr,
            lp_supply: initial_lp,
            fee_per_lp_supra: 0,
            fee_per_lp_token: 0,
            creator_pid,
            locked: false,
            swaps_enabled,
            extend_ref: pool_extend_ref,
        });

        event::emit(PoolCreated {
            handle,
            pool_addr,
            token_metadata_addr: token_meta_addr,
            supra_in: supra_amount,
            token_in: token_amount,
            lp_minted: initial_lp,
            creator_pid,
        });

        initial_lp
    }

    fun create_store_at_pool(pool_addr: address, metadata: Object<Metadata>): Object<FungibleStore> {
        let store_constructor = object::create_object(pool_addr);
        fungible_asset::create_store<Metadata>(&store_constructor, metadata)
    }

    public(friend) fun add_liquidity_internal(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        token_in: FungibleAsset,
        min_lp_out: u64,
    ): (u128, FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        let supra_amount = fungible_asset::amount(&supra_in);
        let token_amount = fungible_asset::amount(&token_in);
        assert!(supra_amount > 0 && token_amount > 0, E_ZERO_AMOUNT);

        let supra_meta = fungible_asset::metadata_from_asset(&supra_in);
        assert!(object::object_address(&supra_meta) == governance::native_fa_metadata(), E_INVALID_FA_TYPE);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        assert!(object::object_address(&token_meta) == pool.token_metadata_addr, E_INVALID_FA_TYPE);

        let supra_reserve_amt = fungible_asset::balance(pool.supra_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);
        assert!(supra_reserve_amt > 0 && token_reserve_amt > 0, E_INSUFFICIENT_LIQUIDITY);

        let lp_from_supra = ((supra_amount as u128) * pool.lp_supply) / (supra_reserve_amt as u128);
        let lp_from_token = ((token_amount as u128) * pool.lp_supply) / (token_reserve_amt as u128);
        let lp_minted = if (lp_from_supra < lp_from_token) lp_from_supra else lp_from_token;
        assert!(lp_minted > 0, E_INSUFFICIENT_LIQUIDITY);
        assert!(lp_minted >= (min_lp_out as u128), E_SLIPPAGE_EXCEEDED);

        let optimal_supra = (lp_minted * (supra_reserve_amt as u128)) / pool.lp_supply;
        let optimal_token = (lp_minted * (token_reserve_amt as u128)) / pool.lp_supply;
        let supra_surplus = (supra_amount as u128) - optimal_supra;
        let token_surplus = (token_amount as u128) - optimal_token;

        let supra_refund = if (supra_surplus > 0) {
            fungible_asset::extract(&mut supra_in, (supra_surplus as u64))
        } else {
            fungible_asset::zero(supra_meta)
        };
        let token_refund = if (token_surplus > 0) {
            fungible_asset::extract(&mut token_in, (token_surplus as u64))
        } else {
            fungible_asset::zero(token_meta)
        };

        fungible_asset::deposit(pool.supra_reserve, supra_in);
        fungible_asset::deposit(pool.token_reserve, token_in);
        pool.lp_supply = pool.lp_supply + lp_minted;

        event::emit(LiquidityAdded {
            handle: pool.handle,
            pool_addr,
            supra_in: supra_amount - (supra_surplus as u64),
            token_in: token_amount - (token_surplus as u64),
            lp_minted,
            new_supra_reserve: fungible_asset::balance(pool.supra_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
            new_lp_supply: pool.lp_supply,
        });

        (lp_minted, supra_refund, token_refund)
    }

    public(friend) fun remove_liquidity_internal(
        handle: vector<u8>,
        lp_amount: u128,
        min_supra_out: u64,
        min_token_out: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        assert!(lp_amount > 0, E_ZERO_AMOUNT);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        assert!(pool.lp_supply >= lp_amount, E_INSUFFICIENT_LP_BURN);

        let supra_reserve_amt = fungible_asset::balance(pool.supra_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let supra_out_u128 = ((supra_reserve_amt as u128) * lp_amount) / pool.lp_supply;
        let token_out_u128 = ((token_reserve_amt as u128) * lp_amount) / pool.lp_supply;
        let supra_out = (supra_out_u128 as u64);
        let token_out = (token_out_u128 as u64);

        assert!(supra_out >= min_supra_out, E_SLIPPAGE_EXCEEDED);
        assert!(token_out >= min_token_out, E_SLIPPAGE_EXCEEDED);
        assert!(supra_out > 0 || token_out > 0, E_INSUFFICIENT_LIQUIDITY);

        pool.lp_supply = pool.lp_supply - lp_amount;

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let supra_out_fa = fungible_asset::withdraw(&pool_signer, pool.supra_reserve, supra_out);
        let token_out_fa = fungible_asset::withdraw(&pool_signer, pool.token_reserve, token_out);

        event::emit(LiquidityRemoved {
            handle: pool.handle,
            pool_addr,
            lp_burned: lp_amount,
            supra_out,
            token_out,
            new_supra_reserve: fungible_asset::balance(pool.supra_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
            new_lp_supply: pool.lp_supply,
        });

        (supra_out_fa, token_out_fa)
    }

    public(friend) fun extract_fees_for_claim(
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);

        assert!(!pool.locked, E_LOCKED);
        assert!(fungible_asset::balance(pool.supra_fees) >= supra_amount, E_INSUFFICIENT_FEE_BUCKET);
        assert!(fungible_asset::balance(pool.token_fees) >= token_amount, E_INSUFFICIENT_FEE_BUCKET);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let supra_fa = fungible_asset::withdraw(&pool_signer, pool.supra_fees, supra_amount);
        let token_fa = fungible_asset::withdraw(&pool_signer, pool.token_fees, token_amount);

        event::emit(FeesExtractedForClaim {
            handle: pool.handle,
            pool_addr,
            supra_extracted: supra_amount,
            token_extracted: token_amount,
        });

        (supra_fa, token_fa)
    }

    public fun swap(
        pool_addr: address,
        _swapper: address,
        fa_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let handle = borrow_global<Pool>(pool_addr).handle;

        let in_meta = fungible_asset::metadata_from_asset(&fa_in);
        let in_meta_addr = object::object_address(&in_meta);
        if (in_meta_addr == governance::native_fa_metadata()) {
            swap_exact_supra_in(handle, fa_in, min_out)
        } else {
            swap_exact_token_in(handle, fa_in, min_out)
        }
    }

    public entry fun swap_supra_for_token(
        caller: &signer,
        handle: vector<u8>,
        amount_in: u64,
        min_out: u64,
    ) acquires Pool {
        let caller_addr = signer::address_of(caller);
        let supra_coin = coin::withdraw<SupraCoin>(caller, amount_in);
        let supra_fa = coin::coin_to_fungible_asset(supra_coin);
        let token_out_fa = swap_exact_supra_in_actor(handle, supra_fa, min_out, caller_addr);
        primary_fungible_store::deposit(caller_addr, token_out_fa);
    }

    public entry fun swap_token_for_supra(
        caller: &signer,
        handle: vector<u8>,
        amount_in: u64,
        min_out: u64,
    ) acquires Pool {
        let caller_addr = signer::address_of(caller);
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let token_meta_addr = borrow_global<Pool>(pool_addr).token_metadata_addr;
        let token_meta = object::address_to_object<Metadata>(token_meta_addr);

        let token_fa = primary_fungible_store::withdraw(caller, token_meta, amount_in);
        let supra_out_fa = swap_exact_token_in_actor(handle, token_fa, min_out, caller_addr);
        primary_fungible_store::deposit(caller_addr, supra_out_fa);
    }

    public fun swap_exact_supra_in(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        swap_exact_supra_in_actor(handle, supra_in, min_out, @0x0)
    }

    public fun swap_exact_supra_in_actor(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        min_out: u64,
        actor: address,
    ): FungibleAsset acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        let amount_in = fungible_asset::amount(&supra_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let supra_meta = fungible_asset::metadata_from_asset(&supra_in);
        assert!(object::object_address(&supra_meta) == governance::native_fa_metadata(), E_INVALID_FA_TYPE);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        assert!(pool.swaps_enabled, E_SWAPS_DISABLED);
        let supra_reserve_amt = fungible_asset::balance(pool.supra_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let fee_amount = (amount_in * FEE_BPS) / FEE_DENOM;

        let amount_out = compute_amount_out(supra_reserve_amt, token_reserve_amt, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);
        assert!(amount_out > 0, E_INSUFFICIENT_LIQUIDITY);

        let supra_fee_fa = fungible_asset::extract(&mut supra_in, fee_amount);
        fungible_asset::deposit(pool.supra_fees, supra_fee_fa);

        if (pool.lp_supply > 0) {
            let fee_per_lp_delta = ((fee_amount as u128) * FEE_ACC_SCALE) / pool.lp_supply;
            pool.fee_per_lp_supra = pool.fee_per_lp_supra + fee_per_lp_delta;
        };

        fungible_asset::deposit(pool.supra_reserve, supra_in);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let token_out_fa = fungible_asset::withdraw(&pool_signer, pool.token_reserve, amount_out);

        event::emit(Swapped {
            handle: pool.handle,
            pool_addr,
            actor,
            supra_to_token: true,
            amount_in,
            amount_out,
            fee_amount,
            new_supra_reserve: fungible_asset::balance(pool.supra_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
        });

        token_out_fa
    }

    public fun swap_exact_token_in(
        handle: vector<u8>,
        token_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        swap_exact_token_in_actor(handle, token_in, min_out, @0x0)
    }

    public fun swap_exact_token_in_actor(
        handle: vector<u8>,
        token_in: FungibleAsset,
        min_out: u64,
        actor: address,
    ): FungibleAsset acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        let amount_in = fungible_asset::amount(&token_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        assert!(pool.swaps_enabled, E_SWAPS_DISABLED);
        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        assert!(object::object_address(&token_meta) == pool.token_metadata_addr, E_INVALID_FA_TYPE);

        let supra_reserve_amt = fungible_asset::balance(pool.supra_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let fee_amount = (amount_in * FEE_BPS) / FEE_DENOM;

        let amount_out = compute_amount_out(token_reserve_amt, supra_reserve_amt, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);
        assert!(amount_out > 0, E_INSUFFICIENT_LIQUIDITY);

        let token_fee_fa = fungible_asset::extract(&mut token_in, fee_amount);
        fungible_asset::deposit(pool.token_fees, token_fee_fa);

        if (pool.lp_supply > 0) {
            let fee_per_lp_delta = ((fee_amount as u128) * FEE_ACC_SCALE) / pool.lp_supply;
            pool.fee_per_lp_token = pool.fee_per_lp_token + fee_per_lp_delta;
        };

        fungible_asset::deposit(pool.token_reserve, token_in);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let supra_out_fa = fungible_asset::withdraw(&pool_signer, pool.supra_reserve, amount_out);

        event::emit(Swapped {
            handle: pool.handle,
            pool_addr,
            actor,
            supra_to_token: false,
            amount_in,
            amount_out,
            fee_amount,
            new_supra_reserve: fungible_asset::balance(pool.supra_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
        });

        supra_out_fa
    }

    public fun flash_borrow(
        pool_addr: address,
        metadata: Object<Metadata>,
        amount: u64,
    ): (FungibleAsset, FlashReceipt) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        pool.locked = true;

        let metadata_addr = object::object_address(&metadata);
        let store = if (metadata_addr == governance::native_fa_metadata()) {
            pool.supra_reserve
        } else {
            assert!(metadata_addr == pool.token_metadata_addr, E_WRONG_TOKEN);
            pool.token_reserve
        };

        let available = fungible_asset::balance(store);
        assert!(available >= amount, E_INSUFFICIENT_LIQUIDITY);

        let fee = (amount * FLASH_FEE_BPS) / FEE_DENOM;
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa_out = fungible_asset::withdraw(&pool_signer, store, amount);

        let receipt = FlashReceipt {
            pool_addr,
            metadata_addr,
            amount,
            fee,
        };

        event::emit(FlashBorrowed {
            pool_addr,
            metadata_addr,
            amount,
            fee,
        });

        (fa_out, receipt)
    }

    public fun flash_repay(
        pool_addr: address,
        fa_in: FungibleAsset,
        receipt: FlashReceipt,
    ) acquires Pool {
        let FlashReceipt { pool_addr: r_pool, metadata_addr, amount, fee } = receipt;
        assert!(pool_addr == r_pool, E_WRONG_POOL);

        let in_amount = fungible_asset::amount(&fa_in);
        assert!(in_amount == amount + fee, E_K_VIOLATED);

        let in_meta = fungible_asset::metadata_from_asset(&fa_in);
        assert!(object::object_address(&in_meta) == metadata_addr, E_WRONG_TOKEN);

        let pool = borrow_global_mut<Pool>(pool_addr);

        let (reserve_store, fee_store, is_supra) = if (metadata_addr == governance::native_fa_metadata()) {
            (pool.supra_reserve, pool.supra_fees, true)
        } else {
            (pool.token_reserve, pool.token_fees, false)
        };

        let fee_fa = fungible_asset::extract(&mut fa_in, fee);
        fungible_asset::deposit(fee_store, fee_fa);
        fungible_asset::deposit(reserve_store, fa_in);

        if (pool.lp_supply > 0) {
            let fee_per_lp_delta = ((fee as u128) * FEE_ACC_SCALE) / pool.lp_supply;
            if (is_supra) {
                pool.fee_per_lp_supra = pool.fee_per_lp_supra + fee_per_lp_delta;
            } else {
                pool.fee_per_lp_token = pool.fee_per_lp_token + fee_per_lp_delta;
            };
        };

        pool.locked = false;

        event::emit(FlashRepaid {
            pool_addr,
            metadata_addr,
            repaid: in_amount,
        });
    }

    #[view]
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
    ): u64 {
        let amount_in_after_fee = (amount_in as u128) * ((FEE_DENOM - FEE_BPS) as u128);
        let numerator = amount_in_after_fee * (reserve_out as u128);
        let denominator = (reserve_in as u128) * (FEE_DENOM as u128) + amount_in_after_fee;
        ((numerator / denominator) as u64)
    }

    public fun compute_flash_fee(amount: u64): u64 {
        (amount * FLASH_FEE_BPS) / FEE_DENOM
    }

    fun mint_lp_initial(supra: u64, token: u64): u128 {
        let product = (supra as u128) * (token as u128);
        math128::sqrt(product)
    }

    #[view]
    public fun reserves(handle: vector<u8>): (u64, u64) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.supra_reserve),
            fungible_asset::balance(pool.token_reserve),
        )
    }

    #[view]
    public fun fee_buckets(handle: vector<u8>): (u64, u64) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.supra_fees),
            fungible_asset::balance(pool.token_fees),
        )
    }

    #[view]
    public fun lp_supply(handle: vector<u8>): u128 acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).lp_supply
    }

    #[view]
    public fun fee_per_lp(handle: vector<u8>): (u128, u128) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (pool.fee_per_lp_supra, pool.fee_per_lp_token)
    }

    #[view]
    public fun token_metadata_addr(handle: vector<u8>): address acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).token_metadata_addr
    }

    #[view]
    public fun creator_pid(handle: vector<u8>): address acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).creator_pid
    }

    #[view]
    public fun quote_swap_exact_in(
        handle: vector<u8>,
        amount_in: u64,
        supra_to_token: bool,
    ): u64 acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let supra_r = fungible_asset::balance(pool.supra_reserve);
        let token_r = fungible_asset::balance(pool.token_reserve);
        if (supra_to_token) {
            compute_amount_out(supra_r, token_r, amount_in)
        } else {
            compute_amount_out(token_r, supra_r, amount_in)
        }
    }

    #[view]
    public fun reserves_at(pool_addr: address): (u64, u64) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.supra_reserve),
            fungible_asset::balance(pool.token_reserve),
        )
    }

    #[view]
    public fun lp_supply_at(pool_addr: address): u128 acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).lp_supply
    }

    #[view]
    public fun lp_fee_per_share(pool_addr: address): (u128, u128) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (pool.fee_per_lp_supra, pool.fee_per_lp_token)
    }

    #[view]
    public fun pool_tokens(pool_addr: address): (Object<Metadata>, Object<Metadata>) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        (supra_meta, token_meta)
    }

    #[view]
    public fun pool_locked(pool_addr: address): bool acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).locked
    }

    #[view]
    public fun lp_fee_per_share_by_handle(handle: vector<u8>): (u128, u128) acquires Pool {
        lp_fee_per_share(pool_address_of_handle(handle))
    }

    #[view]
    public fun pool_locked_by_handle(handle: vector<u8>): bool acquires Pool {
        pool_locked(pool_address_of_handle(handle))
    }

    #[view]
    public fun creator_pid_at(pool_addr: address): address acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).creator_pid
    }

    #[view]
    public fun fee_buckets_at(pool_addr: address): (u64, u64) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (fungible_asset::balance(pool.supra_fees), fungible_asset::balance(pool.token_fees))
    }

    #[view]
    public fun quote_swap_exact_in_at(
        pool_addr: address,
        amount_in: u64,
        is_supra_in: bool,
    ): u64 acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let supra_r = fungible_asset::balance(pool.supra_reserve);
        let token_r = fungible_asset::balance(pool.token_reserve);
        if (is_supra_in) {
            compute_amount_out(supra_r, token_r, amount_in)
        } else {
            compute_amount_out(token_r, supra_r, amount_in)
        }
    }

    #[view]
    public fun fee_acc_scale(): u128 { FEE_ACC_SCALE }

    #[view]
    public fun fee_bps(_handle: vector<u8>): u64 { FEE_BPS }

    #[view]
    public fun flash_fee_bps(): u64 { FLASH_FEE_BPS }

    #[view]
    public fun read_warning(): vector<u8> { WARNING }

    public(friend) fun enable_swaps(handle: vector<u8>) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<Pool>(pool_addr);
        pool.swaps_enabled = true;
    }

    #[test_only]
    public fun calc_swap_out_for_test(amount_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        compute_amount_out(reserve_in, reserve_out, amount_in)
    }

    #[test_only]
    public fun mint_lp_initial_for_test(supra: u64, token: u64): u128 {
        mint_lp_initial(supra, token)
    }

    #[test_only]
    public fun create_pool_atomic_for_test(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        token_in: FungibleAsset,
        creator_pid: address,
        swaps_enabled: bool,
    ): u128 {
        create_pool_atomic(handle, supra_in, token_in, creator_pid, swaps_enabled)
    }

    #[test_only]
    public fun add_liquidity_internal_for_test(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        token_in: FungibleAsset,
        min_lp_out: u64,
    ): u128 acquires Pool {
        let (lp, supra_refund, token_refund) =
            add_liquidity_internal(handle, supra_in, token_in, min_lp_out);
        if (fungible_asset::amount(&supra_refund) > 0) {
            primary_fungible_store::deposit(@desnet, supra_refund);
        } else { fungible_asset::destroy_zero(supra_refund) };
        if (fungible_asset::amount(&token_refund) > 0) {
            primary_fungible_store::deposit(@desnet, token_refund);
        } else { fungible_asset::destroy_zero(token_refund) };
        lp
    }

    #[test_only]
    public fun remove_liquidity_internal_for_test(
        handle: vector<u8>,
        lp_amount: u128,
        min_supra_out: u64,
        min_token_out: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        remove_liquidity_internal(handle, lp_amount, min_supra_out, min_token_out)
    }

    #[test]
    fun test_pool_address_deterministic() {
        let h = b"alice";
        assert!(pool_address_of_handle(h) == pool_address_of_handle(h), 1);
    }

    #[test]
    fun test_pool_addr_unique_per_handle() {
        assert!(pool_address_of_handle(b"alice") != pool_address_of_handle(b"bob"), 1);
    }

    #[test]
    fun test_compute_amount_out_known_values() {
        assert!(compute_amount_out(1000, 2000, 100) == 180, 1);
    }

    #[test]
    fun test_compute_amount_out_with_fee() {
        assert!(compute_amount_out(100_000, 200_000, 10_000) == 18016, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        assert!(compute_amount_out(1000, 2000, 0) == 0, 1);
    }

    #[test]
    fun test_compute_flash_fee() {
        assert!(compute_flash_fee(10000) == 100, 1);
        assert!(compute_flash_fee(100_000_000) == 1_000_000, 2);
    }

    #[test]
    fun test_mint_lp_initial_perfect_square() {
        assert!(mint_lp_initial(4, 9) == 6, 1);
    }

    #[test]
    fun test_mint_lp_initial_real_scale() {
        assert!(mint_lp_initial(500_000_000, 5_000_000_000_000_000) == 1_581_138_830_084, 1);
    }

    #[test]
    fun test_fee_bps_constant() {
        assert!(fee_bps(b"x") == FEE_BPS, 1);
    }

    #[test]
    fun test_flash_fee_bps_constant() {
        assert!(flash_fee_bps() == FLASH_FEE_BPS, 1);
    }

    #[test]
    fun test_fee_acc_scale_constant() {
        assert!(fee_acc_scale() == 1_000_000_000_000_000_000, 1);
    }

    #[test]
    fun test_pool_seed_includes_handle() {
        assert!(pool_seed(&b"alice") != pool_seed(&b"bob"), 1);
    }

    #[test]
    fun test_swap_round_trip_loses_fee() {
        let r0 = 1_000_000_000u64;
        let r1 = 1_000_000_000_000u64;
        let amount_in = 100_000_000u64;
        let token_out = compute_amount_out(r0, r1, amount_in);
        let r0_after = r0 + amount_in;
        let r1_after = r1 - token_out;
        let supra_back = compute_amount_out(r1_after, r0_after, token_out);
        assert!(supra_back < amount_in, 1);
        let loss_bps = ((amount_in - supra_back) * 10000) / amount_in;
        assert!(loss_bps >= 180 && loss_bps <= 220, 2);
    }
}
