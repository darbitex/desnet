# DeSNet v0.3.3 — Source Bundle (PART 2 financial)

**PRE-DEPLOY (LOCAL SOURCE) — not yet on chain. R6 audit submission.**

This is **2 of 3** parts. Each part covers a domain-grouped subset of modules.

## Package metadata

```json
{
  "tag": "v0.3.3-pre-deploy-r2",
  "commit": "93a05a2b418259cf6858169e9ebf45a082c5645c",
  "parent_deployed": "v0.3.2-mainnet-live (commit 31765c2, mainnet upgrade_number 4)",
  "total_lines": 8869,
  "total_bytes": 351447,
  "source_concat_sha3_256": "77f1831c265acbfac8712aeebe56aecd4548b82694a0866c5e29555e6cd7beb0"
}
```

## Modules in this part

| module | lines | bytes | sha3_256 |
|---|---:|---:|---|
| `amm` | 1025 | 37,825 | `b5f0a2136e2e0646dfb22e68d88b9cd3bd15848df2d5f2a7144eb47ea34a08c0` |
| `apt_vault` | 346 | 12,700 | `2a4a92a63d297c0bf8b5a3e6885d157a21f0c1dcd059f53e8903e047b5fd6c06` |
| `lp_staking` | 699 | 27,518 | `5082a91a2a783944264c8f06f4a184249ee570d14af74af5435b55683759c46d` |
| `lp_emission` | 192 | 6,300 | `d113c874e46571cd129b2f112b98b4e84999c96107d923619cbf1c6d8b908c79` |
| `reaction_emission` | 244 | 8,765 | `b3d7074176a1ca96844973c713ae71a8e1a643987f1ba49419dc97e124420530` |
| `handle_fee_vault` | 275 | 12,639 | `aaed18c378f3433bdf32ecd8b67625ea22c7df9b892ff3d905131e2db8a6e9d9` |

To verify each module's sha3 matches:
```bash
sha3sum sources/<name>.move
```

---


## Module `amm` (1025 lines, 37825 bytes)

`sha3_256: b5f0a2136e2e0646dfb22e68d88b9cd3bd15848df2d5f2a7144eb47ea34a08c0`

```move
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
```

---

## Module `apt_vault` (346 lines, 12700 bytes)

`sha3_256: 2a4a92a63d297c0bf8b5a3e6885d157a21f0c1dcd059f53e8903e047b5fd6c06`

```move
/// Vault — receives APT revenue, splits 50% buyback-burn / 50% to PID owner.
///
/// One Vault per spawned token. Sealed at mint. Holds BurnRef (no extraction).
/// AMM pool is always seeded atomically at register_handle, so settle is always 50/50.
///
/// Inputs:
///   - NFT marketplace royalty (Press collection royalty_payee = vault addr)
///   - Direct deposit_apt (manual top-up)
///   - Future revenue streams
///
/// Outputs:
///   - 50% APT to current PID owner = object::owner(pid_object) [auto-follows NFT transfer]
///   - 50% APT → $TOKEN via in-house desnet::amm 10 bps swap, then BURN via BurnRef
module desnet::apt_vault {
    use std::signer;
    use std::vector;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, BurnRef};
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::timestamp;

    use desnet::amm;

    friend desnet::factory;
    friend desnet::handle_fee_vault;

    // ============ CONSTANTS ============

    /// Min APT balance for settle to execute (anti-dust). 0.1 APT (8 decimals).
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 4;

    const SEED_VAULT: vector<u8> = b"vault::";

    /// H3 fix (audit R3): two-phase commit-reveal settle.
    /// `request_settle` records timestamp; `execute_settle` requires ≥ delay elapsed.
    /// Same-tx sandwich is impossible because manipulator must hold position across
    /// blocks under arbitrage exposure (~200 blocks at Aptos ~0.3s block time).
    const SETTLE_DELAY_SECS: u64 = 60;

    /// Re-request grace: after delay + grace, anyone can override a stale pending
    /// request. Bounds DoS vector where a spammer keeps refreshing the timer.
    const SETTLE_REQUEST_GRACE_SECS: u64 = 3600;

    /// H3 fix R3 (defense-in-depth): cap buyback amount per settle at 1% of pool APT
    /// reserve. Bounds price impact → bounds attacker's pre-position profit envelope.
    /// Excess APT redirects to PID owner (owner_amount = total_apt - capped_buyback).
    const MAX_BUYBACK_BPS_OF_RESERVE: u64 = 100;
    const BPS_DENOM: u64 = 10000;

    // ============ ERROR CODES ============

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_SWAP_FAILED: u64 = 3;
    const E_BURN_FAILED: u64 = 4;
    const E_POOL_ADDR_DRIFT: u64 = 5;
    const E_NO_PENDING_SETTLE: u64 = 6;
    const E_SETTLE_NOT_READY: u64 = 7;
    const E_SETTLE_REQUEST_PENDING: u64 = 8;

    // ============ TYPES ============

    /// Per-token Vault state.
    struct Vault has key {
        apt_balance: Coin<AptosCoin>,
        burn_ref: BurnRef,
        token_metadata_addr: address,
        handle: vector<u8>,                          // for amm swap calls
        amm_pool_addr: address,                       // cached for views
        pid_object_addr: address,
        spec_version: u32,
        extend_ref: ExtendRef,
        /// H3 fix R3: timestamp of last `request_settle`. 0 = no pending request.
        /// `execute_settle` requires `now >= pending_settle_at_secs + SETTLE_DELAY_SECS`.
        pending_settle_at_secs: u64,
    }

    // ============ EVENTS ============

    #[event]
    struct AptDeposited has drop, store {
        vault_addr: address,
        depositor: address,
        amount: u64,
    }

    #[event]
    struct AptSettled has drop, store {
        vault_addr: address,
        total_apt: u64,
        to_buyback: u64,
        to_owner: u64,
        owner_addr: address,
        token_burned: u64,
    }

    #[event]
    struct SettleRequested has drop, store {
        vault_addr: address,
        requested_at_secs: u64,
        executable_at_secs: u64,
    }

    // ============ DEPLOY — friend, called by factory at token spawn ============

    public(friend) fun deploy(
        factory_signer: &signer,
        token_handle: vector<u8>,
        token_metadata_addr: address,
        amm_pool_addr: address,
        pid_object_addr: address,
        burn_ref: BurnRef,
    ): address {
        let seed = make_seed(&token_handle);
        let constructor_ref = object::create_named_object(factory_signer, seed);
        let vault_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let vault_signer = object::generate_signer(&constructor_ref);

        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        move_to(&vault_signer, Vault {
            apt_balance: coin::zero<AptosCoin>(),
            burn_ref,
            token_metadata_addr,
            handle: token_handle,
            amm_pool_addr,
            pid_object_addr,
            spec_version: SPEC_VERSION,
            extend_ref,
            pending_settle_at_secs: 0,
        });

        vault_addr
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_VAULT);
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ DEPOSIT — permissionless ============

    public entry fun deposit_apt(
        depositor: &signer,
        vault_addr: address,
        amount: u64,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        let apt_in = coin::withdraw<AptosCoin>(depositor, amount);
        coin::merge(&mut vault.apt_balance, apt_in);

        event::emit(AptDeposited {
            vault_addr,
            depositor: signer::address_of(depositor),
            amount,
        });
    }

    // ============ SETTLE — two-phase (R3 H3 fix) ============

    /// Phase 1: record request timestamp. Permissionless.
    /// `execute_settle` becomes callable after SETTLE_DELAY_SECS elapses.
    /// If a pending request already exists and is younger than
    /// `SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS`, this aborts (DoS guard).
    public entry fun request_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let now = timestamp::now_seconds();
        assert!(
            vault.pending_settle_at_secs == 0
                || now >= vault.pending_settle_at_secs + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS,
            E_SETTLE_REQUEST_PENDING
        );

        vault.pending_settle_at_secs = now;

        event::emit(SettleRequested {
            vault_addr,
            requested_at_secs: now,
            executable_at_secs: now + SETTLE_DELAY_SECS,
        });
    }

    /// Phase 2: execute the buyback-burn + owner payout. Permissionless.
    /// Requires a pending request older than `SETTLE_DELAY_SECS`.
    /// Buyback amount is capped at `MAX_BUYBACK_BPS_OF_RESERVE` (1%) of pool APT
    /// reserve as defense-in-depth against pre-positioning over the delay window.
    /// M5: cached amm_pool_addr matches current handle-derived addr.
    public entry fun execute_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        // Two-phase guard: pending request must exist and have aged past delay.
        assert!(vault.pending_settle_at_secs > 0, E_NO_PENDING_SETTLE);
        let now = timestamp::now_seconds();
        assert!(
            now >= vault.pending_settle_at_secs + SETTLE_DELAY_SECS,
            E_SETTLE_NOT_READY
        );

        // M5: cache consistency check (assert before any swap).
        assert!(
            amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
            E_POOL_ADDR_DRIFT
        );

        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        // H3 R3 defense-in-depth: cap buyback at 1% of pool APT reserve.
        // Excess APT redirects to PID owner. Bounds attacker pre-position profit
        // envelope (manipulation cost grows ~Δ², extractable profit grows ~Δ).
        let raw_buyback = total_apt / 2;
        let (apt_reserve, _token_reserve) = amm::reserves(vault.handle);
        let reserve_cap = (apt_reserve * MAX_BUYBACK_BPS_OF_RESERVE) / BPS_DENOM;
        let buyback_amount = if (raw_buyback > reserve_cap) reserve_cap else raw_buyback;
        let owner_amount = total_apt - buyback_amount;

        let apt_for_buyback = coin::extract(&mut vault.apt_balance, buyback_amount);
        let apt_for_owner = coin::extract(&mut vault.apt_balance, owner_amount);

        // Buyback path: APT → $TOKEN via in-house AMM 10 bps, then BURN.
        // No min_out slippage check — same-tx sandwich is impossible (two-phase delay)
        // and pre-position attack profitability is bounded by the buyback cap.
        let apt_fa_buyback = coin::coin_to_fungible_asset(apt_for_buyback);
        let token_received = amm::swap_exact_apt_in(
            vault.handle,
            apt_fa_buyback,
            0,
        );
        let burned_amount = fungible_asset::amount(&token_received);
        fungible_asset::burn(&vault.burn_ref, token_received);

        // Owner path: APT direct to current PID owner.
        coin::deposit(owner_addr, apt_for_owner);

        // Consume the pending request.
        vault.pending_settle_at_secs = 0;

        event::emit(AptSettled {
            vault_addr,
            total_apt,
            to_buyback: buyback_amount,
            to_owner: owner_amount,
            owner_addr,
            token_burned: burned_amount,
        });
    }

    // ============ VIEW ============

    #[view]
    public fun apt_balance(vault_addr: address): u64 acquires Vault {
        coin::value(&borrow_global<Vault>(vault_addr).apt_balance)
    }

    #[view]
    public fun current_owner(vault_addr: address): address acquires Vault {
        let vault = borrow_global<Vault>(vault_addr);
        let pid_obj = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        object::owner(pid_obj)
    }

    #[view]
    public fun pool_addr(vault_addr: address): address acquires Vault {
        borrow_global<Vault>(vault_addr).amm_pool_addr
    }

    #[view]
    public fun token_metadata(vault_addr: address): address acquires Vault {
        borrow_global<Vault>(vault_addr).token_metadata_addr
    }

    #[view]
    public fun handle(vault_addr: address): vector<u8> acquires Vault {
        borrow_global<Vault>(vault_addr).handle
    }

    #[view]
    public fun pending_settle_at_secs(vault_addr: address): u64 acquires Vault {
        borrow_global<Vault>(vault_addr).pending_settle_at_secs
    }

    #[view]
    public fun settle_executable_at_secs(vault_addr: address): u64 acquires Vault {
        let pending = borrow_global<Vault>(vault_addr).pending_settle_at_secs;
        if (pending == 0) 0 else pending + SETTLE_DELAY_SECS
    }

    // ============ DELEGATE BURN — friend (handle_fee_vault, v0.3.2 F9) ============

    /// handle_fee_vault swaps APT → DESNET via amm, then asks the DESNET per-token
    /// vault to burn the FA via its held BurnRef. Direction-locked: caller hands a FA
    /// whose metadata MUST match `vault.token_metadata_addr` (the fungible_asset::burn
    /// check enforces this — wrong-token FA aborts).
    /// No state mutation, no event (handle_fee_vault::Settled covers it).
    public(friend) fun burn_via_vault(
        vault_addr: address,
        fa: fungible_asset::FungibleAsset,
    ) acquires Vault {
        let vault = borrow_global<Vault>(vault_addr);
        fungible_asset::burn(&vault.burn_ref, fa);
    }

    // ============ TEST-ONLY HELPERS ============

    #[test_only]
    public fun deploy_for_test(
        factory_signer: &signer,
        token_handle: vector<u8>,
        token_metadata_addr: address,
        amm_pool_addr: address,
        pid_object_addr: address,
        burn_ref: BurnRef,
    ): address {
        deploy(factory_signer, token_handle, token_metadata_addr, amm_pool_addr, pid_object_addr, burn_ref)
    }

    #[test_only]
    public fun deposit_apt_coin_for_test(
        vault_addr: address,
        apt_coin: Coin<AptosCoin>,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        coin::merge(&mut vault.apt_balance, apt_coin);
    }
}
```

---

## Module `lp_staking` (699 lines, 27518 bytes)

`sha3_256: 5082a91a2a783944264c8f06f4a184249ee570d14af74af5435b55683759c46d`

```move
/// LP Position NFT — V3-style position management + emission + fee claims (LOCKED 2026-05-02).
///
/// LP repr: each position = an Object (NFT-style). NO LP FA exists.
/// Auth model: `object::owner(position)` — V3 NFT semantics. Position transferable.
/// Three position kinds via `unlock_at_secs` marker on unified `Position` struct:
///   1. **LockedPosition (creator atomic)** — unlock_at_secs = u64::MAX (never).
///      Stored AT pid_addr. Recipient at claim = object::owner(pid_obj) [auto-follows NFT transfer].
///   2. **FreePosition** — unlock_at_secs = 0 (anytime withdraw). Recipient = object::owner(position).
///   3. **TimeLockedPosition** — unlock_at_secs > 0 (withdraw after t). Recipient = object::owner(position).
///
/// Universal yield (LOCKED 2026-05-02): ALL positions earn:
///   - **Swap fees (APT + TOKEN)** — proportional to shares / amm.lp_supply
///   - **Emission ($TOKEN from 900M reserve)** — C-variant, 10/sec, denominator = amm.lp_supply
///
/// No "raw LP forfeits" mechanic. No staked-vs-unstaked distinction. Free, time-locked,
/// locked all earn identically. The only difference is exit option (unlock_at).
///
/// Forever-lock invariant (structural): for unlock_at=u64::MAX, `unstake` aborts before
/// calling `amm::remove_liquidity_internal`. LP reserves never returned. Forever-locked.
module desnet::lp_staking {
    use std::signer;
    use std::vector;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, ObjectCore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use desnet::amm;
    use desnet::governance;
    use desnet::lp_emission;
    use desnet::voter_history;

    friend desnet::factory;

    // ============ CONSTANTS ============

    /// Default emission rate: 10 $TOKEN/sec at 8 dec = 1e9 raw/sec.
    const DEFAULT_RATE_PER_SEC: u64 = 1_000_000_000;

    const ACC_SCALE: u128 = 1_000_000_000_000_000_000;

    /// Forever marker.
    const UNLOCK_FOREVER: u64 = 18446744073709551615;

    const SEED_STAKING_POOL: vector<u8> = b"desnet::lp_staking::pool::";

    // ============ ERROR CODES ============

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_POOL_ALREADY_EXISTS: u64 = 2;
    const E_POSITION_NOT_FOUND: u64 = 3;
    const E_NOT_POSITION_OWNER: u64 = 4;
    const E_ZERO_SHARES: u64 = 5;
    const E_LOCKED_NOT_YET_UNLOCKED: u64 = 6;
    const E_LOCKED_FOREVER: u64 = 7;
    const E_LOCK_DURATION_INVALID: u64 = 8;
    const E_LOCKED_POSITION_EXISTS: u64 = 9;
    const E_INVALID_PID_SIGNER: u64 = 10;

    // ============ TYPES ============

    /// Per-handle staking emission state. C-variant: rate fixed per pool,
    /// accumulated_per_share advances on every stake/unstake/claim.
    /// Denominator = amm::lp_supply(handle) (universal — all Position.shares contribute).
    struct StakingPool has key {
        handle: vector<u8>,
        token_metadata_addr: address,
        rate_per_sec: u64,
        accumulated_per_share: u128,
        last_update_secs: u64,
        emission_reserve_addr: address,
        extend_ref: ExtendRef,
    }

    /// Unified Position. NFT-style (Object with object::owner-based auth).
    /// Stored at pid_addr (creator-locked) OR staker-derived addr (free/time-locked).
    struct Position has key {
        pool_addr: address,
        handle: vector<u8>,
        shares: u128,                                 // logical LP units
        last_acc_per_share: u128,                     // emission snapshot
        last_fee_per_lp_apt: u128,                    // APT fee snapshot
        last_fee_per_lp_token: u128,                  // TOKEN fee snapshot
        unlock_at_secs: u64,                          // 0=free, t=until-t, MAX=forever
        recipient_pid: address,                       // @0x0 → pay object::owner(position); else → object::owner(pid)
    }

    // ============ EVENTS ============

    #[event]
    struct StakingPoolCreated has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        token_metadata_addr: address,
        emission_reserve_addr: address,
        rate_per_sec: u64,
    }

    #[event]
    struct PositionCreated has drop, store {
        handle: vector<u8>,
        position_addr: address,
        owner: address,
        shares: u128,
        unlock_at_secs: u64,
        recipient_pid: address,
        kind: u8,                                     // 1=locked-creator, 2=free, 3=time-locked
    }

    #[event]
    struct PositionRemoved has drop, store {
        handle: vector<u8>,
        position_addr: address,
        owner: address,
        shares: u128,
        apt_returned: u64,
        token_returned: u64,
    }

    #[event]
    struct Claimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        emission_amount: u64,
        apt_fee_amount: u64,
        token_fee_amount: u64,
    }

    // ============ ADDR DERIVATION ============

    public fun staking_pool_address_of_handle(handle: vector<u8>): address {
        let seed = pool_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    public fun staking_pool_exists(handle: vector<u8>): bool {
        exists<StakingPool>(staking_pool_address_of_handle(handle))
    }

    fun pool_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_STAKING_POOL;
        vector::append(&mut s, *handle);
        s
    }

    // ============ CREATE — friend-only (factory atomic at register) ============

    /// Create StakingPool + LockedPosition at pid_addr with creator's initial LP.
    public(friend) fun create_pool_and_lock(
        handle: vector<u8>,
        token_metadata_addr: address,
        emission_reserve_addr: address,
        creator_pid: address,
        pid_signer: &signer,
        initial_shares: u128,
    ): address {
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(!exists<StakingPool>(pool_addr), E_POOL_ALREADY_EXISTS);
        assert!(initial_shares > 0, E_ZERO_SHARES);
        assert!(signer::address_of(pid_signer) == creator_pid, E_INVALID_PID_SIGNER);
        assert!(!exists<Position>(creator_pid), E_LOCKED_POSITION_EXISTS);

        let pkg_signer = governance::derive_pkg_signer();
        let constructor = object::create_named_object(&pkg_signer, pool_seed(&handle));
        let pool_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        let now = timestamp::now_seconds();

        move_to(&pool_signer, StakingPool {
            handle,
            token_metadata_addr,
            rate_per_sec: DEFAULT_RATE_PER_SEC,
            accumulated_per_share: 0,
            last_update_secs: now,
            emission_reserve_addr,
            extend_ref,
        });

        event::emit(StakingPoolCreated {
            handle,
            pool_addr,
            token_metadata_addr,
            emission_reserve_addr,
            rate_per_sec: DEFAULT_RATE_PER_SEC,
        });

        // Snapshot fee accumulators at creation
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);

        move_to(pid_signer, Position {
            pool_addr,
            handle,
            shares: initial_shares,
            last_acc_per_share: 0,
            last_fee_per_lp_apt: fee_per_apt,
            last_fee_per_lp_token: fee_per_token,
            unlock_at_secs: UNLOCK_FOREVER,
            recipient_pid: creator_pid,
        });

        event::emit(PositionCreated {
            handle,
            position_addr: creator_pid,
            owner: object::owner(object::address_to_object<ObjectCore>(creator_pid)),
            shares: initial_shares,
            unlock_at_secs: UNLOCK_FOREVER,
            recipient_pid: creator_pid,
            kind: 1,
        });

        pool_addr
    }

    // ============ ADD LIQUIDITY — public entries ============

    /// Public add liquidity. Withdraws APT + TOKEN from caller, calls amm::add_liquidity_internal,
    /// creates Position (kind = free, unlock_at = 0). Returns nothing — Position is at caller-derived addr.
    /// Frontend reads PositionCreated event for position_addr.
    public entry fun add_liquidity(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
    ) acquires StakingPool {
        let unlock_at_secs = 0u64;
        add_liquidity_with_lock_internal(caller, handle, apt_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    /// Public add liquidity with time-lock. Position cannot be removed until unlock_at_secs.
    public entry fun add_liquidity_with_lock(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let now = timestamp::now_seconds();
        assert!(unlock_at_secs > now, E_LOCK_DURATION_INVALID);
        add_liquidity_with_lock_internal(caller, handle, apt_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    fun add_liquidity_with_lock_internal(
        caller: &signer,
        handle: vector<u8>,
        apt_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let caller_addr = signer::address_of(caller);
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);

        // Withdraw APT (Coin → FA)
        let apt_coin = coin::withdraw<AptosCoin>(caller, apt_amount);
        let apt_fa = coin::coin_to_fungible_asset(apt_coin);

        // Withdraw TOKEN (FA from primary store)
        let pool = borrow_global<StakingPool>(pool_addr);
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        let token_fa = primary_fungible_store::withdraw(caller, token_meta, token_amount);

        // Mint LP shares via amm. M1 fix (audit R1): refund surplus on ratio mismatch.
        let (lp_minted, apt_refund, token_refund) =
            amm::add_liquidity_internal(handle, apt_fa, token_fa, min_lp_out);
        assert!(lp_minted > 0, E_ZERO_SHARES);
        if (fungible_asset::amount(&apt_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, apt_refund);
        } else {
            fungible_asset::destroy_zero(apt_refund);
        };
        if (fungible_asset::amount(&token_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, token_refund);
        } else {
            fungible_asset::destroy_zero(token_refund);
        };

        // Update emission accumulator BEFORE snapshotting position
        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let snapshot_acc = pool.accumulated_per_share;
        let pool_handle = pool.handle;

        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);

        // Create Position object owned by caller (NFT-style)
        let constructor = object::create_object(caller_addr);
        let pos_signer = object::generate_signer(&constructor);
        let pos_addr = signer::address_of(&pos_signer);

        move_to(&pos_signer, Position {
            pool_addr,
            handle,
            shares: lp_minted,
            last_acc_per_share: snapshot_acc,
            last_fee_per_lp_apt: fee_per_apt,
            last_fee_per_lp_token: fee_per_token,
            unlock_at_secs,
            recipient_pid: @0x0,
        });

        let kind: u8 = if (unlock_at_secs == 0) 2 else 3;
        event::emit(PositionCreated {
            handle: pool_handle,
            position_addr: pos_addr,
            owner: caller_addr,
            shares: lp_minted,
            unlock_at_secs,
            recipient_pid: @0x0,
            kind,
        });
    }

    // ============ REMOVE LIQUIDITY — public, gated by unlock_at ============

    /// Caller must be Position object owner (NFT semantics — Position is transferable).
    /// Forever-locked positions can NEVER unstake. Auto-claims pending before destroy.
    public entry fun remove_liquidity(
        caller: &signer,
        position_addr: address,
        min_apt_out: u64,
        min_token_out: u64,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let position = borrow_global<Position>(position_addr);
        let unlock_at = position.unlock_at_secs;
        let pool_addr = position.pool_addr;
        let handle = position.handle;
        let position_obj = object::address_to_object<Position>(position_addr);
        let position_owner = object::owner(position_obj);

        // Auth: caller must be current owner of Position object
        assert!(signer::address_of(caller) == position_owner, E_NOT_POSITION_OWNER);

        // Forever-lock check
        assert!(unlock_at != UNLOCK_FOREVER, E_LOCKED_FOREVER);
        let now = timestamp::now_seconds();
        assert!(now >= unlock_at, E_LOCKED_NOT_YET_UNLOCKED);

        // Auto-claim before destroy
        claim_internal(position_addr);

        // Now destroy position + return reserves
        let Position {
            pool_addr: _,
            handle: _,
            shares,
            last_acc_per_share: _,
            last_fee_per_lp_apt: _,
            last_fee_per_lp_token: _,
            unlock_at_secs: _,
            recipient_pid: _,
        } = move_from<Position>(position_addr);

        let (apt_fa, token_fa) = amm::remove_liquidity_internal(handle, shares, min_apt_out, min_token_out);
        let apt_returned = fungible_asset::amount(&apt_fa);
        let token_returned = fungible_asset::amount(&token_fa);

        primary_fungible_store::deposit(position_owner, apt_fa);
        primary_fungible_store::deposit(position_owner, token_fa);

        let pool_handle_dummy = handle;
        event::emit(PositionRemoved {
            handle: pool_handle_dummy,
            position_addr,
            owner: position_owner,
            shares,
            apt_returned,
            token_returned,
        });
    }

    // ============ CLAIM — permissionless triple-settle ============

    /// Anyone can poke. Recipient resolved at claim:
    /// - recipient_pid != @0x0 → object::owner(pid) [auto-follows NFT transfer]
    /// - recipient_pid == @0x0 → object::owner(position) [Position transfer = recipient transfer]
    public entry fun claim(
        _caller: &signer,
        position_addr: address,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        claim_internal(position_addr);
    }

    fun claim_internal(position_addr: address) acquires Position, StakingPool {
        let position = borrow_global_mut<Position>(position_addr);
        let pool_addr = position.pool_addr;
        let handle = position.handle;
        let shares_u128 = position.shares;

        // 1. Update + read emission accumulator
        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let acc = pool.accumulated_per_share;
        let pending_emission_u128 = ((acc - position.last_acc_per_share) * shares_u128) / ACC_SCALE;
        position.last_acc_per_share = acc;

        // 2. Read amm fee accumulators
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt_u128 = ((fee_per_apt - position.last_fee_per_lp_apt) * shares_u128) / amm_scale;
        let pending_token_u128 = ((fee_per_token - position.last_fee_per_lp_token) * shares_u128) / amm_scale;
        position.last_fee_per_lp_apt = fee_per_apt;
        position.last_fee_per_lp_token = fee_per_token;

        let pending_emission = (pending_emission_u128 as u64);
        let pending_apt = (pending_apt_u128 as u64);
        let pending_token = (pending_token_u128 as u64);

        // 3. Resolve recipient
        let recipient = resolve_recipient(position.recipient_pid, position_addr);

        // 4. Pull emission ($TOKEN) from lp_emission reserve.
        //    H2 fix (audit R1): record voting power for ACTUAL paid amount, not requested.
        //    pull_for_claim caps at reserve balance (graceful depletion); recording
        //    pending_emission would inflate voting power post-depletion at zero cost.
        if (pending_emission > 0) {
            let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
            let emission_fa = lp_emission::pull_for_claim(
                pool.emission_reserve_addr,
                token_meta,
                pending_emission,
            );
            let actual_paid = fungible_asset::amount(&emission_fa);
            primary_fungible_store::deposit(recipient, emission_fa);

            if (actual_paid > 0) {
                let pkg_signer = governance::derive_pkg_signer();
                // v0.3.2 (F7): record per-token (also writes legacy mixed for compat).
                // Token addr is the pool's emission token = current pool.token_metadata_addr.
                voter_history::record_reward_received_for_token(
                    &pkg_signer,
                    recipient,
                    pool.token_metadata_addr,
                    actual_paid,
                );
                // v0.3.2 (F6): feed the 30d auto-tracker so DAO threshold/quorum
                // become driven by actual emission flow (eliminates manipulation
                // surface of multisig::update_total_30d_emission).
                governance::record_emission_for_window(actual_paid);
            };
        };

        // 5. Pull LP fees (APT + TOKEN)
        if (pending_apt > 0 || pending_token > 0) {
            let (apt_fa, token_fa) = amm::extract_fees_for_claim(handle, pending_apt, pending_token);
            if (fungible_asset::amount(&apt_fa) > 0) {
                primary_fungible_store::deposit(recipient, apt_fa);
            } else {
                fungible_asset::destroy_zero(apt_fa);
            };
            if (fungible_asset::amount(&token_fa) > 0) {
                primary_fungible_store::deposit(recipient, token_fa);
            } else {
                fungible_asset::destroy_zero(token_fa);
            };
        };

        if (pending_emission == 0 && pending_apt == 0 && pending_token == 0) return;

        event::emit(Claimed {
            handle: pool.handle,
            position_addr,
            recipient,
            emission_amount: pending_emission,
            apt_fee_amount: pending_apt,
            token_fee_amount: pending_token,
        });
    }

    fun resolve_recipient(recipient_pid: address, position_addr: address): address {
        if (recipient_pid == @0x0) {
            // Free / time-locked: recipient = current Position object owner
            let pos_obj = object::address_to_object<Position>(position_addr);
            object::owner(pos_obj)
        } else {
            // Locked-creator: recipient = current PID NFT owner
            let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
            object::owner(pid_obj)
        }
    }

    // ============ INTERNAL — emission accumulator (C-variant) ============

    /// Universal denominator: amm::lp_supply(handle) — ALL positions (locked + free + time-locked).
    fun update_pool(pool_addr: address) acquires StakingPool {
        let pool = borrow_global_mut<StakingPool>(pool_addr);
        let now = timestamp::now_seconds();
        if (now <= pool.last_update_secs) return;

        let lp_supply = amm::lp_supply(pool.handle);
        if (lp_supply == 0) {
            pool.last_update_secs = now;
            return
        };

        let elapsed = now - pool.last_update_secs;
        let new_emission = (elapsed as u128) * (pool.rate_per_sec as u128);
        let delta_per_share = (new_emission * ACC_SCALE) / lp_supply;
        pool.accumulated_per_share = pool.accumulated_per_share + delta_per_share;
        pool.last_update_secs = now;
    }

    // ============ VIEWS ============

    #[view]
    public fun has_position(position_addr: address): bool {
        exists<Position>(position_addr)
    }

    #[view]
    public fun position_pool(position_addr: address): address acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).pool_addr
    }

    #[view]
    public fun position_shares(position_addr: address): u128 acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).shares
    }

    #[view]
    public fun position_unlock_at(position_addr: address): u64 acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).unlock_at_secs
    }

    #[view]
    public fun position_recipient_pid(position_addr: address): address acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(position_addr).recipient_pid
    }

    /// NFT owner of position (= effective claimer for free/time-locked).
    #[view]
    public fun position_owner(position_addr: address): address {
        let pos_obj = object::address_to_object<Position>(position_addr);
        object::owner(pos_obj)
    }

    // ============ DARBITEX-SHAPE COMPOSABILITY VIEWS (Object<Position>-based) ============

    /// Pool addr containing this position. Matches darbitex `position_pool_addr(pos)`.
    #[view]
    public fun position_pool_addr(pos: Object<Position>): address acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).pool_addr
    }

    /// Per-position fee snapshots (last claim point). Matches darbitex `position_fee_debt(pos)`.
    /// Returns (last_fee_per_lp_apt, last_fee_per_lp_token).
    #[view]
    public fun position_fee_debt(pos: Object<Position>): (u128, u128) acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        let p = borrow_global<Position>(pos_addr);
        (p.last_fee_per_lp_apt, p.last_fee_per_lp_token)
    }

    /// Pending claimable LP fees only (excluding emission). Matches darbitex
    /// `position_pending_fees(pos): (u64, u64)`.
    /// For triple-settle (emission + fees), use `position_pending_all`.
    #[view]
    public fun position_pending_fees(pos: Object<Position>): (u64, u64) acquires Position {
        let pos_addr = object::object_address(&pos);
        if (!exists<Position>(pos_addr)) return (0, 0);
        let p = borrow_global<Position>(pos_addr);
        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(p.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt = (((fee_per_apt - p.last_fee_per_lp_apt) * p.shares) / amm_scale) as u64;
        let pending_token = (((fee_per_token - p.last_fee_per_lp_token) * p.shares) / amm_scale) as u64;
        (pending_apt, pending_token)
    }

    /// Position shares as Object input (Object-shape for darbitex parity).
    #[view]
    public fun position_shares_obj(pos: Object<Position>): u128 acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).shares
    }

    /// Returns (pending_emission, pending_apt_fee, pending_token_fee).
    #[view]
    public fun position_pending_all(position_addr: address): (u64, u64, u64)
        acquires Position, StakingPool
    {
        if (!exists<Position>(position_addr)) return (0, 0, 0);
        let position = borrow_global<Position>(position_addr);
        let pool_addr = position.pool_addr;
        if (!exists<StakingPool>(pool_addr)) return (0, 0, 0);
        let pool = borrow_global<StakingPool>(pool_addr);
        let lp_supply = amm::lp_supply(position.handle);

        let now = timestamp::now_seconds();
        let acc = pool.accumulated_per_share;
        if (now > pool.last_update_secs && lp_supply > 0) {
            let elapsed = now - pool.last_update_secs;
            let new_emission = (elapsed as u128) * (pool.rate_per_sec as u128);
            let delta = (new_emission * ACC_SCALE) / lp_supply;
            acc = acc + delta;
        };

        let pending_emission = (((acc - position.last_acc_per_share) * position.shares) / ACC_SCALE) as u64;

        let (fee_per_apt, fee_per_token) = amm::fee_per_lp(position.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_apt = (((fee_per_apt - position.last_fee_per_lp_apt) * position.shares) / amm_scale) as u64;
        let pending_token = (((fee_per_token - position.last_fee_per_lp_token) * position.shares) / amm_scale) as u64;

        (pending_emission, pending_apt, pending_token)
    }

    #[view]
    public fun pool_acc_per_share(pool_addr: address): u128 acquires StakingPool {
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<StakingPool>(pool_addr).accumulated_per_share
    }

    #[view]
    public fun pool_rate_per_sec(pool_addr: address): u64 acquires StakingPool {
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);
        borrow_global<StakingPool>(pool_addr).rate_per_sec
    }

    #[view]
    public fun unlock_forever_marker(): u64 { UNLOCK_FOREVER }

    #[view]
    public fun default_rate_per_sec(): u64 { DEFAULT_RATE_PER_SEC }

    #[view]
    public fun acc_scale(): u128 { ACC_SCALE }

    // ============ UNIT TESTS ============

    #[test]
    fun test_unlock_forever_marker_is_u64_max() {
        assert!(unlock_forever_marker() == 18446744073709551615u64, 1);
    }

    #[test]
    fun test_default_rate_per_sec_is_10_token_per_sec() {
        assert!(default_rate_per_sec() == 1_000_000_000, 1);
    }

    #[test]
    fun test_acc_scale_is_1e18() {
        assert!(acc_scale() == 1_000_000_000_000_000_000, 1);
    }

    #[test]
    fun test_staking_pool_address_deterministic() {
        assert!(
            staking_pool_address_of_handle(b"alice") == staking_pool_address_of_handle(b"alice"),
            1
        );
    }

    #[test]
    fun test_staking_pool_addr_unique_per_handle() {
        assert!(
            staking_pool_address_of_handle(b"alice") != staking_pool_address_of_handle(b"bob"),
            1
        );
    }

    #[test]
    fun test_pool_seed_differs_per_handle() {
        assert!(pool_seed(&b"alice") != pool_seed(&b"alice2"), 1);
    }

    #[test]
    fun test_emission_depletion_eta_calculation() {
        let total_emission = 90_000_000_000_000_000u64;
        let secs_to_deplete = total_emission / default_rate_per_sec();
        assert!(secs_to_deplete == 90_000_000, 1);
    }

    #[test]
    fun test_staking_pool_seed_differs_from_amm_pool_seed() {
        assert!(
            staking_pool_address_of_handle(b"alice") != amm::pool_address_of_handle(b"alice"),
            1
        );
    }
}
```

---

## Module `lp_emission` (192 lines, 6300 bytes)

`sha3_256: d113c874e46571cd129b2f112b98b4e84999c96107d923619cbf1c6d8b908c79`

```move
/// LP Emission Reserve — sealed $TOKEN reserve drained by lp_staking on claim.
///
/// One reserve per spawned token (90% of supply at mint).
/// 900M × 10^8 raw / (10 × 10^8 raw/sec) ≈ 2.85 years to depletion.
///
/// Pull-based architecture:
/// - lp_staking::claim_internal calls `pull_for_claim` (friend) per claim
/// - lp_staking wires voter_history via governance pkg_signer
/// - This module guards the FA reserve + permissionless top-up
module desnet::lp_emission {
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    friend desnet::factory;
    friend desnet::lp_staking;

    // ============ CONSTANTS ============

    const SPEC_VERSION: u32 = 2;
    const SEED_LP_RESERVE: vector<u8> = b"lp_reserve::";

    // ============ ERROR CODES ============

    const E_RESERVE_NOT_FOUND: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;

    // ============ TYPES ============

    /// Per-token LP emission reserve. Token balance lives in primary fungible
    /// store at this Object's addr.
    struct LpReserve has key {
        token_metadata_addr: address,
        spec_version: u32,
        extend_ref: ExtendRef,
        total_distributed: u64,
        deployed_at_secs: u64,
    }

    // ============ EVENTS ============

    #[event]
    struct LpReserveDeployed has drop, store {
        reserve_addr: address,
        token_metadata_addr: address,
        initial_amount: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct LpPulledForClaim has drop, store {
        reserve_addr: address,
        amount: u64,
        new_balance: u64,
    }

    #[event]
    struct LpReserveToppedUp has drop, store {
        reserve_addr: address,
        depositor: address,
        amount: u64,
        new_balance: u64,
    }

    // ============ DEPLOY — friend, called by factory at token spawn ============

    public(friend) fun deploy(
        factory_signer: &signer,
        token_handle: vector<u8>,
        token_metadata_addr: address,
        initial_allocation: FungibleAsset,
    ): address {
        let seed = make_seed(&token_handle);
        let constructor_ref = object::create_named_object(factory_signer, seed);
        let reserve_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let reserve_signer = object::generate_signer(&constructor_ref);

        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        let now = timestamp::now_seconds();
        let initial_amount = fungible_asset::amount(&initial_allocation);

        move_to(&reserve_signer, LpReserve {
            token_metadata_addr,
            spec_version: SPEC_VERSION,
            extend_ref,
            total_distributed: 0,
            deployed_at_secs: now,
        });

        primary_fungible_store::deposit(reserve_addr, initial_allocation);

        event::emit(LpReserveDeployed {
            reserve_addr,
            token_metadata_addr,
            initial_amount,
            timestamp_secs: now,
        });

        reserve_addr
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_LP_RESERVE);
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ PULL — friend, called by lp_staking on claim ============

    /// Withdraw $TOKEN from reserve as hot-potato FA. lp_staking deposits to recipient.
    /// Caps at remaining balance (no abort on partial — emission depletion graceful).
    public(friend) fun pull_for_claim(
        reserve_addr: address,
        token_metadata: Object<Metadata>,
        amount: u64,
    ): FungibleAsset acquires LpReserve {
        assert!(exists<LpReserve>(reserve_addr), E_RESERVE_NOT_FOUND);
        let reserve = borrow_global_mut<LpReserve>(reserve_addr);

        let available = primary_fungible_store::balance(reserve_addr, token_metadata);
        let payout = if (amount < available) amount else available;

        if (payout == 0) {
            return fungible_asset::zero(token_metadata)
        };

        let reserve_signer = object::generate_signer_for_extending(&reserve.extend_ref);
        let fa = primary_fungible_store::withdraw(&reserve_signer, token_metadata, payout);

        reserve.total_distributed = reserve.total_distributed + payout;
        let new_balance = primary_fungible_store::balance(reserve_addr, token_metadata);

        event::emit(LpPulledForClaim {
            reserve_addr,
            amount: payout,
            new_balance,
        });

        fa
    }

    // ============ TOP-UP — public ============

    public entry fun topup_reserve(
        depositor: &signer,
        reserve_addr: address,
        token_metadata: Object<Metadata>,
        amount: u64,
    ) {
        let token_in = primary_fungible_store::withdraw(depositor, token_metadata, amount);
        primary_fungible_store::deposit(reserve_addr, token_in);

        let new_balance = primary_fungible_store::balance(reserve_addr, token_metadata);

        event::emit(LpReserveToppedUp {
            reserve_addr,
            depositor: signer::address_of(depositor),
            amount,
            new_balance,
        });
    }

    // ============ VIEWS ============

    #[view]
    public fun reserve_balance(reserve_addr: address, token_metadata: Object<Metadata>): u64 {
        primary_fungible_store::balance(reserve_addr, token_metadata)
    }

    #[view]
    public fun total_distributed(reserve_addr: address): u64 acquires LpReserve {
        borrow_global<LpReserve>(reserve_addr).total_distributed
    }

    #[view]
    public fun token_metadata_addr(reserve_addr: address): address acquires LpReserve {
        borrow_global<LpReserve>(reserve_addr).token_metadata_addr
    }

    #[view]
    public fun deployed_at_secs(reserve_addr: address): u64 acquires LpReserve {
        borrow_global<LpReserve>(reserve_addr).deployed_at_secs
    }
}
```

---

## Module `reaction_emission` (244 lines, 8765 bytes)

`sha3_256: b3d7074176a1ca96844973c713ae71a8e1a643987f1ba49419dc97e124420530`

```move
/// Reaction Emission Reserve — distributes TOKEN to Press actors via linear curve.
///
/// One reserve per spawned token. Sealed by allocation (5% of supply at mint).
/// Permissionless top-up allowed (anyone can deposit more TOKEN).
///
/// Distribution rule (LOCKED):
///   emission(n) = n × REACTION_BASE_VALUE
///   where n = press order on a post (1 to author-set supply_cap)
///
/// INCREASING per press (anti-FOMO design):
///   - Press #1: minimal reward (1 × BASE)
///   - Press #N: max reward (cap × BASE)
///   - Last presser gets MAX, rewards patience + judgment
///
/// Total per post = sum(1..cap) = cap × (cap+1) / 2 × BASE.
///   At cap=1000: 500,500 × BASE per post.
///
/// Anti-manipulation (enforced upstream by DeSNet protocol):
///   - Per-actor uniqueness: 1 press per actor per post
///   - Self-press: max 1 per author per post
///   - Pool-seed gating
///   - Aptos gas cost baseline friction
module desnet::reaction_emission {
    use std::signer;
    use std::vector;
    use std::option;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use aptos_framework::object::{Self, ExtendRef};

    friend desnet::factory;

    // ============ CONSTANTS ============

    /// Base unit for emission curve. emission(n) = n × BASE.
    /// With 8 decimals: 1 × 10^8 = 1 token per "n" unit.
    /// At cap=1000, total per post = 500,500 tokens.
    const REACTION_BASE_VALUE: u64 = 100_000_000;

    /// Press supply_cap range (LOCKED 1-1000).
    const MIN_SUPPLY_CAP: u64 = 1;
    const MAX_SUPPLY_CAP: u64 = 1000;

    /// Press window range (LOCKED 1-7 days).
    const MIN_WINDOW_SECS: u64 = 86_400;
    const MAX_WINDOW_SECS: u64 = 604_800;

    const SPEC_VERSION: u32 = 1;

    const SEED_REACTION_RESERVE: vector<u8> = b"reaction_reserve::";

    // ============ ERROR CODES ============

    const E_RESERVE_EMPTY: u64 = 1;
    const E_INVALID_PRESS_ORDER: u64 = 2;
    const E_INVALID_SUPPLY_CAP: u64 = 3;
    const E_INVALID_WINDOW: u64 = 4;
    const E_RESERVE_NOT_FOUND: u64 = 5;

    // ============ TYPES ============

    /// Per-token reaction emission reserve. Token balance lives in primary
    /// fungible store at this Object's addr (queried via primary_fungible_store).
    struct ReactionReserve has key {
        token_metadata_addr: address,
        spec_version: u32,
        extend_ref: ExtendRef,
        total_distributed: u64,
        topup_count: u64,
    }

    // ============ EVENTS ============

    #[event]
    struct ReactionEmitted has drop, store {
        reserve_addr: address,
        recipient: address,
        post_id: vector<u8>,
        press_order: u64,
        emission_amount: u64,
    }

    #[event]
    struct ReserveToppedUp has drop, store {
        reserve_addr: address,
        depositor: address,
        amount: u64,
        new_balance: u64,
    }

    // ============ INIT — called by factory at token spawn ============

    /// Initialize reaction reserve with 5% allocation. Called only by factory.
    public(friend) fun deploy(
        factory_signer: &signer,
        token_handle: vector<u8>,
        token_metadata_addr: address,
        initial_allocation: FungibleAsset,
    ): address {
        let seed = make_seed(&token_handle);
        let constructor_ref = object::create_named_object(factory_signer, seed);
        let reserve_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let reserve_signer = object::generate_signer(&constructor_ref);

        // Seal reserve Object: lock ownership, no transfer possible forever.
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);

        move_to(&reserve_signer, ReactionReserve {
            token_metadata_addr,
            spec_version: SPEC_VERSION,
            extend_ref,
            total_distributed: 0,
            topup_count: 0,
        });

        // Deposit initial 5% allocation into reserve's primary store
        aptos_framework::primary_fungible_store::deposit(reserve_addr, initial_allocation);

        reserve_addr
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_REACTION_RESERVE);
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ DISTRIBUTION — called by DeSNet Press handler ============

    /// Compute and distribute emission to presser. Caller (DeSNet protocol via
    /// factory wrapper) validates upstream (uniqueness, self-press, gate).
    /// Returns actual amount distributed (may be less if reserve depleted).
    public(friend) fun emit_to_presser(
        reserve_addr: address,
        recipient: address,
        post_id: vector<u8>,
        press_order: u64,
        supply_cap: u64,
    ): u64 acquires ReactionReserve {
        // Validate inputs
        assert!(press_order > 0 && press_order <= supply_cap, E_INVALID_PRESS_ORDER);
        assert!(
            supply_cap >= MIN_SUPPLY_CAP && supply_cap <= MAX_SUPPLY_CAP,
            E_INVALID_SUPPLY_CAP
        );

        let reserve = borrow_global_mut<ReactionReserve>(reserve_addr);
        let token_metadata = object::address_to_object<fungible_asset::Metadata>(
            reserve.token_metadata_addr
        );

        // 1. Compute emission curve value
        let emission = press_order * REACTION_BASE_VALUE;

        // 2. Cap at remaining reserve balance — graceful degradation if depleted
        let available = aptos_framework::primary_fungible_store::balance(reserve_addr, token_metadata);
        let to_distribute = if (emission > available) available else emission;

        if (to_distribute == 0) {
            // Reserve depleted — emit zero-distributed event for indexer visibility
            event::emit(ReactionEmitted {
                reserve_addr,
                recipient,
                post_id,
                press_order,
                emission_amount: 0,
            });
            return 0
        };

        // 3. Extract from reserve via ExtendRef-derived signer, deposit to recipient
        let reserve_signer = object::generate_signer_for_extending(&reserve.extend_ref);
        let token_out = aptos_framework::primary_fungible_store::withdraw(
            &reserve_signer, token_metadata, to_distribute
        );
        aptos_framework::primary_fungible_store::deposit(recipient, token_out);

        // 4. Update accumulator
        reserve.total_distributed = reserve.total_distributed + to_distribute;

        // 5. Emit event + return distributed amount
        event::emit(ReactionEmitted {
            reserve_addr,
            recipient,
            post_id,
            press_order,
            emission_amount: to_distribute,
        });

        to_distribute
    }

    // ============ TOP-UP — permissionless ============

    /// Anyone can deposit TOKEN to extend reaction reserve life.
    /// Same-token only.
    public entry fun topup_reserve(
        depositor: &signer,
        reserve_addr: address,
        token_metadata: object::Object<fungible_asset::Metadata>,
        amount: u64,
    ) acquires ReactionReserve {
        let reserve = borrow_global_mut<ReactionReserve>(reserve_addr);
        let token_in = aptos_framework::primary_fungible_store::withdraw(depositor, token_metadata, amount);
        aptos_framework::primary_fungible_store::deposit(reserve_addr, token_in);

        reserve.topup_count = reserve.topup_count + 1;
        let new_balance = aptos_framework::primary_fungible_store::balance(reserve_addr, token_metadata);

        event::emit(ReserveToppedUp {
            reserve_addr,
            depositor: signer::address_of(depositor),
            amount,
            new_balance,
        });
    }

    // ============ VIEW ============

    #[view]
    public fun reserve_balance(reserve_addr: address, token_metadata: object::Object<fungible_asset::Metadata>): u64 {
        aptos_framework::primary_fungible_store::balance(reserve_addr, token_metadata)
    }

    #[view]
    public fun total_distributed(reserve_addr: address): u64 acquires ReactionReserve {
        borrow_global<ReactionReserve>(reserve_addr).total_distributed
    }

    #[view]
    public fun compute_emission(press_order: u64, supply_cap: u64): u64 {
        if (press_order == 0 || press_order > supply_cap) return 0;
        press_order * REACTION_BASE_VALUE
    }

    #[view]
    public fun total_post_emission(supply_cap: u64): u64 {
        // sum(1..cap) × BASE = cap × (cap+1) / 2 × BASE
        (supply_cap * (supply_cap + 1) / 2) * REACTION_BASE_VALUE
    }
}
```

---

## Module `handle_fee_vault` (275 lines, 12639 bytes)

`sha3_256: aaed18c378f3433bdf32ecd8b67625ea22c7df9b892ff3d905131e2db8a6e9d9`

```move
/// HandleFeeVault — handle reg fees: 10% deployer, 90% buy DESNET + burn.
/// Destinations immutable. No admin.
module desnet::handle_fee_vault {
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::primary_fungible_store;

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::factory;
    use desnet::governance;

    friend desnet::profile;

    const SEED_VAULT: vector<u8> = b"handle_fee_vault";
    const DESNET_HANDLE: vector<u8> = b"desnet";
    const APT_FA_ADDR: address = @0xa;

    /// 10% to deployer beneficiary, 90% to DESNET buyback-burn.
    const SPLIT_DEPLOYER_BPS: u64 = 1000;
    const SPLIT_BURN_BPS: u64 = 9000;
    const BPS_DENOM: u64 = 10000;

    /// Min APT balance for settle (anti-dust). 0.1 APT.
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_INITIALIZED: u64 = 2;
    /// v0.3.3 (G3): old single-tx settle deprecated for MEV-safety. Use two-phase.
    const E_USE_TWO_PHASE: u64 = 3;
    const E_PENDING_SETTLE_NOT_FOUND: u64 = 4;
    const E_PENDING_SETTLE_NOT_RIPE: u64 = 5;
    const E_PENDING_SETTLE_EXPIRED: u64 = 6;
    const E_PENDING_SETTLE_ALREADY_EXISTS: u64 = 7;

    /// v0.3.3 (G3): commit-reveal delay parameters mirror R3 H3 fix on apt_vault.
    /// 60s delay defeats single-tx sandwich (atomic same-tx grief impossible);
    /// cross-tx pre-positioning bounded by 5% slippage tolerance baked at request.
    /// Grace window: 600s before request expires (prevents stale baseline exploit).
    const SETTLE_DELAY_SECS: u64 = 60;
    const SETTLE_REQUEST_GRACE_SECS: u64 = 600;
    const SETTLE_SLIPPAGE_BPS: u64 = 9500;
    const BPS_FULL: u64 = 10000;

    struct HandleFeeVault has key {
        deployer_beneficiary: address,
        extend_ref: ExtendRef,
    }

    /// v0.3.3 (G3 + S1 fix): two-phase commit-reveal settle state. Lives at `vault_addr()`.
    /// All amounts LOCKED at request time — execute uses these (NOT current balance) so
    /// (swap_amount, min_out) stay paired from same snapshot. Without this S1 fix, balance
    /// growing during the 60s window would let attacker sandwich the larger swap with
    /// trivially-satisfied stale min_out (anchored to smaller request-time amount).
    /// Excess balance accrued during window stays in vault for next settle cycle.
    struct PendingSettle has key, drop {
        requested_at_secs: u64,
        apt_balance_at_request: u64,
        to_deployer_at_request: u64,
        to_burn_at_request: u64,
        min_desnet_out: u64,
    }

    #[event]
    struct Settled has drop, store {
        total_apt: u64,
        to_deployer: u64,
        desnet_burned: u64,
    }

    /// Auto-fires on compat-upgrade publish since this module is new.
    /// `account` is @desnet (resource account signer assembled by code::publish_package_txn).
    fun init_module(account: &signer) {
        let constructor = object::create_named_object(account, SEED_VAULT);
        let vault_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        move_to(&vault_signer, HandleFeeVault {
            deployer_beneficiary: @origin,
            extend_ref,
        });
    }

    /// v0.3.3 (G6, R5 Claude C8): added #[view] so frontend can call gas-free.
    #[view]
    public fun vault_addr(): address {
        object::create_object_address(&@desnet, SEED_VAULT)
    }

    /// v0.3.3 (G6): added #[view].
    #[view]
    public fun vault_exists(): bool {
        exists<HandleFeeVault>(vault_addr())
    }

    /// Friend-only: APT FA → vault primary store. Called by profile::register_handle.
    public(friend) fun deposit_apt_fa(fa: fungible_asset::FungibleAsset) {
        primary_fungible_store::deposit(vault_addr(), fa);
    }

    /// Public top-up — anyone can deposit APT to vault.
    public entry fun deposit_apt(depositor: &signer, amount: u64) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let fa = primary_fungible_store::withdraw(depositor, apt_meta, amount);
        deposit_apt_fa(fa);
    }

    /// v0.3.3 (G3, R5 CONV-1 MED-HIGH fix): old single-tx settle DEPRECATED for
    /// MEV-safety. The original `min_out=0` swap was atomically sandwich-attackable;
    /// any caller could front-run by skewing the AMM pool, trigger settle to swap
    /// at unfavorable rate, then back-run to extract APT and leak protocol revenue.
    /// Replaced by two-phase commit-reveal: `request_settle()` (records reserves
    /// snapshot + 5% slippage min_out) → 60s delay → `execute_settle()` (enforces
    /// pre-recorded min_out). Single-tx sandwich now structurally impossible;
    /// cross-tx pre-positioning bounded by 5% baked tolerance.
    /// Body kept (with abort) for compat preservation of `acquires HandleFeeVault`
    /// annotation parity. Callers MUST switch to two-phase flow.
    public entry fun settle(_caller: &signer) acquires HandleFeeVault {
        let _ = borrow_global<HandleFeeVault>(vault_addr());
        abort E_USE_TWO_PHASE
    }

    /// v0.3.3 (G3): Phase 1 of MEV-safe settle. Records current pool quote +
    /// 5% slippage tolerance. After SETTLE_DELAY_SECS, anyone can call
    /// `execute_settle` to consume this snapshot. If cross-tx attacker shifts pool
    /// >5% during the 60s window, execute_settle aborts (pool moved too far).
    /// Pending settle expires after grace (cleanable via `cancel_pending_settle`).
    public entry fun request_settle(_caller: &signer) acquires HandleFeeVault {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(!exists<PendingSettle>(v_addr), E_PENDING_SETTLE_ALREADY_EXISTS);

        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let total = primary_fungible_store::balance(v_addr, apt_meta);
        assert!(total >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
        let to_burn = total - to_deployer;

        // Quote DESNET-out for to_burn at current reserves; bake 5% slippage tolerance.
        let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
        let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;

        let vault = borrow_global<HandleFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        move_to(&vault_signer, PendingSettle {
            requested_at_secs: aptos_framework::timestamp::now_seconds(),
            apt_balance_at_request: total,
            to_deployer_at_request: to_deployer,
            to_burn_at_request: to_burn,
            min_desnet_out: min_out,
        });
    }

    /// v0.3.3 (G3): Phase 2 of MEV-safe settle. Requires pending request from
    /// at least SETTLE_DELAY_SECS ago, within grace window. Enforces baked min_out
    /// — if pool moved >5% adversely since request, swap aborts (caller must
    /// `cancel_pending_settle` and `request_settle` again at fresh reserves).
    public entry fun execute_settle(_caller: &signer) acquires HandleFeeVault, PendingSettle {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(exists<PendingSettle>(v_addr), E_PENDING_SETTLE_NOT_FOUND);

        let now = aptos_framework::timestamp::now_seconds();
        let pending_ref = borrow_global<PendingSettle>(v_addr);
        let requested_at = pending_ref.requested_at_secs;
        let min_out = pending_ref.min_desnet_out;
        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_PENDING_SETTLE_NOT_RIPE);
        assert!(now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS, E_PENDING_SETTLE_EXPIRED);

        // S1 fix: extract LOCKED amounts from snapshot — do NOT recompute from current balance.
        // Excess balance (current - apt_balance_at_request) stays in vault for next cycle.
        let PendingSettle {
            requested_at_secs: _,
            apt_balance_at_request,
            to_deployer_at_request,
            to_burn_at_request,
            min_desnet_out,
        } = move_from<PendingSettle>(v_addr);

        // Sanity check: vault must still have ≥ snapshot amount (vault has no withdraw path
        // other than this fn, so balance can only grow via deposits — never shrink).
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let current_total = primary_fungible_store::balance(v_addr, apt_meta);
        assert!(current_total >= apt_balance_at_request, E_BELOW_THRESHOLD);

        let vault = borrow_global<HandleFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);

        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer_at_request);
        primary_fungible_store::deposit(vault.deployer_beneficiary, apt_for_deployer);

        // 90% APT swap with min_out enforcement — sandwich-safe per snapshot.
        // Swap amount AND min_out paired from same request snapshot — slippage check
        // properly bounds the actual swap size (S1 fix vs anchor-mismatch bug).
        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn_at_request);
        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, min_desnet_out);
        let desnet_burned = fungible_asset::amount(&desnet_fa);

        let desnet_apt_vault = factory::vault_addr_of_handle(DESNET_HANDLE);
        apt_vault::burn_via_vault(desnet_apt_vault, desnet_fa);

        // Settled.total_apt reflects snapshot amount actually settled (not current vault balance).
        event::emit(Settled {
            total_apt: apt_balance_at_request,
            to_deployer: to_deployer_at_request,
            desnet_burned,
        });
    }

    /// v0.3.3 (G3): permissionless cancel of stale/grief'd pending settle. Cost = gas only.
    /// Anyone can call to clear a stuck PendingSettle (e.g., griefer requested then
    /// abandoned, blocking honest caller from new request_settle).
    public entry fun cancel_pending_settle(_caller: &signer) acquires PendingSettle {
        let v_addr = vault_addr();
        if (exists<PendingSettle>(v_addr)) {
            let _ = move_from<PendingSettle>(v_addr);
        };
    }

    #[view]
    public fun pending_settle_exists(): bool { exists<PendingSettle>(vault_addr()) }

    #[view]
    public fun pending_settle_executable_at_secs(): u64 acquires PendingSettle {
        let v_addr = vault_addr();
        if (!exists<PendingSettle>(v_addr)) return 0;
        borrow_global<PendingSettle>(v_addr).requested_at_secs + SETTLE_DELAY_SECS
    }

    #[view]
    public fun pending_settle_min_out(): u64 acquires PendingSettle {
        let v_addr = vault_addr();
        if (!exists<PendingSettle>(v_addr)) return 0;
        borrow_global<PendingSettle>(v_addr).min_desnet_out
    }

    /// One-time poke: migrate stranded pre-upgrade fees from @desnet primary store.
    /// Pre-v0.3.1, register_handle deposited fees to `state.fee_receiver` (= @desnet
    /// at init). This pulls those funds into the vault for proper 10/90 split.
    public entry fun migrate_legacy_fees(_caller: &signer) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let balance = primary_fungible_store::balance(@desnet, apt_meta);
        if (balance == 0) return;
        let pkg_signer = governance::derive_pkg_signer();
        let fa = primary_fungible_store::withdraw(&pkg_signer, apt_meta, balance);
        deposit_apt_fa(fa);
    }

    #[view]
    public fun deployer_beneficiary(): address acquires HandleFeeVault {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        borrow_global<HandleFeeVault>(v_addr).deployer_beneficiary
    }

    #[view]
    public fun apt_balance(): u64 {
        let v_addr = vault_addr();
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        primary_fungible_store::balance(v_addr, apt_meta)
    }

    #[view]
    public fun split_deployer_bps(): u64 { SPLIT_DEPLOYER_BPS }

    #[view]
    public fun split_burn_bps(): u64 { SPLIT_BURN_BPS }

    #[view]
    public fun settle_threshold(): u64 { APT_SETTLE_THRESHOLD }
}
```

---
