/// AMM — purpose-built APT/$TOKEN constant-product pool (LOCKED 2026-05-02).
///
/// Composability shape MATCHES darbitex AMM exactly (minus arbitrage module).
/// External aggregators / arb bots can route through both venues uniformly via:
/// - `compute_amount_out(reserve_in, reserve_out, amount_in)` — pure quote
/// - `swap(pool_addr, swapper, fa_in, min_out): FA` — generic by addr
/// - `flash_borrow(pool_addr, metadata, amount): (FA, FlashReceipt)` — Aave-standard
/// - `flash_repay(pool_addr, fa_in, receipt)` — strict repay equality
/// - Addr-based views: `reserves(pool_addr)`, `lp_supply(pool_addr)`,
///   `lp_fee_per_share(pool_addr)`, `pool_tokens(pool_addr)`
///
/// Single non-composable surface = `create_pool_atomic` (friend-only, factory at register).
/// All other entries (add/remove/swap/flash/claim) are PUBLIC.
///
/// LP repr: Position NFT (Object<Position>), managed by `desnet::lp_staking`.
/// Universal fee accumulator (denominator = lp_supply, all positions earn).
module desnet::amm {
    use std::signer;
    use std::vector;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_std::math128;

    use desnet::governance;

    friend desnet::factory;
    friend desnet::lp_staking;
    friend desnet::apt_vault;

    // ============ CONSTANTS ============

    const FEE_BPS: u64 = 10;
    const FLASH_FEE_BPS: u64 = 10;                    // = LP swap fee (uniform 10 bps, all 100% to LP)
    const FEE_DENOM: u64 = 10000;
    const MIN_INITIAL_LP: u128 = 1000;
    const APT_FA_ADDR: address = @0xa;
    const FEE_ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    const SEED_POOL: vector<u8> = b"desnet::amm::pool::";

    /// On-chain user-facing risk disclosure (concise; off-chain docs hold full text).
    const WARNING: vector<u8> = b"DESNET AMM x*y=k. Multi-LLM audited (R1-R5, mainnet live). Use at own risk.";

    // ============ ERROR CODES ============

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

    // ============ TYPES ============

    /// Per-handle Pool. LP is in `desnet::lp_staking::Position` NFTs (not FA).
    struct Pool has key {
        handle: vector<u8>,
        apt_reserve: Object<FungibleStore>,
        token_reserve: Object<FungibleStore>,
        apt_fees: Object<FungibleStore>,
        token_fees: Object<FungibleStore>,
        token_metadata_addr: address,
        lp_supply: u128,
        fee_per_lp_apt: u128,
        fee_per_lp_token: u128,
        creator_pid: address,
        locked: bool,                                 // flash loan reentrancy guard
        extend_ref: ExtendRef,
    }

    /// Flash loan hot-potato. No drop/store/key — must be consumed via flash_repay same tx.
    struct FlashReceipt {
        pool_addr: address,
        metadata_addr: address,
        amount: u64,
        fee: u64,
    }

    // ============ EVENTS ============

    #[event]
    struct PoolCreated has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        token_metadata_addr: address,
        apt_in: u64,
        token_in: u64,
        lp_minted: u128,
        creator_pid: address,
    }

    #[event]
    struct LiquidityAdded has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        apt_in: u64,
        token_in: u64,
        lp_minted: u128,
        new_apt_reserve: u64,
        new_token_reserve: u64,
        new_lp_supply: u128,
    }

    #[event]
    struct LiquidityRemoved has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        lp_burned: u128,
        apt_out: u64,
        token_out: u64,
        new_apt_reserve: u64,
        new_token_reserve: u64,
        new_lp_supply: u128,
    }

    #[event]
    struct Swapped has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        actor: address,
        apt_to_token: bool,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64,
        new_apt_reserve: u64,
        new_token_reserve: u64,
    }

    #[event]
    struct FeesExtractedForClaim has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        apt_extracted: u64,
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

    // ============ ADDR DERIVATION ============

    public fun pool_address_of_handle(handle: vector<u8>): address {
        let seed = pool_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    public fun pool_exists(handle: vector<u8>): bool {
        exists<Pool>(pool_address_of_handle(handle))
    }

    /// Darbitex-shape: check by addr instead of handle.
    public fun pool_exists_at(pool_addr: address): bool {
        exists<Pool>(pool_addr)
    }

    fun pool_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_POOL;
        vector::append(&mut s, *handle);
        s
    }

    // ============ CREATE (FRIEND, called by factory at register_handle) ============

    public(friend) fun create_pool_atomic(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        token_in: FungibleAsset,
        creator_pid: address,
    ): u128 {
        assert!(!vector::is_empty(&handle), E_INVALID_HANDLE);
        let pool_addr = pool_address_of_handle(handle);
        assert!(!exists<Pool>(pool_addr), E_POOL_ALREADY_EXISTS);

        let apt_amount = fungible_asset::amount(&apt_in);
        let token_amount = fungible_asset::amount(&token_in);
        assert!(apt_amount > 0 && token_amount > 0, E_ZERO_AMOUNT);

        let apt_meta = fungible_asset::metadata_from_asset(&apt_in);
        assert!(object::object_address(&apt_meta) == APT_FA_ADDR, E_INVALID_FA_TYPE);

        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        let token_meta_addr = object::object_address(&token_meta);

        let pkg_signer = governance::derive_pkg_signer();
        let pool_constructor = object::create_named_object(&pkg_signer, pool_seed(&handle));
        let pool_signer = object::generate_signer(&pool_constructor);
        let pool_extend_ref = object::generate_extend_ref(&pool_constructor);
        let pool_transfer_ref = object::generate_transfer_ref(&pool_constructor);
        object::disable_ungated_transfer(&pool_transfer_ref);

        let apt_reserve = create_store_at_pool(pool_addr, apt_meta);
        let token_reserve = create_store_at_pool(pool_addr, token_meta);
        let apt_fees = create_store_at_pool(pool_addr, apt_meta);
        let token_fees = create_store_at_pool(pool_addr, token_meta);

        let initial_lp = mint_lp_initial(apt_amount, token_amount);
        assert!(initial_lp >= MIN_INITIAL_LP, E_INITIAL_LP_BELOW_MIN);

        fungible_asset::deposit(apt_reserve, apt_in);
        fungible_asset::deposit(token_reserve, token_in);

        move_to(&pool_signer, Pool {
            handle: handle,
            apt_reserve,
            token_reserve,
            apt_fees,
            token_fees,
            token_metadata_addr: token_meta_addr,
            lp_supply: initial_lp,
            fee_per_lp_apt: 0,
            fee_per_lp_token: 0,
            creator_pid,
            locked: false,
            extend_ref: pool_extend_ref,
        });

        event::emit(PoolCreated {
            handle,
            pool_addr,
            token_metadata_addr: token_meta_addr,
            apt_in: apt_amount,
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

    // ============ ADD LIQUIDITY (FRIEND, called by lp_staking) ============

    /// M1 fix (audit R1): returns (lp_minted, apt_refund_fa, token_refund_fa).
    /// Caller (lp_staking) deposits refund FAs back to user. Uniswap V2 pattern —
    /// prevents naive callers from gifting surplus to existing LPs on ratio mismatch.
    public(friend) fun add_liquidity_internal(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        token_in: FungibleAsset,
        min_lp_out: u64,
    ): (u128, FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        let apt_amount = fungible_asset::amount(&apt_in);
        let token_amount = fungible_asset::amount(&token_in);
        assert!(apt_amount > 0 && token_amount > 0, E_ZERO_AMOUNT);

        let apt_meta = fungible_asset::metadata_from_asset(&apt_in);
        assert!(object::object_address(&apt_meta) == APT_FA_ADDR, E_INVALID_FA_TYPE);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        assert!(object::object_address(&token_meta) == pool.token_metadata_addr, E_INVALID_FA_TYPE);

        let apt_reserve_amt = fungible_asset::balance(pool.apt_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);
        assert!(apt_reserve_amt > 0 && token_reserve_amt > 0, E_INSUFFICIENT_LIQUIDITY);

        let lp_from_apt = ((apt_amount as u128) * pool.lp_supply) / (apt_reserve_amt as u128);
        let lp_from_token = ((token_amount as u128) * pool.lp_supply) / (token_reserve_amt as u128);
        let lp_minted = if (lp_from_apt < lp_from_token) lp_from_apt else lp_from_token;
        assert!(lp_minted > 0, E_INSUFFICIENT_LIQUIDITY);
        assert!(lp_minted >= (min_lp_out as u128), E_SLIPPAGE_EXCEEDED);

        // M1: compute optimal pair from lp_minted; refund surplus from over-funded side.
        let optimal_apt = (lp_minted * (apt_reserve_amt as u128)) / pool.lp_supply;
        let optimal_token = (lp_minted * (token_reserve_amt as u128)) / pool.lp_supply;
        let apt_surplus = (apt_amount as u128) - optimal_apt;
        let token_surplus = (token_amount as u128) - optimal_token;

        let apt_refund = if (apt_surplus > 0) {
            fungible_asset::extract(&mut apt_in, (apt_surplus as u64))
        } else {
            fungible_asset::zero(apt_meta)
        };
        let token_refund = if (token_surplus > 0) {
            fungible_asset::extract(&mut token_in, (token_surplus as u64))
        } else {
            fungible_asset::zero(token_meta)
        };

        fungible_asset::deposit(pool.apt_reserve, apt_in);
        fungible_asset::deposit(pool.token_reserve, token_in);
        pool.lp_supply = pool.lp_supply + lp_minted;

        event::emit(LiquidityAdded {
            handle: pool.handle,
            pool_addr,
            apt_in: apt_amount - (apt_surplus as u64),
            token_in: token_amount - (token_surplus as u64),
            lp_minted,
            new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
            new_lp_supply: pool.lp_supply,
        });

        (lp_minted, apt_refund, token_refund)
    }

    // ============ REMOVE LIQUIDITY (FRIEND) ============

    public(friend) fun remove_liquidity_internal(
        handle: vector<u8>,
        lp_amount: u128,
        min_apt_out: u64,
        min_token_out: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        assert!(lp_amount > 0, E_ZERO_AMOUNT);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        assert!(pool.lp_supply >= lp_amount, E_INSUFFICIENT_LP_BURN);

        let apt_reserve_amt = fungible_asset::balance(pool.apt_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let apt_out_u128 = ((apt_reserve_amt as u128) * lp_amount) / pool.lp_supply;
        let token_out_u128 = ((token_reserve_amt as u128) * lp_amount) / pool.lp_supply;
        let apt_out = (apt_out_u128 as u64);
        let token_out = (token_out_u128 as u64);

        assert!(apt_out >= min_apt_out, E_SLIPPAGE_EXCEEDED);
        assert!(token_out >= min_token_out, E_SLIPPAGE_EXCEEDED);
        assert!(apt_out > 0 && token_out > 0, E_INSUFFICIENT_LIQUIDITY);

        pool.lp_supply = pool.lp_supply - lp_amount;

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let apt_out_fa = fungible_asset::withdraw(&pool_signer, pool.apt_reserve, apt_out);
        let token_out_fa = fungible_asset::withdraw(&pool_signer, pool.token_reserve, token_out);

        event::emit(LiquidityRemoved {
            handle: pool.handle,
            pool_addr,
            lp_burned: lp_amount,
            apt_out,
            token_out,
            new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
            new_lp_supply: pool.lp_supply,
        });

        (apt_out_fa, token_out_fa)
    }

    // ============ FEE EXTRACTION (FRIEND, called by lp_staking on claim) ============

    public(friend) fun extract_fees_for_claim(
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);

        // M1 (self-audit): defense-in-depth — gate fee extraction during flash window.
        assert!(!pool.locked, E_LOCKED);
        assert!(fungible_asset::balance(pool.apt_fees) >= apt_amount, E_INSUFFICIENT_FEE_BUCKET);
        assert!(fungible_asset::balance(pool.token_fees) >= token_amount, E_INSUFFICIENT_FEE_BUCKET);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let apt_fa = fungible_asset::withdraw(&pool_signer, pool.apt_fees, apt_amount);
        let token_fa = fungible_asset::withdraw(&pool_signer, pool.token_fees, token_amount);

        event::emit(FeesExtractedForClaim {
            handle: pool.handle,
            pool_addr,
            apt_extracted: apt_amount,
            token_extracted: token_amount,
        });

        (apt_fa, token_fa)
    }

    // ============ SWAP (PUBLIC) ============

    /// Generic swap by pool_addr — darbitex-shape composable entry for aggregators.
    /// Detects direction from fa_in metadata: APT_FA → APT-in, else → TOKEN-in.
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
        if (in_meta_addr == APT_FA_ADDR) {
            swap_exact_apt_in(handle, fa_in, min_out)
        } else {
            swap_exact_token_in(handle, fa_in, min_out)
        }
    }

    public entry fun swap_apt_for_token(
        caller: &signer,
        handle: vector<u8>,
        amount_in: u64,
        min_out: u64,
    ) acquires Pool {
        let caller_addr = signer::address_of(caller);
        let apt_coin = coin::withdraw<AptosCoin>(caller, amount_in);
        let apt_fa = coin::coin_to_fungible_asset(apt_coin);
        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
        let token_out_fa = swap_exact_apt_in_actor(handle, apt_fa, min_out, caller_addr);
        primary_fungible_store::deposit(caller_addr, token_out_fa);
    }

    public entry fun swap_token_for_apt(
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
        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
        let apt_out_fa = swap_exact_token_in_actor(handle, token_fa, min_out, caller_addr);
        primary_fungible_store::deposit(caller_addr, apt_out_fa);
    }

    /// v0.3.2 (F5): backward-compat wrapper. Composable callers (aggregators/flash arbs)
    /// that don't have the actor address available can still call this — event.actor stays
    /// @0x0 sentinel. New code should prefer `swap_exact_apt_in_actor` to preserve attribution.
    public fun swap_exact_apt_in(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        swap_exact_apt_in_actor(handle, apt_in, min_out, @0x0)
    }

    /// v0.3.2 (F5): actor-aware variant. `actor` is recorded in `Swapped` event for indexer
    /// attribution. Pass `@0x0` for sentinel "actor unknown / multi-hop call".
    public fun swap_exact_apt_in_actor(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        min_out: u64,
        actor: address,
    ): FungibleAsset acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);

        let amount_in = fungible_asset::amount(&apt_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let apt_meta = fungible_asset::metadata_from_asset(&apt_in);
        assert!(object::object_address(&apt_meta) == APT_FA_ADDR, E_INVALID_FA_TYPE);

        let pool = borrow_global_mut<Pool>(pool_addr);
        assert!(!pool.locked, E_LOCKED);
        let apt_reserve_amt = fungible_asset::balance(pool.apt_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let fee_amount = (amount_in * FEE_BPS) / FEE_DENOM;

        let amount_out = compute_amount_out(apt_reserve_amt, token_reserve_amt, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);
        assert!(amount_out > 0, E_INSUFFICIENT_LIQUIDITY);

        let apt_fee_fa = fungible_asset::extract(&mut apt_in, fee_amount);
        fungible_asset::deposit(pool.apt_fees, apt_fee_fa);

        if (pool.lp_supply > 0) {
            let fee_per_lp_delta = ((fee_amount as u128) * FEE_ACC_SCALE) / pool.lp_supply;
            pool.fee_per_lp_apt = pool.fee_per_lp_apt + fee_per_lp_delta;
        };

        fungible_asset::deposit(pool.apt_reserve, apt_in);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let token_out_fa = fungible_asset::withdraw(&pool_signer, pool.token_reserve, amount_out);

        event::emit(Swapped {
            handle: pool.handle,
            pool_addr,
            actor,
            apt_to_token: true,
            amount_in,
            amount_out,
            fee_amount,
            new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
        });

        token_out_fa
    }

    /// v0.3.2 (F5): backward-compat wrapper for token-in direction.
    public fun swap_exact_token_in(
        handle: vector<u8>,
        token_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        swap_exact_token_in_actor(handle, token_in, min_out, @0x0)
    }

    /// v0.3.2 (F5): actor-aware variant for token-in direction.
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
        let token_meta = fungible_asset::metadata_from_asset(&token_in);
        assert!(object::object_address(&token_meta) == pool.token_metadata_addr, E_INVALID_FA_TYPE);

        let apt_reserve_amt = fungible_asset::balance(pool.apt_reserve);
        let token_reserve_amt = fungible_asset::balance(pool.token_reserve);

        let fee_amount = (amount_in * FEE_BPS) / FEE_DENOM;

        let amount_out = compute_amount_out(token_reserve_amt, apt_reserve_amt, amount_in);
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
        let apt_out_fa = fungible_asset::withdraw(&pool_signer, pool.apt_reserve, amount_out);

        event::emit(Swapped {
            handle: pool.handle,
            pool_addr,
            actor,
            apt_to_token: false,
            amount_in,
            amount_out,
            fee_amount,
            new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
        });

        apt_out_fa
    }

    // ============ FLASH LOAN (PUBLIC, Aave-standard) ============

    /// Flash borrow `amount` of `metadata` from pool. Returns FA + hot-potato receipt.
    /// Pool LOCKED during borrow span — swap/LP/flash all abort until repay.
    /// Flash fee: 9 bps of borrowed amount (matches darbitex).
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
        let store = if (metadata_addr == APT_FA_ADDR) {
            pool.apt_reserve
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

    /// Repay flash loan. STRICT equality: fa_in.amount == receipt.amount + receipt.fee.
    /// Borrow → Reserve; fee → Fee bucket (accumulates to LPs via fee_per_lp).
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

        let (reserve_store, fee_store, is_apt) = if (metadata_addr == APT_FA_ADDR) {
            (pool.apt_reserve, pool.apt_fees, true)
        } else {
            (pool.token_reserve, pool.token_fees, false)
        };

        // Split: fee → fee bucket, principal → reserve
        let fee_fa = fungible_asset::extract(&mut fa_in, fee);
        fungible_asset::deposit(fee_store, fee_fa);
        fungible_asset::deposit(reserve_store, fa_in);

        // Update fee accumulator
        if (pool.lp_supply > 0) {
            let fee_per_lp_delta = ((fee as u128) * FEE_ACC_SCALE) / pool.lp_supply;
            if (is_apt) {
                pool.fee_per_lp_apt = pool.fee_per_lp_apt + fee_per_lp_delta;
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

    // ============ INTERNAL MATH ============

    /// Pure quote — darbitex-shape signature. CPMM with 10 bps fee.
    /// v0.3.2 (F4b): added #[view] so frontend can call gas-free via /v1/view.
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

    fun mint_lp_initial(apt: u64, token: u64): u128 {
        let product = (apt as u128) * (token as u128);
        math128::sqrt(product)
    }

    // ============ VIEWS — handle-based (internal) ============

    #[view]
    public fun reserves(handle: vector<u8>): (u64, u64) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.apt_reserve),
            fungible_asset::balance(pool.token_reserve),
        )
    }

    #[view]
    public fun fee_buckets(handle: vector<u8>): (u64, u64) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.apt_fees),
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
        (pool.fee_per_lp_apt, pool.fee_per_lp_token)
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
        apt_to_token: bool,
    ): u64 acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let apt_r = fungible_asset::balance(pool.apt_reserve);
        let token_r = fungible_asset::balance(pool.token_reserve);
        if (apt_to_token) {
            compute_amount_out(apt_r, token_r, amount_in)
        } else {
            compute_amount_out(token_r, apt_r, amount_in)
        }
    }

    // ============ VIEWS — addr-based (darbitex-shape composability) ============

    #[view]
    public fun reserves_at(pool_addr: address): (u64, u64) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        (
            fungible_asset::balance(pool.apt_reserve),
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
        (pool.fee_per_lp_apt, pool.fee_per_lp_token)
    }

    #[view]
    public fun pool_tokens(pool_addr: address): (Object<Metadata>, Object<Metadata>) acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        (apt_meta, token_meta)
    }

    #[view]
    public fun pool_locked(pool_addr: address): bool acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<Pool>(pool_addr).locked
    }

    // ============ v0.3.2 (F4c): handle/pool_addr companion view fns ============
    // Some views take handle, others take pool_addr — caller convenience companions
    // for the missing direction. Body delegates to existing variant.

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
        (fungible_asset::balance(pool.apt_fees), fungible_asset::balance(pool.token_fees))
    }

    #[view]
    public fun quote_swap_exact_in_at(
        pool_addr: address,
        amount_in: u64,
        is_apt_in: bool,
    ): u64 acquires Pool {
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);
        let apt_r = fungible_asset::balance(pool.apt_reserve);
        let token_r = fungible_asset::balance(pool.token_reserve);
        if (is_apt_in) {
            compute_amount_out(apt_r, token_r, amount_in)
        } else {
            compute_amount_out(token_r, apt_r, amount_in)
        }
    }

    #[view]
    public fun fee_acc_scale(): u128 { FEE_ACC_SCALE }

    #[view]
    public fun fee_bps(_handle: vector<u8>): u64 { FEE_BPS }

    #[view]
    public fun flash_fee_bps(): u64 { FLASH_FEE_BPS }

    /// On-chain user-facing risk disclosure (matches darbitex AMM pattern).
    #[view]
    public fun read_warning(): vector<u8> { WARNING }

    // ============ TEST-ONLY HELPERS ============

    #[test_only]
    public fun calc_swap_out_for_test(amount_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        compute_amount_out(reserve_in, reserve_out, amount_in)
    }

    #[test_only]
    public fun mint_lp_initial_for_test(apt: u64, token: u64): u128 {
        mint_lp_initial(apt, token)
    }

    #[test_only]
    public fun create_pool_atomic_for_test(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        token_in: FungibleAsset,
        creator_pid: address,
    ): u128 {
        create_pool_atomic(handle, apt_in, token_in, creator_pid)
    }

    #[test_only]
    public fun add_liquidity_internal_for_test(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        token_in: FungibleAsset,
        min_lp_out: u64,
    ): u128 acquires Pool {
        let (lp, apt_refund, token_refund) =
            add_liquidity_internal(handle, apt_in, token_in, min_lp_out);
        // Tests may pass non-exact-ratio inputs, so refunds can be non-zero.
        // Sink them at @desnet (test-only path; production caller receives the refund).
        if (fungible_asset::amount(&apt_refund) > 0) {
            primary_fungible_store::deposit(@desnet, apt_refund);
        } else { fungible_asset::destroy_zero(apt_refund) };
        if (fungible_asset::amount(&token_refund) > 0) {
            primary_fungible_store::deposit(@desnet, token_refund);
        } else { fungible_asset::destroy_zero(token_refund) };
        lp
    }

    #[test_only]
    public fun remove_liquidity_internal_for_test(
        handle: vector<u8>,
        lp_amount: u128,
        min_apt_out: u64,
        min_token_out: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        remove_liquidity_internal(handle, lp_amount, min_apt_out, min_token_out)
    }

    // ============ UNIT TESTS ============

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
        // 100 in, 1000 reserve_in, 2000 reserve_out
        // amount_after_fee = 100 × 9990 = 999000
        // num = 999000 × 2000 = 1_998_000_000
        // den = 1000 × 10000 + 999000 = 10_999_000
        // out = 1_998_000_000 / 10_999_000 = 181
        assert!(compute_amount_out(1000, 2000, 100) == 181, 1);
    }

    #[test]
    fun test_compute_amount_out_with_fee() {
        // 10000 in, 100k/200k reserves
        // amount_after_fee = 10000 × 9990 = 99_900_000
        // num = 99_900_000 × 200_000 = 19_980_000_000_000
        // den = 100_000 × 10_000 + 99_900_000 = 1_099_900_000
        // out = 19_980_000_000_000 / 1_099_900_000 = 18165
        assert!(compute_amount_out(100_000, 200_000, 10_000) == 18165, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        assert!(compute_amount_out(1000, 2000, 0) == 0, 1);
    }

    #[test]
    fun test_compute_flash_fee() {
        // 10 bps of 10000 = 10
        assert!(compute_flash_fee(10000) == 10, 1);
        // 10 bps of 100M = 100000
        assert!(compute_flash_fee(100_000_000) == 100_000, 2);
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
        assert!(fee_bps(b"x") == 10, 1);
    }

    #[test]
    fun test_flash_fee_bps_constant() {
        assert!(flash_fee_bps() == 10, 1);
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
        let apt_back = compute_amount_out(r1_after, r0_after, token_out);
        assert!(apt_back < amount_in, 1);
        let loss_bps = ((amount_in - apt_back) * 10000) / amount_in;
        assert!(loss_bps >= 18 && loss_bps <= 30, 2);
    }
}
