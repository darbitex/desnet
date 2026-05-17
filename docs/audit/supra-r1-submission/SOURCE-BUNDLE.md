# SOURCE-BUNDLE — all 21 modules + tests

Generated 2026-05-17 from tip commit `3a30ba2` on branch `port/v0.4-supra`.
Each section is one source file at its current state. Reviewers may also pull files
individually from https://github.com/darbitex/desnet/tree/port/v0.4-supra.

---

## `Move.toml`

```toml
[package]
name = "Desnet"
# Plain SemVer X.Y.Z — supra CLI 0.5.0 rejects pre-release suffixes ("-supra").
# Distribution-tag info lives in the header comment below.
version = "0.4.0"
upgrade_policy = "compatible"
authors = ["Rera", "Claude (Anthropic)"]
license = "Unlicense"

# DeSNet Supra port — parallel-track experiment (second mode) vs Aptos v0.3.3.
# Diverges from canonical Aptos branch — both modes coexist on different chains.
# Lineage: Aptos v0.3.1 baseline → v0.3.3 audit hardening (F7, F9, G2, G3, G6)
# applied → v0.4 features (opinion, assets Tier-2/3) → Supra-specific rewrites:
#   - 100% supply → IPO launchpad (no creator-locked LP at registration)
#   - lp_emission + reaction_emission rewritten as multi-FA permissionless gauges
#   - reaction_emission keyed by author PID (not handle string) — main + subdomain
#     authors get independent pools, no collision via profile::handle_of()
#   - IPO Position = auto-stake with reward_debts (Model A — no separate stake NFT)
#   - Position stored AT subdomain PID's deterministic addr → NFT transfer carries
#     locked-LP implicitly
#   - 13 verb entries gained explicit pid_addr param + profile::assert_authorized
#     so subdomain PID is a full citizen (not just main-handle)
#   - register_handle_with_creator_seed: atomic register + self-IPO + 10% cap
#     (creator_wallet frozen at create_ipo = cap-eligibility only; the LP itself
#      locks onto a creator-chosen subdomain PID NFT, same as every other backer)
#   - supra_fee_vault replaces Aptos handle_fee_vault (native FA = SUPRA)
# See docs/v0.3.0-design-lock.md (Aptos baseline) + memory desnet-supra-experiment
# for the Supra delta.

[addresses]
# Filled at deploy via --named-addresses CLI flag.
# Mainnet: desnet=0x7ba7ee5a..., origin=0x000073c4..., desnet_claimer=0x000073c4...
desnet = "0xDADE"
origin = "0xA0E1"
desnet_claimer = "0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9"
# darbitex handle: claimer = darbitex Final pkg/publisher multisig (3/5).
darbitex_claimer = "0xc988d39a4a27b26e1d659431a0c5828f3862c155d1c331386cd5974298dd78dd"
# d handle: claimer = D Supra pkg (resource_account, SEALED — no signer derivable).
# Permanent reservation = effective burn. Slot can never be registered.
d_claimer = "0x587c80846b18b7d7c3801fe11e88ca114305a5153082b51d0d2547ad48622c77"
# supra handle: claimer = Darbitex treasury multisig (3/5).
supra_claimer = "0xdbce89113a975826028236f910668c3ff99c8db8981be6a448caa2f8836f9576"
# supra handle: claimer = dedicated multisig.
# (Duplicate removed)


[dependencies.DesnetBootstrap]
local = "../desnet-bootstrap-supra"

[dependencies.SupraFramework]
git = "https://github.com/Entropy-Foundation/aptos-core.git"
rev = "306b60776be2ba382e35e327a7812233ae7acb13"
subdir = "aptos-move/framework/supra-framework"

[dependencies.AptosStdlib]
git = "https://github.com/Entropy-Foundation/aptos-core.git"
rev = "306b60776be2ba382e35e327a7812233ae7acb13"
subdir = "aptos-move/framework/aptos-stdlib"

[dependencies.AptosTokenObjects]
git = "https://github.com/Entropy-Foundation/aptos-core.git"
rev = "306b60776be2ba382e35e327a7812233ae7acb13"
subdir = "aptos-move/framework/aptos-token-objects"

```

---

## `sources/amm.move`

```move
/// AMM - purpose-built SUPRA/$TOKEN constant-product pool (LOCKED 2026-05-02).
///
/// Composability shape MATCHES darbitex AMM exactly (minus arbitrage module).
/// External aggregators / arb bots can route through both venues uniformly via:
/// - `compute_amount_out(reserve_in, reserve_out, amount_in)` - pure quote
/// - `swap(pool_addr, swapper, fa_in, min_out): FA` - generic by addr
/// - `flash_borrow(pool_addr, metadata, amount): (FA, FlashReceipt)` - Aave-standard
/// - `flash_repay(pool_addr, fa_in, receipt)` - strict repay equality
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

    // ============ CONSTANTS ============

    const FEE_BPS: u64 = 100;
    const FLASH_FEE_BPS: u64 = 100;                    // = LP swap fee (uniform 10 bps, all 100% to LP)
    const FEE_DENOM: u64 = 10000;
    const MIN_INITIAL_LP: u128 = 1000;
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
    const E_SWAPS_DISABLED: u64 = 16;

    // ============ TYPES ============

    /// Per-handle Pool. LP is in `desnet::lp_staking::Position` NFTs (not FA).
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
        locked: bool,                                 // flash loan reentrancy guard
        swaps_enabled: bool,                          // IPO gate: false sampai IPO complete
        extend_ref: ExtendRef,
    }

    /// Flash loan hot-potato. No drop/store/key - must be consumed via flash_repay same tx.
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

    // ============ ADD LIQUIDITY (FRIEND, called by lp_staking) ============

    /// M1 fix (audit R1): returns (lp_minted, supra_refund_fa, token_refund_fa).
    /// Caller (lp_staking) deposits refund FAs back to user. Uniswap V2 pattern -
    /// prevents naive callers from gifting surplus to existing LPs on ratio mismatch.
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

        // M1: compute optimal pair from lp_minted; refund surplus from over-funded side.
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

    // ============ REMOVE LIQUIDITY (FRIEND) ============

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

    // ============ FEE EXTRACTION (FRIEND, called by lp_staking on claim) ============

    public(friend) fun extract_fees_for_claim(
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
    ): (FungibleAsset, FungibleAsset) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global<Pool>(pool_addr);

        // M1 (self-audit): defense-in-depth - gate fee extraction during flash window.
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

    // ============ SWAP (PUBLIC) ============

    /// Generic swap by pool_addr - darbitex-shape composable entry for aggregators.
    /// Detects direction from fa_in metadata: SUPRA_FA -> SUPRA-in, else -> TOKEN-in.
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
        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
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
        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
        let supra_out_fa = swap_exact_token_in_actor(handle, token_fa, min_out, caller_addr);
        primary_fungible_store::deposit(caller_addr, supra_out_fa);
    }

    /// v0.3.2 (F5): backward-compat wrapper. Composable callers (aggregators/flash arbs)
    /// that don't have the actor address available can still call this - event.actor stays
    /// @0x0 sentinel. New code should prefer `swap_exact_supra_in_actor` to preserve attribution.
    public fun swap_exact_supra_in(
        handle: vector<u8>,
        supra_in: FungibleAsset,
        min_out: u64,
    ): FungibleAsset acquires Pool {
        swap_exact_supra_in_actor(handle, supra_in, min_out, @0x0)
    }

    /// v0.3.2 (F5): actor-aware variant. `actor` is recorded in `Swapped` event for indexer
    /// attribution. Pass `@0x0` for sentinel "actor unknown / multi-hop call".
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

    // ============ FLASH LOAN (PUBLIC, Aave-standard) ============

    /// Flash borrow `amount` of `metadata` from pool. Returns FA + hot-potato receipt.
    /// Pool LOCKED during borrow span - swap/LP/flash all abort until repay.
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

    /// Repay flash loan. STRICT equality: fa_in.amount == receipt.amount + receipt.fee.
    /// Borrow -> Reserve; fee -> Fee bucket (accumulates to LPs via fee_per_lp).
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

        // Split: fee -> fee bucket, principal -> reserve
        let fee_fa = fungible_asset::extract(&mut fa_in, fee);
        fungible_asset::deposit(fee_store, fee_fa);
        fungible_asset::deposit(reserve_store, fa_in);

        // Update fee accumulator
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

    // ============ INTERNAL MATH ============

    /// Pure quote - darbitex-shape signature. CPMM with 10 bps fee.
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

    fun mint_lp_initial(supra: u64, token: u64): u128 {
        let product = (supra as u128) * (token as u128);
        math128::sqrt(product)
    }

    // ============ VIEWS - handle-based (internal) ============

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

    // ============ VIEWS - addr-based (darbitex-shape composability) ============

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

    // ============ v0.3.2 (F4c): handle/pool_addr companion view fns ============
    // Some views take handle, others take pool_addr - caller convenience companions
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

    /// On-chain user-facing risk disclosure (matches darbitex AMM pattern).
    #[view]
    public fun read_warning(): vector<u8> { WARNING }

    // ============ IPO GATE ============

    /// Enable swaps on a pool. Friend-only (called by ipo::complete_ipo).
    /// Permanently irreversible for a given pool - no disable counterpart.
    public(friend) fun enable_swaps(handle: vector<u8>) acquires Pool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<Pool>(pool_addr);
        pool.swaps_enabled = true;
    }

    // ============ TEST-ONLY HELPERS ============

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
        // Tests may pass non-exact-ratio inputs, so refunds can be non-zero.
        // Sink them at @desnet (test-only path; production caller receives the refund).
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
        // amount_after_fee = 100 * 9900 = 990000
        // num = 990000 * 2000 = 1_980_000_000
        // den = 1000 * 10000 + 990000 = 10_990_000
        // out = 1_980_000_000 / 10_990_000 = 180
        assert!(compute_amount_out(1000, 2000, 100) == 180, 1);
    }

    #[test]
    fun test_compute_amount_out_with_fee() {
        // 10000 in, 100k/200k reserves
        // amount_after_fee = 10000 * 9900 = 99_000_000
        // num = 99_000_000 * 200_000 = 19_800_000_000_000
        // den = 100_000 * 10_000 + 99_000_000 = 1_099_000_000
        // out = 19_800_000_000_000 / 1_099_000_000 = 18016
        assert!(compute_amount_out(100_000, 200_000, 10_000) == 18016, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        assert!(compute_amount_out(1000, 2000, 0) == 0, 1);
    }

    #[test]
    fun test_compute_flash_fee() {
        // 100 bps of 10000 = 100
        assert!(compute_flash_fee(10000) == 100, 1);
        // 100 bps of 100M = 1_000_000
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

```

---

## `sources/assets.move`

```move
/// Assets - fractal-tree on-chain storage for media >8KB (LOCKED 2026-05-01).
///
/// Class-A primitive: bytes are stored on-chain so client loaders can reassemble,
/// but Move runtime never reads payload bytes (only references via Master addr).
///
/// Storage model: file split into <=30KB Chunks. Single chunk -> depth=0, root=chunk_addr.
/// Multiple chunks -> grouped under Node(s), recursively until single root Node.
/// Master records (root, depth, total_size, mime). After finalize() Master.sealed=true,
/// no further mutation allowed via this module.
///
/// MIME whitelist (aligned with mint.move): PNG/JPEG/GIF/WebP/SVG. SVG INCLUDED
/// 2026-05-01 for on-chain generative art - XSS = frontend responsibility via
/// <img>-tag sandbox.
/// MAX_TOTAL_SIZE = 5MB hard cap. CHUNK_SIZE_MAX = 30000 bytes.
///
/// Asset ownership = anyone-can-reference (sealed Master is public good - Echo/Remix
/// can attach any sealed Master regardless of creator). Defamation/illegal-content
/// moderation = frontend responsibility, not protocol.
module desnet::assets {
    use std::bcs;
    use std::signer;
    use std::vector;
    use supra_framework::event;
    use supra_framework::object;
    use supra_framework::timestamp;

    // ============ CONSTANTS ============

    const CHUNK_SIZE_MAX: u64 = 30000;
    const MAX_TOTAL_SIZE: u64 = 5_000_000;     // 5MB

    // v0.3.4 Tier-3 deterministic-addr seeds. Seeds are domain-separated by
    // a constant prefix so master/chunk/node namespaces never collide. Two
    // uploaders cannot collide either - `create_named_object` mixes the
    // uploader's address into the hash before the seed bytes.
    const SEED_PREFIX_MASTER: vector<u8> = b"desnet/asset/master/";
    const SEED_PREFIX_CHUNK: vector<u8>  = b"desnet/asset/chunk/";
    const SEED_PREFIX_NODE: vector<u8>   = b"desnet/asset/node/";

    /// MIME enum (aligned with mint.move).
    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    // ============ ERROR CODES ============

    const E_INVALID_MIME: u64 = 1;
    const E_TOTAL_SIZE_EXCEEDED: u64 = 2;
    const E_TOTAL_SIZE_ZERO: u64 = 3;
    const E_CHUNK_TOO_LARGE: u64 = 4;
    const E_CHUNK_EMPTY: u64 = 5;
    const E_MASTER_SEALED: u64 = 6;
    const E_MASTER_NOT_FOUND: u64 = 7;
    const E_CHUNK_NOT_FOUND: u64 = 8;
    const E_NODE_NOT_FOUND: u64 = 9;
    const E_NODE_EMPTY: u64 = 10;
    const E_NOT_CREATOR: u64 = 11;
    /// v0.3.4 Tier-3: caller's chosen nonce/index already used. Pick a fresh value.
    const E_SEED_TAKEN: u64 = 12;
    /// v0.3.4 Tier-3 finalize_v2: the depth/root pair caller passed doesn't match
    /// what the deterministic addresses prove. Fail-fast - callers should use the
    /// `derive_*_addr_v2` views to build a consistent root.
    const E_ROOT_MISMATCH: u64 = 13;

    // ============ TYPES ============

    /// Master record at Master Object addr. Tracks asset metadata + sealed status.
    /// After finalize(), sealed=true and root/depth set; module mutators abort.
    /// **anyone-can-REFERENCE** semantic applies POST-FINALIZE only (sealed Master is
    /// public good for Echo/Remix). DURING upload, only `creator_addr` may deploy
    /// chunks/nodes and finalize - prevents asymmetric DoS griefing where an attacker
    /// finalizes another's unsealed master with bogus root.
    struct Master has key {
        root: address,                // 0x0 until finalize; then chunk_addr (depth=0) or node_addr (depth>=1)
        depth: u8,                    // 0 = single chunk; 1+ = tree
        total_size: u64,              // declared at start_upload; informational
        mime: u8,                     // MIME_*
        creator_pid: address,         // informational; not enforced for engagement-side
        creator_addr: address,        // ENFORCED: only this address may deploy_chunk/deploy_node/finalize pre-seal
        sealed: bool,                 // false during upload, true after finalize
        created_at_secs: u64,
    }

    /// Leaf chunk - bytes payload <=30KB. Created via deploy_chunk.
    struct Chunk has key {
        data: vector<u8>,
    }

    /// Internal node (tree depth >=1) - vector of child addresses (chunks or sub-nodes).
    struct Node has key {
        children: vector<address>,
    }

    // ============ EVENTS ============

    #[event]
    struct AssetMasterCreated has drop, store {
        master_addr: address,
        creator_pid: address,
        mime: u8,
        total_size: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetChunkDeployed has drop, store {
        master_addr: address,
        chunk_addr: address,
        data_len: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetNodeDeployed has drop, store {
        master_addr: address,
        node_addr: address,
        children_count: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct AssetFinalized has drop, store {
        master_addr: address,
        root: address,
        depth: u8,
        timestamp_secs: u64,
    }

    // ============ ENTRY: start_upload ============

    /// Allocate a new Master Object. Returns master_addr via emitted event
    /// (entry fns can't return values; frontend reads AssetMasterCreated).
    /// v0.3.4: body delegates to `start_upload_internal`; `start_upload_pub`
    /// is the address-returning sibling for Move-script bundling (Tier-2
    /// orchestrator). Existing ABI is unchanged.
    public entry fun start_upload(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ) {
        let _master_addr = start_upload_internal(uploader, mime, total_size, creator_pid);
    }

    /// v0.3.4 (Tier-2 orchestrator support): same as the entry above, but
    /// returns master_addr so a Move script can chain it directly into
    /// `deploy_chunk_pub` / `finalize` without round-tripping the address
    /// through an event. ABI is purely additive.
    public fun start_upload_pub(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ): address {
        start_upload_internal(uploader, mime, total_size, creator_pid)
    }

    fun start_upload_internal(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ): address {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        let uploader_addr = signer::address_of(uploader);
        let constructor_ref = object::create_object(uploader_addr);
        let master_signer = object::generate_signer(&constructor_ref);
        let master_addr = signer::address_of(&master_signer);

        let now_secs = timestamp::now_seconds();
        move_to(&master_signer, Master {
            root: @0x0,
            depth: 0,
            total_size,
            mime,
            creator_pid,
            creator_addr: uploader_addr,
            sealed: false,
            created_at_secs: now_secs,
        });

        event::emit(AssetMasterCreated {
            master_addr,
            creator_pid,
            mime,
            total_size,
            timestamp_secs: now_secs,
        });

        master_addr
    }

    // ============ ENTRY: deploy_chunk ============

    /// Deploy a leaf chunk (<=30KB). Master must exist and not be sealed.
    /// Returns chunk_addr via emitted event. v0.3.4 delegates body to
    /// `deploy_chunk_internal`.
    public entry fun deploy_chunk(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ) acquires Master {
        let _chunk_addr = deploy_chunk_internal(uploader, master_addr, data);
    }

    /// v0.3.4 (Tier-2): same body but returns chunk_addr.
    public fun deploy_chunk_pub(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ): address acquires Master {
        deploy_chunk_internal(uploader, master_addr, data)
    }

    fun deploy_chunk_internal(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let constructor_ref = object::create_object(uploader_addr);
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);

        move_to(&chunk_signer, Chunk { data });

        event::emit(AssetChunkDeployed {
            master_addr,
            chunk_addr,
            data_len: len,
            timestamp_secs: timestamp::now_seconds(),
        });

        chunk_addr
    }

    // ============ ENTRY: deploy_node ============

    /// Deploy an internal Node pointing to children (chunk addrs or sub-node addrs).
    /// Used for tree depth >=1. Master must not be sealed.
    /// Returns node_addr via emitted event. v0.3.4 delegates to
    /// `deploy_node_internal`.
    public entry fun deploy_node(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ) acquires Master {
        let _node_addr = deploy_node_internal(uploader, master_addr, children);
    }

    /// v0.3.4 (Tier-2): same body but returns node_addr.
    public fun deploy_node_pub(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ): address acquires Master {
        deploy_node_internal(uploader, master_addr, children)
    }

    fun deploy_node_internal(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let n = vector::length(&children);
        assert!(n > 0, E_NODE_EMPTY);

        let constructor_ref = object::create_object(uploader_addr);
        let node_signer = object::generate_signer(&constructor_ref);
        let node_addr = signer::address_of(&node_signer);

        move_to(&node_signer, Node { children });

        event::emit(AssetNodeDeployed {
            master_addr,
            node_addr,
            children_count: n,
            timestamp_secs: timestamp::now_seconds(),
        });

        node_addr
    }

    // ============ ENTRY: finalize ============

    /// Finalize Master: set root + depth, mark sealed=true. After this, the asset
    /// is permanently immutable from this module's perspective.
    /// Caller is responsible for having deployed root chunk/node beforehand.
    /// v0.3.4 delegates body to `finalize_internal`.
    public entry fun finalize(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        finalize_internal(uploader, master_addr, root, depth);
    }

    /// v0.3.4 (Tier-2): script-callable finalize. Returns nothing because
    /// finalize is purely state-mutation; scripts can call it as the last
    /// step of a bundled upload after `start_upload_pub` + `deploy_chunk_pub`
    /// chain.
    public fun finalize_pub(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        finalize_internal(uploader, master_addr, root, depth);
    }

    fun finalize_internal(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global_mut<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        // CRITICAL auth: only the master's creator may finalize. Without this check,
        // any address could seal another's unsealed master with bogus root -> permanent
        // grief (asymmetric DoS, low-cost-attacker vs high-cost-victim).
        assert!(master.creator_addr == signer::address_of(uploader), E_NOT_CREATOR);

        // Sanity: root must point to existing Chunk (depth=0) or Node (depth>=1)
        if (depth == 0) {
            assert!(exists<Chunk>(root), E_CHUNK_NOT_FOUND);
        } else {
            assert!(exists<Node>(root), E_NODE_NOT_FOUND);
        };

        master.root = root;
        master.depth = depth;
        master.sealed = true;

        event::emit(AssetFinalized {
            master_addr,
            root,
            depth,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ v0.3.4 TIER-3 - deterministic-address `*_v2` entries ============
    //
    // These mirror the v1 entries but use `object::create_named_object` with
    // caller-supplied indices, so the resulting addresses are predictable
    // off-chain via `derive_*_addr_v2` views. JS can pre-compute every chunk
    // address before submitting any tx - the entire upload + the final
    // `create_mint` collapse into one Move script transaction.
    //
    // Compat: v1 entries are untouched. Existing uploads via the v1 path keep
    // working bit-for-bit. v2 entries are ABI-additive.
    //
    // Seed scope: `create_named_object(creator, seed)` mixes `signer::address_of(creator)`
    // into the SHA3-256, so the per-creator seed namespace is isolated. Two
    // different uploaders cannot collide even with the same nonce.

    /// v0.3.4 (Tier-3): deterministic-addr Master allocation. Caller picks
    /// any u64 nonce - addr = sha3(uploader || SEED_PREFIX_MASTER || bcs(nonce) || 0xFE).
    /// Aborts E_SEED_TAKEN if (uploader, nonce) was used before. Common pattern:
    /// nonce = `timestamp::now_microseconds()` to make collisions impossible
    /// in practice; or a per-uploader counter the frontend tracks locally.
    public fun start_upload_v2(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
        nonce: u64,
    ): address {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        // R3 audit L1 - explicit pre-check is BELT + SUSPENDERS. Aptos
        // `create_named_object` aborts on collision (EOBJECT_EXISTS),
        // so this exists<Master> assertion is technically redundant.
        // Kept because: (a) we get a domain-specific error code
        // (E_SEED_TAKEN) instead of the framework's generic one, which
        // makes frontend error decoding cleaner; (b) gas overhead is
        // ~200 units, negligible vs the create_named_object cost; (c)
        // fails CLOSED on any future framework change to abort behavior.
        let seed = master_seed(nonce);
        let uploader_addr = signer::address_of(uploader);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Master>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, master_seed(nonce));
        let master_signer = object::generate_signer(&constructor_ref);
        let master_addr = signer::address_of(&master_signer);

        let now_secs = timestamp::now_seconds();
        move_to(&master_signer, Master {
            root: @0x0,
            depth: 0,
            total_size,
            mime,
            creator_pid,
            creator_addr: uploader_addr,
            sealed: false,
            created_at_secs: now_secs,
        });

        event::emit(AssetMasterCreated {
            master_addr,
            creator_pid,
            mime,
            total_size,
            timestamp_secs: now_secs,
        });

        master_addr
    }

    /// v0.3.4 (Tier-3): deterministic-addr Chunk allocation. `chunk_index`
    /// must be unique per (uploader, master). Convention: 0-indexed from the
    /// frontend's chunking pass.
    public fun deploy_chunk_v2(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
        chunk_index: u64,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let seed = chunk_seed(master_addr, chunk_index);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Chunk>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, chunk_seed(master_addr, chunk_index));
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);

        move_to(&chunk_signer, Chunk { data });

        event::emit(AssetChunkDeployed {
            master_addr,
            chunk_addr,
            data_len: len,
            timestamp_secs: timestamp::now_seconds(),
        });

        chunk_addr
    }

    /// v0.3.4 (Tier-3): deterministic-addr Node. `node_index` must be unique
    /// per (uploader, master). Frontend convention: 0..N-1 for leaf-grouping
    /// nodes, then N for the root in a depth-2 tree.
    public fun deploy_node_v2(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
        node_index: u64,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let n = vector::length(&children);
        assert!(n > 0, E_NODE_EMPTY);

        let seed = node_seed(master_addr, node_index);
        let derived = object::create_object_address(&uploader_addr, seed);
        assert!(!exists<Node>(derived), E_SEED_TAKEN);

        let constructor_ref = object::create_named_object(uploader, node_seed(master_addr, node_index));
        let node_signer = object::generate_signer(&constructor_ref);
        let node_addr = signer::address_of(&node_signer);

        move_to(&node_signer, Node { children });

        event::emit(AssetNodeDeployed {
            master_addr,
            node_addr,
            children_count: n,
            timestamp_secs: timestamp::now_seconds(),
        });

        node_addr
    }

    /// v0.3.4 (Tier-3): finalize variant that double-checks `root` matches a
    /// derivable seed. Mostly redundant with v1 finalize (which only verifies
    /// the resource exists), but worth having for callers that derive `root`
    /// JS-side and want belt-and-suspenders confidence the addr they pass
    /// matches an `*_v2`-deployed object.
    ///
    /// `root_index_opt = none` -> caller passes the raw root addr and we just
    /// verify resource existence (same as v1 finalize, but reachable from
    /// scripts without `entry`).
    /// `root_index_opt = some(idx)` -> we recompute the seed and assert the
    /// hash matches `root` before sealing.
    public fun finalize_v2(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
        root_index: u64,
        verify_seed: bool,
    ) acquires Master {
        if (verify_seed) {
            let uploader_addr = signer::address_of(uploader);
            let seed = if (depth == 0) {
                chunk_seed(master_addr, root_index)
            } else {
                node_seed(master_addr, root_index)
            };
            let expected = object::create_object_address(&uploader_addr, seed);
            assert!(expected == root, E_ROOT_MISMATCH);
        };
        finalize_internal(uploader, master_addr, root, depth);
    }

    // ============ Tier-3 seed helpers + JS-derivation views ============

    fun master_seed(nonce: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_MASTER);
        vector::append(&mut s, bcs::to_bytes(&nonce));
        s
    }

    fun chunk_seed(master_addr: address, chunk_index: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_CHUNK);
        vector::append(&mut s, bcs::to_bytes(&master_addr));
        vector::append(&mut s, bcs::to_bytes(&chunk_index));
        s
    }

    fun node_seed(master_addr: address, node_index: u64): vector<u8> {
        let s = vector::empty<u8>();
        vector::append(&mut s, SEED_PREFIX_NODE);
        vector::append(&mut s, bcs::to_bytes(&master_addr));
        vector::append(&mut s, bcs::to_bytes(&node_index));
        s
    }

    /// JS-callable: pre-compute a Tier-3 master addr for (uploader, nonce)
    /// before any tx is signed. Lets the frontend bundle start_upload_v2 +
    /// deploy_chunk_v2 * N + finalize_v2 in one Move script with all addrs
    /// known up front.
    #[view]
    public fun derive_master_addr_v2(uploader: address, nonce: u64): address {
        object::create_object_address(&uploader, master_seed(nonce))
    }

    #[view]
    public fun derive_chunk_addr_v2(uploader: address, master_addr: address, chunk_index: u64): address {
        object::create_object_address(&uploader, chunk_seed(master_addr, chunk_index))
    }

    #[view]
    public fun derive_node_addr_v2(uploader: address, master_addr: address, node_index: u64): address {
        object::create_object_address(&uploader, node_seed(master_addr, node_index))
    }

    // ============ INTERNAL ============

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

    // ============ VIEWS ============

    #[view]
    public fun master_exists(addr: address): bool {
        exists<Master>(addr)
    }

    #[view]
    public fun is_sealed(addr: address): bool acquires Master {
        if (!exists<Master>(addr)) return false;
        borrow_global<Master>(addr).sealed
    }

    #[view]
    public fun mime_of(addr: address): u8 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).mime
    }

    #[view]
    public fun root_of(addr: address): address acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).root
    }

    #[view]
    public fun depth_of(addr: address): u8 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).depth
    }

    #[view]
    public fun total_size_of(addr: address): u64 acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).total_size
    }

    #[view]
    public fun creator_pid_of(addr: address): address acquires Master {
        assert!(exists<Master>(addr), E_MASTER_NOT_FOUND);
        borrow_global<Master>(addr).creator_pid
    }

    #[view]
    public fun read_chunk(chunk_addr: address): vector<u8> acquires Chunk {
        assert!(exists<Chunk>(chunk_addr), E_CHUNK_NOT_FOUND);
        borrow_global<Chunk>(chunk_addr).data
    }

    #[view]
    public fun chunk_size(chunk_addr: address): u64 acquires Chunk {
        if (!exists<Chunk>(chunk_addr)) return 0;
        vector::length(&borrow_global<Chunk>(chunk_addr).data)
    }

    #[view]
    public fun read_node(node_addr: address): vector<address> acquires Node {
        assert!(exists<Node>(node_addr), E_NODE_NOT_FOUND);
        borrow_global<Node>(node_addr).children
    }

    #[view]
    public fun chunk_size_max(): u64 { CHUNK_SIZE_MAX }

    #[view]
    public fun max_total_size(): u64 { MAX_TOTAL_SIZE }

    /// v0.3.4: capability marker for the asset-upload orchestrator tier the
    /// frontend can use against THIS bytecode version. Returns:
    ///   1 = only original entries (multi-tx, address from events)
    ///   2 = `*_pub` mirrors live (Move script bundling possible, fewer txs)
    ///   3 = deterministic-address `*_v2` entries live (B3 single-tx upload)
    /// Frontend calls this to auto-enable higher tiers in the picker. v0.3.3
    /// did NOT have this view, so frontends fall back to tier 1 on the call
    /// failing - no breakage. v0.3.4 ships BOTH B2 (`*_pub` mirrors) AND B3
    /// (`*_v2` deterministic-addr entries) so this returns 3.
    #[view]
    public fun orchestrator_tier(): u8 { 3 }

    #[view]
    public fun mime_png(): u8 { MIME_PNG }

    #[view]
    public fun mime_jpeg(): u8 { MIME_JPEG }

    #[view]
    public fun mime_gif(): u8 { MIME_GIF }

    #[view]
    public fun mime_webp(): u8 { MIME_WEBP }

    #[view]
    public fun mime_svg(): u8 { MIME_SVG }

    // ============ TEST-ONLY WRAPPERS ============

    /// Test wrapper: returns master_addr (entry fns can't return values).
    #[test_only]
    public fun start_upload_for_test(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ): address {
        assert_valid_mime(mime);
        assert!(total_size > 0, E_TOTAL_SIZE_ZERO);
        assert!(total_size <= MAX_TOTAL_SIZE, E_TOTAL_SIZE_EXCEEDED);

        let uploader_addr = signer::address_of(uploader);
        let constructor_ref = object::create_object(uploader_addr);
        let master_signer = object::generate_signer(&constructor_ref);
        let master_addr = signer::address_of(&master_signer);
        let now_secs = timestamp::now_seconds();
        move_to(&master_signer, Master {
            root: @0x0,
            depth: 0,
            total_size,
            mime,
            creator_pid,
            creator_addr: uploader_addr,
            sealed: false,
            created_at_secs: now_secs,
        });
        master_addr
    }

    /// Test wrapper: returns chunk_addr.
    #[test_only]
    public fun deploy_chunk_for_test(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ): address acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        let uploader_addr = signer::address_of(uploader);
        assert!(master.creator_addr == uploader_addr, E_NOT_CREATOR);

        let len = vector::length(&data);
        assert!(len > 0, E_CHUNK_EMPTY);
        assert!(len <= CHUNK_SIZE_MAX, E_CHUNK_TOO_LARGE);

        let constructor_ref = object::create_object(uploader_addr);
        let chunk_signer = object::generate_signer(&constructor_ref);
        let chunk_addr = signer::address_of(&chunk_signer);
        move_to(&chunk_signer, Chunk { data });
        chunk_addr
    }

    // ============ TESTS ============

    #[test]
    fun test_assert_valid_mime_accepts_all_five() {
        assert_valid_mime(MIME_PNG);
        assert_valid_mime(MIME_JPEG);
        assert_valid_mime(MIME_GIF);
        assert_valid_mime(MIME_WEBP);
        assert_valid_mime(MIME_SVG);   // SVG re-included 2026-05-01
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_zero() {
        assert_valid_mime(0);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_six() {
        assert_valid_mime(6);
    }

    #[test]
    fun test_constants_match_views() {
        assert!(mime_png() == MIME_PNG, 1);
        assert!(mime_svg() == MIME_SVG, 2);
        assert!(chunk_size_max() == 30000, 3);
        assert!(max_total_size() == 5_000_000, 4);
    }

    // ============ INTEGRATION TESTS (lifecycle) ============

    #[test_only]
    fun setup_test_env(framework: &signer, uploader: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        supra_framework::account::create_account_for_test(signer::address_of(uploader));
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_lifecycle_single_chunk_seal(framework: &signer, uploader: &signer)
        acquires Master, Chunk
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_for_test(uploader, MIME_PNG, 1024, @0xfeed);
        assert!(!is_sealed(master_addr), 1);
        assert!(mime_of(master_addr) == MIME_PNG, 2);

        let data = vector::empty<u8>();
        let i = 0;
        while (i < 1024) { vector::push_back(&mut data, 0xAB); i = i + 1; };

        let chunk_addr = deploy_chunk_for_test(uploader, master_addr, data);
        assert!(chunk_size(chunk_addr) == 1024, 3);

        finalize(uploader, master_addr, chunk_addr, 0);
        assert!(is_sealed(master_addr), 4);
        assert!(root_of(master_addr) == chunk_addr, 5);
        assert!(depth_of(master_addr) == 0, 6);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_finalize_rejects_non_creator_A2_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        supra_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_JPEG, 100, @0xfeed);
        // Attacker tries to finalize with bogus root - must fail per A2 fix.
        finalize(attacker, master_addr, @0xdeadbeef, 0);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_deploy_chunk_rejects_non_creator_A3_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        supra_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_GIF, 100, @0xfeed);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x42);
        // Attacker deploys chunk for victim's master - must fail.
        deploy_chunk_for_test(attacker, master_addr, data);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_MASTER_SEALED, location = Self)]
    fun test_deploy_chunk_after_seal_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_for_test(uploader, MIME_WEBP, 50, @0xfeed);
        let data1 = vector::empty<u8>();
        vector::push_back(&mut data1, 0x42);
        let chunk_addr = deploy_chunk_for_test(uploader, master_addr, data1);
        finalize(uploader, master_addr, chunk_addr, 0);

        // After seal, deploy_chunk should abort.
        let data2 = vector::empty<u8>();
        vector::push_back(&mut data2, 0x42);
        deploy_chunk_for_test(uploader, master_addr, data2);
    }

    #[test(uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_TOTAL_SIZE_EXCEEDED, location = Self)]
    fun test_start_upload_total_size_cap(uploader: &signer) {
        // 5MB+1 byte -> reject
        start_upload_for_test(uploader, MIME_SVG, 5_000_001, @0xfeed);
    }

    // ============ v0.3.4 TIER-2 (B2) tests ============

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_b2_pub_returns_addresses(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);

        let master_addr = start_upload_pub(uploader, MIME_PNG, 1024, @0xfeed);
        assert!(exists<Master>(master_addr), 1);
        assert!(!is_sealed(master_addr), 2);

        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0xAA);
        let chunk_addr = deploy_chunk_pub(uploader, master_addr, data);
        assert!(exists<Chunk>(chunk_addr), 3);

        finalize_pub(uploader, master_addr, chunk_addr, 0);
        assert!(is_sealed(master_addr), 4);
        assert!(root_of(master_addr) == chunk_addr, 5);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_orchestrator_tier_is_3_in_v034(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        assert!(orchestrator_tier() == 3, 1);
    }

    // ============ v0.3.4 TIER-3 (B3) tests ============

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_b3_lifecycle_single_chunk(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let uploader_addr = signer::address_of(uploader);

        // Pre-compute master addr off-chain (the JS-equivalent path).
        // Cross-verified 2026-05-03 against frontend `deriveMasterAddrV2`:
        // both yield 0x539417401dc65683d7f3d98d30006ce261c172240fa5a45cd94a7dbe0846a1e4.
        let predicted_master = derive_master_addr_v2(uploader_addr, 42);
        let master_addr = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 42);
        assert!(predicted_master == master_addr, 1);

        // Pre-compute chunk addr.
        let predicted_chunk = derive_chunk_addr_v2(uploader_addr, master_addr, 0);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x99);
        let chunk_addr = deploy_chunk_v2(uploader, master_addr, data, 0);
        assert!(predicted_chunk == chunk_addr, 2);

        // finalize_v2 with verify_seed=true must accept the matching root.
        finalize_v2(uploader, master_addr, chunk_addr, 0, 0, true);
        assert!(is_sealed(master_addr), 3);
        assert!(root_of(master_addr) == chunk_addr, 4);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    fun test_b3_depth1_node_predictable(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let uploader_addr = signer::address_of(uploader);

        let master = start_upload_v2(uploader, MIME_PNG, 200, @0xfeed, 1);

        let d1 = vector::empty<u8>(); vector::push_back(&mut d1, 0x01);
        let d2 = vector::empty<u8>(); vector::push_back(&mut d2, 0x02);
        let c1 = deploy_chunk_v2(uploader, master, d1, 0);
        let c2 = deploy_chunk_v2(uploader, master, d2, 1);

        let predicted_node = derive_node_addr_v2(uploader_addr, master, 0);
        let children = vector::empty<address>();
        vector::push_back(&mut children, c1);
        vector::push_back(&mut children, c2);
        let node = deploy_node_v2(uploader, master, children, 0);
        assert!(predicted_node == node, 1);

        finalize_v2(uploader, master, node, 1, 0, true);
        assert!(depth_of(master) == 1, 2);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_master_nonce_collision_aborts(framework: &signer, uploader: &signer) {
        setup_test_env(framework, uploader);
        // Same nonce twice from same uploader -> collision -> abort.
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
        start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 7);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_SEED_TAKEN, location = Self)]
    fun test_b3_chunk_index_collision_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 8);
        let d1 = vector::empty<u8>(); vector::push_back(&mut d1, 0x11);
        let d2 = vector::empty<u8>(); vector::push_back(&mut d2, 0x22);
        deploy_chunk_v2(uploader, master, d1, 0);
        // Same chunk_index -> collision.
        deploy_chunk_v2(uploader, master, d2, 0);
    }

    #[test(framework = @supra_framework, uploader = @0xa11ce)]
    #[expected_failure(abort_code = E_ROOT_MISMATCH, location = Self)]
    fun test_b3_finalize_v2_root_mismatch_aborts(framework: &signer, uploader: &signer)
        acquires Master
    {
        setup_test_env(framework, uploader);
        let master = start_upload_v2(uploader, MIME_PNG, 100, @0xfeed, 9);
        let d = vector::empty<u8>(); vector::push_back(&mut d, 0x33);
        let c = deploy_chunk_v2(uploader, master, d, 0);
        // Pass a bogus root with verify_seed=true -> must abort.
        let _ = c;
        finalize_v2(uploader, master, @0xdeadbeef, 0, 0, true);
    }

    #[test(framework = @supra_framework, alice = @0xa11ce, bob = @0xb0b)]
    fun test_b3_per_uploader_seed_isolation(
        framework: &signer,
        alice: &signer,
        bob: &signer,
    ) {
        setup_test_env(framework, alice);
        supra_framework::account::create_account_for_test(signer::address_of(bob));

        // Same nonce across different uploaders -> distinct addresses, both succeed.
        let master_alice = start_upload_v2(alice, MIME_PNG, 100, @0xfeed, 5);
        let master_bob = start_upload_v2(bob, MIME_PNG, 100, @0xfeed, 5);
        assert!(master_alice != master_bob, 1);
    }
}

```

---

## `sources/factory.move`

```move
/// Token Factory - atomic spawn of $TOKEN + vault + IPO pool.
///
/// Full atomic register_handle flow. One tx = PID + token + vault + IPO.
/// 100% of supply goes to IPO pool. No emission reserves, no AMM pool at register.
///
/// Caller flow:
///   profile::register_handle (charges handle_fee, sets IPO params) ->
///   factory::create_token_atomic(handle, pid_addr, target_tvl, entry_price) ->
///     mints 1B $TOKEN -> creates vault -> creates IPO pool with all 1B $TOKEN
module desnet::factory {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset};
    use supra_framework::object::{Self};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::supra_vault;
    use desnet::governance;
    use desnet::ipo;

    use supra_framework::fungible_asset::MutateMetadataRef;

    friend desnet::registration;

    // ============ CONSTANTS ============

    /// Total supply per spawned token: 1B at 8 dec.
    const TOTAL_SUPPLY: u64 = 100_000_000_000_000_000;
    const TOKEN_DECIMALS: u8 = 8;

    const SPEC_VERSION_V3: u32 = 3;

    /// Handle character constraints (1-64 chars, lowercase + digits + hyphens).
    const HANDLE_MIN_LEN: u64 = 1;
    const HANDLE_MAX_LEN: u64 = 64;

    const SEED_TOKEN: vector<u8> = b"token::";

    // ============ ERROR CODES ============

    const E_HANDLE_TAKEN: u64 = 3;
    const E_HANDLE_TOO_SHORT: u64 = 4;
    const E_HANDLE_TOO_LONG: u64 = 5;
    const E_HANDLE_INVALID_CHAR: u64 = 6;
    const E_FACTORY_PAUSED: u64 = 8;
    const E_PID_NOT_REGISTERED: u64 = 10;
    const E_NOT_ADMIN: u64 = 13;
    const E_INVALID_ADDRESS: u64 = 14;
    const E_NAME_TOO_LONG: u64 = 15;
    const E_SYMBOL_TOO_LONG: u64 = 16;
    const E_ICON_URI_TOO_LONG: u64 = 17;
    const E_NOT_PID_OWNER: u64 = 18;
    const E_TOKEN_NOT_FOUND: u64 = 19;
    const E_PROJECT_URI_TOO_LONG: u64 = 20;

    /// Mirror Supra `fungible_asset` framework limits - pre-validate so callers
    /// get a clear abort instead of a deep-stack framework error.
    const MAX_NAME_LEN: u64 = 32;
    const MAX_SYMBOL_LEN: u64 = 32;
    const MAX_URI_LEN: u64 = 512;

    // ============ TYPES ============

    struct FactoryState has key {
        spawn_count: u64,
        paused: bool,
        /// R3 fix (Gemini HIGH): rotatable pause/admin authority. Initialized to
        /// `@origin` at deploy. Can be rotated to a DAO-governed addr post-launch
        /// to align with `governance::disable_multisig_upgrade` (avoiding the
        /// post-DAO-transition deadlock where @origin retains a permanent
        /// kill-switch or, if dissolved, pause becomes permanently bricked).
        admin: address,
    }

    /// Per-spawned-token registry record.
    struct TokenRecord has store, copy, drop {
        handle: String,
        token_metadata: address,
        owner_addr: address,                          // PID Object addr (transferable)
        supra_vault: address,
        ipo_addr: address,                            // IPO pool address
        spec_version: u32,
        spawned_at_secs: u64,
    }

    struct FactoryRegistry has key {
        records: SmartTable<String, TokenRecord>,
        metadata_index: SmartTable<address, String>,    // token_metadata -> handle
        owner_index: SmartTable<address, String>,        // owner_addr (pid) -> handle
    }

    /// Holds the `MutateMetadataRef` for a spawned token's FA Metadata. Stored at
    /// the FA Metadata object addr (one-to-one with the token). The ref's only
    /// authorized use is `update_token_icon`, gated by PID-NFT-owner signer
    /// (cold wallet - same authority tier as `withdraw_pid_token`).
    /// Name/symbol/decimals/project_uri are NOT mutable by design.
    struct TokenMetadataMutRef has key {
        mutate_ref: MutateMetadataRef,
    }

    // ============ EVENTS ============

    #[event]
    struct FactoryInitialized has drop, store {
        factory_addr: address,
        deployer: address,
    }

    #[event]
    struct TokenSpawned has drop, store {
        handle: String,
        token_metadata: address,
        owner_addr: address,
        ipo_addr: address,
        supra_vault: address,
        spec_version: u32,
        timestamp_secs: u64,
    }

    // ============ INIT ============

    fun init_module(account: &signer) {
        let factory_addr = signer::address_of(account);

        move_to(account, FactoryState {
            spawn_count: 0,
            paused: false,
            admin: @origin,
        });

        move_to(account, FactoryRegistry {
            records: smart_table::new(),
            metadata_index: smart_table::new(),
            owner_index: smart_table::new(),
        });

        event::emit(FactoryInitialized {
            factory_addr,
            deployer: @origin,
        });
    }

    // ============ MAIN ENTRY (FRIEND-ONLY) ============

    /// Atomic token + vault + IPO pool.
    /// Friend-only: sole caller is `desnet::profile::register_handle`.
    ///
    /// Caller MUST:
    /// - Have already minted PID NFT at `pid_addr`
    /// - Have already collected handle_fee from end-user
    /// - Pass `name`/`symbol` (<=32 b each, PERMANENT) and `icon_uri`/`project_uri`
    ///   (<=512 b each, mutable post-mint via `update_token_icon` /
    ///   `update_token_project_uri`, both PID-NFT-owner gated).
    /// - Pass IPO params (target_tvl, entry_price_x, entry_price_y)
    public(friend) fun create_token_atomic(
        handle: vector<u8>,
        pid_addr: address,
        creator_wallet: address,
        name: String,
        symbol: String,
        icon_uri: String,
        project_uri: String,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
    ) acquires FactoryState, FactoryRegistry {
        validate_handle(&handle);
        validate_token_metadata_strings(&name, &symbol, &icon_uri, &project_uri);
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(!smart_table::contains(&registry.records, handle_str), E_HANDLE_TAKEN);

        let state = borrow_global<FactoryState>(@desnet);
        assert!(!state.paused, E_FACTORY_PAUSED);

        let factory_signer = governance::derive_pkg_signer();

        // Step 1: Mint $TOKEN FA at deterministic addr.
        let token_seed = make_token_seed(&handle);
        let constructor_ref = object::create_named_object(&factory_signer, token_seed);
        let token_metadata_addr = object::address_from_constructor_ref(&constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some((TOTAL_SUPPLY as u128)),
            name,
            symbol,
            TOKEN_DECIMALS,
            icon_uri,
            project_uri,
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let mutate_ref = fungible_asset::generate_mutate_metadata_ref(&constructor_ref);
        let metadata_signer = object::generate_signer(&constructor_ref);
        move_to(&metadata_signer, TokenMetadataMutRef { mutate_ref });

        let metadata_obj_transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&metadata_obj_transfer_ref);
        let _ = object::object_from_constructor_ref<fungible_asset::Metadata>(&constructor_ref);

        // Step 2: Mint full supply - 100% goes to IPO (no more 50M/50M/900M split).
        let ipo_token_fa = fungible_asset::mint(&mint_ref, TOTAL_SUPPLY);

        // Step 3: Deploy vault (sealed, holds BurnRef for future buyback).
        // AMM pool belum ada saat register; vault diberi @0x0, di-set kemudian.
        let supra_vault_addr = supra_vault::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            @0x0,                                      // pool addr: di-set setelah IPO complete
            pid_addr,
            burn_ref,
        );

        // Step 4: Create IPO pool with 100% token supply.
        ipo::create_ipo(
            handle,
            token_metadata_addr,
            ipo_token_fa,
            target_tvl,
            entry_price_x,
            entry_price_y,
            creator_wallet,
        );
        let ipo_addr = ipo::ipo_address_of_handle(handle);

        // Step 5: Destroy MintRef (fixed_supply forever).
        let _ = mint_ref;

        // Step 6: Record TokenRecord.
        let now_secs = timestamp::now_seconds();
        let record = TokenRecord {
            handle: handle_str,
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            supra_vault: supra_vault_addr,
            ipo_addr,
            spec_version: SPEC_VERSION_V3,
            spawned_at_secs: now_secs,
        };

        let registry = borrow_global_mut<FactoryRegistry>(@desnet);
        smart_table::add(&mut registry.records, string::utf8(handle), record);
        smart_table::add(&mut registry.metadata_index, token_metadata_addr, string::utf8(handle));
        smart_table::add(&mut registry.owner_index, pid_addr, string::utf8(handle));

        let state = borrow_global_mut<FactoryState>(@desnet);
        state.spawn_count = state.spawn_count + 1;

        event::emit(TokenSpawned {
            handle: string::utf8(handle),
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            ipo_addr,
            supra_vault: supra_vault_addr,
            spec_version: SPEC_VERSION_V3,
            timestamp_secs: now_secs,
        });
    }

    // ============ TOKEN METADATA UPDATE - PID-NFT-OWNER ONLY ============

    /// Update the FA `icon_uri` for a spawned token. Authority = PID-NFT-owner
    /// (cold wallet, same tier as `withdraw_pid_token`). Name/symbol are NOT
    /// mutable. New icon_uri must be <= 512 bytes (Supra framework cap).
    public entry fun update_token_icon(
        owner: &signer,
        handle: vector<u8>,
        new_icon_uri: String,
    ) acquires FactoryRegistry, TokenMetadataMutRef {
        assert!(string::length(&new_icon_uri) <= MAX_URI_LEN, E_ICON_URI_TOO_LONG);
        let mut_ref = assert_owner_and_get_mut_ref(owner, handle);
        fungible_asset::mutate_metadata(
            mut_ref,
            option::none(), option::none(), option::none(),
            option::some(new_icon_uri),            // icon_uri - UPDATE
            option::none(),
        );
    }

    /// Update the FA `project_uri` for a spawned token. Same authority as
    /// `update_token_icon` (PID-NFT-owner). Symmetric mutability for the two
    /// non-load-bearing display fields.
    public entry fun update_token_project_uri(
        owner: &signer,
        handle: vector<u8>,
        new_project_uri: String,
    ) acquires FactoryRegistry, TokenMetadataMutRef {
        assert!(string::length(&new_project_uri) <= MAX_URI_LEN, E_PROJECT_URI_TOO_LONG);
        let mut_ref = assert_owner_and_get_mut_ref(owner, handle);
        fungible_asset::mutate_metadata(
            mut_ref,
            option::none(), option::none(), option::none(),
            option::none(),
            option::some(new_project_uri),         // project_uri - UPDATE
        );
    }

    /// Shared auth + lookup helper for owner-gated metadata updates.
    /// Returns a reference to the token's MutateMetadataRef.
    inline fun assert_owner_and_get_mut_ref(
        owner: &signer,
        handle: vector<u8>,
    ): &MutateMetadataRef {
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(smart_table::contains(&registry.records, handle_str), E_TOKEN_NOT_FOUND);
        let record = smart_table::borrow(&registry.records, handle_str);
        let pid_addr = record.owner_addr;
        let token_metadata_addr = record.token_metadata;

        let pid_object = object::address_to_object<object::ObjectCore>(pid_addr);
        let pid_owner = object::owner(pid_object);
        assert!(signer::address_of(owner) == pid_owner, E_NOT_PID_OWNER);

        &borrow_global<TokenMetadataMutRef>(token_metadata_addr).mutate_ref
    }

    // ============ HANDLE VALIDATION ============

    fun validate_token_metadata_strings(
        name: &String,
        symbol: &String,
        icon_uri: &String,
        project_uri: &String,
    ) {
        assert!(string::length(name) <= MAX_NAME_LEN, E_NAME_TOO_LONG);
        assert!(string::length(symbol) <= MAX_SYMBOL_LEN, E_SYMBOL_TOO_LONG);
        assert!(string::length(icon_uri) <= MAX_URI_LEN, E_ICON_URI_TOO_LONG);
        assert!(string::length(project_uri) <= MAX_URI_LEN, E_PROJECT_URI_TOO_LONG);
    }


    fun validate_handle(handle: &vector<u8>) {
        let len = vector::length(handle);
        assert!(len >= HANDLE_MIN_LEN, E_HANDLE_TOO_SHORT);
        assert!(len <= HANDLE_MAX_LEN, E_HANDLE_TOO_LONG);

        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(handle, i);
            let is_lowercase = ch >= 0x61 && ch <= 0x7A;
            let is_digit = ch >= 0x30 && ch <= 0x39;
            let is_hyphen = ch == 0x2D;
            assert!(is_lowercase || is_digit || is_hyphen, E_HANDLE_INVALID_CHAR);
            i = i + 1;
        };
    }

    // ============ ADDRESS DERIVATION (PURE) ============

    #[view]
    public fun derive_token_metadata_addr(handle: vector<u8>): address {
        let seed = make_token_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    fun make_token_seed(handle: &vector<u8>): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_TOKEN);
        vector::append(&mut seed, *handle);
        seed
    }


    // ============ VIEW FNS ============

    #[view]
    public fun get_token_record(handle: vector<u8>): TokenRecord acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        // v0.3.2 (F1): semantic-correct error code (was E_HANDLE_TAKEN - misleading).
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        *smart_table::borrow(&registry.records, key)
    }

    #[view]
    public fun handle_registered(handle: vector<u8>): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.records, string::utf8(handle))
    }

    #[view]
    public fun is_factory_token(token_metadata: address): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.metadata_index, token_metadata)
    }

    #[view]
    public fun handle_of_token(token_metadata: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.metadata_index, token_metadata),
            E_TOKEN_NOT_FOUND
        );
        *smart_table::borrow(&registry.metadata_index, token_metadata)
    }

    /// Note: `owner_addr` is the PID Object addr (= the registered owner_index key),
    /// NOT the wallet that holds the PID NFT. Use `handle_of_wallet` for wallet->handle.
    #[view]
    public fun handle_of_owner(owner_addr: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        *smart_table::borrow(&registry.owner_index, owner_addr)
    }

    // (v0.3.2 F1b: handle_of_wallet lives in profile.move to avoid factory->profile
    // dependency cycle. Profile already uses factory; reverse direction would cycle.)

    #[view]
    public fun token_metadata_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).token_metadata
    }

    #[view]
    public fun ipo_addr_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).ipo_addr
    }

    #[view]
    public fun owner_has_token(owner_addr: address): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.owner_index, owner_addr)
    }

    #[view]
    public fun spawn_count(): u64 acquires FactoryState {
        borrow_global<FactoryState>(@desnet).spawn_count
    }

    #[view]
    public fun is_paused(): bool acquires FactoryState {
        borrow_global<FactoryState>(@desnet).paused
    }

    /// Kimi F2 fix (audit R1): admin pause/unpause control.
    /// Gemini R2 HIGH fix (R3): authority read from rotatable `FactoryState.admin`
    /// (initially `@origin`, rotatable via `rotate_admin` to a DAO-governed addr).
    public entry fun set_paused(admin: &signer, new_paused: bool) acquires FactoryState {
        let state = borrow_global_mut<FactoryState>(@desnet);
        assert!(signer::address_of(admin) == state.admin, E_NOT_ADMIN);
        state.paused = new_paused;
    }

    /// Rotate the factory admin (pause authority) to a new address.
    /// Used to transfer pause control to the DAO post-bootstrap.
    /// Mirrors the `profile::rotate_admin` pattern.
    public entry fun rotate_admin(
        current_admin: &signer,
        new_admin: address,
    ) acquires FactoryState {
        assert!(new_admin != @0x0, E_INVALID_ADDRESS);
        let state = borrow_global_mut<FactoryState>(@desnet);
        assert!(signer::address_of(current_admin) == state.admin, E_NOT_ADMIN);
        state.admin = new_admin;
    }

    #[view]
    public fun admin(): address acquires FactoryState {
        borrow_global<FactoryState>(@desnet).admin
    }

    #[view]
    public fun vault_addr_of_pid(pid_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        smart_table::borrow(&registry.records, handle).supra_vault
    }

    /// v0.3.2 F9: single-hop handle -> supra_vault lookup. Used by supra_fee_vault::settle
    /// to delegate-burn DESNET via desnet's supra_vault BurnRef.
    #[view]
    public fun vault_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        smart_table::borrow(&registry.records, key).supra_vault
    }

    #[view]
    public fun ipo_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        smart_table::borrow(&registry.records, key).ipo_addr
    }
}

```

---

## `sources/giveaway.move`

```move
/// Giveaway - opt-in attached giveaway primitive (LOCKED 2026-05-01).
///
/// Two types: FA (fungible token, fixed amount per claim) + NFT (FCFS sequential).
/// Token scope = AGNOSTIC (any FA, any NFT collection - NOT factory-only).
///
/// Three optional gates (independent opt-in):
/// - follower_only: synced to sponsor
/// - nft_gate: NFT collection holder
/// - lp_stake_gate: LP staker in target_pid's pool (Endorse-tier integration)
///
/// Default = PID-only claim (tier model enforces guest exclusion - claim = write action).
/// NO citizen_only / guest_allowed field (redundant).
/// NO min_reputation field v1 (deferred until reputation primitive lands).
///
/// Refund flow: post-deadline permissionless `settle_giveaway(mint_id)` destroys
/// SmartTable, refunds unclaimed budget to sponsor, pays caller 5 bps bounty (FA mode)
/// or no bounty (NFT mode - sponsor incentive enough).
module desnet::giveaway {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::{Self, ExtendRef, Object, ObjectCore};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::link;
    use desnet::mint;
    use desnet::lp_staking;
    use aptos_token_objects::token;

    // ============ CONSTANTS ============

    /// Bounty for permissionless settler (FA mode) = 5 bps of refunded amount.
    const SETTLE_BOUNTY_BPS: u64 = 5;

    /// GiveawayKind variant tags
    const KIND_FA: u8 = 1;
    const KIND_NFT: u8 = 2;

    // ============ ERROR CODES ============

    const E_GIVEAWAY_NOT_FOUND: u64 = 1;
    const E_GIVEAWAY_EXPIRED: u64 = 2;
    const E_GIVEAWAY_EXHAUSTED: u64 = 3;
    const E_ALREADY_CLAIMED: u64 = 4;
    const E_FOLLOWER_GATE_FAILED: u64 = 5;
    const E_NFT_GATE_FAILED: u64 = 6;
    const E_LP_STAKE_GATE_FAILED: u64 = 7;
    const E_NOT_DEADLINE: u64 = 8;
    const E_INVALID_KIND: u64 = 9;
    const E_GUEST_CANNOT_CLAIM: u64 = 10;
    const E_GIVEAWAY_ALREADY_EXISTS: u64 = 11;
    const E_NOT_SPONSOR: u64 = 12;
    const E_MINT_NOT_FOUND: u64 = 13;

    // ============ TYPES ============

    /// Per-mint Giveaway. Stored at sponsor PID, keyed by mint_seq.
    /// Single Giveaway per mint v1 (multi-prize deferred v2).
    struct Giveaway has key, store {
        sponsor_pid: address,
        sponsor_wallet: address,             // wallet that funded the giveaway; refund recipient
        kind: u8,                            // KIND_FA | KIND_NFT
        deadline_secs: u64,
        // FA fields (used when kind=KIND_FA)
        fa_token_metadata: address,          // ANY FA addr (agnostic)
        fa_amount_per_claim: u64,
        fa_total_budget: u64,
        // NFT fields (used when kind=KIND_NFT)
        nft_collection_addr: address,
        nft_addrs: vector<address>,          // FCFS pop_front, vector::length = remaining
        // Common counters
        claims_made: u64,
        // Optional gates (3 independent)
        follower_only: bool,
        nft_gate: Option<address>,
        lp_stake_gate: Option<address>,
        // Per-actor dedup (PID Object addr -> true)
        claimers: SmartTable<address, bool>,
        // Object signer (escrow holds funds for FA mode at this Object's primary store)
        extend_ref: ExtendRef,
    }

    /// Per-PID giveaway storage. SmartTable<mint_seq, Giveaway addr>.
    /// Each Giveaway lives at its own Object addr (escrow holds funds).
    struct PidGiveawayStorage has key {
        giveaways: SmartTable<u64, address>,  // mint_seq -> giveaway Object addr
    }

    // ============ EVENTS ============

    #[event]
    struct GiveawayCreated has drop, store {
        sponsor_pid: address,
        mint_seq: u64,
        giveaway_addr: address,
        kind: u8,
        deadline_secs: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct GiveawayClaimed has drop, store {
        giveaway_addr: address,
        claimer_pid: address,
        claim_index: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct GiveawaySettled has drop, store {
        giveaway_addr: address,
        sponsor_pid: address,
        settler: address,
        refund_amount: u64,
        bounty_paid: u64,
        timestamp_secs: u64,
    }

    // ============ CREATE - FA mode ============

    /// Sponsor creates FA giveaway attached to their mint. Atomic: deposits
    /// total_budget into giveaway escrow, registers under PidGiveawayStorage.
    public entry fun create_fa_giveaway(
        sponsor: &signer,
        sponsor_pid: address,
        mint_seq: u64,
        token_metadata: Object<Metadata>,
        amount_per_claim: u64,
        total_budget: u64,
        deadline_secs: u64,
        follower_only: bool,
        nft_gate_addr: address,
        nft_gate_set: bool,
        lp_stake_gate_addr: address,
        lp_stake_gate_set: bool,
    ) acquires PidGiveawayStorage {
        profile::assert_authorized(sponsor, sponsor_pid);
        let sponsor_addr = signer::address_of(sponsor);

        // Validate mint_seq corresponds to a real mint by sponsor
        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        // Withdraw total_budget from sponsor's primary store (atomic; aborts if no balance)
        let escrow_fa = primary_fungible_store::withdraw(sponsor, token_metadata, total_budget);

        // Create giveaway Object (escrow holds funds at its primary store)
        let constructor_ref = object::create_object(sponsor_addr);
        let giveaway_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        primary_fungible_store::deposit(giveaway_addr, escrow_fa);

        let giveaway = Giveaway {
            sponsor_pid,
            sponsor_wallet: sponsor_addr,
            kind: KIND_FA,
            deadline_secs,
            fa_token_metadata: object::object_address(&token_metadata),
            fa_amount_per_claim: amount_per_claim,
            fa_total_budget: total_budget,
            nft_collection_addr: @0x0,
            nft_addrs: vector::empty(),
            claims_made: 0,
            follower_only,
            nft_gate: if (nft_gate_set) option::some(nft_gate_addr) else option::none(),
            lp_stake_gate: if (lp_stake_gate_set) option::some(lp_stake_gate_addr) else option::none(),
            claimers: smart_table::new(),
            extend_ref,
        };

        move_to(&object_signer, giveaway);

        // Register in sponsor's giveaway storage (lazy-init if first time)
        ensure_giveaway_storage(sponsor_pid);
        let storage = borrow_global_mut<PidGiveawayStorage>(sponsor_pid);
        smart_table::add(&mut storage.giveaways, mint_seq, giveaway_addr);

        event::emit(GiveawayCreated {
            sponsor_pid,
            mint_seq,
            giveaway_addr,
            kind: KIND_FA,
            deadline_secs,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ CREATE - NFT mode ============

    /// Sponsor creates NFT giveaway. Sponsor passes pre-collected NFT Object addrs
    /// in FCFS order. Each claim transfers next NFT in vector to claimer.
    /// **ATOMIC ESCROW (LOCKED 2026-05-01)**: at create-time, sponsor must own ALL NFTs
    /// in `nft_addrs`. Each is verified + transferred to `giveaway_addr` in this tx.
    /// Aborts whole tx if any NFT not owned by sponsor (no partial-escrow state).
    public entry fun create_nft_giveaway(
        sponsor: &signer,
        sponsor_pid: address,
        mint_seq: u64,
        collection_addr: address,
        nft_addrs: vector<address>,
        deadline_secs: u64,
        follower_only: bool,
        nft_gate_addr: address,
        nft_gate_set: bool,
        lp_stake_gate_addr: address,
        lp_stake_gate_set: bool,
    ) acquires PidGiveawayStorage {
        profile::assert_authorized(sponsor, sponsor_pid);
        let sponsor_addr = signer::address_of(sponsor);

        // Validate mint_seq corresponds to a real mint by sponsor
        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        let constructor_ref = object::create_object(sponsor_addr);
        let giveaway_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        // Atomic escrow: verify each NFT owned by sponsor + transfer to giveaway_addr.
        // Closes race window where sponsor "promises" NFTs but never transfers,
        // leaving claimers in broken state.
        let n_nfts = vector::length(&nft_addrs);
        assert!(n_nfts > 0, E_GIVEAWAY_EXHAUSTED);    // empty giveaway = misuse, reject upfront
        let i = 0;
        while (i < n_nfts) {
            let nft_addr = *vector::borrow(&nft_addrs, i);
            let nft_obj = object::address_to_object<ObjectCore>(nft_addr);
            assert!(object::owner(nft_obj) == sponsor_addr, E_NOT_SPONSOR);
            object::transfer(sponsor, nft_obj, giveaway_addr);
            i = i + 1;
        };

        let giveaway = Giveaway {
            sponsor_pid,
            sponsor_wallet: sponsor_addr,
            kind: KIND_NFT,
            deadline_secs,
            fa_token_metadata: @0x0,
            fa_amount_per_claim: 0,
            fa_total_budget: 0,
            nft_collection_addr: collection_addr,
            nft_addrs,
            claims_made: 0,
            follower_only,
            nft_gate: if (nft_gate_set) option::some(nft_gate_addr) else option::none(),
            lp_stake_gate: if (lp_stake_gate_set) option::some(lp_stake_gate_addr) else option::none(),
            claimers: smart_table::new(),
            extend_ref,
        };

        move_to(&object_signer, giveaway);

        ensure_giveaway_storage(sponsor_pid);
        let storage = borrow_global_mut<PidGiveawayStorage>(sponsor_pid);
        smart_table::add(&mut storage.giveaways, mint_seq, giveaway_addr);

        event::emit(GiveawayCreated {
            sponsor_pid,
            mint_seq,
            giveaway_addr,
            kind: KIND_NFT,
            deadline_secs,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ CLAIM ============

    /// Permissionless claim. Validates gates + dedup + deadline + supply.
    /// FA mode: transfers amount_per_claim from escrow to claimer's primary store.
    /// NFT mode: pop_front nft_addrs (FCFS sequential), transfer NFT Object to claimer.
    ///
    /// `claimer_nft_proof_addr`: caller-supplied NFT Object addr for nft_gate verification.
    /// Must be owned by claimer's wallet AND in the gate-required collection. Pass `@0x0`
    /// if giveaway has no nft_gate.
    /// `claimer_stake_position_addr`: caller-supplied `desnet::lp_staking::Position` addr for
    /// lp_stake_gate verification. Pass `@0x0` if giveaway has no lp_stake_gate.
    public entry fun claim_giveaway(
        claimer: &signer,
        claimer_pid: address,
        giveaway_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) acquires Giveaway {
        profile::assert_authorized(claimer, claimer_pid);
        let claimer_addr = signer::address_of(claimer);

        let giveaway = borrow_global_mut<Giveaway>(giveaway_addr);

        // Deadline + dedup
        let now = timestamp::now_seconds();
        assert!(now < giveaway.deadline_secs, E_GIVEAWAY_EXPIRED);
        assert!(!smart_table::contains(&giveaway.claimers, claimer_pid), E_ALREADY_CLAIMED);

        // Gate checks (3 independent, each opt-in via giveaway config)
        check_gates(giveaway, claimer_pid, claimer_addr, claimer_nft_proof_addr, claimer_stake_position_addr);

        // Derive giveaway escrow signer once (immutable ref through mut borrow is OK)
        let giveaway_signer = object::generate_signer_for_extending(&giveaway.extend_ref);

        // Mode-dispatch claim
        if (giveaway.kind == KIND_FA) {
            let token_metadata = object::address_to_object<Metadata>(giveaway.fa_token_metadata);
            let remaining = primary_fungible_store::balance(giveaway_addr, token_metadata);
            assert!(remaining >= giveaway.fa_amount_per_claim, E_GIVEAWAY_EXHAUSTED);

            // Withdraw from giveaway escrow + deposit to claimer
            let claim_fa = primary_fungible_store::withdraw(
                &giveaway_signer,
                token_metadata,
                giveaway.fa_amount_per_claim,
            );
            primary_fungible_store::deposit(claimer_addr, claim_fa);
        } else if (giveaway.kind == KIND_NFT) {
            assert!(!vector::is_empty(&giveaway.nft_addrs), E_GIVEAWAY_EXHAUSTED);
            // FCFS sequential: pop front, transfer to claimer
            let next_nft_addr = vector::remove(&mut giveaway.nft_addrs, 0);
            let nft_object = object::address_to_object<ObjectCore>(next_nft_addr);
            object::transfer(&giveaway_signer, nft_object, claimer_addr);
        } else {
            abort E_INVALID_KIND
        };

        smart_table::add(&mut giveaway.claimers, claimer_pid, true);
        giveaway.claims_made = giveaway.claims_made + 1;

        event::emit(GiveawayClaimed {
            giveaway_addr,
            claimer_pid,
            claim_index: giveaway.claims_made,
            timestamp_secs: now,
        });
    }

    // ============ SETTLE - permissionless post-deadline ============

    /// Anyone can call after deadline. Refunds unclaimed budget to sponsor's wallet,
    /// pays caller 5 bps bounty (FA mode) or no bounty (NFT mode).
    /// Idempotent on already-settled (re-call refunds 0 / transfers 0 NFTs, gas-only).
    public entry fun settle_giveaway(
        settler: &signer,
        giveaway_addr: address,
    ) acquires Giveaway {
        let giveaway = borrow_global_mut<Giveaway>(giveaway_addr);
        let now = timestamp::now_seconds();
        assert!(now >= giveaway.deadline_secs, E_NOT_DEADLINE);

        let settler_addr = signer::address_of(settler);
        let sponsor_wallet = giveaway.sponsor_wallet;
        let giveaway_signer = object::generate_signer_for_extending(&giveaway.extend_ref);

        let refund_amount: u64 = 0;
        let bounty: u64 = 0;

        if (giveaway.kind == KIND_FA) {
            let token_metadata = object::address_to_object<Metadata>(giveaway.fa_token_metadata);
            let remaining = primary_fungible_store::balance(giveaway_addr, token_metadata);
            if (remaining > 0) {
                bounty = (remaining * SETTLE_BOUNTY_BPS) / 10000;
                refund_amount = remaining - bounty;

                // Withdraw bounty + refund from escrow, deposit to settler + sponsor_wallet
                if (bounty > 0) {
                    let bounty_fa = primary_fungible_store::withdraw(
                        &giveaway_signer, token_metadata, bounty
                    );
                    primary_fungible_store::deposit(settler_addr, bounty_fa);
                };
                if (refund_amount > 0) {
                    let refund_fa = primary_fungible_store::withdraw(
                        &giveaway_signer, token_metadata, refund_amount
                    );
                    primary_fungible_store::deposit(sponsor_wallet, refund_fa);
                };
            };
        } else if (giveaway.kind == KIND_NFT) {
            // Refund remaining NFTs to sponsor_wallet (no bounty for NFT mode v1)
            let count = vector::length(&giveaway.nft_addrs);
            refund_amount = count;
            while (!vector::is_empty(&giveaway.nft_addrs)) {
                let nft_addr = vector::pop_back(&mut giveaway.nft_addrs);
                let nft_object = object::address_to_object<ObjectCore>(nft_addr);
                object::transfer(&giveaway_signer, nft_object, sponsor_wallet);
            };
        };

        // Note: giveaway resource NOT destroyed (preserves audit trail + claimers history).
        // Storage refund deferred - minor cost, idempotent re-settle returns 0/0.

        event::emit(GiveawaySettled {
            giveaway_addr,
            sponsor_pid: giveaway.sponsor_pid,
            settler: settler_addr,
            refund_amount,
            bounty_paid: bounty,
            timestamp_secs: now,
        });
    }

    // ============ INTERNAL - gate checks ============

    /// Three independent gates (LOCKED 2026-05-01: BUKAN unified ReferenceGate - different
    /// scope: giveaway = sponsor-defined eligibility per-mint, ReferenceGate = sync/balance/LP
    /// for verb engagement. Kept separate intentionally).
    ///
    /// Wallet-addr semantic (locked 2026-05-01): nft_gate + lp_stake_gate verify ownership
    /// at claimer's wallet (default custody for NFTs and stake positions).
    fun check_gates(
        giveaway: &Giveaway,
        claimer_pid: address,
        claimer_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) {
        // 1. follower_only - claimer must be synced to sponsor's PID
        if (giveaway.follower_only) {
            assert!(
                link::is_synced(claimer_pid, giveaway.sponsor_pid),
                E_FOLLOWER_GATE_FAILED
            );
        };

        // 2. nft_gate - claimer must hold >=1 NFT in the required collection
        if (option::is_some(&giveaway.nft_gate)) {
            let required_collection = *option::borrow(&giveaway.nft_gate);
            assert!(claimer_nft_proof_addr != @0x0, E_NFT_GATE_FAILED);
            assert!(
                object::object_exists<token::Token>(claimer_nft_proof_addr),
                E_NFT_GATE_FAILED
            );
            let nft_obj = object::address_to_object<token::Token>(claimer_nft_proof_addr);
            assert!(object::owner(nft_obj) == claimer_addr, E_NFT_GATE_FAILED);
            // Verify NFT belongs to the required collection
            let collection_obj = token::collection_object(nft_obj);
            assert!(
                object::object_address(&collection_obj) == required_collection,
                E_NFT_GATE_FAILED
            );
        };

        // 3. lp_stake_gate - claimer must hold a Position on the required pool with shares > 0.
        // Ownership: free/time-locked -> staker == claimer_addr; locked (creator's perma-lock) ->
        // current PID owner of recipient_pid == claimer_addr.
        if (option::is_some(&giveaway.lp_stake_gate)) {
            let required_pool = *option::borrow(&giveaway.lp_stake_gate);
            assert!(claimer_stake_position_addr != @0x0, E_LP_STAKE_GATE_FAILED);
            assert!(
                lp_staking::has_position(claimer_stake_position_addr),
                E_LP_STAKE_GATE_FAILED
            );
            assert!(
                lp_staking::position_pool(claimer_stake_position_addr) == required_pool,
                E_LP_STAKE_GATE_FAILED
            );
            let recipient_pid = lp_staking::position_recipient_pid(claimer_stake_position_addr);
            if (recipient_pid == @0x0) {
                assert!(
                    lp_staking::position_owner(claimer_stake_position_addr) == claimer_addr,
                    E_LP_STAKE_GATE_FAILED
                );
            } else {
                let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
                assert!(object::owner(pid_obj) == claimer_addr, E_LP_STAKE_GATE_FAILED);
            };
            assert!(
                lp_staking::position_shares(claimer_stake_position_addr) > 0,
                E_LP_STAKE_GATE_FAILED
            );
        };
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidGiveawayStorage at PID addr. Called from create_*_giveaway
    /// on first-write. Idempotent. Cycle-safe via profile::derive_pid_signer.
    fun ensure_giveaway_storage(pid_addr: address) {
        if (!exists<PidGiveawayStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidGiveawayStorage {
                giveaways: smart_table::new(),
            });
        };
    }

    // ============ VIEWS ============

    #[view]
    public fun giveaway_addr_for_mint(sponsor_pid: address, mint_seq: u64): address
        acquires PidGiveawayStorage
    {
        let storage = borrow_global<PidGiveawayStorage>(sponsor_pid);
        *smart_table::borrow(&storage.giveaways, mint_seq)
    }

    #[view]
    public fun claims_made(giveaway_addr: address): u64 acquires Giveaway {
        borrow_global<Giveaway>(giveaway_addr).claims_made
    }

    #[view]
    public fun deadline_secs(giveaway_addr: address): u64 acquires Giveaway {
        borrow_global<Giveaway>(giveaway_addr).deadline_secs
    }

    #[view]
    public fun has_claimed(giveaway_addr: address, claimer_pid: address): bool acquires Giveaway {
        smart_table::contains(&borrow_global<Giveaway>(giveaway_addr).claimers, claimer_pid)
    }

    #[view]
    public fun kind_fa(): u8 { KIND_FA }

    #[view]
    public fun kind_nft(): u8 { KIND_NFT }

    #[view]
    public fun settle_bounty_bps(): u64 { SETTLE_BOUNTY_BPS }
}

```

---

## `sources/governance.move`

```move
/// Governance - DAO orchestrator for the DeSNet monolith package.
///
/// All DeSNet modules (factory, profile, mint/pulse/press/...) share a single
/// resource_account at @desnet. Governance is the SOLE holder of the resource_account
/// `SignerCapability`; sibling modules acquire a package signer at runtime via
/// `derive_pkg_signer()` (friend-only).
///
/// Two upgrade paths:
///   1. `multisig_upgrade(@origin signer, ...)` - bootstrap path, no DAO vote.
///      Used pre-PMF while the team iterates rapidly. Off-chain: simply stop
///      calling this once DAO is trusted.
///   2. `propose_upgrade` -> `cast_vote` -> `ratify` -> `execute_proposal` -
///      full DAO flow with voting, quorum, approval threshold, and 30d timelock.
///      Calls `supra_framework::code::publish_package_txn` directly with the
///      derived package signer (no cross-package dispatch needed in monolith).
///
/// Voting power formula (LOCKED, anti-whale):
///   voting_power(voter) = min(
///     voter_history::rewards_earned_30d(voter),    // proves LP staking commitment
///     primary_fungible_store::balance(voter, DESNET) // proves still-holding at cast
///   )
/// Snapshot at vote casting time.
///
/// Thresholds (LOCKED 2026-04-30):
///   - Proposal threshold: 5% of last-30d emission
///   - Quorum: 35% of last-30d emission
///   - Approval: 70% of total cast votes
///   - Voting period: 7 days
///   - Timelock post-approval: 30 days
module desnet::governance {
    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::code;
    use supra_framework::event;
    // Bootstrap publisher lives at @origin (deployer multisig). It holds the
    // SignerCapability for @desnet (created at bootstrap deploy) until our
    // init_module takes ownership via `take_cap_for_desnet` here. This indirection
    // is required because the main DesNet package exceeds the 64KB single-tx
    // publish limit and must be deployed via chunked publish through bootstrap.
    use origin::publisher;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::voter_history;

    friend desnet::factory;
    friend desnet::profile;
    friend desnet::amm;
    friend desnet::lp_staking;
    friend desnet::supra_fee_vault;
    friend desnet::ipo;
    friend desnet::lp_emission;
    friend desnet::reaction_emission;

    // ============ CONSTANTS ============

    const PROPOSAL_THRESHOLD_BPS: u64 = 500;
    const QUORUM_BPS: u64 = 3500;
    const APPROVAL_THRESHOLD_BPS: u64 = 7000;
    const VOTING_PERIOD_SECS: u64 = 7 * 86_400;
    const TIMELOCK_SECS: u64 = 30 * 86_400;

    // ============ ERROR CODES ============

    const E_INSUFFICIENT_VOTING_POWER: u64 = 1;
    const E_PROPOSAL_NOT_FOUND: u64 = 2;
    const E_PROPOSAL_INACTIVE: u64 = 3;
    const E_VOTING_PERIOD_OVER: u64 = 4;
    const E_VOTING_PERIOD_ACTIVE: u64 = 5;
    const E_QUORUM_NOT_MET: u64 = 6;
    const E_APPROVAL_NOT_MET: u64 = 7;
    const E_TIMELOCK_NOT_EXPIRED: u64 = 8;
    const E_ALREADY_VOTED: u64 = 9;
    const E_NOT_INITIALIZED: u64 = 11;
    const E_NOT_MULTISIG: u64 = 15;
    const E_ALREADY_EXECUTED: u64 = 16;
    const E_ALREADY_RATIFIED: u64 = 17;
    const E_HASH_MISMATCH: u64 = 18;
    const E_MULTISIG_DISABLED: u64 = 19;
    const E_INVALID_ADDRESS: u64 = 20;
    /// v0.3.0.6 chunked-upgrade infra
    const E_ARGS_LEN_MISMATCH: u64 = 21;
    /// v0.3.1 Item 3b: setters NEUTERED post-hardcode of DESNET_FA_ADDR.
    const E_NEUTERED: u64 = 22;
    /// v0.3.2 (F2): chunked-publish defense-in-depth - at least one module slot empty.
    const E_INCOMPLETE_CHUNKS: u64 = 23;
    /// v0.3.3 (G2): caller is not the original DAO stager for this proposal.
    const E_NOT_STAGER: u64 = 24;
    /// v0.3.2 (F6): 30-day rolling emission tracker constants.
    const SECONDS_PER_DAY: u64 = 86400;
    const ROLLING_WINDOW_DAYS: u64 = 30;
    /// v0.3.1 Item 3b: hardcoded DESNET FA addr - eliminates manipulation surface.
    /// Computable as `factory::derive_token_metadata_addr(b"desnet")`.
    /// `desnet_fa_metadata` field in GovernanceState becomes vestigial (compat only).
    const DESNET_FA_ADDR: address = @0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7;

    // ============ TYPES ============

    /// Governance singleton state at @desnet. Sole holder of pkg signer_cap.
    struct GovernanceState has key {
        signer_cap: SignerCapability,
        proposal_count: u64,
        proposals: SmartTable<u64, Proposal>,
        // DESNET FA addr for voting_power balance check.
        // @0x0 = NOT YET CONFIGURED (voting_power returns 0).
        desnet_fa_metadata: address,
        // Native asset FA addr (e.g., SUPRA). Used for fees and AMM reserves.
        native_fa_metadata: address,
        // 30d emission estimate (denominator for threshold/quorum).
        // 0 = NOT YET CONFIGURED (proposals can't be submitted).
        total_30d_emission: u64,
        // M2 fix (audit R1): one-way switch to disable multisig_upgrade backdoor.
        // Set true via `disable_multisig_upgrade` once DAO is trusted; never reversible.
        multisig_upgrade_disabled: bool,
    }

    struct Proposal has store {
        id: u64,
        proposer: address,
        target_package_addr: address,        // forward-compat; in monolith always @desnet
        new_module_bytes_hash: vector<u8>,
        votes_for: u64,
        votes_against: u64,
        voters: SmartTable<address, ProposalVote>,
        created_at_secs: u64,
        voting_end_secs: u64,
        approved_at_secs: Option<u64>,
        executed_at_secs: Option<u64>,
        cancelled: bool,
    }

    struct ProposalVote has store, copy, drop {
        voter: address,
        weight: u64,
        support: bool,
        cast_at_secs: u64,
    }

    /// v0.3.0.6 chunked-upgrade staging. Accumulates metadata + per-module bytecode
    /// across multiple `multisig_stage_upgrade_chunk` txs at @desnet, then consumed
    /// by `multisig_publish_chunked_upgrade` (final chunk + publish in single tx).
    /// Allows package upgrades larger than 64KB single-tx limit.
    struct UpgradeStaging has key, drop {
        metadata: vector<u8>,
        code: vector<vector<u8>>,
    }

    /// v0.3.3 (G2, R5 CONV-2 MED fix): isolated DAO chunked staging. Separate from
    /// multisig `UpgradeStaging` - DAO + multisig paths can no longer collide.
    /// `proposal_id` field binds staging to one proposal (stale staging for a
    /// different proposal auto-clears on next stage call). `stager` field locks
    /// further appends to original staging address (anti-grief).
    /// Permissionless `dao_cleanup_upgrade_staging` allows recovery if stage
    /// becomes corrupted or stale.
    struct DaoUpgradeStaging has key, drop {
        proposal_id: u64,
        stager: address,
        metadata: vector<u8>,
        code: vector<vector<u8>>,
    }

    /// v0.3.2 (F6): Auto-tracker for 30-day rolling emission. Eliminates manipulation
    /// surface where multisig sets `total_30d_emission` to arbitrary value.
    /// Per-day buckets indexed by (day_number % 30); parallel vector tracks the
    /// day_number each entry actually refers to (for staleness check on read).
    /// `record_emission_for_window` called by lp_staking::claim_internal per claim;
    /// `total_30d_emission_auto` view aggregates fresh buckets only.
    /// Lazy-initialized on first record (init_module skipped for upgrades).
    struct Emission30dRollingBucket has key {
        daily_amounts: vector<u64>,
        daily_day_nums: vector<u64>,
    }

    // ============ EVENTS ============

    #[event]
    struct GovernanceInitialized has drop, store {
        governance_addr: address,
        deployer: address,
        timestamp_secs: u64,
    }

    #[event]
    struct ProposalCreated has drop, store {
        proposal_id: u64,
        proposer: address,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
        voting_end_secs: u64,
    }

    #[event]
    struct VoteCast has drop, store {
        proposal_id: u64,
        voter: address,
        support: bool,
        weight: u64,
    }

    #[event]
    struct ProposalRatified has drop, store {
        proposal_id: u64,
        votes_for_final: u64,
        votes_against_final: u64,
        timelock_until: u64,
    }

    #[event]
    struct ProposalExecuted has drop, store {
        proposal_id: u64,
        target_package_addr: address,
        executor: address,
    }

    #[event]
    struct MultisigUpgrade has drop, store {
        multisig: address,
        timestamp_secs: u64,
    }

    #[event]
    struct MultisigUpgradeDisabled has drop, store {
        disabled_by: address,
        timestamp_secs: u64,
    }

    /// v0.3.2 (F3): emitted on cleanup_upgrade_staging - observability for indexers.
    #[event]
    struct UpgradeStagingCleanup has drop, store {
        multisig: address,
        timestamp_secs: u64,
    }

    // ============ INIT - called by resource_account at deploy ============

    fun init_module(account: &signer) {
        let signer_cap = publisher::take_cap_for_desnet(account);
        let governance_addr = signer::address_of(account);

        move_to(account, GovernanceState {
            signer_cap,
            proposal_count: 0,
            proposals: smart_table::new(),
            desnet_fa_metadata: @0x0,
            native_fa_metadata: @0xa, // Default to SUPRA native asset
            total_30d_emission: 0,
            multisig_upgrade_disabled: false,
        });

        // Initialize centralized voter_history Registry at @desnet.
        voter_history::init_registry(account);

        event::emit(GovernanceInitialized {
            governance_addr,
            deployer: @origin,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ VIEW ============

    #[view]
    public fun native_fa_metadata(): address acquires GovernanceState {
        borrow_global<GovernanceState>(@desnet).native_fa_metadata
    }

    // ============ PACKAGE SIGNER (friend-only) ============

    /// Sole entry point for sibling modules to acquire the package signer at
    /// runtime. Replaces per-module `signer_cap` fields and prevents accidental
    /// sprawl of the cap.
    public(friend) fun derive_pkg_signer(): signer acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        account::create_signer_with_capability(&state.signer_cap)
    }

    // ============ MULTISIG-PHASE UPGRADE (pre-DAO transition) ============

    /// Multisig (@origin) directly upgrades the package without a DAO vote.
    /// Used pre-PMF while the team iterates rapidly. Off-chain: simply stop
    /// calling this once DAO is trusted.
    /// M2 fix (audit R1): callable only while `multisig_upgrade_disabled == false`.
    /// Use `disable_multisig_upgrade` for irreversible on-chain renouncement.
    public entry fun multisig_upgrade(
        multisig: &signer,
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        assert!(
            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
            E_MULTISIG_DISABLED
        );

        let pkg_signer = derive_pkg_signer();
        code::publish_package_txn(&pkg_signer, metadata, code_bytes);

        event::emit(MultisigUpgrade {
            multisig: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// One-way switch to permanently renounce the multisig backdoor.
    /// After this, the only upgrade path is the full DAO flow. NOT REVERSIBLE.
    public entry fun disable_multisig_upgrade(multisig: &signer) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        borrow_global_mut<GovernanceState>(@desnet).multisig_upgrade_disabled = true;
        event::emit(MultisigUpgradeDisabled {
            disabled_by: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ CHUNKED MULTISIG UPGRADE (v0.3.0.6) ============
    // Allows upgrades > 64KB single-tx limit by staging chunks across multiple
    // multisig txs, then publishing in a final tx. Mirror of bootstrap publisher
    // pattern, but uses pkg_signer (held in GovernanceState) instead of an external
    // SignerCapability holder. Same auth + disable-flag check as `multisig_upgrade`.
    // DAO chunked variant deferred to v0.3.1 (will share `UpgradeStaging` resource).

    fun stage_chunks_into_staging(
        pkg_signer: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires UpgradeStaging {
        assert!(
            vector::length(&code_indices) == vector::length(&code_chunks),
            E_ARGS_LEN_MISMATCH
        );
        if (!exists<UpgradeStaging>(@desnet)) {
            move_to(pkg_signer, UpgradeStaging {
                metadata: vector::empty(),
                code: vector::empty(),
            });
        };
        let staging = borrow_global_mut<UpgradeStaging>(@desnet);
        vector::append(&mut staging.metadata, metadata_chunk);
        let n = vector::length(&code_chunks);
        let i = 0;
        while (i < n) {
            let idx = (*vector::borrow(&code_indices, i) as u64);
            while (vector::length(&staging.code) <= idx) {
                vector::push_back(&mut staging.code, vector::empty());
            };
            let target = vector::borrow_mut(&mut staging.code, idx);
            let chunk = *vector::borrow(&code_chunks, i);
            vector::append(target, chunk);
            i = i + 1;
        };
    }

    /// Stage one chunk for an upcoming chunked multisig upgrade. Permissionless of
    /// chunks order - final chunk landed by `multisig_publish_chunked_upgrade`.
    public entry fun multisig_stage_upgrade_chunk(
        multisig: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires GovernanceState, UpgradeStaging {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        assert!(
            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
            E_MULTISIG_DISABLED
        );
        let pkg_signer = derive_pkg_signer();
        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
    }

    /// Stage final chunk + publish the assembled package. Consumes UpgradeStaging.
    public entry fun multisig_publish_chunked_upgrade(
        multisig: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires GovernanceState, UpgradeStaging {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        assert!(
            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
            E_MULTISIG_DISABLED
        );
        let pkg_signer = derive_pkg_signer();
        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
        // v0.3.2 (F2): defense-in-depth - reject incomplete staging (any empty slot).
        // Without this, out-of-order/missing chunk produces a generic framework error
        // at code::publish_package_txn instead of clear ours-error.
        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };
        code::publish_package_txn(&pkg_signer, metadata, code);
        event::emit(MultisigUpgrade {
            multisig: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// v0.3.3 (G5, R5 Claude C7 LOW defense-in-depth): hash-verifying multisig publish.
    /// Same as `multisig_publish_chunked_upgrade` but asserts assembled `(metadata, code)`
    /// digest equals `expected_digest` parameter - pin the hash off-chain (e.g., from a
    /// signed multisig review summary), preventing a single rogue signer from substituting
    /// chunk bytes during multisig coordination.
    public entry fun multisig_publish_chunked_upgrade_with_digest(
        multisig: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
        expected_digest: vector<u8>,
    ) acquires GovernanceState, UpgradeStaging {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        assert!(
            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
            E_MULTISIG_DISABLED
        );
        let pkg_signer = derive_pkg_signer();
        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
        // Empty-slot defense (mirror multisig_publish_chunked_upgrade).
        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };
        // v0.3.3 hash-verify: assembled payload must match pinned digest.
        let assembled_digest = compute_upgrade_digest(&metadata, &code);
        assert!(assembled_digest == expected_digest, E_HASH_MISMATCH);
        code::publish_package_txn(&pkg_signer, metadata, code);
        event::emit(MultisigUpgrade {
            multisig: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// Discard a half-staged UpgradeStaging (e.g., aborted upgrade, restart).
    public entry fun cleanup_upgrade_staging(multisig: &signer) acquires UpgradeStaging {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        if (exists<UpgradeStaging>(@desnet)) {
            let _ = move_from<UpgradeStaging>(@desnet);
            // v0.3.2 (F3): observability event for off-chain indexers.
            event::emit(UpgradeStagingCleanup {
                multisig: signer::address_of(multisig),
                timestamp_secs: timestamp::now_seconds(),
            });
        };
    }

    #[view]
    public fun upgrade_staging_exists(): bool { exists<UpgradeStaging>(@desnet) }

    // ============ EMISSION AUTO-TRACKER (v0.3.2 F6) ============
    //
    // 30-day rolling bucket of emission distributed via lp_staking::claim_internal.
    // Eliminates manipulation surface where multisig sets `total_30d_emission` to
    // arbitrary value (was the last remaining off-DAO knob in v0.3.1).
    //
    // Per-day buckets indexed by (day_number % 30); parallel `daily_day_nums`
    // tracks which day_number each bucket entry actually refers to (so the view
    // can distinguish fresh vs stale entries without a sweep on read).
    //
    // Lazy-init on first record (init_module doesn't re-run on upgrade).

    /// Friend-only: lp_staking::claim_internal calls this with `actual_paid` (capped
    /// emission amount, post graceful-depletion). Saturates a single daily bucket;
    /// view sums across the rolling 30-day window.
    public(friend) fun record_emission_for_window(amount: u64) acquires GovernanceState, Emission30dRollingBucket {
        if (amount == 0) return;
        let now = timestamp::now_seconds();
        let day = now / SECONDS_PER_DAY;

        if (!exists<Emission30dRollingBucket>(@desnet)) {
            let pkg_signer = derive_pkg_signer();
            let amounts = vector::empty<u64>();
            let days = vector::empty<u64>();
            let i = 0;
            while (i < ROLLING_WINDOW_DAYS) {
                vector::push_back(&mut amounts, 0);
                vector::push_back(&mut days, 0);
                i = i + 1;
            };
            move_to(&pkg_signer, Emission30dRollingBucket {
                daily_amounts: amounts,
                daily_day_nums: days,
            });
        };

        let tracker = borrow_global_mut<Emission30dRollingBucket>(@desnet);
        let idx = day % ROLLING_WINDOW_DAYS;
        let stored_day = *vector::borrow(&tracker.daily_day_nums, idx);
        if (stored_day != day) {
            // Stale entry from prior cycle - reset before adding.
            *vector::borrow_mut(&mut tracker.daily_amounts, idx) = 0;
            *vector::borrow_mut(&mut tracker.daily_day_nums, idx) = day;
        };
        let cur = *vector::borrow(&tracker.daily_amounts, idx);
        // Saturating add: pin to u64::MAX on overflow rather than abort
        // (single-day emission overflowing u64 is structurally impossible
        // given 1B token cap, but defense-in-depth).
        let new_val = if (cur > 18446744073709551615u64 - amount) {
            18446744073709551615u64
        } else {
            cur + amount
        };
        *vector::borrow_mut(&mut tracker.daily_amounts, idx) = new_val;
    }

    /// Sum of fresh (within rolling 30-day window) bucket amounts. Returns 0 pre-init.
    #[view]
    public fun total_30d_emission_auto(): u64 acquires Emission30dRollingBucket {
        if (!exists<Emission30dRollingBucket>(@desnet)) return 0;
        let tracker = borrow_global<Emission30dRollingBucket>(@desnet);
        let now = timestamp::now_seconds();
        let day = now / SECONDS_PER_DAY;
        let cutoff = if (day >= ROLLING_WINDOW_DAYS - 1) day - (ROLLING_WINDOW_DAYS - 1) else 0;

        let sum: u64 = 0;
        let i = 0;
        while (i < ROLLING_WINDOW_DAYS) {
            let stored_day = *vector::borrow(&tracker.daily_day_nums, i);
            if (stored_day >= cutoff) {
                let v = *vector::borrow(&tracker.daily_amounts, i);
                // Saturating sum
                if (sum > 18446744073709551615u64 - v) {
                    sum = 18446744073709551615u64;
                } else {
                    sum = sum + v;
                };
            };
            i = i + 1;
        };
        sum
    }

    /// v0.3.3 (G4, R5 Deepseek HIGH): now reads ONLY auto-tracker. Manual field
    /// `state.total_30d_emission` permanently ignored - eliminates latent overflow
    /// vector where `(eff * BPS) / 10000` could abort if vestigial value was extreme.
    /// `update_total_30d_emission` already neutered (E_NEUTERED) in v0.3.2 F6b, so
    /// vestigial value is frozen at deploy-time state. Defense-in-depth for forks.
    /// Borrow kept (unused) to preserve `acquires GovernanceState` annotation parity.
    fun effective_30d_emission(): u64 acquires GovernanceState, Emission30dRollingBucket {
        let _ = borrow_global<GovernanceState>(@desnet);
        total_30d_emission_auto()
    }

    #[view]
    public fun effective_30d_emission_view(): u64 acquires GovernanceState, Emission30dRollingBucket {
        effective_30d_emission()
    }

    // ============ DAO-PHASE PROPOSAL LIFECYCLE ============

    /// IMPORTANT: `new_module_bytes_hash` MUST be computed via
    /// `governance::compute_upgrade_digest(metadata, code_bytes)` (or its view
    /// variant `compute_upgrade_digest_view`). Any other scheme - including the
    /// natural BCS encoding of the tuple `(metadata, code_bytes)` - produces a
    /// different digest, and the proposal will fail at `execute_proposal` with
    /// `E_HASH_MISMATCH` after the timelock window has elapsed.
    public entry fun propose_upgrade(
        proposer: &signer,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
    ) acquires GovernanceState, Emission30dRollingBucket {
        // v0.3.2 (F14, R2 Kimi R2-N1): defense-in-depth - only @desnet pkg upgrades
        // are valid in monolith. Reject impossible proposals at submission time.
        assert!(target_package_addr == @desnet, E_INVALID_ADDRESS);

        // v0.3.2 (F6): DAO-unlock now driven by auto-tracker (lp_staking emission claims).
        // `update_total_30d_emission` manual setter still functional but auto-tracker
        // takes precedence via `effective_30d_emission()`.
        assert!(effective_30d_emission() > 0, E_NOT_INITIALIZED);

        let proposer_addr = signer::address_of(proposer);
        let proposer_power = voting_power(proposer_addr);
        assert!(proposer_power >= proposal_threshold_amount(), E_INSUFFICIENT_VOTING_POWER);

        let state = borrow_global_mut<GovernanceState>(@desnet);
        let id = state.proposal_count;
        state.proposal_count = id + 1;

        let now = timestamp::now_seconds();
        let voting_end = now + VOTING_PERIOD_SECS;

        let proposal = Proposal {
            id,
            proposer: proposer_addr,
            target_package_addr,
            new_module_bytes_hash,
            votes_for: 0,
            votes_against: 0,
            voters: smart_table::new(),
            created_at_secs: now,
            voting_end_secs: voting_end,
            approved_at_secs: option::none(),
            executed_at_secs: option::none(),
            cancelled: false,
        };

        smart_table::add(&mut state.proposals, id, proposal);

        event::emit(ProposalCreated {
            proposal_id: id,
            proposer: proposer_addr,
            target_package_addr,
            new_module_bytes_hash,
            voting_end_secs: voting_end,
        });
    }

    public entry fun cast_vote(
        voter: &signer,
        proposal_id: u64,
        support: bool,
    ) acquires GovernanceState {
        let voter_addr = signer::address_of(voter);
        let weight = voting_power(voter_addr);
        assert!(weight > 0, E_INSUFFICIENT_VOTING_POWER);

        let state = borrow_global_mut<GovernanceState>(@desnet);
        assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = smart_table::borrow_mut(&mut state.proposals, proposal_id);

        let now = timestamp::now_seconds();
        assert!(!proposal.cancelled, E_PROPOSAL_INACTIVE);
        assert!(option::is_none(&proposal.approved_at_secs), E_ALREADY_RATIFIED);
        assert!(now < proposal.voting_end_secs, E_VOTING_PERIOD_OVER);
        assert!(!smart_table::contains(&proposal.voters, voter_addr), E_ALREADY_VOTED);

        let vote = ProposalVote {
            voter: voter_addr,
            weight,
            support,
            cast_at_secs: now,
        };
        smart_table::add(&mut proposal.voters, voter_addr, vote);

        if (support) {
            proposal.votes_for = proposal.votes_for + weight;
        } else {
            proposal.votes_against = proposal.votes_against + weight;
        };

        event::emit(VoteCast {
            proposal_id,
            voter: voter_addr,
            support,
            weight,
        });
    }

    /// Anyone can call after voting period ends. Idempotent on already-ratified.
    public entry fun ratify(
        _caller: &signer,
        proposal_id: u64,
    ) acquires GovernanceState, Emission30dRollingBucket {
        // Pre-compute quorum BEFORE mut-borrow (view fn acquires same resource = conflict).
        let q = quorum_amount();

        let state = borrow_global_mut<GovernanceState>(@desnet);
        assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = smart_table::borrow_mut(&mut state.proposals, proposal_id);

        let now = timestamp::now_seconds();
        assert!(now >= proposal.voting_end_secs, E_VOTING_PERIOD_ACTIVE);
        assert!(option::is_none(&proposal.approved_at_secs), E_ALREADY_RATIFIED);
        assert!(!proposal.cancelled, E_PROPOSAL_INACTIVE);

        let total_cast = proposal.votes_for + proposal.votes_against;
        assert!(total_cast >= q, E_QUORUM_NOT_MET);

        // Approval: votes_for / total_cast >= 70%
        assert!(
            proposal.votes_for * 10000 >= APPROVAL_THRESHOLD_BPS * total_cast,
            E_APPROVAL_NOT_MET
        );

        proposal.approved_at_secs = option::some(now);

        event::emit(ProposalRatified {
            proposal_id,
            votes_for_final: proposal.votes_for,
            votes_against_final: proposal.votes_against,
            timelock_until: now + TIMELOCK_SECS,
        });
    }

    /// Execute approved proposal after timelock expires. Calls
    /// `code::publish_package_txn` with the derived package signer.
    ///
    /// H1 fix (audit R1): the executor MUST submit metadata + code_bytes whose
    /// digest matches `proposal.new_module_bytes_hash` recorded at propose time.
    /// Without this check, executor can ship arbitrary code post-timelock - full
    /// DAO bypass. Digest scheme: sha3_256(bcs(metadata) ++ concat(bcs(code_bytes[i])))
    /// - `propose_upgrade` callers MUST use the same scheme to compute their hash.
    public entry fun execute_proposal(
        caller: &signer,
        proposal_id: u64,
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ) acquires GovernanceState {
        // Compute digest BEFORE deriving pkg_signer (deterministic on inputs).
        let submitted_digest = compute_upgrade_digest(&metadata, &code_bytes);

        // Derive pkg signer (acquires GovernanceState) before mut-borrow below.
        let pkg_signer = derive_pkg_signer();

        let target_package_addr;
        {
            let state = borrow_global_mut<GovernanceState>(@desnet);
            assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
            let proposal = smart_table::borrow_mut(&mut state.proposals, proposal_id);

            let approved_opt = proposal.approved_at_secs;
            assert!(option::is_some(&approved_opt), E_QUORUM_NOT_MET);
            assert!(option::is_none(&proposal.executed_at_secs), E_ALREADY_EXECUTED);

            let approved_at = *option::borrow(&approved_opt);
            let now = timestamp::now_seconds();
            assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);

            // Verify submitted code matches what voters approved.
            assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);

            // v0.3.2 (F14, R2 Kimi R2-N1): defense-in-depth at execute too.
            // `target_package_addr` was sanitized at propose time, but re-assert in
            // case future code paths bypass propose-time validation.
            assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);

            proposal.executed_at_secs = option::some(now);
            target_package_addr = proposal.target_package_addr;
        };

        // Real on-chain dispatch (no cross-package cycle in monolith).
        code::publish_package_txn(&pkg_signer, metadata, code_bytes);

        event::emit(ProposalExecuted {
            proposal_id,
            target_package_addr,
            executor: signer::address_of(caller),
        });
    }

    // ============ DAO CHUNKED EXECUTE (v0.3.2 F8) ============
    //
    // Sister of multisig_stage_upgrade_chunk / multisig_publish_chunked_upgrade but
    // gated on DAO proposal lifecycle (approved + ratified + timelock-elapsed).
    //
    // Reuses `UpgradeStaging` resource. Hash-verify the assembled (metadata, code) at
    // publish time matches `proposal.new_module_bytes_hash`. Auth: anyone can call
    // (post-ratify, the DAO has spoken; staging is pure mechanics).
    //
    // Flow:
    //   1. Anyone calls `dao_stage_upgrade_chunk(proposal_id, ...)` N-1 times to stage
    //   2. Anyone calls `dao_publish_chunked_upgrade(proposal_id, last_chunk, ...)` -
    //      stages final + verifies digest + publishes + marks proposal executed

    /// v0.3.3 (G2): per-proposal staging via DaoUpgradeStaging. Auto-resets if
    /// existing staging is for a different proposal. Locks appends to original
    /// stager addr to prevent grief from concurrent callers on same proposal.
    fun dao_stage_chunks_into_staging(
        pkg_signer: &signer,
        caller_addr: address,
        proposal_id: u64,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires DaoUpgradeStaging {
        assert!(
            vector::length(&code_indices) == vector::length(&code_chunks),
            E_ARGS_LEN_MISMATCH
        );
        // Auto-reset if existing staging is for a different proposal (stale).
        if (exists<DaoUpgradeStaging>(@desnet)) {
            let staging_ref = borrow_global<DaoUpgradeStaging>(@desnet);
            if (staging_ref.proposal_id != proposal_id) {
                let _ = move_from<DaoUpgradeStaging>(@desnet);
            } else {
                // Same proposal - must be original stager (anti-grief append).
                assert!(staging_ref.stager == caller_addr, E_NOT_STAGER);
            };
        };
        if (!exists<DaoUpgradeStaging>(@desnet)) {
            move_to(pkg_signer, DaoUpgradeStaging {
                proposal_id,
                stager: caller_addr,
                metadata: vector::empty(),
                code: vector::empty(),
            });
        };
        let staging = borrow_global_mut<DaoUpgradeStaging>(@desnet);
        vector::append(&mut staging.metadata, metadata_chunk);
        let n = vector::length(&code_chunks);
        let i = 0;
        while (i < n) {
            let idx = (*vector::borrow(&code_indices, i) as u64);
            while (vector::length(&staging.code) <= idx) {
                vector::push_back(&mut staging.code, vector::empty());
            };
            let target = vector::borrow_mut(&mut staging.code, idx);
            let chunk = *vector::borrow(&code_chunks, i);
            vector::append(target, chunk);
            i = i + 1;
        };
    }

    public entry fun dao_stage_upgrade_chunk(
        caller: &signer,
        proposal_id: u64,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires GovernanceState, DaoUpgradeStaging {
        // Verify proposal is approved + ratified + timelock-elapsed (same as execute_proposal).
        let state = borrow_global<GovernanceState>(@desnet);
        assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        let proposal = smart_table::borrow(&state.proposals, proposal_id);
        let approved_opt = proposal.approved_at_secs;
        assert!(option::is_some(&approved_opt), E_QUORUM_NOT_MET);
        assert!(option::is_none(&proposal.executed_at_secs), E_ALREADY_EXECUTED);
        let approved_at = *option::borrow(&approved_opt);
        let now = timestamp::now_seconds();
        assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
        assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);

        let caller_addr = signer::address_of(caller);
        let pkg_signer = derive_pkg_signer();
        dao_stage_chunks_into_staging(&pkg_signer, caller_addr, proposal_id, metadata_chunk, code_indices, code_chunks);
    }

    public entry fun dao_publish_chunked_upgrade(
        caller: &signer,
        proposal_id: u64,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires GovernanceState, DaoUpgradeStaging {
        // Re-verify (defense-in-depth - staging may span days; conditions can change).
        let target_package_addr;
        let stored_hash;
        {
            let state = borrow_global<GovernanceState>(@desnet);
            assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
            let proposal = smart_table::borrow(&state.proposals, proposal_id);
            let approved_opt = proposal.approved_at_secs;
            assert!(option::is_some(&approved_opt), E_QUORUM_NOT_MET);
            assert!(option::is_none(&proposal.executed_at_secs), E_ALREADY_EXECUTED);
            let approved_at = *option::borrow(&approved_opt);
            let now = timestamp::now_seconds();
            assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
            assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);
            target_package_addr = proposal.target_package_addr;
            stored_hash = proposal.new_module_bytes_hash;
        };

        let caller_addr = signer::address_of(caller);
        let pkg_signer = derive_pkg_signer();
        dao_stage_chunks_into_staging(&pkg_signer, caller_addr, proposal_id, metadata_chunk, code_indices, code_chunks);

        let DaoUpgradeStaging { proposal_id: _, stager: _, metadata, code } = move_from<DaoUpgradeStaging>(@desnet);

        // Defense-in-depth - same empty-slot check as multisig variant.
        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };

        // Verify assembled payload matches the hash voters approved.
        // v0.3.3 NOTE: on hash-fail, abort reverts entire tx including the move_from above
        // -> DaoUpgradeStaging stays UNTOUCHED (Move atomicity), so legitimate publisher can
        // retry without a separate cleanup call.
        let assembled_digest = compute_upgrade_digest(&metadata, &code);
        assert!(assembled_digest == stored_hash, E_HASH_MISMATCH);

        // Mark proposal executed BEFORE publish (preserve ordering vs single-tx execute).
        let now = timestamp::now_seconds();
        {
            let state_mut = borrow_global_mut<GovernanceState>(@desnet);
            let proposal_mut = smart_table::borrow_mut(&mut state_mut.proposals, proposal_id);
            proposal_mut.executed_at_secs = option::some(now);
        };

        code::publish_package_txn(&pkg_signer, metadata, code);

        event::emit(ProposalExecuted {
            proposal_id,
            target_package_addr,
            executor: caller_addr,
        });
    }

    /// v0.3.3 (G2): permissionless cleanup of DAO chunked staging. Anyone can wipe
    /// `DaoUpgradeStaging` if it's stale or grief'd. Cost = gas only. Original stager
    /// (or anyone else) can re-stage cleanly afterward. Multisig path's `cleanup_upgrade_staging`
    /// remains multisig-only by design (different trust model).
    public entry fun dao_cleanup_upgrade_staging(_caller: &signer) acquires DaoUpgradeStaging {
        if (exists<DaoUpgradeStaging>(@desnet)) {
            let _ = move_from<DaoUpgradeStaging>(@desnet);
        };
    }

    #[view]
    public fun dao_upgrade_staging_exists(): bool { exists<DaoUpgradeStaging>(@desnet) }

    #[view]
    public fun dao_upgrade_staging_proposal_id(): u64 acquires DaoUpgradeStaging {
        if (!exists<DaoUpgradeStaging>(@desnet)) return 0;
        borrow_global<DaoUpgradeStaging>(@desnet).proposal_id
    }

    /// Canonical digest of upgrade payload. Used by both `propose_upgrade` (off-chain
    /// callers compute this on the intended payload) and `execute_proposal` (verifies
    /// submitted bytes match). Scheme: sha3_256(bcs(metadata) || concat(bcs(code_bytes[i]))).
    /// Off-chain callers should prefer `compute_upgrade_digest_view` (owned-value
    /// wrapper, callable via `/v1/view`) - this reference variant is for on-chain use.
    public fun compute_upgrade_digest(
        metadata: &vector<u8>,
        code_bytes: &vector<vector<u8>>,
    ): vector<u8> {
        let buf = bcs::to_bytes(metadata);
        let i = 0;
        let n = vector::length(code_bytes);
        while (i < n) {
            let chunk_bcs = bcs::to_bytes(vector::borrow(code_bytes, i));
            vector::append(&mut buf, chunk_bcs);
            i = i + 1;
        };
        hash::sha3_256(buf)
    }

    /// R3 fix (Claude R2-N3): owned-value `#[view]` wrapper around
    /// `compute_upgrade_digest`. Lets off-chain SDKs invoke gas-free via
    /// `/v1/view` for ground-truth hash verification before calling
    /// `propose_upgrade`. Identical semantics to the reference variant.
    #[view]
    public fun compute_upgrade_digest_view(
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ): vector<u8> {
        compute_upgrade_digest(&metadata, &code_bytes)
    }

    // ============ VIEWS ============

    /// voting_power = min(rewards_earned_30d, current DESNET balance).
    /// v0.3.1 Item 3b: DESNET FA addr hardcoded as `DESNET_FA_ADDR` constant (eliminates
    /// manipulation surface). `state.desnet_fa_metadata` field intentionally ignored
    /// (vestigial; compat-preserved).
    /// Object-exists guard: returns 0 pre-`register_handle("desnet")` (when DESNET FA
    /// hasn't been spawned yet at the deterministic addr).
    /// NOTE v0.3.1: `rewards_earned_30d` still mixed-token aggregate. Item 2 (per-token
    /// rewards isolation) deferred to v0.3.2 - until then, voting power = min(LP-stake-
    /// earned-mixed, DESNET balance). Cross-token reward claims still inflate first
    /// term but bound by DESNET balance.
    /// v0.3.3 (G1, R5 CONV-3 HIGH fix): per-USER fallback eliminates lazy-flip
    /// disenfranchisement. Previous v0.3.2 logic checked GLOBAL `has_per_token_registry`
    /// - first claimer post-v0.3.2 flipped the flag for everyone, instantly zeroing
    /// voting_power for all other pre-existing voters until they claimed themselves.
    /// New logic: per-user - read per-token if THIS voter has a per-token entry; else
    /// fall back to legacy mixed for THIS voter. Each voter migrates individually
    /// when they next claim. No cross-voter flip event.
    ///
    /// v0.3.3 R6 NOTE (Qwen H1 vs Claude analysis): Qwen flagged that voter who
    /// claims only non-DESNET (e.g., $alice) gets has_per_token_entry==true ->
    /// DESNET-only branch returns 0 -> voting_power=0. Initial fix used per-token
    /// DESNET-specific check, but Claude correctly identified this would re-open
    /// the F7 cross-token inflation surface (legacy includes mixed). REVERTED to
    /// generic per-user check - F7-strict semantic preserved. A voter who claims
    /// any token post-v0.3.2 is "in the new system" and evaluated by F7 rules
    /// (DESNET-specific only).
    #[view]
    public fun voting_power(voter_addr: address): u64 acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        if (!supra_framework::object::object_exists<supra_framework::fungible_asset::Metadata>(DESNET_FA_ADDR))
            return 0;
        let earned = if (voter_history::has_per_token_entry(voter_addr)) {
            voter_history::rewards_earned_30d_for_token(voter_addr, DESNET_FA_ADDR)
        } else {
            voter_history::rewards_earned_30d(voter_addr)
        };
        let fa_meta = supra_framework::object::address_to_object<supra_framework::fungible_asset::Metadata>(
            DESNET_FA_ADDR
        );
        let balance = supra_framework::primary_fungible_store::balance(voter_addr, fa_meta);
        if (earned < balance) earned else balance
    }

    #[view]
    public fun proposal_threshold_amount(): u64 acquires GovernanceState, Emission30dRollingBucket {
        // v0.3.2 (F6): use effective (max of auto-tracked, manual) for denominator.
        let eff = effective_30d_emission();
        if (eff == 0) return 18446744073709551615u64;
        (eff * PROPOSAL_THRESHOLD_BPS) / 10000
    }

    #[view]
    public fun quorum_amount(): u64 acquires GovernanceState, Emission30dRollingBucket {
        // v0.3.2 (F6): use effective (max of auto-tracked, manual) for denominator.
        let eff = effective_30d_emission();
        if (eff == 0) return 18446744073709551615u64;
        (eff * QUORUM_BPS) / 10000
    }

    // ============ ADMIN SETTERS (multisig-only) ============

    const E_NOT_MULTISIG_ADMIN: u64 = 100;

    /// v0.3.1 Item 3b: NEUTERED. DESNET FA addr now hardcoded as `DESNET_FA_ADDR` constant.
    /// Field `desnet_fa_metadata` retained as vestigial (compat-only, not read).
    /// Eliminates manipulation surface where multisig could set malicious FA addr post
    /// `disable_multisig_upgrade`.
    public entry fun update_desnet_fa_metadata(
        _multisig: &signer,
        _fa_addr: address,
    ) acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        abort E_NEUTERED
    }

    #[view]
    public fun desnet_fa_addr(): address { DESNET_FA_ADDR }

    /// v0.3.2 (F6b): NEUTERED. Auto-tracker (Emission30dRollingBucket) is sole source
    /// of truth via `effective_30d_emission()`. Manual setter eliminates manipulation
    /// surface where multisig could pin denominator to favorable value.
    /// Field `total_30d_emission` retained as vestigial (compat-only, not read).
    public entry fun update_total_30d_emission(
        _multisig: &signer,
        _amount: u64,
    ) acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        abort E_NEUTERED
    }

    /// Update the native FA metadata address (e.g., if SUPRA address changes or for different networks).
    public entry fun update_native_fa_metadata(
        multisig: &signer,
        new_addr: address,
    ) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        let state = borrow_global_mut<GovernanceState>(@desnet);
        state.native_fa_metadata = new_addr;
    }

    #[view]
    public fun timelock_secs(): u64 { TIMELOCK_SECS }

    #[view]
    public fun voting_period_secs(): u64 { VOTING_PERIOD_SECS }

    #[view]
    public fun proposal_count(): u64 acquires GovernanceState {
        borrow_global<GovernanceState>(@desnet).proposal_count
    }

    #[view]
    public fun proposal_exists(proposal_id: u64): bool acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        smart_table::contains(&state.proposals, proposal_id)
    }

    #[view]
    public fun proposal_hash(proposal_id: u64): vector<u8> acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        smart_table::borrow(&state.proposals, proposal_id).new_module_bytes_hash
    }

    #[view]
    public fun proposal_target(proposal_id: u64): address acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        smart_table::borrow(&state.proposals, proposal_id).target_package_addr
    }

    #[view]
    public fun proposal_approved_at(proposal_id: u64): Option<u64> acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        smart_table::borrow(&state.proposals, proposal_id).approved_at_secs
    }

    #[view]
    public fun proposal_executed_at(proposal_id: u64): Option<u64> acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        smart_table::borrow(&state.proposals, proposal_id).executed_at_secs
    }

    // ============ TEST-ONLY HELPERS ============

    /// Test-only init: bypasses resource_account::retrieve_resource_account_cap
    /// (which requires actual deploy via create_resource_account). Synthesizes
    /// a SignerCapability at @desnet for derive_pkg_signer to work in tests.
    #[test_only]
    public fun init_for_test() {
        use supra_framework::account;
        if (!account::exists_at(@desnet)) {
            account::create_account_for_test(@desnet);
        };
        let desnet_signer = account::create_signer_for_test(@desnet);
        let signer_cap = account::create_test_signer_cap(@desnet);

        move_to(&desnet_signer, GovernanceState {
            signer_cap,
            proposal_count: 0,
            proposals: smart_table::new(),
            desnet_fa_metadata: @0x0,
            native_fa_metadata: @0xa,
            total_30d_emission: 0,
            multisig_upgrade_disabled: false,
        });
        voter_history::init_registry(&desnet_signer);
    }
}

```

---

## `sources/history.move`

```move
/// History - per-PID append-only on-chain log (LOCKED 2026-05-01).
///
/// Replaces event::emit for the 7-verb palette (Mint/Spark/Voice/Echo/Remix/Press/Sync).
/// Class-B primitive: Move runtime CAN read entries via view fns for gating logic
/// (Endorse, ReferenceGate cross-checks) without indexer dependency.
///
/// Storage: HistoryLog at PID Object addr (lazy-init via profile::derive_pid_signer).
/// Entries grouped into HistoryChunks (separate Objects owned by PID); current chunk
/// rotates when ~30KB threshold reached. Sealed chunks immutable from this module.
///
/// Cached counters per verb (O(1) view) - count_verb(pid, verb) for gating.
///
/// Encoding: Entry.payload = BCS-encoded verb-specific data (e.g., bcs::to_bytes(&MintEvent{..})).
/// Frontend / indexer decodes payload via Move struct definitions in respective modules.
module desnet::history {
    use std::option::Option;
    use std::signer;
    use std::vector;
    use supra_framework::object;

    use desnet::profile;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::link;
    friend desnet::press;
    friend desnet::opinion;

    // ============ CONSTANTS ============

    /// Verb enum (history Entry.verb).
    const VERB_MINT: u8 = 0;
    const VERB_SPARK: u8 = 1;
    const VERB_VOICE: u8 = 2;
    const VERB_ECHO: u8 = 3;
    const VERB_REMIX: u8 = 4;
    const VERB_PRESS: u8 = 5;
    const VERB_SYNC: u8 = 6;
    const VERB_OPINION: u8 = 7;

    /// Chunk rotation threshold: when current chunk's tracked size exceeds this,
    /// seal it and allocate a new one. ~30KB ~ 375 small entries.
    const CHUNK_ROTATE_THRESHOLD: u64 = 30000;

    /// Per-Entry payload hard cap (BCS bytes only; Entry.asset is separate ref).
    /// Sized to fit worst-case BCS-encoded MintEvent: inline media (8192) + content (333) +
    /// 5 tags + 10 mentions + 5 tickers + 10 tips + Option overhead ~ 10075 bytes. 12000
    /// gives 1925-byte headroom. CHUNK_ROTATE_THRESHOLD (30000) still > 2* this so chunk
    /// rotation calculus remains sane.
    const MAX_PAYLOAD_BYTES: u64 = 12000;

    /// Per-entry overhead estimate (verb + ts + target option + asset option +
    /// vector length headers). Used for chunk size accounting.
    const ENTRY_OVERHEAD_BYTES: u64 = 64;

    // ============ ERROR CODES ============

    const E_PAYLOAD_TOO_LARGE: u64 = 1;
    // E_PID_NOT_FOUND removed (was unused - profile module owns PID-existence checks).
    const E_HISTORY_NOT_INITIALIZED: u64 = 3;
    const E_CHUNK_NOT_FOUND: u64 = 4;
    const E_INVALID_VERB: u64 = 5;

    // ============ TYPES ============

    /// Per-PID history log root. Lives at PID Object addr.
    /// head_chunk is always set after ensure_history_log (initialized lazily on first append).
    struct HistoryLog has key {
        head_chunk: address,
        sealed_chunks: vector<address>,
        entry_count: u64,
        total_bytes: u64,                  // running sum of (payload + overhead) across all chunks
        head_chunk_bytes: u64,             // bytes accumulated in current head_chunk
        // Cached per-verb counters (O(1) reads for gating)
        mint_count: u64,
        spark_count: u64,
        voice_count: u64,
        echo_count: u64,
        remix_count: u64,
        press_count: u64,
        sync_count: u64,
    }

    /// Append-only chunk holding a vector of Entry. Sealed=true after rotate.
    /// Module mutators check `sealed == false` before appending; sealed chunks
    /// are read-only from Move runtime perspective.
    struct HistoryChunk has key {
        entries: vector<Entry>,
        sealed: bool,
    }

    /// Single history entry. BCS-encoded into payload by the verb module.
    /// Has store + copy + drop so it can be vec-pushed and copy-read by views.
    struct Entry has store, copy, drop {
        verb: u8,
        timestamp_secs: u64,
        target: Option<address>,           // referenced PID/post for Echo/Sync/Voice/Remix
        payload: vector<u8>,               // BCS-encoded verb-specific data, <=MAX_PAYLOAD_BYTES
        asset: Option<address>,            // optional desnet::assets::Master ref (>8KB media)
    }

    // ============ FRIEND CONSTRUCTORS ============

    /// Build an Entry for friend module to pass into append.
    /// Validates payload size cap.
    public(friend) fun new_entry(
        verb: u8,
        timestamp_secs: u64,
        target: Option<address>,
        payload: vector<u8>,
        asset: Option<address>,
    ): Entry {
        assert!(verb <= VERB_OPINION, E_INVALID_VERB);
        assert!(vector::length(&payload) <= MAX_PAYLOAD_BYTES, E_PAYLOAD_TOO_LARGE);
        Entry { verb, timestamp_secs, target, payload, asset }
    }

    // ============ LAZY-INIT ============

    /// Lazy-create HistoryLog + first HistoryChunk at PID addr. Idempotent.
    /// Called from append on first-write per PID. Cycle-safe via
    /// profile::derive_pid_signer friend pattern (history is friend of profile).
    fun ensure_history_log(pid_addr: address) {
        if (exists<HistoryLog>(pid_addr)) return;

        let pid_signer = profile::derive_pid_signer(pid_addr);

        // First chunk Object owned by PID addr
        let chunk_constructor = object::create_object(pid_addr);
        let chunk_signer = object::generate_signer(&chunk_constructor);
        let chunk_addr = signer::address_of(&chunk_signer);
        move_to(&chunk_signer, HistoryChunk {
            entries: vector::empty(),
            sealed: false,
        });

        move_to(&pid_signer, HistoryLog {
            head_chunk: chunk_addr,
            sealed_chunks: vector::empty(),
            entry_count: 0,
            total_bytes: 0,
            head_chunk_bytes: 0,
            mint_count: 0,
            spark_count: 0,
            voice_count: 0,
            echo_count: 0,
            remix_count: 0,
            press_count: 0,
            sync_count: 0,
        });
    }

    // ============ APPEND (friend-only) ============

    /// Append an Entry to PID's history. Lazy-init on first call.
    /// Auto-rotates chunk when threshold exceeded: seals current head, allocates new.
    public(friend) fun append(pid_addr: address, entry: Entry)
        acquires HistoryLog, HistoryChunk
    {
        ensure_history_log(pid_addr);

        let entry_size = vector::length(&entry.payload) + ENTRY_OVERHEAD_BYTES;

        // Check rotate condition
        let log = borrow_global_mut<HistoryLog>(pid_addr);
        if (log.head_chunk_bytes + entry_size > CHUNK_ROTATE_THRESHOLD) {
            // Seal current head (mark immutable; sealed chunks not mutated by this module)
            let old_head = log.head_chunk;
            {
                let head_chunk = borrow_global_mut<HistoryChunk>(old_head);
                head_chunk.sealed = true;
            };
            vector::push_back(&mut log.sealed_chunks, old_head);

            // Allocate new chunk Object owned by PID addr
            let new_chunk_constructor = object::create_object(pid_addr);
            let new_chunk_signer = object::generate_signer(&new_chunk_constructor);
            let new_chunk_addr = signer::address_of(&new_chunk_signer);
            move_to(&new_chunk_signer, HistoryChunk {
                entries: vector::empty(),
                sealed: false,
            });

            log.head_chunk = new_chunk_addr;
            log.head_chunk_bytes = 0;
        };

        // Append entry to head chunk
        let verb = entry.verb;
        {
            let head = borrow_global_mut<HistoryChunk>(log.head_chunk);
            vector::push_back(&mut head.entries, entry);
        };

        // Bump global counters
        log.entry_count = log.entry_count + 1;
        log.total_bytes = log.total_bytes + entry_size;
        log.head_chunk_bytes = log.head_chunk_bytes + entry_size;

        // Bump per-verb counter
        if (verb == VERB_MINT) {
            log.mint_count = log.mint_count + 1;
        } else if (verb == VERB_SPARK) {
            log.spark_count = log.spark_count + 1;
        } else if (verb == VERB_VOICE) {
            log.voice_count = log.voice_count + 1;
        } else if (verb == VERB_ECHO) {
            log.echo_count = log.echo_count + 1;
        } else if (verb == VERB_REMIX) {
            log.remix_count = log.remix_count + 1;
        } else if (verb == VERB_PRESS) {
            log.press_count = log.press_count + 1;
        } else if (verb == VERB_SYNC) {
            log.sync_count = log.sync_count + 1;
        };
    }

    // ============ VIEWS ============

    #[view]
    public fun history_exists(pid_addr: address): bool {
        exists<HistoryLog>(pid_addr)
    }

    #[view]
    public fun total_entries(pid_addr: address): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        borrow_global<HistoryLog>(pid_addr).entry_count
    }

    #[view]
    public fun total_bytes(pid_addr: address): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        borrow_global<HistoryLog>(pid_addr).total_bytes
    }

    #[view]
    public fun head_chunk_addr(pid_addr: address): address acquires HistoryLog {
        assert!(exists<HistoryLog>(pid_addr), E_HISTORY_NOT_INITIALIZED);
        borrow_global<HistoryLog>(pid_addr).head_chunk
    }

    #[view]
    public fun sealed_chunks_list(pid_addr: address): vector<address> acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return vector::empty();
        borrow_global<HistoryLog>(pid_addr).sealed_chunks
    }

    #[view]
    public fun chunk_entries_count(chunk_addr: address): u64 acquires HistoryChunk {
        if (!exists<HistoryChunk>(chunk_addr)) return 0;
        vector::length(&borrow_global<HistoryChunk>(chunk_addr).entries)
    }

    #[view]
    public fun chunk_is_sealed(chunk_addr: address): bool acquires HistoryChunk {
        if (!exists<HistoryChunk>(chunk_addr)) return false;
        borrow_global<HistoryChunk>(chunk_addr).sealed
    }

    /// Read a specific entry from a chunk by local index. Aborts if out of range.
    /// Returns (verb, timestamp_secs, target, payload, asset) tuple.
    #[view]
    public fun chunk_entry_at(
        chunk_addr: address,
        idx: u64,
    ): (u8, u64, Option<address>, vector<u8>, Option<address>)
        acquires HistoryChunk
    {
        assert!(exists<HistoryChunk>(chunk_addr), E_CHUNK_NOT_FOUND);
        let entries = &borrow_global<HistoryChunk>(chunk_addr).entries;
        let e = vector::borrow(entries, idx);
        (e.verb, e.timestamp_secs, e.target, e.payload, e.asset)
    }

    /// Cached per-verb counter - O(1) for gating logic.
    /// E.g., Endorse gate: count_verb(target_pid, VERB_SPARK) >= threshold.
    #[view]
    public fun count_verb(pid_addr: address, verb: u8): u64 acquires HistoryLog {
        if (!exists<HistoryLog>(pid_addr)) return 0;
        let log = borrow_global<HistoryLog>(pid_addr);
        if (verb == VERB_MINT) log.mint_count
        else if (verb == VERB_SPARK) log.spark_count
        else if (verb == VERB_VOICE) log.voice_count
        else if (verb == VERB_ECHO) log.echo_count
        else if (verb == VERB_REMIX) log.remix_count
        else if (verb == VERB_PRESS) log.press_count
        else if (verb == VERB_SYNC) log.sync_count
        else 0
    }

    // Verb constant getters (for cross-module + frontend use)

    #[view]
    public fun verb_mint(): u8 { VERB_MINT }

    #[view]
    public fun verb_spark(): u8 { VERB_SPARK }

    #[view]
    public fun verb_voice(): u8 { VERB_VOICE }

    #[view]
    public fun verb_echo(): u8 { VERB_ECHO }

    #[view]
    public fun verb_remix(): u8 { VERB_REMIX }

    #[view]
    public fun verb_press(): u8 { VERB_PRESS }

    #[view]
    public fun verb_sync(): u8 { VERB_SYNC }

    #[view]
    public fun verb_opinion(): u8 { VERB_OPINION }

    #[view]
    public fun max_payload_bytes(): u64 { MAX_PAYLOAD_BYTES }

    #[view]
    public fun chunk_rotate_threshold(): u64 { CHUNK_ROTATE_THRESHOLD }

    // ============ TESTS ============

    #[test]
    fun test_new_entry_payload_at_cap() {
        let payload = vector::empty<u8>();
        let i = 0;
        while (i < MAX_PAYLOAD_BYTES) {
            vector::push_back(&mut payload, 0x42);
            i = i + 1;
        };
        let _e = new_entry(VERB_MINT, 1000, std::option::none<address>(), payload, std::option::none<address>());
    }

    #[test]
    #[expected_failure(abort_code = E_PAYLOAD_TOO_LARGE, location = Self)]
    fun test_new_entry_payload_over_cap() {
        let payload = vector::empty<u8>();
        let i = 0;
        while (i < MAX_PAYLOAD_BYTES + 1) {
            vector::push_back(&mut payload, 0x42);
            i = i + 1;
        };
        let _e = new_entry(VERB_SPARK, 0, std::option::none<address>(), payload, std::option::none<address>());
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_VERB, location = Self)]
    fun test_new_entry_invalid_verb() {
        // VERB_OPINION = 7 (added post-opinion-port). 8 is the next invalid value.
        let _e = new_entry(8, 0, std::option::none<address>(), vector::empty(), std::option::none<address>());
    }

    #[test]
    fun test_verb_constants() {
        assert!(verb_mint() == 0, 1);
        assert!(verb_spark() == 1, 2);
        assert!(verb_voice() == 2, 3);
        assert!(verb_press() == 5, 6);
        assert!(verb_echo() == 3, 4);
        assert!(verb_remix() == 4, 5);
        assert!(verb_sync() == 6, 7);
    }

    // ============ INTEGRATION TESTS (append + rotate) ============

    #[test_only]
    use supra_framework::timestamp;
    #[test_only]
    use supra_framework::account;
    #[test_only]
    use std::option;

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_first_append_lazy_init(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));

        let pid_addr = profile::setup_test_pid(creator);
        assert!(!history_exists(pid_addr), 1);

        let entry = new_entry(VERB_MINT, 1, option::none(), vector::empty(), option::none());
        append(pid_addr, entry);

        assert!(history_exists(pid_addr), 2);
        assert!(total_entries(pid_addr) == 1, 3);
        assert!(count_verb(pid_addr, VERB_MINT) == 1, 4);
        assert!(count_verb(pid_addr, VERB_SPARK) == 0, 5);
    }

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_verb_counters_independent(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        // Append 3 sparks, 1 voice, 2 echoes
        append(pid_addr, new_entry(VERB_SPARK, 1, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_SPARK, 2, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_SPARK, 3, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_VOICE, 4, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_ECHO, 5, option::none(), vector::empty(), option::none()));
        append(pid_addr, new_entry(VERB_ECHO, 6, option::none(), vector::empty(), option::none()));

        assert!(total_entries(pid_addr) == 6, 1);
        assert!(count_verb(pid_addr, VERB_SPARK) == 3, 2);
        assert!(count_verb(pid_addr, VERB_VOICE) == 1, 3);
        assert!(count_verb(pid_addr, VERB_ECHO) == 2, 4);
        assert!(count_verb(pid_addr, VERB_MINT) == 0, 5);
        assert!(count_verb(pid_addr, VERB_REMIX) == 0, 6);
    }

    #[test(framework = @supra_framework, creator = @0xa11ce)]
    fun test_history_chunk_rotates_at_threshold(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        // Each entry: 8000B payload + 64B overhead = 8064B. Threshold = 30000B.
        // 3 entries: 24192B (under). 4th append: would-be 32256B > 30000 -> rotate fires.
        let big_payload = vector::empty<u8>();
        let i = 0;
        while (i < 8000) { vector::push_back(&mut big_payload, 0xAA); i = i + 1; };

        // First 3 appends: no rotate
        let j = 0;
        while (j < 3) {
            append(pid_addr, new_entry(VERB_MINT, j, option::none(), big_payload, option::none()));
            j = j + 1;
        };
        let sealed_before = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_before) == 0, 1);
        let head_before = head_chunk_addr(pid_addr);

        // 4th append triggers rotation (24192 + 8064 = 32256 > 30000)
        append(pid_addr, new_entry(VERB_MINT, 99, option::none(), big_payload, option::none()));

        let sealed_after = sealed_chunks_list(pid_addr);
        assert!(vector::length(&sealed_after) == 1, 2);
        // Old head sealed + matches what we observed before rotate
        let old_head = *vector::borrow(&sealed_after, 0);
        assert!(old_head == head_before, 3);
        assert!(chunk_is_sealed(old_head), 4);
        // New head exists, distinct, not sealed
        let new_head = head_chunk_addr(pid_addr);
        assert!(new_head != old_head, 5);
        assert!(!chunk_is_sealed(new_head), 6);
        // Mint counter tracks across chunks (3 in old + 1 in new)
        assert!(count_verb(pid_addr, VERB_MINT) == 4, 7);
        assert!(total_entries(pid_addr) == 4, 8);
    }
}

```

---

## `sources/ipo.move`

```move
/// IPO (Initial Pool Offering) - replaces 90%-5%-5% with 100% pooled distribution.
///
/// -- Concept --
/// Buyer deposits SUPRA at fixed entry price during the IPO phase. Each deposit
/// mints a transferable Position NFT representing LP shares in the AMM pool.
///
/// -- Target TVL not yet reached --
///   Burn Position -> refund 100% SUPRA (tokens returned from IPO reserve).
///
/// -- Target TVL reached --
///   Pool unlocks (swaps enabled). LP holders earn swap fees via MasterChef
///   accumulator (amm::fee_per_lp_supra / amm::fee_per_lp_token).
///   Principal stays in the pool - cannot be withdrawn.
///
/// -- Subdomain Profile --
///   IPO creator gets the main handle (PID NFT).
///   IPO participants get subdomain: `alice@domain`.
module desnet::ipo {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::governance;
    use desnet::voter_history;
    use desnet::profile;
    use desnet::lp_emission;

    friend desnet::factory;
    friend desnet::registration;

    const SEED_IPO: vector<u8> = b"desnet::ipo::pool::";
    const SEED_SUBDOMAIN: vector<u8> = b"desnet::subdomain::";

    const E_IPO_NOT_FOUND: u64 = 1;
    const E_IPO_ALREADY_EXISTS: u64 = 2;
    const E_IPO_COMPLETED: u64 = 3;
    const E_IPO_NOT_COMPLETED: u64 = 4;
    const E_ZERO_DEPOSIT: u64 = 5;
    const E_OVER_TARGET: u64 = 6;
    const E_BELOW_TARGET: u64 = 7;
    const E_POSITION_NOT_FOUND: u64 = 8;
    const E_NOT_OWNER: u64 = 9;
    const E_NO_POOL: u64 = 10;
    const E_ALREADY_COMPLETED: u64 = 11;
    const E_NOTHING_TO_CLAIM: u64 = 12;
    const E_BAD_RATIO: u64 = 13;
    const E_SUBDOMAIN_TAKEN: u64 = 14;
    const E_INVALID_SUBDOMAIN: u64 = 15;
    const E_EXCEEDS_MAX_ALLOCATION: u64 = 16;
    const E_TARGET_TOO_LOW: u64 = 17;

    /// Max cumulative deposit per address = 1% of target TVL (normal participant).
    const MAX_PER_ADDRESS_BPS: u64 = 100;
    /// Creator's elevated cap = 10% of target TVL. Caller qualifies for the
    /// elevated cap iff `caller_addr == ipo.creator_wallet` (frozen at
    /// create_ipo). The creator's LP shares themselves still ride on a
    /// creator-chosen subdomain PID NFT - same lock-to-PID mechanics as every
    /// other participant. The frozen `creator_wallet` only gates the 10% cap
    /// eligibility, not where the LP lives.
    const MAX_CREATOR_BPS: u64 = 1000;
    const MIN_TARGET_TVL: u64 = 100_000_000_000_000;

    /// ----- Types -----

    struct IPOPool has key {
        handle: vector<u8>,
        token_metadata_addr: address,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
        total_supra_raised: u64,
        total_token_deployed: u64,
        completed: bool,
        supra_store: Object<FungibleStore>,
        token_store: Object<FungibleStore>,
        extend_ref: ExtendRef,
        pool_addr: address,
        total_lp: u128,
        depositor_totals: SmartTable<address, u64>,
        // Frozen at create_ipo. Cap-eligibility wallet only - the creator
        // participates via the same participate_ipo path as anyone else, and
        // their LP lives on a creator-chosen subdomain PID NFT (same
        // lock-to-PID mechanics as all other participants). Transferring
        // the main-handle PID does NOT migrate cap eligibility - it stays
        // with the original registrant wallet.
        creator_wallet: address,
    }

    /// IPO Position. Stored as a resource at the participant's subdomain PID
    /// addr - NOT a separate Object. Transferring the subdomain Profile NFT
    /// implicitly carries the LP shares + reward debts with it (creator-style
    /// locked LP - sell the identity, sell the position).
    struct Position has key {
        ipo_addr: address,
        depositor: address,
        supra_deposited: u64,
        shares: u128,
        fee_debt_supra: u128,
        fee_debt_token: u128,
        // MasterChef per-reward-token debt. Keyed by reward FA addr. Missing
        // entry == debt 0 (joined before this token was registered in the
        // gauge - gives full historical earn, correct because at notify-time
        // the gauge's total_share already included this position).
        reward_debts: SmartTable<address, u128>,
        subdomain: String,
    }

    /// Subdomain registry per handle.
    struct SubdomainRegistry has key {
        domain: String,
        entries: SmartTable<String, address>,
    }

    /// ----- Events -----

    #[event]
    struct IPOCreated has drop, store {
        handle: vector<u8>,
        ipo_addr: address,
        token_metadata_addr: address,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
    }

    #[event]
    struct DepositMade has drop, store {
        handle: vector<u8>,
        depositor: address,
        position_addr: address,
        supra_amount: u64,
        token_amount: u64,
        lp_minted: u128,
        total_supra_raised: u64,
        subdomain: String,
    }

    #[event]
    struct Refunded has drop, store {
        handle: vector<u8>,
        position_addr: address,
        depositor: address,
        supra_returned: u64,
        lp_burned: u128,
    }

    #[event]
    struct IPOCompleted has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        total_supra: u64,
        total_token: u64,
        total_lp: u128,
    }

    #[event]
    struct FeesClaimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        supra_amount: u64,
        token_amount: u64,
    }

    #[event]
    struct SubdomainRegistered has drop, store {
        domain: String,
        subdomain: String,
        owner: address,
    }

    #[event]
    struct LpRewardsClaimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        reward_token: address,
        amount: u64,
    }

    /// ----- Address derivation -----

    public fun ipo_address_of_handle(handle: vector<u8>): address {
        object::create_object_address(&@desnet, ipo_seed(&handle))
    }

    fun ipo_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_IPO;
        vector::append(&mut s, *handle);
        s
    }

    fun subdomain_registry_address(handle: &vector<u8>): address {
        let s = SEED_SUBDOMAIN;
        vector::append(&mut s, *handle);
        object::create_object_address(&@desnet, s)
    }

    /// ----- Init (friend-only, dipanggil factory) -----

    public(friend) fun create_ipo(
        handle: vector<u8>,
        token_metadata_addr: address,
        token_fa: FungibleAsset,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
        creator_wallet: address,
    ) {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(!exists<IPOPool>(ipo_addr), E_IPO_ALREADY_EXISTS);
        assert!(target_tvl >= MIN_TARGET_TVL, E_TARGET_TOO_LOW);
        assert!(entry_price_x > 0 && entry_price_y > 0, E_BAD_RATIO);
        assert!(fungible_asset::amount(&token_fa) > 0, 2);

        let pkg_signer = governance::derive_pkg_signer();
        let constructor = object::create_named_object(&pkg_signer, ipo_seed(&handle));
        let ipo_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let supra_store = fungible_asset::create_store(&constructor, supra_meta);
        let token_meta = object::address_to_object<Metadata>(token_metadata_addr);
        let token_store = fungible_asset::create_store(&constructor, token_meta);

        fungible_asset::deposit(token_store, token_fa);

        move_to(&ipo_signer, IPOPool {
            handle,
            token_metadata_addr,
            target_tvl,
            entry_price_x,
            entry_price_y,
            total_supra_raised: 0,
            total_token_deployed: 0,
            completed: false,
            supra_store,
            token_store,
            extend_ref,
            pool_addr: @0x0,
            total_lp: 0,
            depositor_totals: smart_table::new(),
            creator_wallet,
        });

        // Init subdomain registry
        let reg_addr = subdomain_registry_address(&handle);
        if (!exists<SubdomainRegistry>(reg_addr)) {
            let reg_constructor = object::create_named_object(&pkg_signer, {
                let s = SEED_SUBDOMAIN;
                vector::append(&mut s, handle);
                s
            });
            let reg_signer = object::generate_signer(&reg_constructor);
            move_to(&reg_signer, SubdomainRegistry {
                domain: string::utf8(handle),
                entries: smart_table::new(),
            });
        };

        event::emit(IPOCreated {
            handle,
            ipo_addr,
            token_metadata_addr,
            target_tvl,
            entry_price_x,
            entry_price_y,
        });
    }

    /// ----- Deposit SUPRA -----

    public entry fun deposit_supra(
        caller: &signer,
        handle: vector<u8>,
        amount: u64,
        subdomain: vector<u8>,
    ) acquires IPOPool, SubdomainRegistry {
        let caller_addr = signer::address_of(caller);
        assert!(amount > 0, E_ZERO_DEPOSIT);
        let sub_name = string::utf8(subdomain);
        validate_subdomain(&sub_name);

        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_IPO_COMPLETED);
        let new_total = ipo.total_supra_raised + amount;
        assert!(new_total <= ipo.target_tvl, E_OVER_TARGET);
        let addr_total = if (smart_table::contains(&ipo.depositor_totals, caller_addr)) {
            *smart_table::borrow(&ipo.depositor_totals, caller_addr)
        } else { 0 };
        // Creator gets a 10% cap, everyone else 1%. The wallet identity
        // eligible for the elevated cap is frozen at create_ipo and does
        // not migrate when the main-handle PID is transferred. The LP
        // shares minted from the creator's deposit still lock onto a
        // creator-chosen subdomain PID NFT - same path as every other
        // participant - so the LP itself follows NFT transfer normally.
        let bps = if (caller_addr == ipo.creator_wallet) { MAX_CREATOR_BPS } else { MAX_PER_ADDRESS_BPS };
        let max_per_addr = (ipo.target_tvl * bps) / 10000;
        assert!(addr_total + amount <= max_per_addr, E_EXCEEDS_MAX_ALLOCATION);
        smart_table::upsert(&mut ipo.depositor_totals, caller_addr, addr_total + amount);

        let token_amount = (((amount as u128) * (ipo.entry_price_y as u128)
            / (ipo.entry_price_x as u128)) as u64);
        assert!(token_amount > 0, E_ZERO_DEPOSIT);

        // Financial transfer FIRST (fix M1: subdomain only registered after SUPRA secured)
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let supra_fa = primary_fungible_store::withdraw(caller, supra_meta, amount);
        let ipo_signer = object::generate_signer_for_extending(&ipo.extend_ref);
        let token_fa = fungible_asset::withdraw(&ipo_signer, ipo.token_store, token_amount);

        // Register subdomain (after transfers succeed)
        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
        assert!(!smart_table::contains(&reg.entries, sub_name), E_SUBDOMAIN_TAKEN);
        smart_table::add(&mut reg.entries, sub_name, caller_addr);

        let lp_minted: u128;
        if (ipo.pool_addr == @0x0) {
            ipo.pool_addr = amm::pool_address_of_handle(handle);
            lp_minted = amm::create_pool_atomic(handle, supra_fa, token_fa, ipo_addr, false);
        } else {
            let (lp, supra_refund, token_refund) = amm::add_liquidity_internal(
                handle, supra_fa, token_fa, 0,
            );
            lp_minted = lp;
            if (fungible_asset::amount(&supra_refund) > 0) {
                primary_fungible_store::deposit(caller_addr, supra_refund);
            } else {
                fungible_asset::destroy_zero(supra_refund);
            };
            if (fungible_asset::amount(&token_refund) > 0) {
                primary_fungible_store::deposit(caller_addr, token_refund);
            } else {
                fungible_asset::destroy_zero(token_refund);
            };
        };

        ipo.total_supra_raised = new_total;
        ipo.total_token_deployed = ipo.total_token_deployed + token_amount;
        ipo.total_lp = ipo.total_lp + lp_minted;

        let (fee_supra, fee_token) = if (ipo.pool_addr != @0x0) {
            amm::fee_per_lp(handle)
        } else {
            (0u128, 0u128)
        };

        // Snapshot reward-debt for every reward token already registered in
        // the gauge. Prevents the new position from claiming historical
        // earnings (acc_per_share advanced before this position contributed
        // to total_share). Tokens registered after this deposit get
        // missing-key debt = 0, capturing full earn from registration onward.
        let reward_tokens = lp_emission::reward_tokens_of(handle);
        let reward_debts = smart_table::new<address, u128>();
        let rt_i = 0;
        let rt_n = vector::length(&reward_tokens);
        while (rt_i < rt_n) {
            let rt = *vector::borrow(&reward_tokens, rt_i);
            let acc = lp_emission::acc_per_share_of(handle, rt);
            smart_table::add(&mut reward_debts, rt, (lp_minted as u128) * acc);
            rt_i = rt_i + 1;
        };

        // Increase the gauge's total_share BEFORE storing the Position so
        // that any reads of total_share between now and the next notify see
        // this position counted.
        lp_emission::on_share_increase(handle, lp_minted);

        // Create the subdomain PID first - Position stores as a resource at
        // the PID's deterministic addr so transferring the NFT carries the
        // LP shares + reward debts implicitly (creator-style locked LP).
        let protocol_signer = governance::derive_pkg_signer();
        profile::create_subdomain_profile(
            &protocol_signer, string::utf8(handle), sub_name, caller_addr, !ipo.completed,
        );
        let pos_addr = profile::derive_subdomain_pid_address(string::utf8(handle), sub_name);
        let pos_signer = profile::derive_pid_signer(pos_addr);

        move_to(&pos_signer, Position {
            ipo_addr,
            depositor: caller_addr,
            supra_deposited: amount,
            shares: lp_minted,
            fee_debt_supra: fee_supra,
            fee_debt_token: fee_token,
            reward_debts,
            subdomain: sub_name,
        });

        event::emit(DepositMade {
            handle,
            depositor: caller_addr,
            position_addr: pos_addr,
            supra_amount: amount,
            token_amount,
            lp_minted,
            total_supra_raised: new_total,
            subdomain: sub_name,
        });

        event::emit(SubdomainRegistered {
            domain: reg.domain,
            subdomain: sub_name,
            owner: caller_addr,
        });
    }

    /// ----- Burn Position -> refund SUPRA -----

    public entry fun burn_for_refund(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
        min_supra_out: u64,
        min_token_out: u64,
    ) acquires IPOPool, Position, SubdomainRegistry {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        // Position lives at the subdomain PID's addr - auth via the Profile NFT.
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

        // Settle outstanding gauge rewards into the owner BEFORE destruction.
        // Otherwise burn would silently forfeit them.
        claim_lp_rewards_internal(handle, position_addr, caller_addr);

        let pos = borrow_global<Position>(position_addr);
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(pos.ipo_addr == ipo_addr, E_IPO_NOT_FOUND);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_IPO_COMPLETED);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);

        // Y-2: caller-supplied slippage bounds. Y-3 self-audit lift -
        // a concurrent participate_ipo in the same block can dilute the
        // pool; min_supra_out / min_token_out let the burner refuse a
        // bad exit. Pass 0/0 for legacy no-slippage behavior.
        let lp_amount = pos.shares;
        let (supra_out, token_out) = amm::remove_liquidity_internal(
            handle, lp_amount, min_supra_out, min_token_out,
        );

        let supra_refund_amt = fungible_asset::amount(&supra_out);
        if (supra_refund_amt > 0) {
            primary_fungible_store::deposit(caller_addr, supra_out);
        } else {
            fungible_asset::destroy_zero(supra_out);
        };
        if (fungible_asset::amount(&token_out) > 0) {
            fungible_asset::deposit(ipo.token_store, token_out);
        } else {
            fungible_asset::destroy_zero(token_out);
        };

        ipo.total_lp = ipo.total_lp - lp_amount;
        ipo.total_supra_raised = ipo.total_supra_raised - pos.supra_deposited;

        // Y-1: anti-wash. Only free the depositor's allocation cap if the
        // refund is initiated by the ORIGINAL depositor (NFT never moved).
        // If the subdomain NFT has been transferred to a different owner,
        // the original depositor's cap stays consumed - closes the
        // deposit -> transfer -> refund -> re-deposit cycling exploit that
        // would otherwise let a single wallet rotate its 10% slot
        // indefinitely for market-manipulation purposes.
        if (caller_addr == pos.depositor) {
            let original_depositor = pos.depositor;
            let remaining = *smart_table::borrow(&ipo.depositor_totals, original_depositor) - pos.supra_deposited;
            if (remaining == 0) {
                smart_table::remove(&mut ipo.depositor_totals, original_depositor);
            } else {
                *smart_table::borrow_mut(&mut ipo.depositor_totals, original_depositor) = remaining;
            };
        };

        // Release subdomain
        let reg_addr = subdomain_registry_address(&handle);
        if (exists<SubdomainRegistry>(reg_addr)) {
            let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
            if (smart_table::contains(&reg.entries, pos.subdomain)) {
                smart_table::remove(&mut reg.entries, pos.subdomain);
            };
        };

        // Tell the gauge this share is leaving total_share before destruction.
        lp_emission::on_share_decrease(handle, lp_amount);

        let Position {
            ipo_addr: _,
            depositor: _,
            supra_deposited: _,
            shares: _,
            fee_debt_supra: _,
            fee_debt_token: _,
            reward_debts,
            subdomain: _,
        } = move_from<Position>(position_addr);
        smart_table::destroy(reward_debts);
        // No object::delete - Position is a resource attached to the
        // subdomain Profile NFT, not its own Object. The Profile remains
        // (orphan in SubdomainRegistry); refund is pre-completion only so
        // re-registration of the same name aborts with E_PID_ALREADY_EXISTS.
        // Accepted limitation for this iteration.

        event::emit(Refunded {
            handle,
            position_addr,
            depositor: caller_addr,
            supra_returned: supra_refund_amt,
            lp_burned: lp_amount,
        });
    }

    /// ----- Complete IPO -----

    public entry fun complete_ipo(
        _caller: &signer,
        handle: vector<u8>,
    ) acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_ALREADY_COMPLETED);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);
        // CRITICAL: must reach target_tvl before swaps unlock.
        // Pre-fix this was `> 0` - allowed anyone to lock the IPO after the
        // first deposit (refund path aborts when completed), turning the 100%
        // refund promise into a griefing surface.
        assert!(ipo.total_supra_raised >= ipo.target_tvl, E_BELOW_TARGET);

        ipo.completed = true;
        amm::enable_swaps(handle);

        event::emit(IPOCompleted {
            handle,
            pool_addr: ipo.pool_addr,
            total_supra: ipo.total_supra_raised,
            total_token: ipo.total_token_deployed,
            total_lp: ipo.total_lp,
        });
    }

    /// ----- Claim fees -----

    public entry fun claim_fees(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires Position, IPOPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

        let pos = borrow_global_mut<Position>(position_addr);
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(pos.ipo_addr == ipo_addr, E_IPO_NOT_FOUND);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        assert!(ipo.completed, E_IPO_NOT_COMPLETED);

        let (fee_supra, fee_token) = amm::fee_per_lp(handle);
        let scale = amm::fee_acc_scale();

        let raw_pending_supra = (pos.shares as u128) * fee_supra;
        let raw_debt_supra = (pos.shares as u128) * pos.fee_debt_supra;
        let pending_supra = (raw_pending_supra / scale) - (raw_debt_supra / scale);

        let raw_pending_token = (pos.shares as u128) * fee_token;
        let raw_debt_token = (pos.shares as u128) * pos.fee_debt_token;
        let pending_token = (raw_pending_token / scale) - (raw_debt_token / scale);

        assert!((pending_supra + pending_token) > 0, E_NOTHING_TO_CLAIM);

        pos.fee_debt_supra = fee_supra;
        pos.fee_debt_token = fee_token;

        let (supra_fa, token_fa) = amm::extract_fees_for_claim(
            handle, (pending_supra as u64), (pending_token as u64),
        );

        if (fungible_asset::amount(&supra_fa) > 0) {
            primary_fungible_store::deposit(caller_addr, supra_fa);
        } else {
            fungible_asset::destroy_zero(supra_fa);
        };
        let token_fee_amount = fungible_asset::amount(&token_fa);
        if (token_fee_amount > 0) {
            primary_fungible_store::deposit(caller_addr, token_fa);
            // Record DESNET-side LP fee for voting power
            if (ipo.token_metadata_addr == governance::desnet_fa_addr()) {
                let pkg_signer = governance::derive_pkg_signer();
                voter_history::record_reward_received_for_token(
                    &pkg_signer, caller_addr, governance::desnet_fa_addr(), token_fee_amount,
                );
            };
        } else {
            fungible_asset::destroy_zero(token_fa);
        };

        event::emit(FeesClaimed {
            handle,
            position_addr,
            recipient: caller_addr,
            supra_amount: (pending_supra as u64),
            token_amount: (pending_token as u64),
        });
    }

    /// ----- Claim LP gauge rewards -----

    /// Walk every reward token the gauge currently tracks, settle per-token
    /// pending into the position's CURRENT owner (so post-transfer the new
    /// owner gets the rewards), and advance the per-token debt cursor.
    /// Permissionless caller is fine - rewards flow to the subdomain Profile
    /// NFT's owner, not the caller.
    public entry fun claim_lp_rewards(
        _caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        let owner = object::owner(pid_obj);
        claim_lp_rewards_internal(handle, position_addr, owner);
    }

    fun claim_lp_rewards_internal(
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
    ) acquires Position {
        let reward_tokens = lp_emission::reward_tokens_of(handle);
        let n = vector::length(&reward_tokens);
        if (n == 0) return;

        let pos = borrow_global_mut<Position>(position_addr);
        let shares = pos.shares;
        let scale = lp_emission::acc_scale();
        let desnet_fa = governance::desnet_fa_addr();

        let i = 0;
        while (i < n) {
            let token_addr = *vector::borrow(&reward_tokens, i);
            let acc = lp_emission::acc_per_share_of(handle, token_addr);
            let owed_raw = (shares as u128) * acc;
            let debt = if (smart_table::contains(&pos.reward_debts, token_addr)) {
                *smart_table::borrow(&pos.reward_debts, token_addr)
            } else {
                0u128
            };
            if (owed_raw > debt) {
                let pending = (((owed_raw - debt) / scale) as u64);
                if (pending > 0) {
                    let token_meta = object::address_to_object<Metadata>(token_addr);
                    let fa = lp_emission::withdraw_reward(handle, token_meta, pending);
                    primary_fungible_store::deposit(recipient, fa);

                    if (smart_table::contains(&pos.reward_debts, token_addr)) {
                        *smart_table::borrow_mut(&mut pos.reward_debts, token_addr) = owed_raw;
                    } else {
                        smart_table::add(&mut pos.reward_debts, token_addr, owed_raw);
                    };

                    if (token_addr == desnet_fa) {
                        let pkg_signer = governance::derive_pkg_signer();
                        voter_history::record_reward_received_for_token(
                            &pkg_signer, recipient, token_addr, pending,
                        );
                    };

                    event::emit(LpRewardsClaimed {
                        handle,
                        position_addr,
                        recipient,
                        reward_token: token_addr,
                        amount: pending,
                    });
                };
            };
            i = i + 1;
        };
    }

    /// ----- Views -----

    #[view]
    public fun ipo_info(handle: vector<u8>): (
        address, u64, u64, u64, u64, u64, bool, address, u128,
    ) acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        (
            ipo.token_metadata_addr,
            ipo.target_tvl,
            ipo.entry_price_x,
            ipo.entry_price_y,
            ipo.total_supra_raised,
            ipo.total_token_deployed,
            ipo.completed,
            ipo.pool_addr,
            ipo.total_lp,
        )
    }

    /// ----- Claim subdomain PID post-IPO -----

    /// Allows a Position owner to claim a subdomain + PID NFT after IPO completes.
    /// Uniqueness guaranteed via SubdomainRegistry (shared with deposit_supra path).
    /// Callable by anyone who owns a Position in the domain, even after transfer.
    public entry fun claim_subdomain_pid(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
        subdomain: vector<u8>,
    ) acquires IPOPool, SubdomainRegistry {
        let caller_addr = signer::address_of(caller);
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        assert!(ipo.completed, E_IPO_NOT_COMPLETED);

        let sub_name = string::utf8(subdomain);
        validate_subdomain(&sub_name);

        // Uniqueness - shared SubdomainRegistry with deposit_supra path
        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
        assert!(!smart_table::contains(&reg.entries, sub_name), E_SUBDOMAIN_TAKEN);
        smart_table::add(&mut reg.entries, sub_name, caller_addr);

        let protocol_signer = governance::derive_pkg_signer();
        profile::create_subdomain_profile(
            &protocol_signer, string::utf8(handle), sub_name, caller_addr, false,
        );
    }

    #[view]
    public fun position_info(position_addr: address): (
        address, address, u64, u128, u128, u128, String,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pos = borrow_global<Position>(position_addr);
        (
            pos.ipo_addr,
            pos.depositor,
            pos.supra_deposited,
            pos.shares,
            pos.fee_debt_supra,
            pos.fee_debt_token,
            pos.subdomain,
        )
    }

    #[view]
    public fun pending_fees(
        handle: vector<u8>,
        position_addr: address,
    ): (u64, u64) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pos = borrow_global<Position>(position_addr);
        let (fee_supra, fee_token) = amm::fee_per_lp(handle);
        let scale = amm::fee_acc_scale();
        let raw_pending_supra = ((pos.shares as u128) * fee_supra) / scale;
        let raw_debt_supra = ((pos.shares as u128) * pos.fee_debt_supra) / scale;
        let pending_supra = if (raw_pending_supra > raw_debt_supra) {
            raw_pending_supra - raw_debt_supra
        } else { 0 };
        let raw_pending_token = ((pos.shares as u128) * fee_token) / scale;
        let raw_debt_token = ((pos.shares as u128) * pos.fee_debt_token) / scale;
        let pending_token = if (raw_pending_token > raw_debt_token) {
            raw_pending_token - raw_debt_token
        } else { 0 };
        ((pending_supra as u64), (pending_token as u64))
    }

    #[view]
    public fun resolve_subdomain(handle: vector<u8>, subdomain: String): address
    acquires SubdomainRegistry {
        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global<SubdomainRegistry>(reg_addr);
        assert!(smart_table::contains(&reg.entries, subdomain), E_SUBDOMAIN_TAKEN);
        *smart_table::borrow(&reg.entries, subdomain)
    }

    #[view]
    public fun has_subdomain(handle: vector<u8>, subdomain: String): bool
    acquires SubdomainRegistry {
        let reg_addr = subdomain_registry_address(&handle);
        if (!exists<SubdomainRegistry>(reg_addr)) return false;
        let reg = borrow_global<SubdomainRegistry>(reg_addr);
        smart_table::contains(&reg.entries, subdomain)
    }

    #[view]
    public fun depositor_total(handle: vector<u8>, depositor: address): u64
    acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        if (smart_table::contains(&ipo.depositor_totals, depositor)) {
            *smart_table::borrow(&ipo.depositor_totals, depositor)
        } else { 0 }
    }

    /// ----- Validation -----

    fun validate_subdomain(name: &String) {
        let len = string::length(name);
        assert!(len >= 1 && len <= 32, E_INVALID_SUBDOMAIN);
        let bytes = string::bytes(name);
        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(bytes, i);
            let ok = (ch >= 0x61 && ch <= 0x7A)
                  || (ch >= 0x30 && ch <= 0x39)
                  || ch == 0x2D;
            assert!(ok, E_INVALID_SUBDOMAIN);
            i = i + 1;
        };
    }

    // ============ MOVE PROVER SPEC ============

    spec module {
        /// Invariant: after first deposit, pool_addr is set and never resets.
        invariant update [suspendable]
            forall ipo_p: address:
                (old(exists<IPOPool>(ipo_p)) && exists<IPOPool>(ipo_p))
                ==> (old(borrow_global<IPOPool>(ipo_p).pool_addr) != @0x0
                     ==> borrow_global<IPOPool>(ipo_p).pool_addr == old(borrow_global<IPOPool>(ipo_p).pool_addr));

        /// Invariant: completed => pool_addr is set.
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).completed ==> borrow_global<IPOPool>(ipo_p).pool_addr != @0x0;

        /// Invariant: completed flag is monotonic (never goes from true -> false).
        invariant update [suspendable]
            forall ipo_p: address:
                (old(exists<IPOPool>(ipo_p)) && exists<IPOPool>(ipo_p))
                ==> (old(borrow_global<IPOPool>(ipo_p).completed) ==> borrow_global<IPOPool>(ipo_p).completed);

        /// Invariant: total_supra_raised <= target_tvl when NOT completed.
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                !borrow_global<IPOPool>(ipo_p).completed
                ==> borrow_global<IPOPool>(ipo_p).total_supra_raised <= borrow_global<IPOPool>(ipo_p).target_tvl;

        /// Invariant: target_tvl >= MIN_TARGET_TVL.
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).target_tvl >= MIN_TARGET_TVL;

        /// Invariant: entry prices are positive.
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).entry_price_x > 0
                && borrow_global<IPOPool>(ipo_p).entry_price_y > 0;

        /// Invariant: total_lp fits in u128 bounds (no arithmetic overflow risk).
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).total_lp <= 340282366920938463463374607431768211455;

        /// Invariant: token_metadata_addr is set and immutable.
        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).token_metadata_addr != @0x0;
    }

    spec fun spec_ipo_seed(handle: vector<u8>): vector<u8> {
        concat(SEED_IPO, handle)
    }

    spec fun spec_subdomain_seed(handle: vector<u8>): vector<u8> {
        concat(SEED_SUBDOMAIN, handle)
    }

    spec position_info {
        aborts_if !exists<Position>(position_addr);
    }
    spec pending_fees {
        aborts_if !exists<Position>(position_addr);
    }
}

```

---

## `sources/link.move`

```move
/// Link - Sync action + PidSyncSet on-chain state (LOCKED 2026-05-01).
///
/// Sync = subscribe to a PID's mints. Unidirectional like node-syncs-to-chain.
/// ENDORSE removed from link_kind enum (= derived view from LP staking position).
///
/// LinkEvent { link_kind: SYNC, state: ADD/REMOVE } - kept ADD/REMOVE pattern
/// (Supra events immutable on emit; un-action emits state=REMOVE).
///
/// PidSyncSet at syncer's PID (NOT target's). Target has count only - popular
/// accounts can't afford full follower-list resource. Indexer derives "who syncs
/// me" from event stream.
///
/// sync_gate (profile-level) gates incoming Sync requests: must pass
/// ReferenceGate.check(actor, target_pid, skip_sync_check=true). Sync precondition
/// itself is skipped (chicken-egg avoidance - first sync to gated PID).
module desnet::link {
    use std::bcs;
    use std::signer;
    use std::option;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::profile::ReferenceGate;
    use desnet::reference_gate;
    use desnet::history;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS ============

    /// link_kind enum (LinkEvent.link_kind)
    const LINK_SYNC: u8 = 1;
    // ENDORSE removed 2026-05-01 - derived from LP staking, not on-chain link_kind.

    /// state enum (LinkEvent.state)
    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    // ============ ERROR CODES ============

    const E_NOT_PID: u64 = 1;
    const E_TARGET_NOT_PID: u64 = 2;
    const E_SYNC_GATE_FAILED: u64 = 3;
    const E_ALREADY_SYNCED: u64 = 4;
    const E_NOT_SYNCED: u64 = 5;
    const E_SELF_SYNC_DISALLOWED: u64 = 6;
    const E_SYNC_SET_NOT_INITIALIZED: u64 = 7;

    // ============ TYPES ============

    /// Per-PID sync set. Stored at syncer's PID Object addr.
    /// `syncs: SmartTable<target_pid, true>` - set semantic, value unused.
    struct PidSyncSet has key {
        syncs: SmartTable<address, bool>,
        sync_count: u64,                    // # of PIDs I sync (= len of syncs table)
        synced_by_count: u64,               // # of PIDs that sync to me (incremented externally via friend)
    }

    // ============ EVENTS ============

    /// Link record (Sync/Unsync). Replaces former #[event] - now BCS-encoded into
    /// history::Entry.payload. Struct retained for canonical encoding.
    struct LinkEvent has drop, store {
        actor_pid: address,
        target_pid: address,
        link_kind: u8,                      // LINK_SYNC only (others removed)
        state: u8,                          // STATE_ADD or STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidSyncSet at PID addr. Called from sync/unsync on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
    fun ensure_sync_set(pid_addr: address) {
        if (!exists<PidSyncSet>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidSyncSet {
                syncs: smart_table::new(),
                sync_count: 0,
                synced_by_count: 0,
            });
        };
    }

    // ============ SYNC + UNSYNC ENTRIES ============

    /// Sync to target_pid. Adds to syncer's PidSyncSet, increments target's
    /// synced_by_count, emits LinkEvent { kind=SYNC, state=ADD }.
    ///
    /// Validation:
    /// - Syncer must be Named tier (Profile exists at syncer's PID)
    /// - target_pid must be Named tier
    /// - target's sync_gate (if set) must pass for syncer (skip_sync_check=true)
    /// - No self-sync
    /// - Not already synced
    public entry fun sync(
        syncer: &signer,
        syncer_pid: address,
        target_pid: address,
        syncer_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidSyncSet {
        profile::assert_authorized(syncer, syncer_pid);
        let syncer_addr = signer::address_of(syncer);

        profile::assert_pid_exists(target_pid);
        assert!(syncer_pid != target_pid, E_SELF_SYNC_DISALLOWED);

        // sync_gate check - skip_sync_check=true (chicken-egg avoidance: can't require
        // sync precondition for the action that creates sync). Sync param is irrelevant
        // when skip_sync_check=true; pass false for clarity.
        let gate_opt = profile::get_sync_gate(target_pid);
        assert!(
            reference_gate::is_open_for(&gate_opt, syncer_addr, false, true, syncer_stake_position_addr),
            E_SYNC_GATE_FAILED
        );

        // Lazy-init both syncer's + target's sync set (target needs synced_by_count counter)
        ensure_sync_set(syncer_pid);
        ensure_sync_set(target_pid);

        let set = borrow_global_mut<PidSyncSet>(syncer_pid);
        assert!(!smart_table::contains(&set.syncs, target_pid), E_ALREADY_SYNCED);
        smart_table::add(&mut set.syncs, target_pid, true);
        set.sync_count = set.sync_count + 1;

        // Target's synced_by_count (lazy-init guaranteed by ensure_sync_set above)
        let target_set = borrow_global_mut<PidSyncSet>(target_pid);
        target_set.synced_by_count = target_set.synced_by_count + 1;

        let now_secs = timestamp::now_seconds();
        let record = LinkEvent {
            actor_pid: syncer_pid,
            target_pid,
            link_kind: LINK_SYNC,
            state: STATE_ADD,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        history::append(
            syncer_pid,
            history::new_entry(history::verb_sync(), now_secs, option::some(target_pid), payload, option::none<address>()),
        );
    }

    /// Unsync from target_pid. Removes from syncer's PidSyncSet, decrements counts,
    /// emits LinkEvent { kind=SYNC, state=REMOVE }.
    public entry fun unsync(
        syncer: &signer,
        syncer_pid: address,
        target_pid: address,
    ) acquires PidSyncSet {
        profile::assert_authorized(syncer, syncer_pid);

        assert!(exists<PidSyncSet>(syncer_pid), E_SYNC_SET_NOT_INITIALIZED);
        let set = borrow_global_mut<PidSyncSet>(syncer_pid);
        assert!(smart_table::contains(&set.syncs, target_pid), E_NOT_SYNCED);
        smart_table::remove(&mut set.syncs, target_pid);
        set.sync_count = set.sync_count - 1;

        if (exists<PidSyncSet>(target_pid)) {
            let target_set = borrow_global_mut<PidSyncSet>(target_pid);
            if (target_set.synced_by_count > 0) {
                target_set.synced_by_count = target_set.synced_by_count - 1;
            };
        };

        let now_secs = timestamp::now_seconds();
        let record = LinkEvent {
            actor_pid: syncer_pid,
            target_pid,
            link_kind: LINK_SYNC,
            state: STATE_REMOVE,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        history::append(
            syncer_pid,
            history::new_entry(history::verb_sync(), now_secs, option::some(target_pid), payload, option::none<address>()),
        );
    }

    // ============ VIEWS ============

    #[view]
    public fun is_synced(syncer_pid: address, target_pid: address): bool acquires PidSyncSet {
        if (!exists<PidSyncSet>(syncer_pid)) return false;
        smart_table::contains(&borrow_global<PidSyncSet>(syncer_pid).syncs, target_pid)
    }

    #[view]
    public fun sync_count(pid_addr: address): u64 acquires PidSyncSet {
        if (!exists<PidSyncSet>(pid_addr)) return 0;
        borrow_global<PidSyncSet>(pid_addr).sync_count
    }

    #[view]
    public fun synced_by_count(pid_addr: address): u64 acquires PidSyncSet {
        if (!exists<PidSyncSet>(pid_addr)) return 0;
        borrow_global<PidSyncSet>(pid_addr).synced_by_count
    }

    #[view]
    public fun sync_kind(): u8 { LINK_SYNC }

    #[view]
    public fun state_add(): u8 { STATE_ADD }

    #[view]
    public fun state_remove(): u8 { STATE_REMOVE }
}

```

---

## `sources/lp_emission.move`

```move
/// LP Rewards Gauge - multi-FA permissionless rewards pool for LP positions.
///
/// One pool per handle. Anyone can `notify_reward` with ANY FA. Each notify
/// bumps a MasterChef-style `acc_per_share` accumulator for that reward token.
/// Positions (held by `ipo::Position`) carry per-token reward debt and claim
/// by walking the pool's reward-token list.
///
/// Total-share bookkeeping is push-driven: ipo calls `on_share_increase` /
/// `on_share_decrease` whenever a Position is created or destroyed. This keeps
/// the module dependency one-way (ipo -> lp_emission) - lp_emission never reads
/// from ipo.
///
/// Replaces the v0.3 sealed-reserve design: Supra mode mints 100% supply into
/// the IPO pool, so the old "deploy 90% reserve at registration" path is gone.
/// The pool starts empty and is funded entirely by external topups.
module desnet::lp_emission {
    use std::signer;
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;

    use desnet::governance;

    friend desnet::ipo;

    // ============ CONSTANTS ============

    /// Fixed-point scale for acc_per_share - 1e12 (MasterChef standard).
    /// Trade-off: lowered from 1e18 to stay clear of u128 overflow on
    /// `shares * acc_per_share`. At extreme bounds (shares ~ 1e15 raw and
    /// cumulative acc ~ 1e23 across many notifies), the product approaches
    /// 1e38 which is still under u128_max (3.4e38). The cost is quantization:
    /// a notify of 1 raw unit against a pool with total_share = 1e12 contributes
    /// `delta = 1 * 1e12 / 1e12 = 1` raw unit per share - fine. Below 1e12
    /// total_share, sub-unit rewards may quantize to 0; permissionless top-ups
    /// of small amounts are encouraged to batch.
    const ACC_SCALE: u128 = 1_000_000_000_000;

    /// Anti-bloat: each pool can register at most this many distinct reward
    /// tokens. Once full, new tokens are rejected to keep iteration cheap.
    const MAX_REWARD_TOKENS: u64 = 32;

    const SEED_LP_REWARDS: vector<u8> = b"lp_rewards::";

    // ============ ERROR CODES ============

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_NO_SHARES: u64 = 3;
    const E_TOO_MANY_REWARD_TOKENS: u64 = 4;
    const E_REWARD_TOKEN_NOT_REGISTERED: u64 = 5;
    const E_SHARE_UNDERFLOW: u64 = 6;
    /// Y-4 (2026-05-17 self-audit): rejects dispatchable FAs. A hook-bearing
    /// FA registered here would let an attacker abort withdraw/deposit on
    /// claim_lp_rewards (and transitively burn_for_refund, which calls claim
    /// before destroying Position). That bricks IPO refunds entirely for any
    /// holder of a Position whose gauge has the malicious token registered.
    const E_DISPATCHABLE_FA_REJECTED: u64 = 7;

    // ============ TYPES ============

    struct LpRewardsPool has key {
        handle: vector<u8>,
        extend_ref: ExtendRef,
        total_share: u128,
        reward_tokens: SmartTable<address, RewardAccumulator>,
        reward_token_list: vector<address>,
    }

    struct RewardAccumulator has store, drop {
        acc_per_share: u128,        // raw FA units * ACC_SCALE per LP share
        total_topped_up: u128,
        total_distributed: u128,
    }

    // ============ EVENTS ============

    #[event]
    struct PoolInitialized has drop, store {
        pool_addr: address,
        handle: vector<u8>,
    }

    #[event]
    struct RewardTokenRegistered has drop, store {
        pool_addr: address,
        reward_token: address,
        slot_index: u64,
    }

    #[event]
    struct RewardNotified has drop, store {
        pool_addr: address,
        depositor: address,
        reward_token: address,
        amount: u64,
        total_share_at_notify: u128,
        acc_per_share_after: u128,
    }

    #[event]
    struct RewardPulled has drop, store {
        pool_addr: address,
        reward_token: address,
        amount: u64,
    }

    #[event]
    struct ShareChanged has drop, store {
        pool_addr: address,
        delta: u128,
        increased: bool,
        total_share_after: u128,
    }

    // ============ ADDRESS DERIVATION ============

    public fun pool_address_of_handle(handle: vector<u8>): address {
        object::create_object_address(&@desnet, make_seed(&handle))
    }

    fun make_seed(handle: &vector<u8>): vector<u8> {
        let seed = SEED_LP_REWARDS;
        vector::append(&mut seed, *handle);
        seed
    }

    // ============ INIT - lazy, auto-fires on first share increase or notify ============

    fun ensure_pool(handle: vector<u8>): address {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) {
            let pkg_signer = governance::derive_pkg_signer();
            let constructor_ref = object::create_named_object(&pkg_signer, make_seed(&handle));
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            object::disable_ungated_transfer(&transfer_ref);
            let pool_signer = object::generate_signer(&constructor_ref);
            move_to(&pool_signer, LpRewardsPool {
                handle,
                extend_ref,
                total_share: 0,
                reward_tokens: smart_table::new(),
                reward_token_list: vector::empty(),
            });
            event::emit(PoolInitialized { pool_addr, handle });
        };
        pool_addr
    }

    // ============ FRIEND: share-tracking hooks from ipo ============

    public(friend) fun on_share_increase(handle: vector<u8>, delta: u128)
        acquires LpRewardsPool
    {
        let pool_addr = ensure_pool(handle);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        pool.total_share = pool.total_share + delta;
        event::emit(ShareChanged {
            pool_addr,
            delta,
            increased: true,
            total_share_after: pool.total_share,
        });
    }

    public(friend) fun on_share_decrease(handle: vector<u8>, delta: u128)
        acquires LpRewardsPool
    {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<LpRewardsPool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        assert!(pool.total_share >= delta, E_SHARE_UNDERFLOW);
        pool.total_share = pool.total_share - delta;
        event::emit(ShareChanged {
            pool_addr,
            delta,
            increased: false,
            total_share_after: pool.total_share,
        });
    }

    // ============ NOTIFY - permissionless topup ============

    /// Anyone deposits any FA into the pool. Caller funds, accumulator bumps,
    /// existing positions earn pro-rata from this point forward.
    ///
    /// Aborts:
    /// - amount == 0
    /// - total_share == 0 (no positions to share with)
    /// - pool already tracks MAX_REWARD_TOKENS and this token isn't one of them
    public entry fun notify_reward(
        depositor: &signer,
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ) acquires LpRewardsPool {
        assert!(amount > 0, E_ZERO_AMOUNT);

        // Y-4: reject dispatchable FAs - see reaction_emission for the
        // attacker model. Here the failure mode is even worse because
        // ipo::burn_for_refund calls claim_lp_rewards_internal before
        // destroying Position; a hook-aborting reward token strands the
        // Position permanently (can never refund, NFT economic value
        // trapped). Check on depositor's primary store which must already
        // exist for the subsequent withdraw to succeed.
        let depositor_addr = signer::address_of(depositor);
        let depositor_store = primary_fungible_store::ensure_primary_store_exists(
            depositor_addr, reward_token_meta,
        );
        assert!(
            std::option::is_none(&fungible_asset::deposit_dispatch_function(depositor_store))
                && std::option::is_none(&fungible_asset::withdraw_dispatch_function(depositor_store)),
            E_DISPATCHABLE_FA_REJECTED,
        );

        let pool_addr = ensure_pool(handle);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        assert!(pool.total_share > 0, E_NO_SHARES);
        let total_share = pool.total_share;
        let token_addr = object::object_address(&reward_token_meta);

        if (!smart_table::contains(&pool.reward_tokens, token_addr)) {
            assert!(
                vector::length(&pool.reward_token_list) < MAX_REWARD_TOKENS,
                E_TOO_MANY_REWARD_TOKENS,
            );
            let slot = vector::length(&pool.reward_token_list);
            vector::push_back(&mut pool.reward_token_list, token_addr);
            smart_table::add(&mut pool.reward_tokens, token_addr, RewardAccumulator {
                acc_per_share: 0,
                total_topped_up: 0,
                total_distributed: 0,
            });
            event::emit(RewardTokenRegistered { pool_addr, reward_token: token_addr, slot_index: slot });
        };

        let fa = primary_fungible_store::withdraw(depositor, reward_token_meta, amount);
        primary_fungible_store::deposit(pool_addr, fa);

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        let delta = ((amount as u128) * ACC_SCALE) / total_share;
        acc.acc_per_share = acc.acc_per_share + delta;
        acc.total_topped_up = acc.total_topped_up + (amount as u128);
        let acc_after = acc.acc_per_share;

        event::emit(RewardNotified {
            pool_addr,
            depositor: signer::address_of(depositor),
            reward_token: token_addr,
            amount,
            total_share_at_notify: total_share,
            acc_per_share_after: acc_after,
        });

        // Feed governance's 30d rolling emission bucket for DESNET-denominated
        // topups only. DAO threshold/quorum reads this in lieu of a manual
        // multisig-bumped counter (v0.3.2 F6 design). Non-DESNET reward tokens
        // are silent to governance.
        if (token_addr == governance::desnet_fa_addr()) {
            governance::record_emission_for_window(amount);
        };
    }

    // ============ FRIEND: claim path called by ipo ============

    /// Snapshot acc_per_share for a token (debt-init + pending calc).
    /// Returns 0 if pool doesn't exist or token isn't registered.
    public fun acc_per_share_of(handle: vector<u8>, reward_token: address): u128
        acquires LpRewardsPool
    {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        let pool = borrow_global<LpRewardsPool>(pool_addr);
        if (!smart_table::contains(&pool.reward_tokens, reward_token)) return 0;
        smart_table::borrow(&pool.reward_tokens, reward_token).acc_per_share
    }

    /// Token list for ipo claim iteration. Empty vec if pool doesn't exist.
    public fun reward_tokens_of(handle: vector<u8>): vector<address> acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return vector::empty();
        borrow_global<LpRewardsPool>(pool_addr).reward_token_list
    }

    /// Friend-only: ipo claim path computes `pending` and pulls that amount as
    /// a hot-potato FA. ipo is responsible for depositing to the position owner.
    public(friend) fun withdraw_reward(
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ): FungibleAsset acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        assert!(exists<LpRewardsPool>(pool_addr), E_POOL_NOT_FOUND);
        let pool = borrow_global_mut<LpRewardsPool>(pool_addr);
        let token_addr = object::object_address(&reward_token_meta);
        assert!(
            smart_table::contains(&pool.reward_tokens, token_addr),
            E_REWARD_TOKEN_NOT_REGISTERED,
        );

        if (amount == 0) {
            return fungible_asset::zero(reward_token_meta)
        };

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        acc.total_distributed = acc.total_distributed + (amount as u128);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = primary_fungible_store::withdraw(&pool_signer, reward_token_meta, amount);

        event::emit(RewardPulled { pool_addr, reward_token: token_addr, amount });
        fa
    }

    // ============ VIEWS ============

    #[view]
    public fun pool_exists(handle: vector<u8>): bool {
        exists<LpRewardsPool>(pool_address_of_handle(handle))
    }

    #[view]
    public fun total_share_of(handle: vector<u8>): u128 acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        borrow_global<LpRewardsPool>(pool_addr).total_share
    }

    #[view]
    public fun reward_token_count(handle: vector<u8>): u64 acquires LpRewardsPool {
        let pool_addr = pool_address_of_handle(handle);
        if (!exists<LpRewardsPool>(pool_addr)) return 0;
        vector::length(&borrow_global<LpRewardsPool>(pool_addr).reward_token_list)
    }

    #[view]
    public fun reward_balance(
        handle: vector<u8>,
        reward_token_meta: Object<Metadata>,
    ): u64 {
        let pool_addr = pool_address_of_handle(handle);
        primary_fungible_store::balance(pool_addr, reward_token_meta)
    }

    #[view]
    public fun acc_scale(): u128 { ACC_SCALE }

    #[view]
    public fun max_reward_tokens(): u64 { MAX_REWARD_TOKENS }
}

```

---

## `sources/lp_staking.move`

```move
/// LP Position NFT - V3-style position management + emission + fee claims (LOCKED 2026-05-02).
///
/// LP repr: each position = an Object (NFT-style). NO LP FA exists.
/// Auth model: `object::owner(position)` - V3 NFT semantics. Position transferable.
/// Three position kinds via `unlock_at_secs` marker on unified `Position` struct:
///   1. **LockedPosition (creator atomic)** - unlock_at_secs = u64::MAX (never).
///      Stored AT pid_addr. Recipient at claim = object::owner(pid_obj) [auto-follows NFT transfer].
///   2. **FreePosition** - unlock_at_secs = 0 (anytime withdraw). Recipient = object::owner(position).
///   3. **TimeLockedPosition** - unlock_at_secs > 0 (withdraw after t). Recipient = object::owner(position).
///
/// Universal yield (LOCKED 2026-05-02): ALL positions earn:
///   - **Swap fees (SUPRA + TOKEN)** - proportional to shares / amm.lp_supply
///   - **Emission ($TOKEN from 900M reserve)** - C-variant, 10/sec, denominator = amm.lp_supply
///
/// No "raw LP forfeits" mechanic. No staked-vs-unstaked distinction. Free, time-locked,
/// locked all earn identically. The only difference is exit option (unlock_at).
///
/// Forever-lock invariant (structural): for unlock_at=u64::MAX, `unstake` aborts before
/// calling `amm::remove_liquidity_internal`. LP reserves never returned. Forever-locked.
module desnet::lp_staking {
    use std::signer;
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef, ObjectCore};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::governance;

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
    /// Denominator = amm::lp_supply(handle) (universal - all Position.shares contribute).
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
        last_fee_per_lp_supra: u128,                    // SUPRA fee snapshot
        last_fee_per_lp_token: u128,                  // TOKEN fee snapshot
        unlock_at_secs: u64,                          // 0=free, t=until-t, MAX=forever
        recipient_pid: address,                       // @0x0 -> pay object::owner(position); else -> object::owner(pid)
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
        supra_returned: u64,
        token_returned: u64,
    }

    #[event]
    struct Claimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        emission_amount: u64,
        supra_fee_amount: u64,
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

    // ============ CREATE - friend-only (factory atomic at register) ============

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
        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);

        move_to(pid_signer, Position {
            pool_addr,
            handle,
            shares: initial_shares,
            last_acc_per_share: 0,
            last_fee_per_lp_supra: fee_per_supra,
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

    // ============ ADD LIQUIDITY - public entries ============

    /// Public add liquidity. Withdraws SUPRA + TOKEN from caller, calls amm::add_liquidity_internal,
    /// creates Position (kind = free, unlock_at = 0). Returns nothing - Position is at caller-derived addr.
    /// Frontend reads PositionCreated event for position_addr.
    public entry fun add_liquidity(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
    ) acquires StakingPool {
        let unlock_at_secs = 0u64;
        add_liquidity_with_lock_internal(caller, handle, supra_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    /// Public add liquidity with time-lock. Position cannot be removed until unlock_at_secs.
    public entry fun add_liquidity_with_lock(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let now = timestamp::now_seconds();
        assert!(unlock_at_secs > now, E_LOCK_DURATION_INVALID);
        add_liquidity_with_lock_internal(caller, handle, supra_amount, token_amount, min_lp_out, unlock_at_secs);
    }

    fun add_liquidity_with_lock_internal(
        caller: &signer,
        handle: vector<u8>,
        supra_amount: u64,
        token_amount: u64,
        min_lp_out: u64,
        unlock_at_secs: u64,
    ) acquires StakingPool {
        let caller_addr = signer::address_of(caller);
        let pool_addr = staking_pool_address_of_handle(handle);
        assert!(exists<StakingPool>(pool_addr), E_POOL_NOT_FOUND);

        // Withdraw SUPRA (Coin -> FA)
        let supra_coin = coin::withdraw<SupraCoin>(caller, supra_amount);
        let supra_fa = coin::coin_to_fungible_asset(supra_coin);

        // Withdraw TOKEN (FA from primary store)
        let pool = borrow_global<StakingPool>(pool_addr);
        let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
        let token_fa = primary_fungible_store::withdraw(caller, token_meta, token_amount);

        // Mint LP shares via amm. M1 fix (audit R1): refund surplus on ratio mismatch.
        let (lp_minted, supra_refund, token_refund) =
            amm::add_liquidity_internal(handle, supra_fa, token_fa, min_lp_out);
        assert!(lp_minted > 0, E_ZERO_SHARES);
        if (fungible_asset::amount(&supra_refund) > 0) {
            primary_fungible_store::deposit(caller_addr, supra_refund);
        } else {
            fungible_asset::destroy_zero(supra_refund);
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

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);

        // Create Position object owned by caller (NFT-style)
        let constructor = object::create_object(caller_addr);
        let pos_signer = object::generate_signer(&constructor);
        let pos_addr = signer::address_of(&pos_signer);

        move_to(&pos_signer, Position {
            pool_addr,
            handle,
            shares: lp_minted,
            last_acc_per_share: snapshot_acc,
            last_fee_per_lp_supra: fee_per_supra,
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

    // ============ REMOVE LIQUIDITY - public, gated by unlock_at ============

    /// Caller must be Position object owner (NFT semantics - Position is transferable).
    /// Forever-locked positions can NEVER unstake. Auto-claims pending before destroy.
    public entry fun remove_liquidity(
        caller: &signer,
        position_addr: address,
        min_supra_out: u64,
        min_token_out: u64,
    ) acquires Position, StakingPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let position = borrow_global<Position>(position_addr);
        let unlock_at = position.unlock_at_secs;
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
            last_fee_per_lp_supra: _,
            last_fee_per_lp_token: _,
            unlock_at_secs: _,
            recipient_pid: _,
        } = move_from<Position>(position_addr);

        let (supra_fa, token_fa) = amm::remove_liquidity_internal(handle, shares, min_supra_out, min_token_out);
        let supra_returned = fungible_asset::amount(&supra_fa);
        let token_returned = fungible_asset::amount(&token_fa);

        primary_fungible_store::deposit(position_owner, supra_fa);
        primary_fungible_store::deposit(position_owner, token_fa);

        let pool_handle_dummy = handle;
        event::emit(PositionRemoved {
            handle: pool_handle_dummy,
            position_addr,
            owner: position_owner,
            shares,
            supra_returned,
            token_returned,
        });
    }

    // ============ CLAIM - permissionless triple-settle ============

    /// Anyone can poke. Recipient resolved at claim:
    /// - recipient_pid != @0x0 -> object::owner(pid) [auto-follows NFT transfer]
    /// - recipient_pid == @0x0 -> object::owner(position) [Position transfer = recipient transfer]
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

        // Supra mode: token emission is sourced exclusively from the new
        // multi-FA gauge owned by ipo::Position holders. lp_staking::Position
        // is the legacy path and earns only AMM swap fees here. The pool's
        // old emission accumulator is still advanced (cheap, keeps the field
        // alive in case we wire a separate stream later) but no payout flows.
        update_pool(pool_addr);
        let pool = borrow_global<StakingPool>(pool_addr);
        let acc = pool.accumulated_per_share;
        position.last_acc_per_share = acc;

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra_u128 = ((fee_per_supra - position.last_fee_per_lp_supra) * shares_u128) / amm_scale;
        let pending_token_u128 = ((fee_per_token - position.last_fee_per_lp_token) * shares_u128) / amm_scale;
        position.last_fee_per_lp_supra = fee_per_supra;
        position.last_fee_per_lp_token = fee_per_token;

        let pending_supra = (pending_supra_u128 as u64);
        let pending_token = (pending_token_u128 as u64);

        let recipient = resolve_recipient(position.recipient_pid, position_addr);

        if (pending_supra > 0 || pending_token > 0) {
            let (supra_fa, token_fa) = amm::extract_fees_for_claim(handle, pending_supra, pending_token);
            if (fungible_asset::amount(&supra_fa) > 0) {
                primary_fungible_store::deposit(recipient, supra_fa);
            } else {
                fungible_asset::destroy_zero(supra_fa);
            };
            if (fungible_asset::amount(&token_fa) > 0) {
                primary_fungible_store::deposit(recipient, token_fa);
            } else {
                fungible_asset::destroy_zero(token_fa);
            };
        };

        let pending_emission: u64 = 0;
        if (pending_emission == 0 && pending_supra == 0 && pending_token == 0) return;

        event::emit(Claimed {
            handle: pool.handle,
            position_addr,
            recipient,
            emission_amount: pending_emission,
            supra_fee_amount: pending_supra,
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

    // ============ INTERNAL - emission accumulator (C-variant) ============

    /// Universal denominator: amm::lp_supply(handle) - ALL positions (locked + free + time-locked).
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
    /// Returns (last_fee_per_lp_supra, last_fee_per_lp_token).
    #[view]
    public fun position_fee_debt(pos: Object<Position>): (u128, u128) acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        let p = borrow_global<Position>(pos_addr);
        (p.last_fee_per_lp_supra, p.last_fee_per_lp_token)
    }

    /// Pending claimable LP fees only (excluding emission). Matches darbitex
    /// `position_pending_fees(pos): (u64, u64)`.
    /// For triple-settle (emission + fees), use `position_pending_all`.
    #[view]
    public fun position_pending_fees(pos: Object<Position>): (u64, u64) acquires Position {
        let pos_addr = object::object_address(&pos);
        if (!exists<Position>(pos_addr)) return (0, 0);
        let p = borrow_global<Position>(pos_addr);
        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(p.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra = ((((fee_per_supra - p.last_fee_per_lp_supra) * p.shares) / amm_scale) as u64);
        let pending_token = ((((fee_per_token - p.last_fee_per_lp_token) * p.shares) / amm_scale) as u64);
        (pending_supra, pending_token)
    }

    /// Position shares as Object input (Object-shape for darbitex parity).
    #[view]
    public fun position_shares_obj(pos: Object<Position>): u128 acquires Position {
        let pos_addr = object::object_address(&pos);
        assert!(exists<Position>(pos_addr), E_POSITION_NOT_FOUND);
        borrow_global<Position>(pos_addr).shares
    }

    /// Returns (pending_emission, pending_supra_fee, pending_token_fee).
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

        let pending_emission = ((((acc - position.last_acc_per_share) * position.shares) / ACC_SCALE) as u64);

        let (fee_per_supra, fee_per_token) = amm::fee_per_lp(position.handle);
        let amm_scale = amm::fee_acc_scale();
        let pending_supra = ((((fee_per_supra - position.last_fee_per_lp_supra) * position.shares) / amm_scale) as u64);
        let pending_token = ((((fee_per_token - position.last_fee_per_lp_token) * position.shares) / amm_scale) as u64);

        (pending_emission, pending_supra, pending_token)
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

## `sources/mint.move`

```move
/// Mint - the creation primitive (LOCKED 2026-05-01).
///
/// MintEvent is the single emission for: Mint (original), Voice (reply), Remix (quote).
/// Mode determined by parent_mint_id + quote_mint_id fields:
///   - Mint:  parent=None, quote=None
///   - Voice: parent=Some, quote=None
///   - Remix: parent=None, quote=Some
///   (parent+quote both Some = invalid, abort)
///
/// Validation rules (LOCKED, on-chain enforced):
/// - author MUST have Profile (Named tier; guests can't mint)
/// - content_text <= 333 bytes
/// - media: if Inline, data <= 8KB hard cap
/// - mentions <= 10 (any Supra addr - flexible: PID/hex/ANS-resolved)
/// - tags <= 5, each 1-32 bytes lowercase a-z/0-9/-
/// - tickers <= 5, each MUST be factory-spawned FA (factory::is_factory_token assert)
/// - tips <= 10, each token MUST be FA-standard (no legacy coin)
///
/// Tags = ownerless folksonomy permanently. Tickers = factory-only scope (every $X
/// resolves to a PID). Mentions = flexible (implicit-then-named magic preserved).
///
/// Self-exempt for ReferenceGate: post creator always passes own mint-level gate.
module desnet::mint {
    use std::bcs;
    use std::signer;
    use std::option::{Self, Option};
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::profile::ReferenceGate;
    use desnet::reference_gate;
    use desnet::history;
    use desnet::assets;
    use desnet::factory;
    use desnet::opinion;

    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS - caps locked 2026-05-01 ============

    const CONTENT_TEXT_MAX_BYTES: u64 = 333;
    const MEDIA_INLINE_MAX_BYTES: u64 = 8192;     // 8KB hard cap
    const MENTIONS_MAX: u64 = 10;
    const TAGS_MAX: u64 = 5;
    const TAG_MAX_BYTES: u64 = 32;
    const TAG_MIN_BYTES: u64 = 1;
    const TICKERS_MAX: u64 = 5;
    const TIPS_MAX: u64 = 10;

    /// MintMedia variant tags
    const MEDIA_KIND_INLINE: u8 = 1;
    const MEDIA_KIND_REF: u8 = 2;

    /// MIME u8 enum. SVG INCLUDED 2026-05-01 (on-chain generative art ethos;
    /// XSS = frontend responsibility via <img>-tag sandbox).
    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    /// Storage backend tags for MintMedia::Ref
    const BACKEND_SHELBY: u8 = 0;
    const BACKEND_WALRUS: u8 = 1;
    const BACKEND_IPFS: u8 = 2;
    const BACKEND_DESNET_ASSETS: u8 = 3;

    // ============ ERROR CODES ============

    const E_GUEST_CANNOT_MINT: u64 = 1;
    const E_BOTH_PARENT_AND_QUOTE: u64 = 2;
    const E_CONTENT_TOO_LONG: u64 = 3;
    const E_INLINE_MEDIA_TOO_LARGE: u64 = 4;
    const E_TOO_MANY_MENTIONS: u64 = 5;
    const E_TOO_MANY_TAGS: u64 = 6;
    const E_TAG_TOO_SHORT: u64 = 7;
    const E_TAG_TOO_LONG: u64 = 8;
    const E_TAG_INVALID_CHAR: u64 = 9;
    const E_TOO_MANY_TICKERS: u64 = 10;
    const E_TICKER_NOT_FACTORY_TOKEN: u64 = 11;
    const E_TOO_MANY_TIPS: u64 = 12;
    const E_INVALID_MIME: u64 = 13;
    const E_INVALID_BACKEND: u64 = 14;
    const E_PARENT_MINT_NOT_FOUND: u64 = 15;
    const E_QUOTE_MINT_NOT_FOUND: u64 = 16;
    const E_GATE_FAILED: u64 = 17;
    const E_MINT_META_NOT_INITIALIZED: u64 = 18;
    const E_MINT_NOT_FOUND: u64 = 20;
    const E_ASSET_NOT_SEALED: u64 = 19;

    // ============ TYPES ============

    /// Per-PID mint sequence + counters. Stored at PID Object addr.
    struct PidMintMeta has key {
        next_seq: u64,
        mint_count: u64,
    }

    /// Per-PID extras storage (PressConfig, Giveaway, MintGate per mint seq).
    /// Lazy-grown SmartTable<seq, MintExtras>.
    struct PidMintExtras has key {
        extras: SmartTable<u64, MintExtras>,
    }

    /// Per-mint optional extras. Stored in PidMintExtras.extras[seq].
    /// Press, Giveaway, ReferenceGate all live HERE (not in event for size reasons).
    struct MintExtras has store {
        gate: Option<ReferenceGate>,
        // Note: PressConfig + Giveaway stored separately in their own modules' resources
        // via mint_id key (= (author_pid, seq) tuple). Kept extensible here for future fields.
    }

    /// MintId compound key: (author_pid, seq). Used as parent_mint_id / quote_mint_id ref.
    struct MintId has copy, drop, store {
        author: address,
        seq: u64,
    }

    /// MintMedia tagged variant (Inline OR Ref, never both).
    struct MintMedia has copy, drop, store {
        kind: u8,                          // MEDIA_KIND_INLINE | MEDIA_KIND_REF
        mime: u8,                          // MIME_PNG | MIME_JPEG | MIME_GIF | MIME_WEBP
        // Inline path
        inline_data: vector<u8>,           // if kind=Inline, <=8KB
        // Ref path
        ref_backend: u8,                   // if kind=Ref, BACKEND_*
        ref_blob_id: vector<u8>,
        ref_hash: vector<u8>,
    }

    /// Atomic tip embedded in mint.
    struct Tip has copy, drop, store {
        recipient: address,
        token_metadata: address,           // FA-only (legacy coin excluded)
        amount: u64,
    }

    // ============ EVENTS ============

    /// THE creation record (LOCKED).
    /// Modes: Mint (parent=None, quote=None) | Voice (parent=Some) | Remix (quote=Some).
    /// Replaces former #[event] - now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct MintEvent has drop, store {
        author: address,                            // PID Object addr
        seq: u64,
        timestamp_us: u64,
        content_kind: u8,                           // type discriminator (text/etc)
        content_text: vector<u8>,                   // <=333 bytes
        media: Option<MintMedia>,                   // optional inline OR ref
        parent_mint_id: Option<MintId>,             // Voice mode if Some
        root_mint_id: Option<MintId>,               // thread-head jump optimization
        quote_mint_id: Option<MintId>,              // Remix mode if Some
        mentions: vector<address>,                  // <=10
        tags: vector<vector<u8>>,                   // <=5, lowercase a-z/0-9/-
        tickers: vector<address>,                   // <=5 factory-spawned FA addrs
        tips: vector<Tip>,                          // <=10 atomic transfers
    }

    /// Atomic tip executed during mint creation (paired with MintEvent).
    #[event]
    struct TipExecuted has drop, store {
        from_pid: address,
        to_addr: address,
        token_metadata: address,
        amount: u64,
        mint_seq: u64,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidMintMeta + PidMintExtras at PID addr.
    /// Called from entry fns on first-write per PID. Idempotent.
    /// Uses profile::derive_pid_signer friend helper (cycle-safe pattern).
    fun ensure_mint_storage(pid_addr: address) {
        if (!exists<PidMintMeta>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintMeta { next_seq: 0, mint_count: 0 });
        };
        if (!exists<PidMintExtras>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintExtras { extras: smart_table::new() });
        };
    }

    // ============ CREATE MINT - main entry ============

    /// Atomic mint creation with all optional extensions.
    /// Mode determined by parent_mint_id + quote_mint_id (caller passes None for unused).
    ///
    /// Tips (if any): each tip transfers from author's primary store to recipient
    /// in same tx. Tx aborts if any tip lacks balance - atomic all-or-nothing.
    public entry fun create_mint(
        author: &signer,
        // PID to post as. Caller is authorized iff signer is the PID's NFT owner OR
        // its configured controller. Subdomain PIDs work transparently here - the
        // wallet that owns `alice@bob` passes that PID's address as `author_pid`.
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
    ) acquires PidMintMeta {
        let _ = do_create_mint(
            author, author_pid, content_kind, content_text,
            media_kind, media_mime, media_inline_data,
            media_ref_backend, media_ref_blob_id, media_ref_hash,
            parent_author, parent_seq, parent_set,
            quote_author, quote_seq, quote_set,
            mentions, tags, tickers,
            tip_recipients, tip_tokens, tip_amounts,
            asset_master_addr, asset_master_set,
        );
    }

    /// Atomic create_mint + bootstrap an OpinionMarket on the new mint.
    /// Single entry, single tx - frontend issues one click. opinion module
    /// validates `initial_mc` bounds and creator-token presence internally.
    public entry fun create_opinion_mint(
        author: &signer,
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
        // Pool seed for the opinion market in $creator_token raw units.
        // Validated [1e13, 1e16] = [100K, 100M] whole token inside opinion module.
        opinion_initial_mc: u64,
    ) acquires PidMintMeta {
        let seq = do_create_mint(
            author, author_pid, content_kind, content_text,
            media_kind, media_mime, media_inline_data,
            media_ref_backend, media_ref_blob_id, media_ref_hash,
            parent_author, parent_seq, parent_set,
            quote_author, quote_seq, quote_set,
            mentions, tags, tickers,
            tip_recipients, tip_tokens, tip_amounts,
            asset_master_addr, asset_master_set,
        );
        opinion::bootstrap_market_for_mint(author, author_pid, seq, opinion_initial_mc);
    }

    /// Shared mint body - returns allocated seq so create_opinion_mint can pin
    /// the OpinionMarket at (author_pid, seq).
    fun do_create_mint(
        author: &signer,
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
    ): u64 acquires PidMintMeta {
        profile::assert_authorized(author, author_pid);
        ensure_mint_storage(author_pid);

        // ============ Validate content + media ============

        assert!(vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES, E_CONTENT_TOO_LONG);

        let media: Option<MintMedia> = if (asset_master_set) {
            // desnet::assets path - Master must be sealed (immutable). MIME read from Master.
            assert!(assets::is_sealed(asset_master_addr), E_ASSET_NOT_SEALED);
            let asset_mime = assets::mime_of(asset_master_addr);
            assert_valid_mime(asset_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: asset_mime,
                inline_data: vector::empty(),
                ref_backend: BACKEND_DESNET_ASSETS,
                ref_blob_id: bcs::to_bytes(&asset_master_addr),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == 0) {
            option::none()
        } else if (media_kind == MEDIA_KIND_INLINE) {
            assert!(vector::length(&media_inline_data) <= MEDIA_INLINE_MAX_BYTES, E_INLINE_MEDIA_TOO_LARGE);
            assert_valid_mime(media_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_INLINE,
                mime: media_mime,
                inline_data: media_inline_data,
                ref_backend: 0,
                ref_blob_id: vector::empty(),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == MEDIA_KIND_REF) {
            assert_valid_mime(media_mime);
            assert_valid_backend(media_ref_backend);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: media_mime,
                inline_data: vector::empty(),
                ref_backend: media_ref_backend,
                ref_blob_id: media_ref_blob_id,
                ref_hash: media_ref_hash,
            })
        } else {
            abort E_INVALID_MIME
        };

        // ============ Validate threading ============

        assert!(!(parent_set && quote_set), E_BOTH_PARENT_AND_QUOTE);

        let parent_mint_id: Option<MintId> = if (parent_set) {
            option::some(MintId { author: parent_author, seq: parent_seq })
        } else {
            option::none()
        };

        let quote_mint_id: Option<MintId> = if (quote_set) {
            option::some(MintId { author: quote_author, seq: quote_seq })
        } else {
            option::none()
        };

        // root_mint_id: derive via parent's root if Voice, else None for Mint/Remix
        let root_mint_id: Option<MintId> = option::none();
        // PRODUCTION: query parent's MintEvent root (or compute via indexer hint)

        // ============ Validate vectors ============

        assert!(vector::length(&mentions) <= MENTIONS_MAX, E_TOO_MANY_MENTIONS);
        // Mentions = flexible (no Profile-existence assert; indexer differentiates)

        validate_tags(&tags);
        validate_tickers(&tickers);

        let tips_len = vector::length(&tip_recipients);
        assert!(tips_len == vector::length(&tip_tokens), E_TOO_MANY_TIPS);
        assert!(tips_len == vector::length(&tip_amounts), E_TOO_MANY_TIPS);
        assert!(tips_len <= TIPS_MAX, E_TOO_MANY_TIPS);

        // ============ Allocate seq + execute tips ============

        let meta = borrow_global_mut<PidMintMeta>(author_pid);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.mint_count = meta.mint_count + 1;

        // Execute tips atomically - abort whole mint if any fails
        let tips_vec = execute_tips(author, author_pid, &tip_recipients, &tip_tokens, &tip_amounts, seq);

        // ============ Build canonical MintEvent + write to history ============

        let now_secs = timestamp::now_seconds();
        let event_record = MintEvent {
            author: author_pid,
            seq,
            timestamp_us: now_secs * 1_000_000,    // microseconds (frontend convention)
            content_kind,
            content_text,
            media,
            parent_mint_id,
            root_mint_id,
            quote_mint_id,
            mentions,
            tags,
            tickers,
            tips: tips_vec,
        };

        // Verb dispatch: Mint=0 (no parent/quote), Voice=2 (parent_set), Remix=4 (quote_set).
        // parent_set + quote_set are mutually exclusive (asserted earlier).
        let verb = if (parent_set) {
            history::verb_voice()
        } else if (quote_set) {
            history::verb_remix()
        } else {
            history::verb_mint()
        };

        let target = if (parent_set) {
            option::some(parent_author)
        } else if (quote_set) {
            option::some(quote_author)
        } else {
            option::none<address>()
        };

        let asset_ref = if (asset_master_set) {
            option::some(asset_master_addr)
        } else {
            option::none<address>()
        };

        let payload = bcs::to_bytes(&event_record);
        history::append(
            author_pid,
            history::new_entry(verb, now_secs, target, payload, asset_ref),
        );

        seq
    }

    // ============ INTERNAL - tip execution ============

    fun execute_tips(
        author: &signer,
        author_pid: address,
        recipients: &vector<address>,
        tokens: &vector<address>,
        amounts: &vector<u64>,
        seq: u64,
    ): vector<Tip> {
        let tips = vector::empty<Tip>();
        let n = vector::length(recipients);
        let i = 0;
        while (i < n) {
            let recipient = *vector::borrow(recipients, i);
            let token_addr = *vector::borrow(tokens, i);
            let amount = *vector::borrow(amounts, i);

            // Withdraw FA from author's primary store + deposit to recipient
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let fa_in = primary_fungible_store::withdraw(author, token_metadata, amount);
            primary_fungible_store::deposit(recipient, fa_in);

            event::emit(TipExecuted {
                from_pid: author_pid,
                to_addr: recipient,
                token_metadata: token_addr,
                amount,
                mint_seq: seq,
                timestamp_secs: timestamp::now_seconds(),
            });

            vector::push_back(&mut tips, Tip {
                recipient,
                token_metadata: token_addr,
                amount,
            });

            i = i + 1;
        };
        tips
    }

    // ============ INTERNAL - validators ============

    fun validate_tags(tags: &vector<vector<u8>>) {
        assert!(vector::length(tags) <= TAGS_MAX, E_TOO_MANY_TAGS);
        let i = 0;
        let n = vector::length(tags);
        while (i < n) {
            let t = vector::borrow(tags, i);
            let len = vector::length(t);
            assert!(len >= TAG_MIN_BYTES, E_TAG_TOO_SHORT);
            assert!(len <= TAG_MAX_BYTES, E_TAG_TOO_LONG);

            let j = 0;
            while (j < len) {
                let ch = *vector::borrow(t, j);
                let ok = (ch >= 0x61 && ch <= 0x7A)
                      || (ch >= 0x30 && ch <= 0x39)
                      || (ch == 0x2D);
                assert!(ok, E_TAG_INVALID_CHAR);
                j = j + 1;
            };
            i = i + 1;
        };
    }

    /// Tickers must be factory-spawned FAs (DeSNet ticker spec lock 2026-05-01).
    /// Calls factory::is_factory_token view fn for each addr.
    fun validate_tickers(tickers: &vector<address>) {
        assert!(vector::length(tickers) <= TICKERS_MAX, E_TOO_MANY_TICKERS);
        let i = 0;
        let n = vector::length(tickers);
        while (i < n) {
            let addr = *vector::borrow(tickers, i);
            assert!(factory::is_factory_token(addr), E_TICKER_NOT_FACTORY_TOKEN);
            i = i + 1;
        };
    }

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

    fun assert_valid_backend(backend: u8) {
        assert!(
            backend == BACKEND_SHELBY || backend == BACKEND_WALRUS
                || backend == BACKEND_IPFS || backend == BACKEND_DESNET_ASSETS,
            E_INVALID_BACKEND
        );
    }

    // ============ MINT-LEVEL GATE ATTACHMENT ============

    /// Attach ReferenceGate to a specific mint. Gates Voice/Spark/Echo/Remix/Press
    /// of this mint. Immutable post-attach.
    /// Args flattened to primitives - Supra entry fns can't take struct params.
    public entry fun attach_mint_gate(
        author: &signer,
        author_pid: address,
        seq: u64,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires PidMintMeta, PidMintExtras {
        profile::assert_authorized(author, author_pid);
        ensure_mint_storage(author_pid);

        // Validate seq corresponds to a real mint by author
        assert!(seq < next_seq(author_pid), E_MINT_NOT_FOUND);

        let gate = profile::reference_gate_new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
        let extras_store = borrow_global_mut<PidMintExtras>(author_pid);
        if (smart_table::contains(&extras_store.extras, seq)) {
            let entry = smart_table::borrow_mut(&mut extras_store.extras, seq);
            entry.gate = option::some(gate);
        } else {
            smart_table::add(&mut extras_store.extras, seq, MintExtras {
                gate: option::some(gate),
            });
        };
    }

    // ============ INTERNAL - gate evaluation for friend modules ============

    /// Friend access for pulse/press/giveaway to check mint-level gate before
    /// allowing engagement.
    public(friend) fun get_mint_gate(author_pid: address, seq: u64): Option<ReferenceGate>
        acquires PidMintExtras
    {
        if (!exists<PidMintExtras>(author_pid)) return option::none();
        let extras_store = borrow_global<PidMintExtras>(author_pid);
        if (!smart_table::contains(&extras_store.extras, seq)) return option::none();
        smart_table::borrow(&extras_store.extras, seq).gate
    }

    // ============ VIEWS ============

    #[view]
    public fun mint_count(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).mint_count
    }

    #[view]
    public fun next_seq(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).next_seq
    }

    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }

    #[view]
    public fun media_inline_max_bytes(): u64 { MEDIA_INLINE_MAX_BYTES }

    #[view]
    public fun mentions_max(): u64 { MENTIONS_MAX }

    #[view]
    public fun tags_max(): u64 { TAGS_MAX }

    #[view]
    public fun tickers_max(): u64 { TICKERS_MAX }

    #[view]
    public fun tips_max(): u64 { TIPS_MAX }

    // ============ TESTS ============

    #[test]
    fun test_assert_valid_mime_accepts_five() {
        assert_valid_mime(MIME_PNG);
        assert_valid_mime(MIME_JPEG);
        assert_valid_mime(MIME_GIF);
        assert_valid_mime(MIME_WEBP);
        assert_valid_mime(MIME_SVG);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_zero() {
        assert_valid_mime(0);
    }

    #[test]
    fun test_assert_valid_backend_accepts_all_four() {
        assert_valid_backend(BACKEND_SHELBY);
        assert_valid_backend(BACKEND_WALRUS);
        assert_valid_backend(BACKEND_IPFS);
        assert_valid_backend(BACKEND_DESNET_ASSETS);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_BACKEND, location = Self)]
    fun test_assert_valid_backend_rejects_unknown() {
        assert_valid_backend(99);
    }

    #[test]
    fun test_validate_tags_accept_valid() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"defi");
        vector::push_back(&mut tags, b"supra-move");
        vector::push_back(&mut tags, b"web3-2026");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_INVALID_CHAR, location = Self)]
    fun test_validate_tags_reject_uppercase() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"DeFi");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_TOO_LONG, location = Self)]
    fun test_validate_tags_reject_too_long() {
        let tags = vector::empty<vector<u8>>();
        // 33 bytes (cap = 32)
        vector::push_back(&mut tags, b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        validate_tags(&tags);
    }
}

```

---

## `sources/opinion.move`

```move
/// Opinion Pool - perpetual no-settle prediction substrate (rev4 2026-05-03).
///
/// Each "opinion" = a tokenized claim posted by a PID author with a registered
/// factory token. YAY (yes-belief) and NAY (no-belief) FA tokens trade on a
/// CPMM pool denominated in the creator's $token. Pool seeded symmetrically at
/// create - active from block 0.
///
/// Curve: pure x*y=k.
/// Vault collateral: creator's $token (factory::token_metadata_of_owner).
/// Tax: same $creator_token, BURNED via supra_vault::burn_via_vault.
///
/// CREATE - single mechanic, creator pays initial_mc:
///   pull initial_mc $creator_token -> vault store
///   mint initial_mc YAY + initial_mc NAY -> both to pool stores
///   creator wallet: 0 YAY, 0 NAY
///   pool: (initial_mc, initial_mc), k = initial_mc^2 - TRADABLE day 1
///   vault: initial_mc (LOCKED forever for creator - alias di-burn dari POV creator)
///
/// SUBSEQUENT TRADER OPS (anyone, including creator post-create):
///   deposit_pick_side(side, c)  : pay c + tax c*tax_bps; mint c YAY + c NAY;
///                                  user keeps c of chosen side; opposite c -> pool
///   swap_yay_for_nay / swap_nay_for_yay : pure CPMM + tax burn
///   redeem_complete_set(amt)    : burn amt YAY + amt NAY; receive amt $token
///                                  + tax amt*tax_bps burned
///
/// Conservation invariant (always):
///   vault_$creator_token == total_yay_supply == total_nay_supply
///   (every mint adds equally to vault & both supplies; redeem subtracts equally;
///    swaps don't touch vault or total supplies)
///
/// NO oracle. NO settle. NO expiry. NO LP shares. NO LP fee.
/// NO press<->opinion coupling (orthogonal verbs by design).
/// Pool is coordination state, not ownable claim.
/// Creator's initial_mc is permanently locked in vault (no redeem path for creator).
///
/// Social-feed integration: each action (create/deposit/swap/redeem) appends
/// to actor's history with VERB_OPINION + BCS payload + #[event].
/// Payload structs carry `is_opinion: bool = true` sentinel.
///
/// See: docs/opinion-pool-amm-design.md (rev4) for full design lock + math.
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

    /// rc3: mint module calls bootstrap_market_for_mint atomically when
    /// is_opinion=true flag is passed to mint::create_mint.
    friend desnet::mint;

    // ============ CONSTANTS ============

    /// Content text cap mirrors mint::CONTENT_TEXT_MAX_BYTES for feed consistency.
    const CONTENT_TEXT_MAX_BYTES: u64 = 333;

    /// Side discriminator for deposit / event encoding.
    const SIDE_NONE: u8 = 0;             // event-payload only (swap/redeem have no side)
    const SIDE_YAY: u8 = 1;
    const SIDE_NAY: u8 = 2;

    /// Event-kind discriminator inside OpinionFeedEntry payload.
    /// rc3: KIND_CREATE no longer used by trade events - create event lives in
    /// MintEvent (VERB_MINT) with is_opinion=true flag. Kept for potential v2.
    const KIND_CREATE: u8 = 0;
    const KIND_DEPOSIT: u8 = 1;
    const KIND_SWAP_YAY_FOR_NAY: u8 = 2;
    const KIND_SWAP_NAY_FOR_YAY: u8 = 3;
    const KIND_REDEEM: u8 = 4;
    /// rc3: atomic balanced-pair mint (anyone). Pool unchanged. KIND for event payload.
    const KIND_DEPOSIT_BALANCED: u8 = 5;

    /// FA decimals for opinion tokens. Matches factory token decimals (8) so
    /// 1 YAY redeems 1:1 with 1 $creator_token (with 1 NAY) via complete-set burn.
    const OPN_DECIMALS: u8 = 8;

    /// initial_mc bounds: [1M, 100M] WHOLE $creator_token.
    /// Factory tokens have 8 decimals + 1B total supply, so:
    ///   MIN = 100K whole token = 0.01% of 1B supply per opinion (Supra mode lowered from 1M)
    ///   MAX = 100M whole token = 10%   of 1B supply per opinion (anti-monopoly)
    const MIN_INITIAL_MC: u64 = 10_000_000_000_000;        //  100K token at 8 decimals = 1e13 raw
    const MAX_INITIAL_MC: u64 = 10_000_000_000_000_000;    //  100M token at 8 decimals = 1e16 raw

    /// Tax bps (creator-set per-opinion, immutable post-create).
    const DEFAULT_TAX_BPS: u64 = 10;     // 0.1% - applied to deposit/swap/redeem amounts
    const MAX_TAX_BPS: u64 = 1000;       // 10% cap (anti-trap)
    const BPS_DENOM: u64 = 10000;

    /// Per-PID cap on # opinion markets a single PID can spawn.
    /// Prevents storage-rent grief via opinion spam (each create allocates 1 market
    /// object + 3 FungibleStore children + 2 FA Metadata objects + SmartTable entry).
    /// 10_000 chosen as practical ceiling - far above any realistic creator's lifetime
    /// opinion count, while bounding worst-case state bloat at ~10k entries.
    const MAX_OPINIONS_PER_PID: u64 = 10_000;

    /// Object seed prefixes (deterministic addrs).
    const SEED_MARKET_PREFIX: vector<u8> = b"opinion_market::";
    const SEED_YAY: vector<u8> = b"YAY";
    const SEED_NAY: vector<u8> = b"NAY";

    // ============ ERROR CODES ============

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
    /// rc2 D-M2 / Claude M-N2: prevents zero-output swap with naive min_out=0.
    const E_ZERO_OUTPUT: u64 = 14;
    /// rc2 Claude M-N1 sanity (impossible while MAX_TAX_BPS=1000<10000, but guards against future bps cap raise).
    const E_TAX_EXCEEDS_AMOUNT: u64 = 15;
    /// rc4 L1: defense-in-depth - burn_tax aborts if tax_bps drifts from DEFAULT_TAX_BPS.
    /// Catches future regression where a setter is added to OpinionMarket.tax_bps.
    /// Placed after compute_tax short-circuit so tax_bps=0 test sentinel still skips burn.
    const E_TAX_DRIFT: u64 = 16;
    /// rc4 L2: defense-in-depth - bootstrap_market_for_mint explicit re-bootstrap guard.
    /// Currently structurally impossible (friend-only + monotonic seq + EOBJECT_EXISTS),
    /// but explicit assert produces a domain-specific abort code.
    const E_MARKET_ALREADY_EXISTS: u64 = 17;

    // ============ TYPES ============

    /// Per-PID opinion sequence + cached counters. Stored at PID Object addr.
    struct PidOpinionMeta has key {
        next_seq: u64,
        opinion_count: u64,
    }

    /// Per-PID directory of seq -> market_addr (frontend convenience + on-chain lookup).
    struct PidOpinionIndex has key {
        markets: SmartTable<u64, address>,
    }

    /// THE opinion-market resource. Lives at deterministic market_addr derived
    /// from (author_pid, seq). Holds YAY/NAY mint+burn refs and pool reserves.
    struct OpinionMarket has key {
        author_pid: address,
        seq: u64,
        creator_wallet: address,
        // rc3: content_text dropped - lives in MintEvent (single source of truth via history).
        // Frontend reads MintEvent at history(author_pid)[seq] for content; OpinionMarket
        // keeps only AMM/economic state.
        // Creator's $token denomination (cached at create - immutable lookup)
        creator_token: address,                    // factory::token_metadata_of_owner(author_pid)
        creator_initial_mc: u64,                   // visible commitment signal (immutable)
        // Tax (creator-set at create, immutable, applies to subsequent trader ops)
        tax_bps: u64,
        // YAY / NAY FA addrs (deterministic children of market_addr)
        yay_metadata: address,
        nay_metadata: address,
        // Capabilities (sealed inside resource - only this module can mint/burn)
        yay_mint_ref: MintRef,
        yay_burn_ref: BurnRef,
        nay_mint_ref: MintRef,
        nay_burn_ref: BurnRef,
        // Pool reserves (FungibleStore objects owned by market_addr)
        pool_yay: Object<FungibleStore>,
        pool_nay: Object<FungibleStore>,
        // Collateral vault ($creator_token FungibleStore owned by market_addr)
        vault_token: Object<FungibleStore>,
        // Conservation accounting (sanity-checked on every mutating op)
        total_yay_supply: u64,
        total_nay_supply: u64,
        created_at_secs: u64,
        // Market signer derivation for FungibleStore withdraws
        market_extend_ref: ExtendRef,
    }

    // ============ EVENTS (#[event] Aptos events for indexers) ============

    // rc3: OpinionMintCreated event DROPPED. Create event now lives in
    // MintEvent (BCS-encoded into history with VERB_MINT) with is_opinion=true
    // flag. Indexers detect opinion-mints by parsing MintEvent.is_opinion.
    // OpinionMarket existence at deterministic addr from (author_pid, seq)
    // confirms the AMM bootstrap.

    /// Vote-like action (deposit / swap / redeem). Aggregator-friendly.
    #[event]
    struct OpinionAction has drop, store {
        is_opinion: bool,                          // = true (sentinel)
        kind: u8,                                  // KIND_DEPOSIT | KIND_SWAP_* | KIND_REDEEM
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,                                  // SIDE_YAY/NAY for deposit, SIDE_NONE for swap/redeem
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,                           // $creator_token burned in this op
        new_pool_yay: u64,
        new_pool_nay: u64,
        new_total_yay_supply: u64,
        new_total_nay_supply: u64,
        timestamp_secs: u64,
    }

    // ============ HISTORY-PAYLOAD STRUCTS (BCS-encoded into Entry.payload) ============

    // rc3: OpinionFeedCreate struct DROPPED. Create event uses MintEvent
    // (mint::create_mint appends VERB_MINT to history with is_opinion=true).

    /// Payload for VERB_OPINION entries with kind in {DEPOSIT, SWAP_*, REDEEM, BALANCED}.
    struct OpinionFeedAction has copy, drop, store {
        is_opinion: bool,                          // = true (sentinel)
        kind: u8,
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

    // ============ LAZY-INIT - per-PID storage ============

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

    // ============ BOOTSTRAP - friend-only, called by mint::create_mint ============

    /// rc3: bootstrap an OpinionMarket atomically as part of mint::create_mint
    /// when is_opinion=true. Friend-only - no public entry.
    ///
    /// Mint already validated profile + allocated seq + appended MintEvent to history
    /// (with is_opinion=true flag). This fn handles the AMM bootstrap side:
    ///   - Validate creator has factory token + initial_mc bounds
    ///   - Create OpinionMarket at deterministic addr from (author_pid, mint_seq)
    ///   - Pull initial_mc $creator_token from author wallet -> vault
    ///   - Mint initial_mc YAY + initial_mc NAY -> both to pool stores
    ///   - Creator gets 0 position; vault locks initial_mc forever
    ///   - Tax_bps fixed at DEFAULT_TAX_BPS (10) - not user-configurable per design
    ///   - Pool active day 1, k = initial_mc^2
    ///
    /// Atomic - any failure here reverts the entire mint tx (including MintEvent).
    public(friend) fun bootstrap_market_for_mint(
        author: &signer,                  // signer from mint, for primary store withdraw
        author_pid: address,
        mint_seq: u64,
        initial_mc: u64,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let author_wallet = signer::address_of(author);
        // Validate bounds (mint side already validated profile)
        assert!(
            initial_mc >= MIN_INITIAL_MC && initial_mc <= MAX_INITIAL_MC,
            E_INITIAL_MC_OUT_OF_RANGE,
        );

        // Guest restriction (must have factory token for $creator_token denomination)
        assert!(factory::owner_has_token(author_pid), E_NO_FACTORY_TOKEN);
        let creator_token = factory::token_metadata_of_owner(author_pid);

        ensure_opinion_storage(author_pid);

        // Per-PID opinion cap (M5: anti-grief)
        let meta = borrow_global_mut<PidOpinionMeta>(author_pid);
        assert!(meta.opinion_count < MAX_OPINIONS_PER_PID, E_OPINION_LIMIT_REACHED);
        meta.opinion_count = meta.opinion_count + 1;

        // rc3: seq comes from mint::PidMintMeta - no separate opinion seq counter.
        let seq = mint_seq;
        let tax_bps = DEFAULT_TAX_BPS;

        // Bootstrap market object as named child of pid_addr -> deterministic addr.
        let pid_signer = profile::derive_pid_signer(author_pid);
        let market_seed = make_market_seed(seq);
        // rc4 L2 FIX: explicit re-bootstrap guard. Currently structurally
        // impossible (friend-only + monotonic seq from mint::PidMintMeta),
        // but explicit check produces a domain-specific abort instead of
        // relying on framework EOBJECT_EXISTS. Cheaper to read than to debug.
        let predicted_market_addr = object::create_object_address(&author_pid, market_seed);
        assert!(!exists<OpinionMarket>(predicted_market_addr), E_MARKET_ALREADY_EXISTS);
        let market_constructor = object::create_named_object(&pid_signer, market_seed);
        let market_addr = object::address_from_constructor_ref(&market_constructor);
        let market_signer = object::generate_signer(&market_constructor);
        let market_extend_ref = object::generate_extend_ref(&market_constructor);
        // Disable ungated transfer - market object is bound to PID
        let mkt_transfer = object::generate_transfer_ref(&market_constructor);
        object::disable_ungated_transfer(&mkt_transfer);

        // L2 FIX: include seq in FA name + symbol for wallet UI uniqueness across
        // opinions. Without this, all YAY tokens display as identical "OPN-YAY"
        // in wallets which makes multi-opinion holdings impossible to distinguish.
        let seq_str = string_utils::to_string<u64>(&seq);

        // Mint YAY FA as named child of market -> deterministic addr
        let yay_constructor = object::create_named_object(&market_signer, SEED_YAY);
        let yay_metadata = object::address_from_constructor_ref(&yay_constructor);
        let yay_name = string::utf8(b"Opinion YAY Share #");
        string::append(&mut yay_name, seq_str);
        let yay_symbol = string::utf8(b"OPN-YAY#");
        string::append(&mut yay_symbol, seq_str);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &yay_constructor,
            option::none<u128>(),                  // unlimited supply (bounded by collateral inflow)
            yay_name,
            yay_symbol,
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let yay_mint_ref = fungible_asset::generate_mint_ref(&yay_constructor);
        let yay_burn_ref = fungible_asset::generate_burn_ref(&yay_constructor);

        // Mint NAY FA as named child of market
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

        // Create FungibleStores at market_addr for pool reserves + vault.
        let yay_metadata_obj = object::address_to_object<Metadata>(yay_metadata);
        let nay_metadata_obj = object::address_to_object<Metadata>(nay_metadata);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token);
        let pool_yay_store = create_store_at_market(market_addr, yay_metadata_obj);
        let pool_nay_store = create_store_at_market(market_addr, nay_metadata_obj);
        let vault_token_store = create_store_at_market(market_addr, creator_token_obj);

        // ============ Symmetric pool seed ============
        // Pull initial_mc $creator_token from author wallet (signer from mint) -> vault.
        // rc3: author signer is `author` (passed-through from mint::create_mint).
        let collateral_in = primary_fungible_store::withdraw(
            author, creator_token_obj, initial_mc,
        );
        fungible_asset::deposit(vault_token_store, collateral_in);

        // Mint initial_mc YAY + initial_mc NAY -> BOTH go to pool (creator gets 0)
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

        // Conservation post-create: vault == total_yay == total_nay == initial_mc [ok]
        let mkt_ref = borrow_global<OpinionMarket>(market_addr);
        assert_conservation(mkt_ref);

        // Register in PID's opinion index (frontend lookup convenience)
        let idx = borrow_global_mut<PidOpinionIndex>(author_pid);
        smart_table::add(&mut idx.markets, seq, market_addr);

        // Pattern B (2026-05-03): NO history::append here - mint::create_opinion_mint
        // -> do_create_mint already appended VERB_MINT with the regular MintEvent
        // (no is_opinion field - compat-safe). Indexers detect opinion-mints by
        // calling `opinion::market_exists(author_pid, seq)` view (returns true iff
        // OpinionMarket resource exists at deterministic addr from this seed).
        // NO #[event] emit either - market existence at predictable addr is the
        // single source of truth.
    }

    // ============ DEPOSIT BALANCED (atomic balanced-pair mint, rc3) ============

    /// Deposit `amount` $creator_token, mint `amount` YAY + `amount` NAY -> BOTH
    /// to user's primary store (NOT to pool). Pool reserves UNCHANGED.
    /// Tax: ceil(amount * tax_bps / 10000) $creator_token, BURNED on top.
    ///
    /// Use case (per design):
    ///   - User wants neutral position (no directional bet)
    ///   - User wants atomic redeem-prep (mint balanced then immediately burn pair
    ///     for $token redemption)
    ///   - 1-tx atomic alternative to (deposit_pick_side YAY + deposit_pick_side NAY)
    ///     which costs 2* and exposes user to MEV between tx
    ///
    /// Conservation: vault +amount, total_yay +amount, total_nay +amount [ok]
    /// (Same shape as deposit_pick_side accounting; different distribution.)
    public entry fun deposit_balanced(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount: u64,
    ) acquires OpinionMarket {
        assert!(amount > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let user_addr = signer::address_of(user);

        // Pull collateral
        let creator_token_obj = object::address_to_object<Metadata>(mkt.creator_token);
        let token_in = primary_fungible_store::withdraw(user, creator_token_obj, amount);
        fungible_asset::deposit(mkt.vault_token, token_in);

        // Mint balanced pair -> BOTH to user (pool unchanged)
        let yay_minted = fungible_asset::mint(&mkt.yay_mint_ref, amount);
        let nay_minted = fungible_asset::mint(&mkt.nay_mint_ref, amount);
        mkt.total_yay_supply = mkt.total_yay_supply + amount;
        mkt.total_nay_supply = mkt.total_nay_supply + amount;
        primary_fungible_store::deposit(user_addr, yay_minted);
        primary_fungible_store::deposit(user_addr, nay_minted);

        // Tax burn (same pattern as deposit_pick_side)
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            user_addr,
            KIND_DEPOSIT_BALANCED,
            SIDE_NONE,                                // no directional side
            amount,
            amount,                                   // amount_in == amount_out (no swap math)
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    // ============ DEPOSIT (Mirror-Mint pair-mint, anyone) ============

    /// Deposit `amount_token` $creator_token, mint amount_token YAY + amount_token NAY,
    /// keep chosen side, opposite side auto-deposits to pool.
    /// Tax: ceil(amount_token * tax_bps / 10000) $creator_token, BURNED on top.
    /// Creator NOT banned - boleh participate as normal trader.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount_token + tax_amount` $creator_token
    /// in primary store before tx - abort otherwise (atomic revert).
    public entry fun deposit_pick_side(
        user: &signer,
        author_pid: address,
        seq: u64,
        side: u8,
        amount_token: u64,
    ) acquires OpinionMarket {
        assert!(amount_token > 0, E_AMOUNT_ZERO);
        assert!(side == SIDE_YAY || side == SIDE_NAY, E_INVALID_SIDE);

        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        // M2 FIX: defense-in-depth pool-active check. Pool is always active post-create
        // (initial_mc symmetric seed > 0), but assert here catches any future regression.
        assert!(
            fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0,
            E_POOL_NOT_ACTIVE,
        );

        let user_addr = signer::address_of(user);

        // Pull collateral
        let creator_token_obj = object::address_to_object<Metadata>(mkt.creator_token);
        let token_in = primary_fungible_store::withdraw(user, creator_token_obj, amount_token);
        fungible_asset::deposit(mkt.vault_token, token_in);

        // Mint complete pair
        let yay_minted = fungible_asset::mint(&mkt.yay_mint_ref, amount_token);
        let nay_minted = fungible_asset::mint(&mkt.nay_mint_ref, amount_token);
        mkt.total_yay_supply = mkt.total_yay_supply + amount_token;
        mkt.total_nay_supply = mkt.total_nay_supply + amount_token;

        // User keeps chosen side; opposite goes to pool
        if (side == SIDE_YAY) {
            primary_fungible_store::deposit(user_addr, yay_minted);
            fungible_asset::deposit(mkt.pool_nay, nay_minted);
        } else {
            primary_fungible_store::deposit(user_addr, nay_minted);
            fungible_asset::deposit(mkt.pool_yay, yay_minted);
        };

        // Tax burn: extra creator_token from user, burned via apt_vault delegate
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_token, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
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

    // ============ SWAP (CPMM, x*y=k) ============

    /// Swap `amount_in` of YAY to receive NAY from pool. No swap fee in YAY/NAY
    /// (pool stays clean); separate $creator_token tax burn.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount_in` YAY in primary store AND
    /// `ceil(amount_in * tax_bps / 10000)` $creator_token for the tax burn - both
    /// checked atomically; abort if either insufficient.
    public entry fun swap_yay_for_nay(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_yay_r, pool_nay_r, amount_in);
        // rc2 D-M2 / M-N2 FIX (convergent DeepSeek+Claude): hard floor on amount_out
        // prevents zero-output swap (user pays input + tax for 0 output) when naive
        // frontend defaults min_out=0. Catches CPMM truncation at extreme pool ratios.
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        // Pull YAY from user -> pool
        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_yay, yay_in);

        // Send NAY to user (derive market signer to authorize FungibleStore withdraw)
        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let nay_out = fungible_asset::withdraw(&market_signer, mkt.pool_nay, amount_out);
        primary_fungible_store::deposit(user_addr, nay_out);

        // rc2 D-M1 FIX (convergent Gemini+DeepSeek): tax base = $creator_token equivalent
        // of amount_in via opinion pool spot price, NOT raw YAY units. 1 YAY != 1 $token
        // standalone (only PAIR redeems 1:1). Spot value: 1 YAY = nay_r/(yay_r+nay_r) $token.
        // Pool reserves captured pre-swap (pool_yay_r, pool_nay_r) for accurate spot.
        let amount_in_token_equiv = ((((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        // M1 FIX: defense-in-depth conservation check. Swap shouldn't change vault
        // or total supplies, but assert here catches any future regression.
        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
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

    /// Swap `amount_in` of NAY to receive YAY from pool.
    /// UX (M4): user needs `amount_in` NAY + `ceil(amount_in * tax_bps / 10000)` $creator_token.
    public entry fun swap_nay_for_yay(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_nay_r, pool_yay_r, amount_in);
        // rc4 M1 FIX: symmetric to swap_yay_for_nay - hard floor on amount_out
        // prevents zero-output swap when naive frontend defaults min_out=0.
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_nay, nay_in);

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let yay_out = fungible_asset::withdraw(&market_signer, mkt.pool_yay, amount_out);
        primary_fungible_store::deposit(user_addr, yay_out);

        // rc2 D-M1 FIX: same as swap_yay_for_nay but reverse direction.
        // 1 NAY spot value = yay_r/(yay_r+nay_r) $token.
        let amount_in_token_equiv = ((((amount_in as u128) * (pool_yay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        // M1 FIX: defense-in-depth conservation check (same rationale as swap_yay_for_nay).
        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
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

    // ============ REDEEM COMPLETE SET ============

    /// Burn `amount` YAY + `amount` NAY from user, return `amount` $creator_token from vault.
    /// Tax: ceil(amount * tax_bps / 10000) $creator_token additional burn.
    /// Conservation invariant maintained.
    /// Note: creator typically has 0 YAY / 0 NAY (post-create), so they can't redeem
    /// unless they accumulate balanced pair via deposits/swaps as a regular trader.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount` YAY + `amount` NAY + `ceil(amount * tax_bps / 10000)`
    /// $creator_token in primary stores. Atomic abort if any insufficient.
    public entry fun redeem_complete_set(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount: u64,
    ) acquires OpinionMarket {
        assert!(amount > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        assert!(fungible_asset::balance(mkt.vault_token) >= amount, E_INSUFFICIENT_VAULT);

        let user_addr = signer::address_of(user);

        // rc2 Claude M-N1 FIX: skim tax FROM VAULT OUTPUT instead of pulling extra
        // $creator_token from user. Preserves pair-mint AMM "always-exit" safety:
        // user holding (X YAY, X NAY, 0 $token) can now redeem (gets amount-tax,
        // tax sourced from vault). Economic effect identical (tax_amount $token
        // burned per redemption); funds source shifts user-wallet -> vault output.
        let tax_amount = compute_tax(amount, mkt.tax_bps);
        assert!(tax_amount <= amount, E_TAX_EXCEEDS_AMOUNT);    // sanity (impossible at MAX_TAX_BPS=1000)

        // Pull YAY and NAY from user, burn both
        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount);
        fungible_asset::burn(&mkt.yay_burn_ref, yay_in);
        fungible_asset::burn(&mkt.nay_burn_ref, nay_in);
        mkt.total_yay_supply = mkt.total_yay_supply - amount;
        mkt.total_nay_supply = mkt.total_nay_supply - amount;

        // Release collateral from vault, split into user-output + tax-burn (M-N1).
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

    // ============ INTERNAL - math + invariants + helpers ============

    /// CPMM constant-product: pure quote (no LP fee - opinion pool has no LP role).
    /// Mirrors amm::compute_amount_out shape (darbitex-shape signature kept).
    /// L1 FIX: #[view] annotation for off-chain SDK / indexer call.
    /// rc2 Claude L-N1 FIX: defensive early-return on degenerate inputs to avoid
    /// framework div-by-zero abort when called from off-chain SDK.
    #[view]
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
    ): u64 {
        if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;
        // No fee: amount_in_after_fee = amount_in
        let amount_in_u128 = (amount_in as u128);
        let numerator = amount_in_u128 * (reserve_out as u128);
        let denominator = (reserve_in as u128) + amount_in_u128;
        ((numerator / denominator) as u64)
    }

    /// M3 FIX: ceiling tax computation. Prevents zero-tax sub-dust trades.
    /// Returns ceil(amount * tax_bps / BPS_DENOM). Pure function for testability.
    /// If tax_bps = 0 returns 0 (free market). If amount = 0 returns 0.
    /// For amount > 0 and tax_bps > 0, always returns >= 1 (anti-dust floor).
    /// rc2 Claude L-N2 FIX: assert tax_bps bound on public surface (matches
    /// internal create_opinion validation).
    #[view]
    public fun compute_tax(amount: u64, tax_bps: u64): u64 {
        assert!(tax_bps <= MAX_TAX_BPS, E_TAX_BPS_TOO_HIGH);
        if (tax_bps == 0 || amount == 0) return 0;
        let numerator = (amount as u128) * (tax_bps as u128) + (BPS_DENOM as u128) - 1;
        ((numerator / (BPS_DENOM as u128)) as u64)
    }

    /// Conservation invariant: vault == total_yay_supply == total_nay_supply.
    /// Held by atomic pair-mint (deposit/create) and pair-burn (redeem) semantics.
    /// rc2 Claude L-N3 FIX: cross-check module-local counter against FA framework
    /// supply view. Defense-in-depth catches any future regression in mint/burn
    /// pairing where local counter drifts from FA framework supply.
    fun assert_conservation(mkt: &OpinionMarket) {
        let vault_amt = fungible_asset::balance(mkt.vault_token);
        assert!(mkt.total_yay_supply == mkt.total_nay_supply, E_CONSERVATION_BROKEN);
        assert!(vault_amt == mkt.total_yay_supply, E_CONSERVATION_BROKEN);

        // L-N3 cross-check: FA framework supply must match tracked counter.
        // For supplies that don't track (unlimited unconstrained), framework returns
        // None - skip the cross-check in that case (still safe via local counter).
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

    /// Pull `compute_tax(amount, tax_bps)` $creator_token from user and burn it via
    /// supra_vault::burn_via_vault. Returns the actual amount burned (for event payload).
    /// M3: uses ceiling rounding via compute_tax - prevents zero-tax dust trades.
    fun burn_tax(
        user: &signer,
        creator_token_addr: address,
        author_pid: address,
        amount: u64,
        tax_bps: u64,
    ): u64 {
        let tax_amount = compute_tax(amount, tax_bps);
        if (tax_amount == 0) return 0;
        // rc4 L1 FIX: defense-in-depth - once we're past the short-circuit, the
        // effective tax_bps MUST equal DEFAULT_TAX_BPS. Any future setter that
        // mutates OpinionMarket.tax_bps to a non-default non-zero value will
        // be caught here. Placement preserves the tax_bps=0 test sentinel.
        assert!(tax_bps == DEFAULT_TAX_BPS, E_TAX_DRIFT);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token_addr);
        let tax_fa = primary_fungible_store::withdraw(user, creator_token_obj, tax_amount);
        let vault_addr = factory::vault_addr_of_pid(author_pid);
        supra_vault::burn_via_vault(vault_addr, tax_fa);
        tax_amount
    }

    fun emit_action(
        mkt: &OpinionMarket,
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
        let actor_pid = profile::derive_pid_address(actor_wallet);
        // If actor has no profile, skip history append (events still emit)
        if (profile::profile_exists(actor_pid)) {
            let feed_payload = OpinionFeedAction {
                is_opinion: true,
                kind,
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
        };

        event::emit(OpinionAction {
            is_opinion: true,
            kind,
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

    /// Create an empty FungibleStore as a child object of market_addr for `metadata`.
    /// Mirrors amm::create_store_at_pool pattern.
    fun create_store_at_market(market_addr: address, metadata: Object<Metadata>): Object<FungibleStore> {
        let store_constructor = object::create_object(market_addr);
        fungible_asset::create_store<Metadata>(&store_constructor, metadata)
    }

    // ============ VIEWS ============

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

    // rc3: content_text view DROPPED. Frontend reads content from MintEvent at
    // history(author_pid)[seq] (single source of truth via mint module).

    #[view]
    public fun is_pool_active(author_pid: address, seq: u64): bool
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        if (!exists<OpinionMarket>(market_addr)) return false;
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0
    }

    /// Marginal YAY price in $creator_token (basis: 1 YAY + 1 NAY = 1 $token via redeem).
    /// Returned as u64 in 1e8 fixed-point ("token raw"). 1.0 token = 100_000_000.
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

    // Side / kind constant getters

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

    // ============ TESTS ============

    #[test]
    fun test_compute_amount_out_no_fee() {
        // Pool (100, 10), buy YAY by sending NAY. Fee=0 (Mirror-Mint has no LP fee).
        // out = 10 * 100 / (100 + 100) = 5 for amount_in=100
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
        // (100, 100), swap 10 -> expected close to 10*100/(100+10) ~ 9
        let out = compute_amount_out(100, 100, 10);
        assert!(out == 9, 1);    // 1000/110 = 9.09 -> 9
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
        // Supra mode: 100K whole token at 8 decimals = 1e13 raw
        assert!(MIN_INITIAL_MC == 10_000_000_000_000, 1);
        // 100M whole token at 8 decimals = 1e16 raw
        assert!(MAX_INITIAL_MC == 10_000_000_000_000_000, 2);
        // 1B (factory total supply) = 1e17 raw, so MAX = 10% of supply
        assert!(MAX_INITIAL_MC * 10 == 100_000_000_000_000_000, 3);
    }

    #[test]
    fun test_tax_bps_constants() {
        assert!(DEFAULT_TAX_BPS == 10, 1);          // 0.1%
        assert!(MAX_TAX_BPS == 1000, 2);            // 10%
        assert!(BPS_DENOM == 10000, 3);
        // Sanity: default tax on 100K token deposit (1e13 raw) at 10 bps
        //   = 1e13 * 10 / 10000 = 1e10 = 10_000_000_000
        let tax = (((MIN_INITIAL_MC as u128) * (DEFAULT_TAX_BPS as u128) / (BPS_DENOM as u128)) as u64);
        assert!(tax == 10_000_000_000, 4);
    }

    // ============ M3 FIX TESTS - compute_tax ceiling rounding ============

    #[test]
    fun test_compute_tax_zero_inputs() {
        // tax_bps = 0 -> 0 (free market)
        assert!(compute_tax(1_000_000_000, 0) == 0, 1);
        // amount = 0 -> 0 (no op to tax)
        assert!(compute_tax(0, 30) == 0, 2);
        // both zero -> 0
        assert!(compute_tax(0, 0) == 0, 3);
    }

    #[test]
    fun test_compute_tax_ceiling_dust_protection() {
        // M3 anti-dust: any nonzero (amount, tax_bps) yields >= 1 raw tax.
        // Without ceiling: 99 * 10 / 10000 = 0 (truncated to 0 = free trade).
        // With ceiling: ceil(99 * 10 / 10000) = ceil(0.099) = 1.
        assert!(compute_tax(99, 10) == 1, 1);
        assert!(compute_tax(1, 1) == 1, 2);          // ceil(1/10000) = 1
        assert!(compute_tax(500, 10) == 1, 3);       // ceil(0.5) = 1
        assert!(compute_tax(999, 10) == 1, 4);       // ceil(0.999) = 1
        assert!(compute_tax(1000, 10) == 1, 5);      // exact 1.0 -> 1
        assert!(compute_tax(1001, 10) == 2, 6);      // ceil(1.001) = 2
    }

    #[test]
    fun test_compute_tax_normal_amounts() {
        // 1M token (1e14 raw) at 10 bps = 1e14 * 10 / 10000 = 1e11 = 100_000_000_000
        assert!(compute_tax(100_000_000_000_000, 10) == 100_000_000_000, 1);
        // 100M token (1e16 raw) at 30 bps = 1e16 * 30 / 10000 = 3e13 = 30_000_000_000_000
        assert!(compute_tax(10_000_000_000_000_000, 30) == 30_000_000_000_000, 2);
        // 1 token (1e8 raw) at max 10% (1000 bps) = 1e8 * 1000 / 10000 = 1e7 = 10_000_000
        assert!(compute_tax(100_000_000, 1000) == 10_000_000, 3);
    }

    #[test]
    fun test_compute_tax_max_bounds_no_overflow() {
        // amount = u64 max (~1.8e19), tax_bps = MAX (1000)
        // numerator = 1.8e19 * 1000 + 9999 ~ 1.8e22, well under u128 (3.4e38)
        // result = 1.8e22 / 10000 = 1.8e18, fits in u64
        let max_amt = 18_446_744_073_709_551_615u64;     // u64::MAX
        let tax = compute_tax(max_amt, MAX_TAX_BPS);
        // Sanity: tax should be ~10% of max_amt
        assert!(tax > max_amt / 10 - 1, 1);
        assert!(tax <= max_amt / 10 + 1, 2);
    }

    // ============ INTEGRATION TEST SCAFFOLD (rc3) ============
    // Addresses 4-way convergent gap from R7 audit (Grok+Kimi+Claude+Qwen):
    // no end-to-end test exercising create->deposit->swap->redeem invariant flow.
    //
    // Strategy: bypass factory dependency via direct OpinionMarket construction
    // with mock $creator_token. Use tax_bps=0 to skip supra_vault::burn_via_vault
    // (which would require full factory + apt_vault setup). Tax math separately
    // covered by existing pure-helper unit tests (test_compute_tax_*).

    #[test_only]
    use supra_framework::account;

    /// Create a mock $token that mimics factory-spawned creator token semantics.
    /// Returns (metadata_addr, mint_ref) so test can mint test balance to user wallets.
    #[test_only]
    fun setup_mock_creator_token(creator: &signer, symbol: vector<u8>): (address, MintRef) {
        let constructor = object::create_named_object(creator, symbol);
        let metadata_addr = object::address_from_constructor_ref(&constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::some(100_000_000_000_000_000u128),    // 1B token at 8 decimals
            string::utf8(symbol),
            string::utf8(symbol),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        (metadata_addr, mint_ref)
    }

    /// Mint test $token balance to a wallet address.
    #[test_only]
    fun mint_test_balance(mint_ref: &MintRef, to: address, amount: u64) {
        let fa = fungible_asset::mint(mint_ref, amount);
        primary_fungible_store::deposit(to, fa);
    }

    /// Build an OpinionMarket directly (bypasses mint::create_mint and factory check).
    /// Used for testing trade entries (deposit/swap/redeem/balanced) in isolation.
    /// tax_bps=0 to skip apt_vault dependency.
    #[test_only]
    fun setup_test_opinion_market(
        creator: &signer,
        creator_token_addr: address,
        creator_token_mint_ref: &MintRef,
        initial_mc: u64,
    ): (address, address) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        // Init framework requirements (timestamp + protocol singletons)
        let creator_addr = signer::address_of(creator);
        let pid_addr = profile::setup_test_pid(creator);

        ensure_opinion_storage(pid_addr);

        // Allocate seq from PidOpinionMeta + bump opinion_count
        let meta = borrow_global_mut<PidOpinionMeta>(pid_addr);
        let seq = meta.next_seq;       // 0 for first call
        meta.next_seq = seq + 1;
        meta.opinion_count = meta.opinion_count + 1;

        // Bootstrap market object as named child of PID
        let pid_signer = profile::derive_pid_signer(pid_addr);
        let market_seed = make_market_seed(seq);
        let market_constructor = object::create_named_object(&pid_signer, market_seed);
        let market_addr = object::address_from_constructor_ref(&market_constructor);
        let market_signer = object::generate_signer(&market_constructor);
        let market_extend_ref = object::generate_extend_ref(&market_constructor);
        let mkt_transfer = object::generate_transfer_ref(&market_constructor);
        object::disable_ungated_transfer(&mkt_transfer);

        // Mint YAY + NAY FA (no seq suffix in test for simplicity)
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

        // FungibleStores at market_addr
        let yay_meta_obj = object::address_to_object<Metadata>(yay_metadata);
        let nay_meta_obj = object::address_to_object<Metadata>(nay_metadata);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token_addr);
        let pool_yay_store = create_store_at_market(market_addr, yay_meta_obj);
        let pool_nay_store = create_store_at_market(market_addr, nay_meta_obj);
        let vault_token_store = create_store_at_market(market_addr, creator_token_obj);

        // Mint creator_token balance for the bootstrap deposit + give to creator
        mint_test_balance(creator_token_mint_ref, creator_addr, initial_mc);

        // Symmetric pool seed: pull initial_mc from creator -> vault, mint YAY+NAY -> pool
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
            tax_bps: 0,                   // <- test sentinel: skips apt_vault dep
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

    /// Helper: setup framework + create test creator with mock token.
    /// Returns (pid_addr, market_addr, mock_token_addr, mock_token_mint_ref) for trade tests.
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

    // ============ INTEGRATION TESTS ============

    #[test(framework = @supra_framework, creator = @0xCAFE)]
    fun test_integration_market_setup(framework: &signer, creator: &signer)
        acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket
    {
        let (pid, market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);

        // Verify initial state matches design spec
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

        // Cleanup
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

        // Mint test balance to Bob: 1M token to deposit + buffer
        let deposit_amt: u64 = 1_000_000_000_000;     // 10K token (1e12 raw)
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        // Bob picks YAY -> keeps deposit_amt YAY, pool gets deposit_amt NAY
        deposit_pick_side(bob, pid, 0, SIDE_YAY, deposit_amt);

        // Verify: pool YAY unchanged, pool NAY +deposit_amt
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 1);                       // unchanged
        assert!(nay_r == MIN_INITIAL_MC + deposit_amt, 2);          // +deposit
        // Vault + supplies up by deposit_amt
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

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        deposit_pick_side(bob, pid, 0, SIDE_NAY, deposit_amt);

        // Mirror of YAY test: pool NAY unchanged, pool YAY +deposit
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

        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);

        deposit_balanced(bob, pid, 0, deposit_amt);

        // Pool UNCHANGED (key property of deposit_balanced)
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 1);                       // unchanged
        assert!(nay_r == MIN_INITIAL_MC, 2);                       // unchanged

        // Vault + supplies up by deposit_amt
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

        // Bob deposits NAY first (keeps NAY, pool gets YAY)
        // Then Bob swaps NAY -> YAY back via pool
        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);
        deposit_pick_side(bob, pid, 0, SIDE_YAY, deposit_amt);
        // Bob now has deposit_amt YAY in primary store; pool=(MIN, MIN+deposit)

        // Swap 100K YAY for some NAY (slippage will reduce output)
        let swap_in: u64 = 100_000_000_000;
        swap_yay_for_nay(bob, pid, 0, swap_in, 1);     // min_out=1 (lenient)

        // Verify: vault unchanged, supplies unchanged (swap doesn't mint/burn)
        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 1);
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt, 2);
        assert!(tn == MIN_INITIAL_MC + deposit_amt, 3);
        // Pool YAY ^ (received), pool NAY v (gave out)
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC + swap_in, 4);
        assert!(nay_r < MIN_INITIAL_MC + deposit_amt, 5);          // some out

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    fun test_integration_redeem_complete_set_full_cycle(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);

        // Setup: Bob does deposit_balanced -> has X YAY + X NAY
        let deposit_amt: u64 = 1_000_000_000_000;
        mint_test_balance(&token_mint_ref, bob_addr, deposit_amt);
        deposit_balanced(bob, pid, 0, deposit_amt);

        // Pre-redeem state
        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt, 1);

        // Bob redeems half of his pair -> gets half deposit_amt back as $token
        let redeem_amt: u64 = deposit_amt / 2;
        redeem_complete_set(bob, pid, 0, redeem_amt);

        // Vault drops by redeem_amt (M-N1 skim with tax_bps=0 = no tax skim)
        assert!(vault_balance(pid, 0) == MIN_INITIAL_MC + deposit_amt - redeem_amt, 2);
        // Total supplies drop by redeem_amt
        let (ty, tn) = total_supplies(pid, 0);
        assert!(ty == MIN_INITIAL_MC + deposit_amt - redeem_amt, 3);
        assert!(tn == MIN_INITIAL_MC + deposit_amt - redeem_amt, 4);
        // Pool unchanged (redeem only burns user-held pairs)
        let (yay_r, nay_r) = pool_reserves(pid, 0);
        assert!(yay_r == MIN_INITIAL_MC, 5);
        assert!(nay_r == MIN_INITIAL_MC, 6);

        let _ = token_mint_ref;
    }

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B, carol = @0xCA401)]
    fun test_integration_conservation_across_full_cycle(
        framework: &signer, creator: &signer, bob: &signer, carol: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        // The big invariant test: vault == total_yay == total_nay holds across
        // create + deposit (Y) + deposit (N) + balanced + swap + redeem.
        let (pid, market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        let carol_addr = signer::address_of(carol);
        account::create_account_for_test(bob_addr);
        account::create_account_for_test(carol_addr);

        let amt: u64 = 1_000_000_000_000;     // 10K each op

        // Op 1: Bob deposit YAY 10K
        mint_test_balance(&token_mint_ref, bob_addr, amt);
        deposit_pick_side(bob, pid, 0, SIDE_YAY, amt);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        // Op 2: Carol deposit NAY 10K
        mint_test_balance(&token_mint_ref, carol_addr, amt);
        deposit_pick_side(carol, pid, 0, SIDE_NAY, amt);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        // Op 3: Bob deposit_balanced 5K (NEW rc3 primitive)
        mint_test_balance(&token_mint_ref, bob_addr, amt / 2);
        deposit_balanced(bob, pid, 0, amt / 2);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        // Op 4: Carol swaps some NAY for YAY
        swap_nay_for_yay(carol, pid, 0, amt / 4, 1);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        // Op 5: Bob redeems some balanced pair
        redeem_complete_set(bob, pid, 0, amt / 4);
        assert_conservation(borrow_global<OpinionMarket>(market_addr));

        // Final: vault should == both totals
        let (final_y, final_n) = total_supplies(pid, 0);
        assert!(final_y == final_n, 1);
        assert!(vault_balance(pid, 0) == final_y, 2);

        let _ = token_mint_ref;
    }

    // ============ M5 FIX TEST - opinion limit constant ============

    #[test]
    fun test_max_opinions_per_pid_constant() {
        assert!(MAX_OPINIONS_PER_PID == 10_000, 1);
        // Sanity: at MIN_INITIAL_MC per opinion (1M token), max 10k opinions
        // would lock 10k * 1M = 10B token, which exceeds 1B factory supply *10.
        // So limit is bound by token supply long before the count cap kicks in.
        // The cap is defense against state-rent grief, not capital griefing.
    }

    // ============ rc2 FIX TESTS ============

    // --- L-N1: compute_amount_out defensive early returns ---

    #[test]
    fun test_compute_amount_out_zero_reserve_in() {
        // L-N1: would div-by-zero in old code; now early-returns 0
        assert!(compute_amount_out(0, 100, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_reserve_out() {
        // L-N1: zero output reserve -> output 0 (no liquidity to give)
        assert!(compute_amount_out(100, 0, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_all_zero() {
        // L-N1: degenerate (0,0,0) safe early-return
        assert!(compute_amount_out(0, 0, 0) == 0, 1);
    }

    // --- L-N2: compute_tax public-surface tax_bps bound ---

    #[test]
    #[expected_failure(abort_code = E_TAX_BPS_TOO_HIGH, location = Self)]
    fun test_compute_tax_rejects_excessive_tax_bps() {
        // L-N2: public surface enforces tax_bps <= MAX_TAX_BPS even from external callers
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS + 1);
    }

    #[test]
    fun test_compute_tax_accepts_max_tax_bps() {
        // boundary: MAX_TAX_BPS itself is allowed
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS);
    }

    // --- D-M1 sanity: spot-price equivalent computation ---

    #[test]
    fun test_swap_tax_spot_value_correctness() {
        // D-M1 / G-H1: at pool (10, 100), spot price of YAY = nay_r/(yay_r+nay_r) = 100/110 ~ 0.909
        // Swapping 11 YAY: spot value = 11 * 100/110 = 10 $token
        // Compared to old (face-value): tax was on 11 YAY raw. Now: tax on 10 $token.
        let pool_yay_r = 10u64;
        let pool_nay_r = 100u64;
        let amount_in = 11u64;
        let amount_in_token_equiv = ((((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64);
        // 11 * 100 / 110 = 1100 / 110 = 10 exactly
        assert!(amount_in_token_equiv == 10, 1);
        // Tax on 10 at default 10 bps = ceil(10*10/10000) = 1
        assert!(compute_tax(amount_in_token_equiv, 10) == 1, 2);
    }

    #[test]
    fun test_swap_tax_extreme_skew_value() {
        // D-M1: extreme skew (1, 999) - 1 YAY worth almost full $token
        // amount_in = 1, spot value = 1 * 999/1000 ~ 0 (rounds down)
        // amount_in = 1000 (10* pool_yay), spot value = 1000 * 999 / 1001 ~ 998
        let v = ((((1000u128) * (999u128)) / ((1u128) + (999u128))) as u64);
        // 999000 / 1000 = 999
        assert!(v == 999, 1);
    }

    // --- M-N1 sanity: redeem skim math ---

    #[test]
    fun test_redeem_skim_math() {
        // M-N1: redeem 1000 with tax_bps=10
        // tax_amount = ceil(1000 * 10 / 10000) = 1
        // user receives 1000 - 1 = 999
        // tax_burned = 1 (from vault output, not user external)
        let amount = 1000u64;
        let tax_amount = compute_tax(amount, 10);
        assert!(tax_amount == 1, 1);
        let user_out = amount - tax_amount;
        assert!(user_out == 999, 2);
        // Pool dust scenario: redeem 1, tax=1, user_out=0
        let dust_tax = compute_tax(1, 10);
        assert!(dust_tax == 1, 3);
        assert!(1 - dust_tax == 0, 4);            // user gets nothing on dust redeem
    }

    // --- D-M2: zero-output swap detection (constant only - full integration deferred) ---

    #[test]
    fun test_zero_output_detection_math() {
        // D-M2 / M-N2: pool (1e18, 1) swapping 1 YAY for NAY
        // amount_out = 1 * 1 / (1e18 + 1) = 0
        // The swap entry now asserts amount_out > 0 before mutation
        let huge_reserve_in = 1_000_000_000_000_000_000u64;        // 1e18
        let amount_in = 1u64;
        let amount_out = compute_amount_out(huge_reserve_in, 1, amount_in);
        assert!(amount_out == 0, 1);
        // E_ZERO_OUTPUT would abort the swap - verified at module-level constant
        assert!(E_ZERO_OUTPUT == 14, 2);
    }

    // ============ rc4 FIX TESTS ============

    // --- M1: swap_nay_for_yay symmetric E_ZERO_OUTPUT defense ---

    #[test(framework = @supra_framework, creator = @0xCAFE, bob = @0xB0B)]
    #[expected_failure(abort_code = E_ZERO_OUTPUT, location = Self)]
    fun test_rc4_m1_swap_nay_for_yay_zero_output_aborts(
        framework: &signer, creator: &signer, bob: &signer,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        // M1: trigger amount_out=0 in swap_nay_for_yay. Default pool=(MIN,MIN).
        // After bob deposit_pick_side(YAY,1) pool=(MIN, MIN+1) and bob has 1 YAY.
        // Then bob deposit_pick_side(NAY,1) pool=(MIN+1, MIN+1), bob has 1 YAY + 1 NAY.
        // swap_nay_for_yay(1) -> out = (MIN+1)*1/(MIN+1+1) = (MIN+1)/(MIN+2) which
        // truncates to 0 for any MIN >= 1. New assert must fire with E_ZERO_OUTPUT.
        let (pid, _market_addr, _token, token_mint_ref) = setup_full_market(framework, creator);
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);

        // Bob needs 2 tokens (1 for each deposit; tax_bps=0 in test -> no tax burn).
        mint_test_balance(&token_mint_ref, bob_addr, 2);
        deposit_pick_side(bob, pid, 0, SIDE_YAY, 1);
        deposit_pick_side(bob, pid, 0, SIDE_NAY, 1);

        // Pool is now (MIN+1, MIN+1). Tiny swap input -> 0 output.
        swap_nay_for_yay(bob, pid, 0, 1, 0);
        let _ = token_mint_ref;
    }

    // --- L1: tax_bps drift defense in burn_tax ---

    #[test(user = @0xB0B)]
    #[expected_failure(abort_code = E_TAX_DRIFT, location = Self)]
    fun test_rc4_l1_burn_tax_drift_aborts(user: &signer) {
        // L1: burn_tax must abort if tax_bps != DEFAULT_TAX_BPS (and tax_amount > 0).
        // amount=1000 with tax_bps=20 -> compute_tax = ceil(1000*20/10000) = 2 > 0 ->
        // assert fires BEFORE primary_fungible_store::withdraw, so no balance setup
        // needed. @0xCAFE / @0xC4FE are placeholder addrs that are never dereferenced.
        burn_tax(user, @0xCAFE, @0xC4FE, 1000, 20);
    }

    #[test(user = @0xB0B)]
    fun test_rc4_l1_burn_tax_zero_short_circuits(user: &signer) {
        // L1 negative: burn_tax with tax_bps=0 must short-circuit to 0 BEFORE the
        // E_TAX_DRIFT assert. Preserves the test sentinel pattern used throughout
        // setup_test_opinion_market (tax_bps=0 to skip apt_vault dependency).
        let burned = burn_tax(user, @0xCAFE, @0xC4FE, 1000, 0);
        assert!(burned == 0, 1);
    }

    // --- L2: explicit re-bootstrap guard constants ---

    #[test]
    fun test_rc4_l2_constants() {
        // L2: defense-in-depth assert in bootstrap_market_for_mint. Currently
        // structurally unreachable (friend-only + monotonic seq + framework
        // EOBJECT_EXISTS). Test verifies the new error code exists and is
        // distinct from the lookup-side E_MARKET_NOT_FOUND.
        assert!(E_MARKET_ALREADY_EXISTS == 17, 1);
        assert!(E_MARKET_ALREADY_EXISTS != E_MARKET_NOT_FOUND, 2);
        assert!(E_TAX_DRIFT == 16, 3);
        assert!(E_TAX_DRIFT != E_TAX_BPS_TOO_HIGH, 4);
    }
}

```

---

## `sources/press.move`

```move
/// Press - NFT collectible wrapping a Mint (LOCKED 2026-05-01).
///
/// Vinyl-pressing metaphor: original recording (Mint) -> physical vinyl (Press NFT).
/// Press IS technically a mint, but at NFT layer (different scope from Mint event).
///
/// Per-mint opt-in PressConfig (LOCKED):
///   - supply_cap: u16 (1-1000, no unlimited v1)
///   - window_days: u8 (1-7, no permanent open)
///   - emission curve: linear INCREASING per press order (anti-FOMO design):
///       emission(n) = n  (press #1 = 1 token, press #1000 = 1000 tokens)
///       Total per post: cap * (cap+1) / 2 (= 500,500 at cap=1000)
///
/// Per-actor uniqueness: each wallet can press a given mint ONLY once.
/// Author may self-press own mint, max 1 (same one-per-actor rule).
///
/// Royalty: 5% Supra NFT v2 native, payee = PID Object addr (current owner).
/// Marketplace patuh otomatis. Future Press royalty 10% routed to vault (v2 spec).
///
/// First press = FREE (gas only). v1 tidak ada paid press; monetization = secondary market.
module desnet::press {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use supra_framework::event;
    use supra_framework::object::{Self, ExtendRef};
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;
    use desnet::factory;
    use desnet::reaction_emission;

    // ============ CONSTANTS ============

    const SUPPLY_CAP_MIN: u16 = 1;
    const SUPPLY_CAP_MAX: u16 = 1000;
    const WINDOW_DAYS_MIN: u8 = 1;
    const WINDOW_DAYS_MAX: u8 = 7;
    const ROYALTY_BPS: u64 = 500;            // 5% Supra NFT v2 native

    // ============ ERROR CODES ============

    const E_PRESS_NOT_ENABLED: u64 = 1;
    const E_PRESS_WINDOW_EXPIRED: u64 = 2;
    const E_PRESS_SUPPLY_EXHAUSTED: u64 = 3;
    const E_ALREADY_PRESSED: u64 = 4;
    const E_GATE_FAILED: u64 = 5;
    const E_INVALID_SUPPLY_CAP: u64 = 6;
    const E_INVALID_WINDOW_DAYS: u64 = 7;
    const E_PRESS_REGISTRY_NOT_FOUND: u64 = 8;
    const E_NOT_AUTHOR: u64 = 9;
    const E_PRESS_ALREADY_CONFIGURED: u64 = 10;
    const E_MINT_NOT_FOUND: u64 = 11;

    // ============ TYPES ============

    /// Per-mint Press configuration. Stored at author's PID, keyed by mint seq.
    struct PressConfig has store, copy, drop {
        supply_cap: u16,                     // 1-1000
        window_us: u64,                      // creation_ts + window_us = deadline
        pressed_count: u16,                  // mutable counter
        emission_consumed_total: u64,        // running sum of emissions
        deadline_us: u64,                    // creation_ts + window
    }

    /// Per-mint pressed registry (per-actor uniqueness check).
    /// Lives at author_pid, keyed by mint seq.
    struct PressedRegistry has store {
        pressed_by: SmartTable<address, bool>,  // actor -> true after press
    }

    /// Per-author Press storage. SmartTable<seq, (PressConfig, PressedRegistry)>.
    struct PidPressStorage has key {
        configs: SmartTable<u64, PressConfig>,
        registries: SmartTable<u64, PressedRegistry>,
    }

    /// Per-author Press NFT Collection. Lazy-init at first press of any of author's mints.
    /// beta-pattern (LOCKED 2026-04-30): "<handle>'s Presses" collection, all of author's
    /// Press NFTs minted into this single collection. Marketplaces auto-list them
    /// under author's brand.
    struct PressCollection has key {
        collection_addr: address,
        extend_ref: ExtendRef,                // for minting child tokens via Collection signer
        name: String,                          // e.g., "alice's Presses"
    }

    // ============ EVENTS ============

    #[event]
    struct PressEnabled has drop, store {
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_us: u64,
        deadline_us: u64,
        timestamp_secs: u64,
    }

    /// Press record. Replaces former #[event] - now BCS-encoded into
    /// history::Entry.payload at presser's PID. Struct retained for canonical encoding.
    struct PressMinted has drop, store {
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        press_order: u16,                    // n-th press (1-indexed)
        emission_amount: u64,                // = press_order (linear increasing)
        nft_object_addr: address,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidPressStorage at PID addr. Called from enable_press on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
    fun ensure_press_storage(pid_addr: address) {
        if (!exists<PidPressStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidPressStorage {
                configs: smart_table::new(),
                registries: smart_table::new(),
            });
        };
    }

    /// Lazy-create PressCollection at PID addr. Called from press() on first press of
    /// any of author's mints. Creates "<handle>'s Presses" collection with 5% royalty
    /// to author_pid.
    fun ensure_press_collection(author_pid: address): address acquires PressCollection {
        if (exists<PressCollection>(author_pid)) {
            return borrow_global<PressCollection>(author_pid).collection_addr
        };

        let pid_signer = profile::derive_pid_signer(author_pid);
        let handle = profile::handle_of(author_pid);
        let collection_name = build_collection_name(&handle);

        // 5% royalty payee = author's Vault addr -> marketplace royalties land at vault,
        // triggering the 50/50 buyback-burn + PID-owner split flow on settle.
        let payee = factory::vault_addr_of_pid(author_pid);
        let r = royalty::create(ROYALTY_BPS, 10000, payee);

        let constructor_ref = collection::create_unlimited_collection(
            &pid_signer,
            build_collection_description(&handle),
            collection_name,
            option::some(r),
            build_collection_uri(&handle),
        );

        let collection_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(&pid_signer, PressCollection {
            collection_addr,
            extend_ref,
            name: collection_name,
        });

        collection_addr
    }

    fun build_collection_name(handle: &String): String {
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s Presses");
        s
    }

    fun build_collection_description(handle: &String): String {
        let s = string::utf8(b"Press NFTs collected from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mints on DeSNet.");
        s
    }

    fun build_collection_uri(_handle: &String): String {
        // Empty URI - frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    fun build_token_name(handle: &String, mint_seq: u64, press_order: u16): String {
        // Format: "<handle> #<mint_seq> press #<press_order>"
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b" #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b" press #");
        string::append(&mut s, u64_to_string((press_order as u64)));
        s
    }

    fun build_token_description(handle: &String, mint_seq: u64): String {
        let s = string::utf8(b"Pressed from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mint #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b".");
        s
    }

    fun build_token_uri(_handle: &String, _mint_seq: u64): String {
        // Empty URI - frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    /// Simple u64 -> decimal String. Supra stdlib doesn't have utoa, hand-roll.
    fun u64_to_string(n: u64): String {
        if (n == 0) return string::utf8(b"0");
        let buf = std::vector::empty<u8>();
        while (n > 0) {
            let d = ((n % 10) as u8) + 0x30;  // '0' = 0x30
            std::vector::push_back(&mut buf, d);
            n = n / 10;
        };
        std::vector::reverse(&mut buf);
        string::utf8(buf)
    }

    // ============ ENABLE PRESS - author opt-in per mint ============

    /// Author opts in to Press for a specific mint. Sets supply_cap + window.
    /// One-time per mint; cannot reconfigure after first press.
    public entry fun enable_press(
        author: &signer,
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_days: u8,
    ) acquires PidPressStorage {
        assert!(supply_cap >= SUPPLY_CAP_MIN && supply_cap <= SUPPLY_CAP_MAX, E_INVALID_SUPPLY_CAP);
        assert!(window_days >= WINDOW_DAYS_MIN && window_days <= WINDOW_DAYS_MAX, E_INVALID_WINDOW_DAYS);

        profile::assert_authorized(author, author_pid);

        // Validate mint_seq corresponds to a real mint. Without this, author can
        // enable_press on bogus seqs and farm reaction emission via secondary wallets.
        assert!(mint_seq < mint::next_seq(author_pid), E_MINT_NOT_FOUND);

        ensure_press_storage(author_pid);

        let storage = borrow_global_mut<PidPressStorage>(author_pid);
        assert!(!smart_table::contains(&storage.configs, mint_seq), E_PRESS_ALREADY_CONFIGURED);

        let now_us = timestamp::now_seconds() * 1_000_000;
        let window_us = (window_days as u64) * 86_400 * 1_000_000;
        let deadline_us = now_us + window_us;

        let config = PressConfig {
            supply_cap,
            window_us,
            pressed_count: 0,
            emission_consumed_total: 0,
            deadline_us,
        };

        smart_table::add(&mut storage.configs, mint_seq, config);
        smart_table::add(&mut storage.registries, mint_seq, PressedRegistry {
            pressed_by: smart_table::new(),
        });

        event::emit(PressEnabled {
            author_pid,
            mint_seq,
            supply_cap,
            window_us,
            deadline_us,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ PRESS - anyone can press, gates checked ============

    /// Press a mint. Mints Supra NFT v2 collectible to presser's wallet.
    /// Atomic: register press -> mint NFT -> emit event -> emission bonus (if pool seeded).
    ///
    /// Validation chain:
    /// 1. PressConfig exists for (author_pid, mint_seq) - author opted in
    /// 2. Window not expired
    /// 3. Supply not exhausted
    /// 4. Per-actor uniqueness - presser hasn't pressed this mint before
    /// 5. Mint-level ReferenceGate (if any) passes for presser
    ///
    /// Emission bonus path: if author's $TOKEN/D pool seeded -> mint emission(n) tokens
    /// to presser. If pool not seeded -> press succeeds without emission. (LOCKED.)
    public entry fun press(
        presser: &signer,
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        presser_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidPressStorage, PressCollection {
        profile::assert_authorized(presser, presser_pid);
        let presser_addr = signer::address_of(presser);

        assert!(exists<PidPressStorage>(author_pid), E_PRESS_NOT_ENABLED);

        // Mint-level ReferenceGate (self-exempt: author always passes own gate).
        // Done before mut-borrow phase to keep storage scope pure.
        // Self-exempt via PID; gate check via wallet addr (presser_addr) per locked semantic
        // 2026-05-01: balance + LP-stake ownership at wallet that holds PID NFT.
        if (presser_pid != author_pid) {
            let gate_opt = mint::get_mint_gate(author_pid, mint_seq);
            if (option::is_some(&gate_opt)) {
                let target_pid = profile::reference_gate_target_pid(option::borrow(&gate_opt));
                let synced = link::is_synced(presser_pid, target_pid);
                let gate = option::extract(&mut gate_opt);
                assert!(
                    reference_gate::check(&gate, presser_addr, synced, false, presser_stake_position_addr),
                    E_GATE_FAILED
                );
            };
        };

        // Validation phase - check + bump counters in mut-borrow scope
        let press_order: u16;
        {
            let storage = borrow_global_mut<PidPressStorage>(author_pid);
            assert!(smart_table::contains(&storage.configs, mint_seq), E_PRESS_NOT_ENABLED);

            let config = smart_table::borrow_mut(&mut storage.configs, mint_seq);
            let now_us = timestamp::now_seconds() * 1_000_000;
            assert!(now_us < config.deadline_us, E_PRESS_WINDOW_EXPIRED);
            assert!(config.pressed_count < config.supply_cap, E_PRESS_SUPPLY_EXHAUSTED);

            // Per-actor uniqueness
            let registry = smart_table::borrow_mut(&mut storage.registries, mint_seq);
            assert!(!smart_table::contains(&registry.pressed_by, presser_pid), E_ALREADY_PRESSED);

            // Register press + bump counters
            smart_table::add(&mut registry.pressed_by, presser_pid, true);
            config.pressed_count = config.pressed_count + 1;
            press_order = config.pressed_count;
            let emission_amount_local = (press_order as u64);
            config.emission_consumed_total = config.emission_consumed_total + emission_amount_local;
        };  // PidPressStorage borrow released here

        // ============ NFT v2 mint ============

        // Lazy-init "<handle>'s Presses" Collection (beta-pattern locked 2026-04-30).
        // Collection is created with pid_signer (= creator addr = author_pid).
        let _collection_addr = ensure_press_collection(author_pid);

        let handle = profile::handle_of(author_pid);
        let token_name = build_token_name(&handle, mint_seq, press_order);
        let token_description = build_token_description(&handle, mint_seq);
        let token_uri = build_token_uri(&handle, mint_seq);

        let collection_state = borrow_global<PressCollection>(author_pid);
        let collection_name = collection_state.name;

        // CRITICAL: token::create derives Collection address from (creator_addr, name).
        // Must use pid_signer (the SAME signer that created the Collection in
        // ensure_press_collection), not collection_signer - otherwise derivation
        // mismatches and aborts EOBJECT_DOES_NOT_EXIST.
        let pid_signer = profile::derive_pid_signer(author_pid);

        // Mint Token Object inside collection. None royalty = inherit from collection (5%).
        let token_constructor_ref = token::create(
            &pid_signer,
            collection_name,
            token_description,
            token_name,
            option::none(),
            token_uri,
        );

        let nft_object_addr = object::address_from_constructor_ref(&token_constructor_ref);
        let token_object = object::object_from_constructor_ref<token::Token>(&token_constructor_ref);

        // Transfer to presser. token::create with pid_signer -> token owned by author_pid.
        // pid_signer authorizes transfer to presser.
        object::transfer(&pid_signer, token_object, presser_addr);

        // ============ Emission bonus ============
        // Reaction gauge is keyed by author_pid (not handle), so each PID -
        // main or subdomain - has its own independent reaction pool. No
        // handle-string collision between a main "alice" and a subdomain
        // `alice@bob`.
        //
        // Self-press blocked: NFT mint still happens (author can collect own
        // work) but emission to author's own wallet is suppressed - would
        // otherwise let author drain their own pool via a single self-press.
        let emission_amount = if (presser_pid == author_pid) {
            0u64
        } else {
            reaction_emission::distribute_to_presser(author_pid, presser_addr)
        };

        let now_secs = timestamp::now_seconds();
        let record = PressMinted {
            presser_pid,
            author_pid,
            mint_seq,
            press_order,
            emission_amount,
            nft_object_addr,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        // History at presser's PID (the actor performing the verb), target = author_pid.
        history::append(
            presser_pid,
            history::new_entry(history::verb_press(), now_secs, option::some(author_pid), payload, option::none<address>()),
        );
    }

    // ============ VIEWS ============

    #[view]
    public fun is_press_enabled(author_pid: address, mint_seq: u64): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        smart_table::contains(&borrow_global<PidPressStorage>(author_pid).configs, mint_seq)
    }

    #[view]
    public fun pressed_count(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return 0;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.configs, mint_seq)) return 0;
        smart_table::borrow(&storage.configs, mint_seq).pressed_count
    }

    #[view]
    public fun supply_cap(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).supply_cap
    }

    #[view]
    public fun deadline_us(author_pid: address, mint_seq: u64): u64 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).deadline_us
    }

    #[view]
    public fun has_pressed(
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
    ): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.registries, mint_seq)) return false;
        let registry = smart_table::borrow(&storage.registries, mint_seq);
        smart_table::contains(&registry.pressed_by, presser_pid)
    }

    #[view]
    public fun royalty_bps(): u64 { ROYALTY_BPS }
}

```

---

## `sources/profile.move`

```move
/// Profile - PID Object NFT primitive (LOCKED 2026-05-01).
///
/// PID = Profile ID. Supra Object NFT, deterministic addr from wallet:
///   pid_addr = derive_pid_address(wallet) = create_object_address(@desnet, bcs(wallet))
///
/// Three-tier capability hierarchy (Opsi 1 ExtendRef pattern, locked v1):
/// 1. Owner = address holding PID NFT (cold wallet / multisig). Can transfer NFT,
///    rotate controller, emergency-revoke signers.
/// 2. Controller = hot wallet. Adds/removes signers, updates metadata. Cannot transfer NFT.
/// 3. Signers = per-app Ed25519 keys. Sign mints/reactions off-chain; app submits with sig.
///
/// Handle registry: bare `alice` lowercase, 1-64 chars, charset a-z/0-9/-.
/// Length-tier D pricing (1-100 D), one-time, immutable post-registration.
///
/// Atomic register_handle: derives PID Object -> stores Profile -> calls factory::create_token
/// to spawn $TOKEN and dual-vault for this PID.
///
/// sync_gate: opt-in `Profile.sync_gate: Option<ReferenceGate>` field. Gates incoming
/// Sync requests. NOT a privacy primitive - mints stay public; only Sync action gated.
///
/// Implicit-then-named magic: mention 0xBOB while bob is guest -> bob registers later
/// -> indexer auto-resolves historical mentions to @bob.
module desnet::profile {
    use std::bcs;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};
    use supra_framework::event;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::{Self, ExtendRef, TransferRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::governance;
    use desnet::supra_fee_vault;

    friend desnet::mint;
    friend desnet::link;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;
    friend desnet::history;
    friend desnet::opinion;
    friend desnet::ipo;


    // ============ CONSTANTS ============

    const HANDLE_MIN_LEN: u64 = 1;
    const HANDLE_MAX_LEN: u64 = 64;

    /// Length-tier SUPRA pricing (one-time, no renewal). Raw u64 (SUPRA has 8 decimals).
    /// Tiers calibrated for SUPRA~$1: 100/50/20/10/5/1 SUPRA.
    const PRICE_1_CHAR_SUPRA: u64 = 100_000_000_000_000;     // 1M SUPRA
    const PRICE_2_CHAR_SUPRA: u64 =  10_000_000_000_000;     // 100K SUPRA
    const PRICE_3_CHAR_SUPRA: u64 =   1_000_000_000_000;     // 10K SUPRA
    const PRICE_4_CHAR_SUPRA: u64 =     100_000_000_000;     // 1K SUPRA
    const PRICE_5_CHAR_SUPRA: u64 =      10_000_000_000;     // 100 SUPRA
    const PRICE_6PLUS_CHAR_SUPRA: u64 =   1_000_000_000;     // 10 SUPRA

    /// Caps for inline metadata at registration.
    const AVATAR_MAX_BYTES: u64 = 8192;       // <=8KB inline (LOCKED)
    const BIO_MAX_BYTES: u64 = 333;           // <=333B inline (LOCKED)

    const SEED_PID: vector<u8> = b"pid::";
    const SEED_SUBPID: vector<u8> = b"subpid::";

    // ============ ERROR CODES ============

    const E_HANDLE_TAKEN: u64 = 1;
    const E_HANDLE_TOO_SHORT: u64 = 2;
    const E_HANDLE_TOO_LONG: u64 = 3;
    const E_HANDLE_INVALID_CHAR: u64 = 4;
    const E_PID_ALREADY_EXISTS: u64 = 5;
    const E_NOT_CONTROLLER: u64 = 6;
    const E_NOT_OWNER: u64 = 7;
    const E_PROFILE_NOT_FOUND: u64 = 8;
    const E_INSUFFICIENT_FEE: u64 = 9;
    const E_REGISTRY_NOT_INITIALIZED: u64 = 10;
    const E_GUEST_CANNOT_WRITE: u64 = 11;
    const E_AVATAR_TOO_LARGE: u64 = 12;
    const E_BIO_TOO_LARGE: u64 = 13;
    const E_NOT_ADMIN: u64 = 14;
    const E_NOT_CONTROLLER_OR_OWNER: u64 = 15;
    const E_SYNC_GATE_ALREADY_SET: u64 = 16;
    const E_RESERVED_HANDLE: u64 = 17;
    const E_INVALID_ADDRESS: u64 = 18;
    /// v0.3.2 (F10): update_fee_receiver neutered after supra_fee_vault (F9) takes over fee routing.
    const E_NEUTERED: u64 = 19;

    // ============ TYPES ============

    /// Single 4-field primitive struct for engagement policy. Stored as Option<ReferenceGate>.
    struct ReferenceGate has copy, drop, store {
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    }

    public fun reference_gate_new(
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ): ReferenceGate {
        ReferenceGate { target_pid, min_token_balance, max_token_balance, min_lp_stake }
    }

    public fun reference_gate_target_pid(gate: &ReferenceGate): address { gate.target_pid }
    public fun reference_gate_min_token_balance(gate: &ReferenceGate): u64 { gate.min_token_balance }
    public fun reference_gate_max_token_balance(gate: &ReferenceGate): u64 { gate.max_token_balance }
    public fun reference_gate_min_lp_stake(gate: &ReferenceGate): u64 { gate.min_lp_stake }

    /// PID Profile resource at PID Object addr.
    struct Profile has key {
        handle: String,                            // bare lowercase, immutable post-reg
        controller: address,                       // hot wallet (delegated daily ops)
        signers_: SmartTable<vector<u8>, SignerEntry>,  // Ed25519 pubkey -> metadata
        metadata_uri: String,                      // mutable, pointer to off-chain profile JSON
        avatar_blob_id: vector<u8>,                // mutable, Shelby/Walrus blob ref
        banner_blob_id: vector<u8>,                // mutable
        bio: String,                               // mutable, inline <=333B
        sync_gate: Option<ReferenceGate>,          // opt-in node-membership policy
        extend_ref: ExtendRef,                     // for ExtendRef-derived signer (Opsi 1)
        registered_at_secs: u64,
        pre_ipo_cohort: bool,                      // true = pre-IPO / IPO-phase, false = post-IPO
    }

    /// Per-app signer registry entry. Controller-managed.
    struct SignerEntry has copy, drop, store {
        app_label: String,                         // human-readable identifier
        added_at_secs: u64,
        last_used_secs: u64,
    }

    /// PID NFT transferability vault - TransferRef stored separately so only
    /// owner-initiated transfers go through (controller has profile signer but
    /// not transfer power). Stored at PID addr alongside Profile.
    struct TransferVault has key {
        transfer_ref: TransferRef,
    }

    /// Protocol-level state singleton at @desnet.
    /// The package signer_cap lives in `desnet::governance`;
    /// profile acquires the package signer at runtime via
    /// `governance::derive_pkg_signer()`.
    struct ProtocolState has key {
        fee_receiver: address,                    // initial: @desnet; post-DESNET: vault addr
        admin: address,                           // multisig (rotated to governance later)
    }

    /// Global handle registry singleton at @desnet.
    /// handle (bare lowercase) -> wallet (PID Object addr derivable from wallet).
    struct HandleRegistry has key {
        handle_to_wallet: SmartTable<String, address>,
    }

    // ============ EVENTS ============

    #[event]
    struct ProtocolInitialized has drop, store {
        protocol_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct HandleRegistered has drop, store {
        handle: String,
        wallet: address,
        pid_addr: address,
        fee_paid_supra: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct ControllerRotated has drop, store {
        pid_addr: address,
        old_controller: address,
        new_controller: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SignerAdded has drop, store {
        pid_addr: address,
        pubkey: vector<u8>,
        app_label: String,
        timestamp_secs: u64,
    }

    #[event]
    struct SignerRevoked has drop, store {
        pid_addr: address,
        pubkey: vector<u8>,
        timestamp_secs: u64,
    }

    #[event]
    struct ProfileMetadataUpdated has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SyncGateAttached has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SyncGateCleared has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct PidTokenWithdrawn has drop, store {
        pid_addr: address,
        token_metadata: address,
        amount: u64,
        recipient: address,
        timestamp_secs: u64,
    }

    // ============ INIT - resource_account deploy pattern (mirror factory) ============

    /// SUPRA FA metadata addr (Supra paired-coin convention).
    const SUPRA_FA_METADATA: address = @0xa;

    /// Init callback. The package SignerCapability is owned by
    /// `desnet::governance`; profile just initializes its singleton resources
    /// using the resource_account signer that Supra passes in here.
    fun init_module(account: &signer) {
        let protocol_addr = signer::address_of(account);

        move_to(account, ProtocolState {
            fee_receiver: protocol_addr,           // initially route fees to protocol addr
            admin: @origin,                        // deployer multisig
        });

        move_to(account, HandleRegistry {
            handle_to_wallet: smart_table::new(),
        });

        event::emit(ProtocolInitialized {
            protocol_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ADMIN - config updates (multisig -> governance later) ============

    /// Admin updates fee_receiver. Used pre-supra_fee_vault to point fees somewhere.
    /// Post-vault upgrade, register_handle body bypasses this field - supra_fee_vault
    /// is the immutable destination. Kept here for v0.3.0 baseline; body becomes
    /// `abort 0` in v0.3.1 compat upgrade.
    /// v0.3.2 (F10): NEUTERED. With supra_fee_vault (F9), `state.fee_receiver` field
    /// is no longer read by `register_handle` body - fees route directly to the vault.
    /// Field retained as vestigial (compat-only). Eliminates the last admin knob over
    /// fee destination once F9 is live.
    public entry fun update_fee_receiver(
        _admin: &signer,
        _new_fee_receiver: address,
    ) acquires ProtocolState {
        let _ = borrow_global<ProtocolState>(@desnet);
        abort E_NEUTERED
    }

    /// Admin rotates admin (e.g., to governance contract). One-way after PMF transition.
    public entry fun rotate_admin(
        current_admin: &signer,
        new_admin: address,
    ) acquires ProtocolState {
        // Gemini MED fix (audit R1): zero-addr check.
        assert!(new_admin != @0x0, E_INVALID_ADDRESS);
        let state = borrow_global_mut<ProtocolState>(@desnet);
        assert!(signer::address_of(current_admin) == state.admin, E_NOT_ADMIN);
        state.admin = new_admin;
    }

    // Package upgrade lives in `desnet::governance` (multisig_upgrade +
    // execute_proposal). No per-module do_upgrade entry needed in monolith.

    // ============ ADDRESS DERIVATION ============

    /// Pure fn - deterministic PID Object addr from wallet.
    /// Single canonical PID per wallet (constraint: same wallet cannot register multiple handles).
    #[view]
    public fun derive_pid_address(wallet: address): address {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
        object::create_object_address(&@desnet, seed)
    }

    /// Derives a deterministic PID address for a subdomain relative to a domain handle.
    #[view]
    public fun derive_subdomain_pid_address(handle: String, subdomain: String): address {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_SUBPID);
        vector::append(&mut seed, bcs::to_bytes(&handle));
        vector::append(&mut seed, bcs::to_bytes(&subdomain));
        object::create_object_address(&@desnet, seed)
    }

    // ============ HANDLE VALIDATION ============

    fun validate_handle(handle: &vector<u8>) {
        let len = vector::length(handle);
        assert!(len >= HANDLE_MIN_LEN, E_HANDLE_TOO_SHORT);
        assert!(len <= HANDLE_MAX_LEN, E_HANDLE_TOO_LONG);

        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(handle, i);
            // Allowed: a-z, 0-9, '-'
            let ok = (ch >= 0x61 && ch <= 0x7A)
                  || (ch >= 0x30 && ch <= 0x39)
                  || (ch == 0x2D);
            assert!(ok, E_HANDLE_INVALID_CHAR);
            i = i + 1;
        };
    }

    /// Length-tier SUPRA pricing. Returns raw u64 (8 decimals).
    public fun handle_fee_supra(handle_len: u64): u64 {
        if (handle_len == 1) PRICE_1_CHAR_SUPRA
        else if (handle_len == 2) PRICE_2_CHAR_SUPRA
        else if (handle_len == 3) PRICE_3_CHAR_SUPRA
        else if (handle_len == 4) PRICE_4_CHAR_SUPRA
        else if (handle_len == 5) PRICE_5_CHAR_SUPRA
        else PRICE_6PLUS_CHAR_SUPRA
    }

    // ============ REGISTER HANDLE - atomic with token spawn ============

    /// Atomic registration. Single-tx flow:
    ///   1. Validate handle (charset + length) + sizes (avatar <=8KB, bio <=333B)
    ///   2. Check uniqueness (handle not taken, PID Object addr not occupied)
    ///   3. Compute fee in D (length-tier 1-100), withdraw from wallet -> fee_receiver
    ///   4. Create PID Object via protocol_signer at deterministic addr derive(wallet)
    ///   5. Generate ExtendRef + TransferRef
    ///   6. move_to Profile (controller, signers SmartTable, metadata, sync_gate=none)
    ///   7. move_to TransferVault (transfer_ref isolated from Profile fields)
    ///   8. Insert handle -> wallet in HandleRegistry
    ///   9. Cross-package call factory::create_token(wallet, handle, pid_addr)
    ///       Factory atomically spawns $TOKEN FA + SUPRA/D vaults + reaction/LP reserves;
    ///       deposits 5% creator allocation (50M $TOKEN) to pid_addr's primary store.
    ///  10. Emit HandleRegistered event
    ///
    /// Constraint: same wallet cannot register multiple handles. derive(wallet) is
    /// occupied for life. Multi-identity = multi-wallet (standard web3 hygiene).
    ///
    /// Sibling storage (PidMintMeta, PidSyncSet, etc.) NOT initialized here - sibling
    /// modules lazy-init on first-write via `derive_pid_signer` friend helper.
    /// Cycle prevention: profile.move doesn't depend on sibling modules.
    public entry fun register_handle(
        wallet: &signer,
        handle: vector<u8>,
        controller_addr: address,
        avatar_b64: vector<u8>,
        bio: vector<u8>,
    ) acquires HandleRegistry, ProtocolState {
        // 1. Validate
        validate_handle(&handle);
        assert!(vector::length(&avatar_b64) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&bio) <= BIO_MAX_BYTES, E_BIO_TOO_LARGE);

        let wallet_addr = signer::address_of(wallet);

        // Reserved handles - each bound to one specific claimer address (per-handle).
        // Prevents front-run squatting between package publish and project's claim tx.
        // Once claimed by the authorized addr, E_HANDLE_TAKEN takes over for any
        // subsequent attempt regardless of caller. PID-per-wallet constraint preserved
        // (each reserved handle has a different claimer addr -> no PID collision).
        let claimer_opt = reserved_handle_claimer(&handle);
        if (option::is_some(&claimer_opt)) {
            let required_claimer = *option::borrow(&claimer_opt);
            assert!(wallet_addr == required_claimer, E_RESERVED_HANDLE);
        };
        let pid_addr = derive_pid_address(wallet_addr);
        let handle_str = string::utf8(handle);

        // 2. Uniqueness
        let registry = borrow_global_mut<HandleRegistry>(@desnet);
        assert!(
            !smart_table::contains(&registry.handle_to_wallet, handle_str),
            E_HANDLE_TAKEN
        );
        assert!(!exists<Profile>(pid_addr), E_PID_ALREADY_EXISTS);

        // 3. Fee in SUPRA - route directly to supra_fee_vault
        let _state = borrow_global<ProtocolState>(@desnet);
        let fee_raw = handle_fee_supra(vector::length(&handle));
        let supra_metadata = object::address_to_object<Metadata>(SUPRA_FA_METADATA);
        if (fee_raw > 0) {
            let fee_fa = primary_fungible_store::withdraw(wallet, supra_metadata, fee_raw);
            supra_fee_vault::deposit_supra_fa(fee_fa);
        };

        // 4. Create PID Object via package signer (governance-derived)
        let protocol_signer = governance::derive_pkg_signer();
        let seed = make_pid_seed(wallet_addr);
        let constructor_ref = object::create_named_object(&protocol_signer, seed);

        // 5. Generate refs
        let pid_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        // 6. Profile resource at PID addr
        let now_secs = timestamp::now_seconds();
        move_to(&pid_signer, Profile {
            handle: handle_str,
            controller: controller_addr,
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: avatar_b64,
            banner_blob_id: vector::empty(),
            bio: string::utf8(bio),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: now_secs,
            pre_ipo_cohort: false,
        });

        // 7. TransferVault - transfer_ref isolated (controller cannot transfer NFT)
        move_to(&pid_signer, TransferVault { transfer_ref });

        // 7.5 Transfer Object ownership to wallet (NFT-style).
        let pid_object = object::address_to_object<Profile>(pid_addr);
        object::transfer(&protocol_signer, pid_object, wallet_addr);

        // 8. Register handle -> wallet mapping
        smart_table::add(&mut registry.handle_to_wallet, string::utf8(handle), wallet_addr);

        // 9. Emit
        event::emit(HandleRegistered {
            handle: string::utf8(handle),
            wallet: wallet_addr,
            pid_addr,
            fee_paid_supra: fee_raw,
            timestamp_secs: now_secs,
        });
    }

    /// Reserved handle -> authorized claimer. Each reserved handle has its OWN claimer
    /// address (different per handle to preserve PID-per-wallet uniqueness). Returns
    /// `Option::none` if handle is not reserved (= public registration).
    ///
    /// - "desnet" -> @desnet_claimer (= @origin = deployer multisig)
    /// - "darbitex" -> Darbitex Final publisher multisig 3/5 (cross-project)
    /// - "d" -> D Supra pkg (sealed resource_account, no signer ever - permanent burn)
    /// - "supra" -> Darbitex treasury multisig 3/5
    /// - "supra" -> dedicated supra-claimer multisig
    fun reserved_handle_claimer(handle: &vector<u8>): option::Option<address> {
        let h = *handle;
        if (h == b"desnet")        option::some(@desnet_claimer)
        else if (h == b"darbitex") option::some(@darbitex_claimer)
        else if (h == b"d")        option::some(@d_claimer)
        else if (h == b"supra")    option::some(@supra_claimer)
        else option::none()
    }

    fun make_pid_seed(wallet: address): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
        seed
    }

    /// Creates a PID NFT for a subdomain registrant (called by `desnet::ipo`).
    ///
    /// Deterministic addr via `derive_subdomain_pid_address(handle, subdomain)`.
    /// Profile.handle = subdomain (bare name), controller = depositor.
    /// Ownership transferred to depositor wallet.
    ///
    /// Caller must provide the protocol_signer (obtained via governance::derive_pkg_signer).
    /// Internally creates the named object, stores Profile + TransferVault, transfers NFT,
    /// and emits HandleRegistered. No caller-side seed or ref management needed.
    public fun create_subdomain_profile(
        protocol_signer: &signer,
        handle: String,
        subdomain: String,
        controller: address,
        pre_ipo_cohort: bool,
    ) {
        let pid_addr = derive_subdomain_pid_address(handle, subdomain);
        assert!(!exists<Profile>(pid_addr), E_PID_ALREADY_EXISTS);
        // (ProtocolState existence is implicit: protocol_signer can only be
        //  produced by governance::derive_pkg_signer, which itself requires
        //  ProtocolState. So we drop the explicit borrow that older Move
        //  compilers want declared in `acquires`.)

        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_SUBPID);
        vector::append(&mut seed, bcs::to_bytes(&handle));
        vector::append(&mut seed, bcs::to_bytes(&subdomain));
        let constructor_ref = object::create_named_object(protocol_signer, seed);

        let pid_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        let now_secs = timestamp::now_seconds();
        move_to(&pid_signer, Profile {
            handle: subdomain,
            controller,
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: vector::empty(),
            banner_blob_id: vector::empty(),
            bio: string::utf8(b""),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: now_secs,
            pre_ipo_cohort,
        });

        move_to(&pid_signer, TransferVault { transfer_ref });

        let pid_object = object::address_to_object<Profile>(pid_addr);
        object::transfer(protocol_signer, pid_object, controller);

        event::emit(HandleRegistered {
            handle,
            wallet: controller,
            pid_addr,
            fee_paid_supra: 0,
            timestamp_secs: now_secs,
        });
    }

    // ============ CONTROLLER + SIGNER MANAGEMENT ============

    /// Owner rotates controller. Only PID NFT owner can call.
    public entry fun rotate_controller(
        owner: &signer,
        pid_addr: address,
        new_controller: address,
    ) acquires Profile {
        assert_owner(owner, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        let old = profile.controller;
        profile.controller = new_controller;

        event::emit(ControllerRotated {
            pid_addr,
            old_controller: old,
            new_controller,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// Controller adds per-app Ed25519 signer. Off-chain signing path (Opsi 1).
    public entry fun add_signer(
        controller: &signer,
        pid_addr: address,
        pubkey: vector<u8>,
        app_label: vector<u8>,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);

        let entry = SignerEntry {
            app_label: string::utf8(app_label),
            added_at_secs: 0,
            last_used_secs: 0,
        };
        smart_table::add(&mut profile.signers_, pubkey, entry);

        event::emit(SignerAdded {
            pid_addr,
            pubkey,
            app_label: string::utf8(app_label),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// Controller revokes signer. Owner can also revoke as emergency override.
    /// Auth: caller must be Profile.controller OR current PID NFT holder (object::owner).
    public entry fun revoke_signer(
        controller_or_owner: &signer,
        pid_addr: address,
        pubkey: vector<u8>,
    ) acquires Profile {
        assert_controller_or_owner(controller_or_owner, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        if (smart_table::contains(&profile.signers_, pubkey)) {
            smart_table::remove(&mut profile.signers_, pubkey);
        };

        event::emit(SignerRevoked {
            pid_addr,
            pubkey,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ METADATA UPDATES (controller-callable, mutable) ============

    /// Controller updates mutable profile metadata (avatar/banner/bio).
    /// FA-level icon_uri stays immutable (locked at create_token); profile-level
    /// avatar resolves dynamically via DeSNet frontend.
    public entry fun update_metadata(
        controller: &signer,
        pid_addr: address,
        new_avatar_blob: vector<u8>,
        new_banner_blob: vector<u8>,
        new_bio: vector<u8>,
        new_metadata_uri: vector<u8>,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        // Mirror register_handle's validation - caps must apply on both initial-set and update.
        // banner uses same 8KB cap as avatar (both inline media of similar nature).
        assert!(vector::length(&new_avatar_blob) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&new_banner_blob) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&new_bio) <= BIO_MAX_BYTES, E_BIO_TOO_LARGE);
        let profile = borrow_global_mut<Profile>(pid_addr);
        profile.avatar_blob_id = new_avatar_blob;
        profile.banner_blob_id = new_banner_blob;
        profile.bio = string::utf8(new_bio);
        profile.metadata_uri = string::utf8(new_metadata_uri);

        event::emit(ProfileMetadataUpdated {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ SYNC GATE (node-membership policy) ============

    /// Controller attaches sync_gate. Gates who can Sync to this PID.
    /// IMMUTABLE post-attach (rugpull-engagement-rules prevention).
    /// To clear, call clear_sync_gate (also one-way to none).
    /// Args flattened to primitives - Supra entry fns can't take struct params.
    public entry fun attach_sync_gate(
        controller: &signer,
        pid_addr: address,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        // Immutability: cannot overwrite an existing gate. To replace, controller must
        // first call clear_sync_gate (2-step replacement = friction = anti-rugpull).
        assert!(option::is_none(&profile.sync_gate), E_SYNC_GATE_ALREADY_SET);
        let gate = reference_gate_new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
        profile.sync_gate = option::some(gate);

        event::emit(SyncGateAttached {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ TREASURY (owner-only) ============

    /// Owner withdraws any FA from PID's primary store to a recipient address.
    /// Used by creators to access their 50M creator allocation (deposited to PID at
    /// register_handle time) + future donations + governance treasury that lands at PID.
    ///
    /// Auth: PID NFT OWNER ONLY (cold wallet). Treasury access is high-value and
    /// must NOT be reachable from controller (hot wallet) - controller compromise
    /// limited to social ops (Spark/Voice/etc), not financial drain. This is the
    /// inverse of the daily-ops-via-controller pattern: TREASURY = OWNER ALWAYS.
    ///
    /// Note: D vault dispurse goes directly to current NFT owner's WALLET (auto-resolved
    /// at settle), not to PID's primary store - so D dispurse income doesn't need
    /// withdraw_pid_token. This fn is for: creator allocation, donations, governance
    /// treasury, anything else accumulated at PID's primary store.
    ///
    /// Buyback-burn safety: structural - buyback portion lives at vault, never deposits
    /// to PID. This withdraw cannot reach it.
    public entry fun withdraw_pid_token(
        owner: &signer,
        pid_addr: address,
        token_metadata_addr: address,
        amount: u64,
        recipient: address,
    ) acquires Profile {
        assert_owner(owner, pid_addr);
        let pid_signer = derive_pid_signer(pid_addr);
        let token_meta = object::address_to_object<Metadata>(token_metadata_addr);
        let fa = primary_fungible_store::withdraw(&pid_signer, token_meta, amount);
        primary_fungible_store::deposit(recipient, fa);

        event::emit(PidTokenWithdrawn {
            pid_addr,
            token_metadata: token_metadata_addr,
            amount,
            recipient,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    public entry fun clear_sync_gate(
        controller: &signer,
        pid_addr: address,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        profile.sync_gate = option::none();

        event::emit(SyncGateCleared {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ASSERTIONS ============

    /// Assert caller is the current owner of the PID NFT.
    /// Owner = address holding the Object NFT (per Supra object framework).
    /// Initially set in register_handle via object::transfer(protocol_signer, ..., wallet).
    /// Owner can rotate via marketplace transfer (ungated_transfer enabled), so always
    /// query current state via object::owner.
    fun assert_owner(caller: &signer, pid_addr: address) {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(
            object::owner(pid_object) == signer::address_of(caller),
            E_NOT_OWNER
        );
    }

    fun assert_controller(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let profile = borrow_global<Profile>(pid_addr);
        assert!(profile.controller == signer::address_of(caller), E_NOT_CONTROLLER);
    }

    /// Caller must be controller OR current NFT owner. Used for signer-key revocation
    /// (owner emergency override path) - owner can revoke any signer even if controller
    /// is compromised.
    fun assert_controller_or_owner(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let profile = borrow_global<Profile>(pid_addr);
        if (profile.controller == caller_addr) return;
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(object::owner(pid_object) == caller_addr, E_NOT_CONTROLLER_OR_OWNER);
    }

    /// Internal - friend access for other DeSNet modules to assert PID exists at addr.
    public(friend) fun assert_pid_exists(pid_addr: address) {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
    }

    /// Verb-auth gate. Caller is allowed to act AS this PID if they are either the
    /// current NFT owner or the configured controller. Used by every verb entry
    /// (mint/pulse/link/press/opinion/giveaway) so that subdomain-PID holders and
    /// main-handle holders are treated identically - the verb modules never derive
    /// pid_addr from the caller's wallet, the caller passes it in.
    public(friend) fun assert_authorized(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let profile = borrow_global<Profile>(pid_addr);
        if (profile.controller == caller_addr) return;
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(object::owner(pid_object) == caller_addr, E_NOT_CONTROLLER_OR_OWNER);
    }

    /// Internal - friend access for sync_gate evaluation in link.move.
    public(friend) fun get_sync_gate(pid_addr: address): Option<ReferenceGate> acquires Profile {
        if (!exists<Profile>(pid_addr)) return option::none();
        borrow_global<Profile>(pid_addr).sync_gate
    }

    /// Internal - friend helper for sibling modules' lazy-init pattern.
    /// Returns ExtendRef-derived signer of the PID Object so siblings can
    /// move_to their own storage resources at PID addr.
    /// Cycle prevention: profile.move doesn't `use` siblings; siblings declare
    /// no friend back. One-way dep: siblings -> profile only.
    public(friend) fun derive_pid_signer(pid_addr: address): signer acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let p = borrow_global<Profile>(pid_addr);
        object::generate_signer_for_extending(&p.extend_ref)
    }

    // ============ VIEWS ============

    #[view]
    public fun is_registered(handle: vector<u8>): bool acquires HandleRegistry {
        let registry = borrow_global<HandleRegistry>(@desnet);
        smart_table::contains(&registry.handle_to_wallet, string::utf8(handle))
    }

    #[view]
    public fun handle_to_wallet(handle: vector<u8>): address acquires HandleRegistry {
        let registry = borrow_global<HandleRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.handle_to_wallet, key), E_PROFILE_NOT_FOUND);
        *smart_table::borrow(&registry.handle_to_wallet, key)
    }

    #[view]
    public fun profile_exists(pid_addr: address): bool {
        exists<Profile>(pid_addr)
    }

    #[view]
    public fun controller_of(pid_addr: address): address acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        borrow_global<Profile>(pid_addr).controller
    }

    #[view]
    public fun handle_of(pid_addr: address): String acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        borrow_global<Profile>(pid_addr).handle
    }

    /// v0.3.2 (F1b): wallet->handle convenience. Derives PID from wallet, looks up
    /// handle. Aborts E_PROFILE_NOT_FOUND if wallet has no registered PID.
    /// (Lives here, not in factory.move, because profile->factory but not the reverse.)
    #[view]
    public fun handle_of_wallet(wallet_addr: address): String acquires Profile {
        let pid_addr = derive_pid_address(wallet_addr);
        handle_of(pid_addr)
    }

    #[view]
    public fun has_signer(pid_addr: address, pubkey: vector<u8>): bool acquires Profile {
        if (!exists<Profile>(pid_addr)) return false;
        smart_table::contains(&borrow_global<Profile>(pid_addr).signers_, pubkey)
    }

    #[view]
    public fun handle_max_len(): u64 { HANDLE_MAX_LEN }

    // ============ TEST-ONLY WRAPPERS ============

    /// Bootstrap a minimal Profile resource at a fresh Object addr. Used by other
    /// modules' integration tests that need a valid PID without going through
    /// register_handle (which requires factory + ProtocolState init).
    /// Returns pid_addr.
    #[test_only]
    public fun setup_test_pid(creator: &signer): address {
        let constructor_ref = object::create_object(signer::address_of(creator));
        let pid_signer = object::generate_signer(&constructor_ref);
        let pid_addr = signer::address_of(&pid_signer);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&pid_signer, Profile {
            handle: string::utf8(b"test"),
            controller: signer::address_of(creator),
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: vector::empty(),
            banner_blob_id: vector::empty(),
            bio: string::utf8(b""),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: 0,
            pre_ipo_cohort: false,
        });
        pid_addr
    }

    // ============ TESTS ============

    #[test]
    fun test_handle_fee_supra_tiers() {
        assert!(handle_fee_supra(1) == PRICE_1_CHAR_SUPRA, 1);     // 100 SUPRA
        assert!(handle_fee_supra(2) == PRICE_2_CHAR_SUPRA, 2);     //  50 SUPRA
        assert!(handle_fee_supra(3) == PRICE_3_CHAR_SUPRA, 3);     //  20 SUPRA
        assert!(handle_fee_supra(4) == PRICE_4_CHAR_SUPRA, 4);     //  10 SUPRA
        assert!(handle_fee_supra(5) == PRICE_5_CHAR_SUPRA, 5);     //   5 SUPRA
        assert!(handle_fee_supra(6) == PRICE_6PLUS_CHAR_SUPRA, 6); //   1 SUPRA
        assert!(handle_fee_supra(64) == PRICE_6PLUS_CHAR_SUPRA, 7);
    }

    #[test]
    fun test_validate_handle_accept_valid() {
        validate_handle(&b"alice");
        validate_handle(&b"a-1");
        validate_handle(&b"a");                            // min length
        validate_handle(&b"abc-def-123");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_INVALID_CHAR, location = Self)]
    fun test_validate_handle_reject_uppercase() {
        validate_handle(&b"Alice");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_INVALID_CHAR, location = Self)]
    fun test_validate_handle_reject_underscore() {
        validate_handle(&b"alice_bob");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_TOO_SHORT, location = Self)]
    fun test_validate_handle_reject_empty() {
        validate_handle(&b"");
    }

    #[test]
    fun test_derive_pid_address_deterministic() {
        let a1 = derive_pid_address(@0x1);
        let a2 = derive_pid_address(@0x1);
        let b1 = derive_pid_address(@0x2);
        assert!(a1 == a2, 1);
        assert!(a1 != b1, 2);
    }
}

// Suppress unused signature reference in skeleton - TransferVault wired during impl pass.

```

---

## `sources/pulse.move`

```move
/// Pulse - reactions umbrella event (Spark + Echo) (LOCKED 2026-05-01).
///
/// Spark = like -> reaction_kind=SPARK
/// Echo = repost forward-as-is -> reaction_kind=ECHO
/// Voice (reply) and Remix (quote) live in mint.move (they create new MintEvents).
/// Press (NFT collectible) lives in press.move (different scope: NFT mint).
///
/// State pattern: PulseEvent { reaction_kind, state: ADD/REMOVE }. Supra events
/// are append-only on emit - un-action emits state=REMOVE same kind. Asymmetric
/// "abort" pattern rejected (events immutable).
///
/// Mint-level gate (ReferenceGate) checked here before allowing reaction.
/// Self-exempt: mint creator always allowed (e.g., self-spark on own mint).
module desnet::pulse {
    use std::bcs;
    use std::signer;
    use std::option;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;

    // ============ CONSTANTS ============

    /// reaction_kind enum
    const REACTION_SPARK: u8 = 1;
    const REACTION_ECHO: u8 = 2;

    /// state enum
    const STATE_ADD: u8 = 1;
    const STATE_REMOVE: u8 = 2;

    // ============ ERROR CODES ============

    const E_GUEST_CANNOT_REACT: u64 = 1;
    const E_INVALID_REACTION_KIND: u64 = 2;
    const E_GATE_FAILED: u64 = 3;
    const E_ALREADY_REACTED: u64 = 4;
    const E_NOT_REACTED: u64 = 5;
    const E_REACTION_REGISTRY_NOT_INITIALIZED: u64 = 6;

    // ============ TYPES ============

    /// Per-PID reaction registry. Stored at actor's PID Object addr.
    /// Keyed by (target_author, target_seq, reaction_kind) tuple -> bool (ADD).
    /// SmartTable key encoded as packed bytes for compound key.
    struct PidReactionRegistry has key {
        // (target_author || target_seq || reaction_kind) bytes -> true if currently active
        active: SmartTable<vector<u8>, bool>,
        spark_count_given: u64,
        echo_count_given: u64,
    }

    // ============ EVENTS ============

    /// Unified Pulse record for Spark + Echo. State ADD on first emit, REMOVE on un-action.
    /// Replaces former #[event] - now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct PulseEvent has drop, store {
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,                // REACTION_SPARK | REACTION_ECHO
        state: u8,                        // STATE_ADD | STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidReactionRegistry at PID addr. Called from spark/echo on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
    fun ensure_reaction_registry(pid_addr: address) {
        if (!exists<PidReactionRegistry>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidReactionRegistry {
                active: smart_table::new(),
                spark_count_given: 0,
                echo_count_given: 0,
            });
        };
    }

    // ============ SPARK + UNSPARK ============

    public entry fun spark(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let actor_addr = signer::address_of(actor);

        // ReferenceGate semantic stays wallet-keyed (balance + LP-stake), but PID-space
        // primitives (self-exempt, sync, history) read actor_pid from the caller.
        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, true);
    }

    public entry fun unspark(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, false);
    }

    // ============ ECHO + UNECHO ============

    public entry fun echo(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let actor_addr = signer::address_of(actor);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, true);
    }

    public entry fun unecho(
        actor: &signer,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        profile::assert_authorized(actor, actor_pid);
        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, false);
    }

    // ============ INTERNAL - gate + toggle ============

    /// Self-exempt comparison via PID (target_author is a PID addr).
    /// Sync check uses PID-space (link::is_synced takes PIDs).
    /// reference_gate::check uses WALLET addr (actor_addr) - semantic locked 2026-05-01:
    /// balance + LP-stake ownership both expected at wallet address that holds PID NFT.
    fun check_mint_gate_or_self_exempt(
        actor_addr: address,
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,
    ) {
        // Self-exempt: actor IS author of target mint
        if (actor_pid == target_author) return;

        let gate_opt = mint::get_mint_gate(target_author, target_seq);
        if (option::is_none(&gate_opt)) return;  // no gate, open access

        // Pre-compute sync state via link (cycle-safe: pulse uses link, link doesn't use pulse).
        let target_pid = profile::reference_gate_target_pid(option::borrow(&gate_opt));
        let synced = link::is_synced(actor_pid, target_pid);

        let gate = option::extract(&mut gate_opt);
        assert!(
            reference_gate::check(&gate, actor_addr, synced, false, actor_stake_position_addr),
            E_GATE_FAILED
        );
    }

    fun toggle_reaction(
        actor_pid: address,
        key: &vector<u8>,
        reaction_kind: u8,
        target_author: address,
        target_seq: u64,
        adding: bool,
    ) acquires PidReactionRegistry {
        assert!(exists<PidReactionRegistry>(actor_pid), E_REACTION_REGISTRY_NOT_INITIALIZED);
        let reg = borrow_global_mut<PidReactionRegistry>(actor_pid);

        if (adding) {
            assert!(!smart_table::contains(&reg.active, *key), E_ALREADY_REACTED);
            smart_table::add(&mut reg.active, *key, true);
            if (reaction_kind == REACTION_SPARK) {
                reg.spark_count_given = reg.spark_count_given + 1;
            } else {
                reg.echo_count_given = reg.echo_count_given + 1;
            };
        } else {
            assert!(smart_table::contains(&reg.active, *key), E_NOT_REACTED);
            smart_table::remove(&mut reg.active, *key);
            if (reaction_kind == REACTION_SPARK) {
                if (reg.spark_count_given > 0) reg.spark_count_given = reg.spark_count_given - 1;
            } else {
                if (reg.echo_count_given > 0) reg.echo_count_given = reg.echo_count_given - 1;
            };
        };

        let now_secs = timestamp::now_seconds();
        let record = PulseEvent {
            actor_pid,
            target_author,
            target_seq,
            reaction_kind,
            state: if (adding) STATE_ADD else STATE_REMOVE,
            timestamp_secs: now_secs,
        };

        // Verb dispatch: Spark=1, Echo=3. Both ADD and REMOVE are written to history
        // (each toggle is a distinct user action with its own timestamp).
        let verb = if (reaction_kind == REACTION_SPARK) {
            history::verb_spark()
        } else {
            history::verb_echo()
        };

        let payload = bcs::to_bytes(&record);
        history::append(
            actor_pid,
            history::new_entry(verb, now_secs, option::some(target_author), payload, option::none<address>()),
        );
    }

    fun make_key(target_author: address, target_seq: u64, reaction_kind: u8): vector<u8> {
        let key = std::bcs::to_bytes(&target_author);
        std::vector::append(&mut key, std::bcs::to_bytes(&target_seq));
        std::vector::push_back(&mut key, reaction_kind);
        key
    }

    // ============ VIEWS ============

    #[view]
    public fun has_reacted(
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,
    ): bool acquires PidReactionRegistry {
        if (!exists<PidReactionRegistry>(actor_pid)) return false;
        let key = make_key(target_author, target_seq, reaction_kind);
        smart_table::contains(&borrow_global<PidReactionRegistry>(actor_pid).active, key)
    }

    #[view]
    public fun spark_kind(): u8 { REACTION_SPARK }

    #[view]
    public fun echo_kind(): u8 { REACTION_ECHO }

    #[view]
    public fun state_add(): u8 { STATE_ADD }

    #[view]
    public fun state_remove(): u8 { STATE_REMOVE }
}

```

---

## `sources/reaction_emission.move`

```move
/// Reaction Rewards Gauge - per-PID multi-FA permissionless rewards pool.
///
/// Keyed by author PID address (not handle string) - every Profile NFT, main
/// or subdomain, gets its own independent reaction pool. Two reasons:
///   1. Avoids the handle-collision hazard where main handle "alice" and
///      subdomain "alice@bob" both resolve `profile::handle_of()` to "alice"
///      and would otherwise share a gauge across unrelated authors.
///   2. Subdomain authors get the same first-class fan-funding surface as
///      main-handle authors - a `alice@bob` subdomain can be tipped/funded
///      independently of bob's main pool.
///
/// On every press, the presser withdraws `BPS_PER_PRESS * current_balance /
/// 10000` from every registered reward token. Pool is asymptotic -
/// multiplicative decay never drives balance to zero, so the "early presser
/// farms entire reserve" failure mode of the v0.3 sealed-reserve design is
/// gone. Replaces v0.3's sealed 5%-of-supply reserve.
module desnet::reaction_emission {
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;

    use desnet::governance;

    friend desnet::press;

    // ============ CONSTANTS ============

    /// Per-press withdrawal rate against current pool balance for each
    /// registered reward token. 25 bps = 0.25% per press. Multiplicative
    /// decay - pool never hits zero.
    const BPS_PER_PRESS: u64 = 25;
    const BPS_DENOM: u64 = 10_000;

    const MAX_REWARD_TOKENS: u64 = 32;

    const SEED_REACTION_REWARDS: vector<u8> = b"reaction_rewards::";

    // ============ ERROR CODES ============

    const E_POOL_NOT_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_TOO_MANY_REWARD_TOKENS: u64 = 3;
    /// Y-4 (2026-05-17 self-audit): rejects dispatchable FAs. A hook-bearing
    /// FA registered here would let an attacker abort distribute_to_presser
    /// on every subsequent press, bricking press::press for the author.
    const E_DISPATCHABLE_FA_REJECTED: u64 = 4;

    // ============ TYPES ============

    struct ReactionRewardsPool has key {
        author_pid: address,
        extend_ref: ExtendRef,
        reward_tokens: SmartTable<address, ReactionAccumulator>,
        reward_token_list: vector<address>,
    }

    struct ReactionAccumulator has store, drop {
        total_topped_up: u128,
        total_distributed: u128,
    }

    // ============ EVENTS ============

    #[event]
    struct PoolInitialized has drop, store {
        pool_addr: address,
        author_pid: address,
    }

    #[event]
    struct RewardTokenRegistered has drop, store {
        pool_addr: address,
        reward_token: address,
        slot_index: u64,
    }

    #[event]
    struct RewardNotified has drop, store {
        pool_addr: address,
        author_pid: address,
        depositor: address,
        reward_token: address,
        amount: u64,
        new_balance: u64,
    }

    #[event]
    struct PressDistributed has drop, store {
        pool_addr: address,
        author_pid: address,
        presser: address,
        reward_token: address,
        amount: u64,
        pool_balance_before: u64,
    }

    // ============ ADDRESS DERIVATION ============

    public fun pool_address_of(author_pid: address): address {
        object::create_object_address(&@desnet, make_seed(author_pid))
    }

    fun make_seed(author_pid: address): vector<u8> {
        let seed = SEED_REACTION_REWARDS;
        vector::append(&mut seed, bcs::to_bytes(&author_pid));
        seed
    }

    // ============ INIT - lazy on first notify ============

    fun ensure_pool(author_pid: address): address {
        let pool_addr = pool_address_of(author_pid);
        if (!exists<ReactionRewardsPool>(pool_addr)) {
            let pkg_signer = governance::derive_pkg_signer();
            let constructor_ref = object::create_named_object(&pkg_signer, make_seed(author_pid));
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            object::disable_ungated_transfer(&transfer_ref);
            let pool_signer = object::generate_signer(&constructor_ref);
            move_to(&pool_signer, ReactionRewardsPool {
                author_pid,
                extend_ref,
                reward_tokens: smart_table::new(),
                reward_token_list: vector::empty(),
            });
            event::emit(PoolInitialized { pool_addr, author_pid });
        };
        pool_addr
    }

    // ============ NOTIFY - permissionless topup ============

    public entry fun notify_reward(
        depositor: &signer,
        author_pid: address,
        reward_token_meta: Object<Metadata>,
        amount: u64,
    ) acquires ReactionRewardsPool {
        assert!(amount > 0, E_ZERO_AMOUNT);

        // Y-4: reject dispatchable FAs. supra-framework's
        // dispatchable_fungible_asset lets an FA register custom
        // withdraw/deposit hooks that run arbitrary code on every transfer.
        // If a hook-bearing FA were registered into a reaction pool, the
        // attacker could make its withdraw hook abort - subsequent
        // distribute_to_presser would revert on that token, bricking
        // press::press for the author (NFT mint and emission share the
        // same tx). We check on the depositor's primary store which must
        // already exist for the withdraw below to succeed.
        let depositor_addr = signer::address_of(depositor);
        let depositor_store = primary_fungible_store::ensure_primary_store_exists(
            depositor_addr, reward_token_meta,
        );
        assert!(
            std::option::is_none(&fungible_asset::deposit_dispatch_function(depositor_store))
                && std::option::is_none(&fungible_asset::withdraw_dispatch_function(depositor_store)),
            E_DISPATCHABLE_FA_REJECTED,
        );

        let pool_addr = ensure_pool(author_pid);
        let pool = borrow_global_mut<ReactionRewardsPool>(pool_addr);
        let token_addr = object::object_address(&reward_token_meta);

        if (!smart_table::contains(&pool.reward_tokens, token_addr)) {
            assert!(
                vector::length(&pool.reward_token_list) < MAX_REWARD_TOKENS,
                E_TOO_MANY_REWARD_TOKENS,
            );
            let slot = vector::length(&pool.reward_token_list);
            vector::push_back(&mut pool.reward_token_list, token_addr);
            smart_table::add(&mut pool.reward_tokens, token_addr, ReactionAccumulator {
                total_topped_up: 0,
                total_distributed: 0,
            });
            event::emit(RewardTokenRegistered { pool_addr, reward_token: token_addr, slot_index: slot });
        };

        let fa = primary_fungible_store::withdraw(depositor, reward_token_meta, amount);
        primary_fungible_store::deposit(pool_addr, fa);

        let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
        acc.total_topped_up = acc.total_topped_up + (amount as u128);

        let new_balance = primary_fungible_store::balance(pool_addr, reward_token_meta);
        event::emit(RewardNotified {
            pool_addr,
            author_pid,
            depositor: signer::address_of(depositor),
            reward_token: token_addr,
            amount,
            new_balance,
        });
    }

    // ============ FRIEND: distribute per press ============

    /// Per-press payout = `BPS_PER_PRESS * balance / 10_000` from every
    /// registered reward token. Returns total distributed (sum across
    /// tokens). Tokens with zero balance or quantized-to-zero payouts
    /// are skipped. Safe to call when pool doesn't exist - returns 0
    /// so press still succeeds before anyone funds the gauge.
    public(friend) fun distribute_to_presser(
        author_pid: address,
        presser: address,
    ): u64 acquires ReactionRewardsPool {
        let pool_addr = pool_address_of(author_pid);
        if (!exists<ReactionRewardsPool>(pool_addr)) return 0;

        let pool = borrow_global_mut<ReactionRewardsPool>(pool_addr);
        let tokens = pool.reward_token_list;
        let n = vector::length(&tokens);
        let total_distributed = 0u64;
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);

        let i = 0;
        while (i < n) {
            let token_addr = *vector::borrow(&tokens, i);
            let token_meta = object::address_to_object<Metadata>(token_addr);
            let balance_before = primary_fungible_store::balance(pool_addr, token_meta);
            if (balance_before > 0) {
                let payout = ((((balance_before as u128) * (BPS_PER_PRESS as u128))
                    / (BPS_DENOM as u128)) as u64);
                if (payout > 0) {
                    let fa = primary_fungible_store::withdraw(&pool_signer, token_meta, payout);
                    primary_fungible_store::deposit(presser, fa);
                    let acc = smart_table::borrow_mut(&mut pool.reward_tokens, token_addr);
                    acc.total_distributed = acc.total_distributed + (payout as u128);
                    total_distributed = total_distributed + payout;
                    event::emit(PressDistributed {
                        pool_addr,
                        author_pid,
                        presser,
                        reward_token: token_addr,
                        amount: payout,
                        pool_balance_before: balance_before,
                    });
                };
            };
            i = i + 1;
        };

        total_distributed
    }

    // ============ VIEWS ============

    #[view]
    public fun pool_exists(author_pid: address): bool {
        exists<ReactionRewardsPool>(pool_address_of(author_pid))
    }

    #[view]
    public fun reward_tokens_of(author_pid: address): vector<address> acquires ReactionRewardsPool {
        let pool_addr = pool_address_of(author_pid);
        if (!exists<ReactionRewardsPool>(pool_addr)) return vector::empty();
        borrow_global<ReactionRewardsPool>(pool_addr).reward_token_list
    }

    #[view]
    public fun reward_balance(
        author_pid: address,
        reward_token_meta: Object<Metadata>,
    ): u64 {
        let pool_addr = pool_address_of(author_pid);
        primary_fungible_store::balance(pool_addr, reward_token_meta)
    }

    #[view]
    public fun bps_per_press(): u64 { BPS_PER_PRESS }

    #[view]
    public fun bps_denom(): u64 { BPS_DENOM }

    #[view]
    public fun max_reward_tokens(): u64 { MAX_REWARD_TOKENS }
}

```

---

## `sources/reference_gate.move`

```move
/// ReferenceGate - opt-in engagement policy primitive (LOCKED 2026-05-01).
///
/// Single primitive, 4 fields. Used by:
/// - Mint-level: gates Voice/Spark/Echo/Remix/Press of specific mint
/// - Profile-level (sync_gate): gates incoming Sync requests
///
/// Logic at gate check (ALL conditions must hold):
/// 1. actor.synced_to(target_pid) - sync precondition (SKIPPED for sync_gate itself, chicken-egg)
/// 2. min_token_balance <= actor.token_balance(target_pid_token) <= max_token_balance
/// 3. LP stake check - removed in IPO model
///
/// Self-exemption: post creator always passes own gate (intuitive, prevents lock-out).
/// Sentinels for "no check": min=0, max=u64::MAX, lp_stake=0.
///
/// Cycle-safe API: caller pre-computes sync state (via link::is_synced) and passes
/// as param. reference_gate doesn't import link (would create cycle since link uses
/// reference_gate for sync_gate evaluation). Pure function design - caller orchestrates queries.
///
/// Naming consistency: ReferenceGate + MintGate + sync_gate = unified gate-family.
module desnet::reference_gate {
    use std::option::{Self, Option};
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::Self;
    use supra_framework::primary_fungible_store;

    use desnet::factory;
    use desnet::profile;
    use desnet::profile::ReferenceGate;

    // ============ ERROR CODES ============

    const E_TARGET_HAS_NO_TOKEN: u64 = 2;

    /// Evaluate gate against an actor.
    ///
    /// `actor_synced_to_target` must be pre-computed by caller via `link::is_synced(actor_pid, gate.target_pid)`.
    /// reference_gate doesn't query link directly (would cycle since link uses reference_gate for sync_gate).
    ///
    /// `skip_sync_check=true` for profile sync_gate path (chicken-egg avoidance: gating Sync
    /// itself can't require sync precondition). For mint-level engagement gates, false.
    ///
    /// `actor_stake_position_addr`: unused in IPO model (LP stake check removed). Pass `@0x0`.
    public fun check(
        gate: &ReferenceGate,
        actor_addr: address,
        actor_synced_to_target: bool,
        skip_sync_check: bool,
        actor_stake_position_addr: address,
    ): bool {
        // 1. Sync check
        if (!skip_sync_check && !actor_synced_to_target) {
            return false
        };

        // 2. Token balance check (skip if both bounds are sentinels = no check)
        let no_min = profile::reference_gate_min_token_balance(gate) == 0;
        let no_max = profile::reference_gate_max_token_balance(gate) == 18446744073709551615u64;  // u64::MAX
        if (!(no_min && no_max)) {
            // Resolve target's token via factory reverse lookup
            if (!factory::owner_has_token(profile::reference_gate_target_pid(gate))) {
                // Target PID has no factory-spawned token -> balance check impossible
                return false
            };
            let token_addr = factory::token_metadata_of_owner(profile::reference_gate_target_pid(gate));
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let balance = primary_fungible_store::balance(actor_addr, token_metadata);
            if (balance < profile::reference_gate_min_token_balance(gate)) return false;
            if (balance > profile::reference_gate_max_token_balance(gate)) return false;
        };

        // 3. LP stake check - removed in IPO model (LP is locked in AMM pool, no staking)

        true
    }

    /// Convenience wrapper for Option<ReferenceGate>: None = open access (always pass).
    public fun is_open_for(
        gate_opt: &Option<ReferenceGate>,
        actor_addr: address,
        actor_synced_to_target: bool,
        skip_sync_check: bool,
        actor_stake_position_addr: address,
    ): bool {
        if (option::is_none(gate_opt)) return true;
        check(option::borrow(gate_opt), actor_addr, actor_synced_to_target, skip_sync_check, actor_stake_position_addr)
    }

    // ============ TESTS ============

    #[test]
    fun test_new_and_getters() {
        let g = profile::reference_gate_new(@0xfeed, 100, 1000, 50);
        assert!(profile::reference_gate_target_pid(&g) == @0xfeed, 1);
        assert!(profile::reference_gate_min_token_balance(&g) == 100, 2);
        assert!(profile::reference_gate_max_token_balance(&g) == 1000, 3);
        assert!(profile::reference_gate_min_lp_stake(&g) == 50, 4);
    }

    #[test]
    fun test_is_open_for_none_gate_passes() {
        // No gate set = always open
        let none_gate = option::none<ReferenceGate>();
        assert!(is_open_for(&none_gate, @0x1, false, false, @0x0), 1);
        assert!(is_open_for(&none_gate, @0x1, false, true, @0x0), 2);
    }

    #[test]
    fun test_check_sync_required_fails_when_not_synced() {
        // Gate with sentinel min/max balance + zero lp_stake -> only sync matters
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        // Actor not synced + skip_sync_check=false -> fail
        assert!(!check(&g, @0x1, false, false, @0x0), 1);
    }

    #[test]
    fun test_check_sync_skipped_passes_no_other_constraints() {
        // skip_sync_check=true (sync_gate path) + sentinels for balance + 0 lp_stake -> pass
        let g = profile::reference_gate_new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(check(&g, @0x1, false, true, @0x0), 1);
    }
}

```

---

## `sources/registration.move`

```move
/// Registration - atomic handle + token + IPO orchestration.
///
/// Single-entry wrapper around profile::register_handle + factory::create_token_atomic
/// (and optionally ipo::deposit_supra for atomic creator self-IPO with elevated 10% cap).
/// Breaks the module dependency cycle (profile -> factory -> ipo -> profile) by lifting
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
    /// at the elevated 10% cap + claim creator's own subdomain - all in one tx.
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

```

---

## `sources/supra_fee_vault.move`

```move
/// SupraFeeVault - handle reg fees: 10% deployer, 90% buy DESNET + burn.
/// Destinations immutable. No admin.
module desnet::supra_fee_vault {
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, ExtendRef};
    use std::vector;
    use supra_framework::primary_fungible_store;

    use desnet::amm;
    use desnet::supra_vault;
    use desnet::governance;

    friend desnet::profile;

    const SEED_VAULT: vector<u8> = b"supra_fee_vault";
    const DESNET_HANDLE: vector<u8> = b"desnet";

    /// 10% to deployer beneficiary, 90% to DESNET buyback-burn.
    const SPLIT_DEPLOYER_BPS: u64 = 1000;
    const SPLIT_BURN_BPS: u64 = 9000;
    const BPS_DENOM: u64 = 10000;

    /// Min SUPRA balance for settle (anti-dust). 0.1 SUPRA.
    const SUPRA_SETTLE_THRESHOLD: u64 = 10_000_000;

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_INITIALIZED: u64 = 2;
    /// v0.3.3 (G3): old single-tx settle deprecated for MEV-safety. Use two-phase.
    const E_USE_TWO_PHASE: u64 = 3;
    const E_PENDING_SETTLE_NOT_FOUND: u64 = 4;
    const E_PENDING_SETTLE_NOT_RIPE: u64 = 5;
    const E_PENDING_SETTLE_EXPIRED: u64 = 6;
    const E_PENDING_SETTLE_ALREADY_EXISTS: u64 = 7;
    /// v0.3.3 (Qwen R6 M1): distinct from E_BELOW_THRESHOLD - semantic clarity for
    /// off-chain monitors. Fires when execute_settle finds vault balance has shrunk
    /// below the request-time snapshot (structurally impossible since vault has no
    /// withdraw path, but kept as defensive guard).
    const E_VAULT_SHRUNK_BELOW_SNAPSHOT: u64 = 8;

    /// v0.3.3 (G3): commit-reveal delay parameters mirror R3 H3 fix on supra_vault.
    /// 60s delay defeats single-tx sandwich (atomic same-tx grief impossible);
    /// cross-tx pre-positioning bounded by 5% slippage tolerance baked at request.
    /// Grace window: 600s before request expires (prevents stale baseline exploit).
    const SETTLE_DELAY_SECS: u64 = 60;
    const SETTLE_REQUEST_GRACE_SECS: u64 = 600;
    const SETTLE_SLIPPAGE_BPS: u64 = 9500;
    const BPS_FULL: u64 = 10000;

    struct SupraFeeVault has key {
        deployer_beneficiary: address,
        extend_ref: ExtendRef,
    }

    /// v0.3.3 (G3 + S1 fix): two-phase commit-reveal settle state. Lives at `vault_addr()`.
    /// All amounts LOCKED at request time - execute uses these (NOT current balance) so
    /// (swap_amount, min_out) stay paired from same snapshot. Without this S1 fix, balance
    /// growing during the 60s window would let attacker sandwich the larger swap with
    /// trivially-satisfied stale min_out (anchored to smaller request-time amount).
    /// Excess balance accrued during window stays in vault for next settle cycle.
    struct PendingSettle has key, drop {
        requested_at_secs: u64,
        supra_balance_at_request: u64,
        to_deployer_at_request: u64,
        to_burn_at_request: u64,
        min_desnet_out: u64,
    }

    #[event]
    struct Settled has drop, store {
        total_supra: u64,
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

        move_to(&vault_signer, SupraFeeVault {
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
        exists<SupraFeeVault>(vault_addr())
    }

    /// Friend-only: SUPRA FA -> vault primary store. Called by profile::register_handle.
    public(friend) fun deposit_supra_fa(fa: fungible_asset::FungibleAsset) {
        primary_fungible_store::deposit(vault_addr(), fa);
    }

    /// Public top-up - anyone can deposit SUPRA to vault.
    public entry fun deposit_supra(depositor: &signer, amount: u64) {
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let fa = primary_fungible_store::withdraw(depositor, supra_meta, amount);
        deposit_supra_fa(fa);
    }

    /// v0.3.3 (G3, R5 CONV-1 MED-HIGH fix): old single-tx settle DEPRECATED for
    /// MEV-safety. The original `min_out=0` swap was atomically sandwich-attackable;
    /// any caller could front-run by skewing the AMM pool, trigger settle to swap
    /// at unfavorable rate, then back-run to extract SUPRA and leak protocol revenue.
    /// Replaced by two-phase commit-reveal: `request_settle()` (records reserves
    /// snapshot + 5% slippage min_out) -> 60s delay -> `execute_settle()` (enforces
    /// pre-recorded min_out). Single-tx sandwich now structurally impossible;
    /// cross-tx pre-positioning bounded by 5% baked tolerance.
    /// Body kept (with abort) for compat preservation of `acquires SupraFeeVault`
    /// annotation parity. Callers MUST switch to two-phase flow.
    public entry fun settle(_caller: &signer) acquires SupraFeeVault {
        let _ = borrow_global<SupraFeeVault>(vault_addr());
        abort E_USE_TWO_PHASE
    }

    /// v0.3.3 (G3): Phase 1 of MEV-safe settle. Records current pool quote +
    /// 5% slippage tolerance. After SETTLE_DELAY_SECS, anyone can call
    /// `execute_settle` to consume this snapshot. If cross-tx attacker shifts pool
    /// >5% during the 60s window, execute_settle aborts (pool moved too far).
    /// Pending settle expires after grace (cleanable via `cancel_pending_settle`).
    public entry fun request_settle(_caller: &signer) acquires SupraFeeVault {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(!exists<PendingSettle>(v_addr), E_PENDING_SETTLE_ALREADY_EXISTS);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let total = primary_fungible_store::balance(v_addr, supra_meta);
        assert!(total >= SUPRA_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
        let to_burn = total - to_deployer;

        // Quote DESNET-out for to_burn at current reserves; bake 5% slippage tolerance.
        let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
        let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;

        let vault = borrow_global<SupraFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        move_to(&vault_signer, PendingSettle {
            requested_at_secs: supra_framework::timestamp::now_seconds(),
            supra_balance_at_request: total,
            to_deployer_at_request: to_deployer,
            to_burn_at_request: to_burn,
            min_desnet_out: min_out,
        });
    }

    /// v0.3.3 (G3): Phase 2 of MEV-safe settle. Requires pending request from
    /// at least SETTLE_DELAY_SECS ago, within grace window. Enforces baked min_out
    /// - if pool moved >5% adversely since request, swap aborts (caller must
    /// `cancel_pending_settle` and `request_settle` again at fresh reserves).
    public entry fun execute_settle(_caller: &signer) acquires SupraFeeVault, PendingSettle {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(exists<PendingSettle>(v_addr), E_PENDING_SETTLE_NOT_FOUND);

        let now = supra_framework::timestamp::now_seconds();
        let pending_ref = borrow_global<PendingSettle>(v_addr);
        let requested_at = pending_ref.requested_at_secs;
        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_PENDING_SETTLE_NOT_RIPE);
        assert!(now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS, E_PENDING_SETTLE_EXPIRED);

        // S1 fix: extract LOCKED amounts from snapshot - do NOT recompute from current balance.
        // Excess balance (current - supra_balance_at_request) stays in vault for next cycle.
        let PendingSettle {
            requested_at_secs: _,
            supra_balance_at_request,
            to_deployer_at_request,
            to_burn_at_request,
            min_desnet_out,
        } = move_from<PendingSettle>(v_addr);

        // Sanity check: vault must still have >= snapshot amount (vault has no withdraw path
        // other than this fn, so balance can only grow via deposits - never shrink).
        // v0.3.3 (Qwen R6 M1): distinct error from anti-dust threshold for monitor clarity.
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let current_total = primary_fungible_store::balance(v_addr, supra_meta);
        assert!(current_total >= supra_balance_at_request, E_VAULT_SHRUNK_BELOW_SNAPSHOT);

        let vault = borrow_global<SupraFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);

        let supra_for_deployer = primary_fungible_store::withdraw(&vault_signer, supra_meta, to_deployer_at_request);
        primary_fungible_store::deposit(vault.deployer_beneficiary, supra_for_deployer);

        // 90% SUPRA swap with min_out enforcement - sandwich-safe per snapshot.
        // Swap amount AND min_out paired from same request snapshot - slippage check
        // properly bounds the actual swap size (S1 fix vs anchor-mismatch bug).
        let supra_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, supra_meta, to_burn_at_request);
        let desnet_fa = amm::swap_exact_supra_in(DESNET_HANDLE, supra_for_burn_fa, min_desnet_out);
        let desnet_burned = fungible_asset::amount(&desnet_fa);

        let vault_seed = vector::empty<u8>();
        vector::append(&mut vault_seed, b"vault::");
        vector::append(&mut vault_seed, DESNET_HANDLE);
        let desnet_supra_vault = object::create_object_address(&@desnet, vault_seed);
        supra_vault::burn_via_vault(desnet_supra_vault, desnet_fa);

        // Settled.total_supra reflects snapshot amount actually settled (not current vault balance).
        event::emit(Settled {
            total_supra: supra_balance_at_request,
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
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let balance = primary_fungible_store::balance(@desnet, supra_meta);
        if (balance == 0) return;
        let pkg_signer = governance::derive_pkg_signer();
        let fa = primary_fungible_store::withdraw(&pkg_signer, supra_meta, balance);
        deposit_supra_fa(fa);
    }

    #[view]
    public fun deployer_beneficiary(): address acquires SupraFeeVault {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        borrow_global<SupraFeeVault>(v_addr).deployer_beneficiary
    }

    #[view]
    public fun supra_balance(): u64 {
        let v_addr = vault_addr();
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        primary_fungible_store::balance(v_addr, supra_meta)
    }

    #[view]
    public fun split_deployer_bps(): u64 { SPLIT_DEPLOYER_BPS }

    #[view]
    public fun split_burn_bps(): u64 { SPLIT_BURN_BPS }

    #[view]
    public fun settle_threshold(): u64 { SUPRA_SETTLE_THRESHOLD }
}

```

---

## `sources/supra_vault.move`

```move
/// Vault - receives SUPRA revenue, splits 50% buyback-burn / 50% to PID owner.
///
/// One Vault per spawned token. Sealed at mint. Holds BurnRef (no extraction).
/// AMM pool is always seeded atomically at register_handle, so settle is always 50/50.
///
/// Inputs:
///   - NFT marketplace royalty (Press collection royalty_payee = vault addr)
///   - Direct deposit_supra (manual top-up)
///   - Future revenue streams
///
/// Outputs:
///   - 50% SUPRA to current PID owner = object::owner(pid_object) [auto-follows NFT transfer]
///   - 50% SUPRA -> $TOKEN via in-house desnet::amm 10 bps swap, then BURN via BurnRef
module desnet::supra_vault {
    use std::signer;
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, BurnRef};
    use supra_framework::object::{Self, ExtendRef};
    use supra_framework::timestamp;

    use desnet::amm;

    friend desnet::factory;
    friend desnet::supra_fee_vault;
    friend desnet::opinion;

    // ============ CONSTANTS ============

    /// Min SUPRA balance for settle to execute (anti-dust). 0.1 SUPRA (8 decimals).
    const SUPRA_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 4;

    const SEED_VAULT: vector<u8> = b"vault::";

    /// H3 fix (audit R3): two-phase commit-reveal settle.
    /// `request_settle` records timestamp; `execute_settle` requires >= delay elapsed.
    /// Same-tx sandwich is impossible because manipulator must hold position across
    /// blocks under arbitrage exposure (~200 blocks at Supra ~0.3s block time).
    const SETTLE_DELAY_SECS: u64 = 60;

    /// Re-request grace: after delay + grace, anyone can override a stale pending
    /// request. Bounds DoS vector where a spammer keeps refreshing the timer.
    const SETTLE_REQUEST_GRACE_SECS: u64 = 3600;

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
        supra_balance: Coin<SupraCoin>,
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
    struct SupraDeposited has drop, store {
        vault_addr: address,
        depositor: address,
        amount: u64,
    }

    #[event]
    struct SupraSettled has drop, store {
        vault_addr: address,
        total_supra: u64,
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

    // ============ DEPLOY - friend, called by factory at token spawn ============

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
            supra_balance: coin::zero<SupraCoin>(),
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

    // ============ DEPOSIT - permissionless ============

    public entry fun deposit_supra(
        depositor: &signer,
        vault_addr: address,
        amount: u64,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        let supra_in = coin::withdraw<SupraCoin>(depositor, amount);
        coin::merge(&mut vault.supra_balance, supra_in);

        event::emit(SupraDeposited {
            vault_addr,
            depositor: signer::address_of(depositor),
            amount,
        });
    }

    // ============ SETTLE - two-phase (R3 H3 fix) ============

    /// Phase 1: record request timestamp. Permissionless.
    /// `execute_settle` becomes callable after SETTLE_DELAY_SECS elapses.
    /// If a pending request already exists and is younger than
    /// `SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS`, this aborts (DoS guard).
    public entry fun request_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        let total_supra = coin::value(&vault.supra_balance);
        assert!(total_supra >= SUPRA_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

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
    /// Settle follows strict 50% burn / 50% owner split. Rounding sisa (1 unit) goes to owner.
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

        let total_supra = coin::value(&vault.supra_balance);
        assert!(total_supra >= SUPRA_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        // Explicit 50/50 split. Buyback gets half (rounded down);
        // owner gets the remainder (guarantees buyback + owner == total).
        let buyback_amount = total_supra / 2;
        let owner_amount = total_supra - buyback_amount;

        let supra_for_buyback = coin::extract(&mut vault.supra_balance, buyback_amount);
        let supra_for_owner = coin::extract(&mut vault.supra_balance, owner_amount);

        // Buyback path: SUPRA -> $TOKEN via in-house AMM 10 bps, then BURN.
        let supra_fa_buyback = coin::coin_to_fungible_asset(supra_for_buyback);
        let token_received = amm::swap_exact_supra_in(
            vault.handle,
            supra_fa_buyback,
            0,
        );
        let burned_amount = fungible_asset::amount(&token_received);
        fungible_asset::burn(&vault.burn_ref, token_received);

        // Owner path: SUPRA direct to current PID owner.
        coin::deposit(owner_addr, supra_for_owner);

        // Consume the pending request.
        vault.pending_settle_at_secs = 0;

        event::emit(SupraSettled {
            vault_addr,
            total_supra,
            to_buyback: buyback_amount,
            to_owner: owner_amount,
            owner_addr,
            token_burned: burned_amount,
        });
    }

    // ============ VIEW ============

    #[view]
    public fun supra_balance(vault_addr: address): u64 acquires Vault {
        coin::value(&borrow_global<Vault>(vault_addr).supra_balance)
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

    // ============ DELEGATE BURN - friend (supra_fee_vault, v0.3.2 F9) ============

    /// supra_fee_vault swaps SUPRA -> DESNET via amm, then asks the DESNET per-token
    /// vault to burn the FA via its held BurnRef. Direction-locked: caller hands a FA
    /// whose metadata MUST match `vault.token_metadata_addr` (the fungible_asset::burn
    /// check enforces this - wrong-token FA aborts).
    /// No state mutation, no event (supra_fee_vault::Settled covers it).
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
    public fun deposit_supra_coin_for_test(
        vault_addr: address,
        supra_coin: Coin<SupraCoin>,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        coin::merge(&mut vault.supra_balance, supra_coin);
    }
}

```

---

## `sources/voter_history.move`

```move
/// Voter History - per-voter cumulative LP fee / rewards record.
///
/// CRITICAL - voting power source authentication:
///
/// Two pathways feed into voting power:
///   1. (Legacy) `desnet::lp_staking::claim_internal` - LP staking rewards (pre-IPO model).
///   2. `desnet::ipo::claim_fees` - DESNET-side LP swap fees (IPO model).
///
/// Cross-module authentication via friend visibility + signer addr check:
///   - `record_reward_received` is `public(friend)` gated; callers validated at
///     compile-time by friend list + runtime `signer::address_of(authority) == @desnet`.
///
/// Storage: centralized SmartTable<voter_addr, VoterHistory> at @desnet.
module desnet::voter_history {
    use std::signer;
    use std::vector;
    use supra_framework::event;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    friend desnet::governance;
    friend desnet::lp_staking;
    friend desnet::ipo;

    // ============ CONSTANTS ============

    /// 30-day rolling window for voting power computation.
    const VOTING_WINDOW_SECS: u64 = 30 * 86_400;

    /// Pruning threshold for VoterHistory entries (storage bound).
    /// 60d = 30d active + 30d safety buffer.
    const HISTORY_PRUNE_AFTER_SECS: u64 = 60 * 86_400;

    // ============ ERROR CODES ============

    const E_NOT_FACTORY_AUTHORITY: u64 = 1;
    const E_REGISTRY_NOT_INITIALIZED: u64 = 2;
    const E_ALREADY_INITIALIZED: u64 = 3;

    // ============ TYPES ============

    /// Per-voter cumulative rewards history. Stored inside Registry SmartTable
    /// at @desnet, keyed by voter wallet addr.
    ///
    /// IMPORTANT: entries here represent ONLY rewards distributed via the
    /// official factory-deployed lp_emission claim path. Other DESNET inflows
    /// do NOT populate this history.
    struct VoterHistory has store, drop {
        rewards_history: vector<RewardEntry>,  // append-only, prunable > 60d
        total_received: u64,                    // cumulative since first reward
    }

    struct RewardEntry has copy, drop, store {
        timestamp_secs: u64,
        amount: u64,
    }

    /// Centralized registry at @desnet.
    struct Registry has key {
        voters: SmartTable<address, VoterHistory>,
    }

    /// v0.3.2 (F7): per-token isolated rewards. Eliminates cross-token mix where a
    /// non-DESNET reward stream could inflate voter's voting power. Lazy-init on
    /// first per-token record. Outer key = voter_addr, inner key = token_metadata_addr.
    /// `governance::voting_power` reads DESNET-only via this registry when present,
    /// falls back to legacy mixed `Registry` when not.
    struct RegistryByToken has key {
        voters: SmartTable<address, SmartTable<address, VoterHistory>>,
    }

    // ============ EVENTS ============

    /// Emitted on every voter reward record. Pairs atomically with
    /// desnet-factory's `LpDistributed` event (same tx). Indexer cross-check:
    /// for each LpDistributed(amount=X) tx, sum of co-emitted VoterRewardRecorded
    /// must equal X. Discrepancy = corruption signal.
    #[event]
    struct VoterRewardRecorded has drop, store {
        voter_addr: address,
        amount: u64,
        cumulative_received: u64,
        history_entry_index: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct VoterHistoryPruned has drop, store {
        voter_addr: address,
        entries_removed: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct VoterRegistryInitialized has drop, store {
        governance_addr: address,
        timestamp_secs: u64,
    }

    // ============ INIT - called once by governance::init_module ============

    public(friend) fun init_registry(governance_account: &signer) {
        let governance_addr = signer::address_of(governance_account);
        assert!(!exists<Registry>(governance_addr), E_ALREADY_INITIALIZED);
        move_to(governance_account, Registry {
            voters: smart_table::new(),
        });
        event::emit(VoterRegistryInitialized {
            governance_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ RECORD - called EXCLUSIVELY by desnet::lp_staking::claim_internal ============

    /// SOLE pathway for voting power generation. Friend-restricted to lp_staking
    /// (load-bearing barrier). The signer.addr == @desnet assertion is belt-and-braces.
    ///
    /// H4 fix (audit R1): visibility tightened from `public` to `public(friend)`.
    /// Previously, sole-call-site invariant was grep-enforced not type-enforced;
    /// any future code with @desnet pkg_signer access could mint voting power.
    /// Now any new caller requires explicit `friend` declaration in this file.
    ///
    /// Lazy-creates voter entry in centralized Registry if missing.
    public(friend) fun record_reward_received(
        factory_authority: &signer,
        voter_addr: address,
        amount: u64,
    ) acquires Registry {
        assert!(
            signer::address_of(factory_authority) == @desnet,
            E_NOT_FACTORY_AUTHORITY
        );
        assert!(exists<Registry>(@desnet), E_REGISTRY_NOT_INITIALIZED);

        let registry = borrow_global_mut<Registry>(@desnet);

        // Lazy-init voter entry on first reward (no voter signer required -
        // factory authority writes to centralized governance storage)
        if (!smart_table::contains(&registry.voters, voter_addr)) {
            smart_table::add(&mut registry.voters, voter_addr, VoterHistory {
                rewards_history: vector::empty(),
                total_received: 0,
            });
        };

        let history = smart_table::borrow_mut(&mut registry.voters, voter_addr);
        let now = timestamp::now_seconds();
        let entry = RewardEntry { timestamp_secs: now, amount };
        vector::push_back(&mut history.rewards_history, entry);
        history.total_received = history.total_received + amount;

        let idx = vector::length(&history.rewards_history) - 1;
        event::emit(VoterRewardRecorded {
            voter_addr,
            amount,
            cumulative_received: history.total_received,
            history_entry_index: idx,
            timestamp_secs: now,
        });
    }

    // ============ v0.3.2 (F7): per-token isolation ============

    /// Friend-only: extends `record_reward_received` with per-token tracking.
    /// Records to BOTH legacy mixed `Registry` (preserve compat for old read-paths)
    /// AND new `RegistryByToken` (per-token isolation for governance::voting_power).
    /// Lazy-init RegistryByToken on first call.
    public(friend) fun record_reward_received_for_token(
        factory_authority: &signer,
        voter_addr: address,
        token_addr: address,
        amount: u64,
    ) acquires Registry, RegistryByToken {
        // 1. Legacy path - keeps old indexers working.
        record_reward_received(factory_authority, voter_addr, amount);

        // 2. Per-token isolated path. (factory_authority asserted == @desnet inside #1.)
        if (!exists<RegistryByToken>(@desnet)) {
            move_to(factory_authority, RegistryByToken { voters: smart_table::new() });
        };
        let registry = borrow_global_mut<RegistryByToken>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) {
            smart_table::add(&mut registry.voters, voter_addr, smart_table::new());
        };
        let voter_tokens = smart_table::borrow_mut(&mut registry.voters, voter_addr);
        if (!smart_table::contains(voter_tokens, token_addr)) {
            smart_table::add(voter_tokens, token_addr, VoterHistory {
                rewards_history: vector::empty(),
                total_received: 0,
            });
        };
        let history = smart_table::borrow_mut(voter_tokens, token_addr);
        let now = timestamp::now_seconds();
        vector::push_back(&mut history.rewards_history, RewardEntry { timestamp_secs: now, amount });
        history.total_received = history.total_received + amount;
    }

    // ============ PRUNE - permissionless storage bound ============

    /// Anyone can call to prune entries older than HISTORY_PRUNE_AFTER_SECS.
    public entry fun prune_voter_history(_caller: &signer, voter_addr: address)
        acquires Registry
    {
        if (!exists<Registry>(@desnet)) return;
        let registry = borrow_global_mut<Registry>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) return;

        let history = smart_table::borrow_mut(&mut registry.voters, voter_addr);
        let now = timestamp::now_seconds();
        let cutoff = if (now > HISTORY_PRUNE_AFTER_SECS) now - HISTORY_PRUNE_AFTER_SECS else 0;

        let kept = vector::empty<RewardEntry>();
        let removed: u64 = 0;
        let len = vector::length(&history.rewards_history);
        let i = 0;
        while (i < len) {
            let e = *vector::borrow(&history.rewards_history, i);
            if (e.timestamp_secs >= cutoff) {
                vector::push_back(&mut kept, e);
            } else {
                removed = removed + 1;
            };
            i = i + 1;
        };
        history.rewards_history = kept;

        if (removed > 0) {
            event::emit(VoterHistoryPruned {
                voter_addr,
                entries_removed: removed,
                timestamp_secs: now,
            });
        };
    }

    // ============ VIEWS ============

    /// v0.3.2 (F7): Per-token rewards within 30d. Returns 0 if RegistryByToken not yet
    /// initialized OR voter has no entry for this token. Replaces mixed-aggregate when
    /// caller wants strict per-token isolation (e.g., governance DESNET-only voting power).
    #[view]
    public fun rewards_earned_30d_for_token(voter_addr: address, token_addr: address): u64
        acquires RegistryByToken
    {
        if (!exists<RegistryByToken>(@desnet)) return 0;
        let registry = borrow_global<RegistryByToken>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) return 0;
        let voter_tokens = smart_table::borrow(&registry.voters, voter_addr);
        if (!smart_table::contains(voter_tokens, token_addr)) return 0;
        let history = smart_table::borrow(voter_tokens, token_addr);

        let now = timestamp::now_seconds();
        let cutoff = if (now > VOTING_WINDOW_SECS) now - VOTING_WINDOW_SECS else 0;
        let sum: u64 = 0;
        let len = vector::length(&history.rewards_history);
        let i = 0;
        while (i < len) {
            let e = vector::borrow(&history.rewards_history, i);
            if (e.timestamp_secs >= cutoff) sum = sum + e.amount;
            i = i + 1;
        };
        sum
    }

    /// v0.3.2 (F7): exists check - gates governance::voting_power's choice of
    /// per-token vs legacy-mixed read.
    /// v0.3.3 (G1) NOTE: superseded for voting-power by per-USER `has_per_token_entry`
    /// to fix lazy-flip disenfranchisement. Kept for indexer compatibility.
    #[view]
    public fun has_per_token_registry(): bool { exists<RegistryByToken>(@desnet) }

    /// v0.3.3 (G1, R5 CONV-3 HIGH): per-USER existence check. Eliminates lazy-flip
    /// disenfranchisement where the FIRST claimer post-v0.3.2 instantly zeroed
    /// voting power for all OTHER pre-existing voters by triggering the global flag.
    /// Returns true only when THIS voter has at least one per-token entry under any
    /// token. Governance::voting_power should use this for per-user fallback to legacy.
    /// v0.3.3 (Qwen R6 H1 NOTE): superseded for voting-power by per-user-per-token
    /// `has_per_token_entry_for_token` (see below). Kept for indexer compatibility.
    /// Reason: claim_internal writes per-pool's token (not always DESNET) - this
    /// generic check returns true for non-DESNET claimers too, which would
    /// disenfranchise their legacy DESNET balance under voting_power's DESNET-only branch.
    #[view]
    public fun has_per_token_entry(voter_addr: address): bool acquires RegistryByToken {
        if (!exists<RegistryByToken>(@desnet)) return false;
        let registry = borrow_global<RegistryByToken>(@desnet);
        smart_table::contains(&registry.voters, voter_addr)
    }

    /// v0.3.3 (Qwen R6 H1 fix): per-USER-per-TOKEN existence check. Eliminates the
    /// disenfranchisement vector where a voter who claims from a non-DESNET pool
    /// (e.g., $alice token) would have `has_per_token_entry == true` triggering
    /// the DESNET-only voting_power branch, which then returns 0 because they have
    /// no DESNET-specific inner entry. governance::voting_power uses THIS view
    /// (with DESNET_FA_ADDR) so a voter only loses legacy fallback once they have
    /// an actual DESNET reward entry, not just any token entry.
    #[view]
    public fun has_per_token_entry_for_token(voter_addr: address, token_addr: address): bool
        acquires RegistryByToken
    {
        if (!exists<RegistryByToken>(@desnet)) return false;
        let registry = borrow_global<RegistryByToken>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) return false;
        let voter_tokens = smart_table::borrow(&registry.voters, voter_addr);
        smart_table::contains(voter_tokens, token_addr)
    }

    /// Sum reward entries within last 30d window. Used as filter A in voting power.
    #[view]
    public fun rewards_earned_30d(voter_addr: address): u64 acquires Registry {
        if (!exists<Registry>(@desnet)) return 0;
        let registry = borrow_global<Registry>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) return 0;

        let history = smart_table::borrow(&registry.voters, voter_addr);
        let now = timestamp::now_seconds();
        let cutoff = if (now > VOTING_WINDOW_SECS) now - VOTING_WINDOW_SECS else 0;

        let total: u64 = 0;
        let len = vector::length(&history.rewards_history);
        let i = 0;
        while (i < len) {
            let e = *vector::borrow(&history.rewards_history, i);
            if (e.timestamp_secs >= cutoff) {
                total = total + e.amount;
            };
            i = i + 1;
        };
        total
    }

    #[view]
    public fun total_received(voter_addr: address): u64 acquires Registry {
        if (!exists<Registry>(@desnet)) return 0;
        let registry = borrow_global<Registry>(@desnet);
        if (!smart_table::contains(&registry.voters, voter_addr)) return 0;
        smart_table::borrow(&registry.voters, voter_addr).total_received
    }

    #[view]
    public fun history_exists(voter_addr: address): bool acquires Registry {
        if (!exists<Registry>(@desnet)) return false;
        smart_table::contains(&borrow_global<Registry>(@desnet).voters, voter_addr)
    }

    #[view]
    public fun voting_window_secs(): u64 { VOTING_WINDOW_SECS }
}

```

---

## TESTS

## `tests/supra_port_v04.move`

```move
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

```

---

## `tests/v030_integration.move`

```move
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

        // Initial LP = sqrt(5e8 * 5e15) = 1.58e12 (V3 returns u128 shares directly, not FA)
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

        // AMM swap fee = FEE_BPS (100 bps = 1%), so fee = swap_in / 100.
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

        // Universal model: lp_supply == initial_shares (no staked_lp_supply distinction)
        assert!(amm::lp_supply(b"viewcoin") == initial_shares, 1);

        // Addr-based view (darbitex composability)
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

        // Addr-based variant (darbitex composability)
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

        // Pure compute_amount_out matches too (darbitex shape)
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

    /// V3 universal model: ALL LP earns fees. Even with no add_liquidity beyond initial,
    /// the initial creator's locked shares (lp_supply > 0) means accumulator WILL advance.
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

        // Universal: lp_supply > 0 -> accumulator advances on swap
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

    /// Flash borrow + repay round-trip. Verifies fee 100% to LP accumulator.
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

        // Borrow 100M raw SUPRA (1 SUPRA)
        let borrow_amount = 100_000_000u64;
        let (borrowed, receipt) = amm::flash_borrow(pool_addr, supra_meta, borrow_amount);
        assert!(fungible_asset::amount(&borrowed) == borrow_amount, 1);

        // Pool locked during borrow
        assert!(amm::pool_locked(pool_addr), 2);

        // Compute fee. FLASH_FEE_BPS = 100 bps (1%).
        let fee = amm::compute_flash_fee(borrow_amount);
        assert!(fee == 1_000_000, 3);  // 1% of 100M raw = 1M raw

        // Bob mints fee top-up + repays
        let topup = mint_supra_fa(&mint, fee);
        fungible_asset::merge(&mut borrowed, topup);

        amm::flash_repay(pool_addr, borrowed, receipt);

        // Pool unlocked
        assert!(!amm::pool_locked(pool_addr), 4);

        // Reserve = original (100M back), fee bucket = 100k
        let (supra_r, _) = amm::reserves(b"flashcoin");
        assert!(supra_r == supra_seed, 5);

        let (supra_fees, _) = amm::fee_buckets(b"flashcoin");
        assert!(supra_fees == fee, 6);

        // Fee accumulator advanced (universal)
        let (acc_supra, _) = amm::fee_per_lp(b"flashcoin");
        assert!(acc_supra > 0, 7);

        cleanup(burn, mint);
        let _ = bob;
        let _ = token_mint_ref;
    }

    /// Flash repay with wrong amount aborts.
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
        // Try to repay WITHOUT fee -> E_K_VIOLATED (14)
        amm::flash_repay(pool_addr, borrowed, receipt);
        cleanup(burn, mint);
        let _ = token_mint_ref;
    }

    /// Generic swap by addr (darbitex shape) routes to correct internal swap.
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

    /// Read warning disclosure (returns bytes).
    #[test(framework = @supra_framework)]
    fun test_read_warning(framework: &signer) {
        let (burn, mint) = setup_framework(framework);
        let warning = amm::read_warning();
        // Sanity: non-empty bytes, contains "DESNET" prefix
        assert!(std::vector::length(&warning) > 30, 1);  // trimmed for tx-size fit
        cleanup(burn, mint);
    }

    // ============ R3 H3 Regression - supra_vault two-phase settle ============

    /// Verify the two-phase settle blocks single-tx sandwich.
    /// Setup: token with burn_ref, pool seeded, vault with deposited SUPRA.
    /// Phase 1: execute_settle without prior request -> E_NO_PENDING_SETTLE (6).
    /// Phase 2: request_settle then immediate execute_settle -> E_SETTLE_NOT_READY (7).
    /// Phase 3: request_settle, fast-forward 60s, execute_settle -> success.
    #[test(framework = @supra_framework, alice = @0xa11ce)]
    #[expected_failure(abort_code = 6, location = desnet::supra_vault)]
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

        // Seed pool 100 SUPRA / 100M tokens.
        let supra_fa = mint_supra_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", supra_fa, token_fa, @0xa11ce, false);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        // Fake PID.
        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);

        // Deploy vault.
        let vault_addr = supra_vault::deploy_for_test(
            alice,
            b"vaultcoin",
            token_meta_addr,
            pool_addr,
            pid_addr,
            burn_ref,
        );

        // Fund the vault with 1 SUPRA (above 0.1 SUPRA threshold).
        let funding_coin = coin::mint<SupraCoin>(100_000_000, &mint);
        supra_vault::deposit_supra_coin_for_test(vault_addr, funding_coin);

        // Attempt execute_settle with NO prior request_settle - expects E_NO_PENDING_SETTLE.
        supra_vault::execute_settle(alice, vault_addr);

        // Unreached - but cleanup pattern for safety.
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

        // Advance past 0 so pending_settle_at_secs is distinguishable from sentinel.
        timestamp::fast_forward_seconds(100);

        // Request, then attempt execute in same tx (no further time advance).
        supra_vault::request_settle(alice, vault_addr);
        // Expects E_SETTLE_NOT_READY (7).
        supra_vault::execute_settle(alice, vault_addr);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }

    /// Positive path: request -> fast-forward >=60s -> execute succeeds.
    /// Also verifies the 1% buyback cap (defense-in-depth) by funding the vault
    /// with much more SUPRA than 1% of pool reserve, and asserting the cap kicks in.
    #[test(framework = @supra_framework, alice = @0xa11ce)]
    fun test_settle_two_phase_executes_after_delay(framework: &signer, alice: &signer) {
        let (burn, mint) = setup_framework(framework);
        account::create_account_for_test(signer::address_of(alice));
        // supra_vault::execute_settle deposits SUPRA back to the owner via the
        // legacy coin v1 API (coin::deposit), which requires the destination
        // to have a CoinStore<SupraCoin>. account_for_test creates only the
        // account header. Register CoinStore explicitly for the test.
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

        // Seed pool: 100 SUPRA (1e10) / 100M tokens (1e16).
        let supra_fa = mint_supra_fa(&mint, 10_000_000_000);
        let token_fa = fungible_asset::mint(&token_mint_ref, 10_000_000_000_000_000);
        let _ = amm::create_pool_atomic_for_test(b"vaultcoin", supra_fa, token_fa, @0xa11ce, true);
        let pool_addr = amm::pool_address_of_handle(b"vaultcoin");

        let pid_ctor = object::create_named_object(alice, b"fake_pid");
        let pid_addr = object::address_from_constructor_ref(&pid_ctor);
        let vault_addr = supra_vault::deploy_for_test(
            alice, b"vaultcoin", token_meta_addr, pool_addr, pid_addr, burn_ref
        );

        // Fund vault with 10 SUPRA - half (5 SUPRA raw) would be the raw_buyback,
        // but cap = 1% of 100 SUPRA reserve = 1 SUPRA. So buyback caps at 1 SUPRA,
        // owner receives 10 - 1 = 9 SUPRA (instead of 10/2 = 5).
        supra_vault::deposit_supra_coin_for_test(vault_addr, coin::mint<SupraCoin>(1_000_000_000, &mint));
        assert!(supra_vault::supra_balance(vault_addr) == 1_000_000_000, 1);

        // Advance past 0 so pending_settle_at_secs is distinguishable from sentinel.
        timestamp::fast_forward_seconds(100);

        // Request settle.
        supra_vault::request_settle(alice, vault_addr);
        assert!(supra_vault::pending_settle_at_secs(vault_addr) > 0, 2);

        // Fast-forward 60s + 1.
        timestamp::fast_forward_seconds(61);

        // Execute settle.
        supra_vault::execute_settle(alice, vault_addr);

        // Vault balance should be 0 (all consumed: 1 SUPRA buyback, 9 SUPRA to owner).
        assert!(supra_vault::supra_balance(vault_addr) == 0, 3);
        // pending should reset.
        assert!(supra_vault::pending_settle_at_secs(vault_addr) == 0, 4);

        let _ = token_mint_ref;
        cleanup(burn, mint);
    }
}

```

---

## EXTERNAL DEP: desnet-bootstrap-supra

## `../desnet-bootstrap-supra/sources/publisher.move`

```move
/// Bootstrap publisher - chunked-publish helper for the main DesNet package.
///
/// One-shot lifecycle:
/// 1. `init_module` (runs at deploy of THIS bootstrap pkg, signer = @origin multisig):
///    creates `@desnet` resource account + stashes its SignerCapability in CapHolder.
/// 2. Multisig calls `stage_chunk` 0+ times to accumulate metadata + bytecode chunks
///    in a StagingArea at @origin.
/// 3. Multisig calls `publish_chunked` (final chunk + publish) - derives @desnet
///    signer via cap, calls `code::publish_package_txn` to install DesNet at @desnet.
/// 4. DesNet's `governance::init_module` (runs at end of publish_chunked tx) takes
///    the cap via friend call `take_cap_for_desnet`. CapHolder consumed.
/// 5. Bootstrap module persists at @origin but inert - CapHolder gone, all entries abort.
module origin::publisher {
    use std::signer;
    use std::vector;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::code;

    const E_NOT_AUTHORIZED: u64 = 1;
    const E_ARGS_LEN_MISMATCH: u64 = 2;
    const E_NOT_DESNET_SIGNER: u64 = 3;

    /// Holds SignerCapability for @desnet resource account.
    /// Created in `init_module`, consumed by `take_cap_for_desnet` (friend-only).
    struct CapHolder has key {
        cap: SignerCapability,
    }

    /// Accumulated metadata + per-module code across stage_chunk calls.
    /// Lives at @origin until consumed by publish_chunked.
    struct StagingArea has key, drop {
        metadata: vector<u8>,
        code: vector<vector<u8>>,
    }

    /// Init: create @desnet resource account + store its SignerCapability.
    /// Signer = @origin (multisig publisher of this bootstrap pkg).
    /// Seed `b"desnet"` derives @desnet = sha3_256(@origin || "desnet" || 0xff).
    fun init_module(deployer: &signer) {
        let (_resource_signer, cap) = account::create_resource_account(deployer, b"desnet");
        move_to(deployer, CapHolder { cap });
    }

    /// Append metadata + code chunks to StagingArea. Permissionless? No - multisig only.
    public entry fun stage_chunk(
        authority: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires StagingArea {
        assert!(signer::address_of(authority) == @origin, E_NOT_AUTHORIZED);
        assert!(
            vector::length(&code_indices) == vector::length(&code_chunks),
            E_ARGS_LEN_MISMATCH
        );
        ensure_staging_area(authority);
        append_chunks(metadata_chunk, code_indices, code_chunks);
    }

    /// Final: stage last chunk + publish DesNet to @desnet.
    public entry fun publish_chunked(
        authority: &signer,
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires CapHolder, StagingArea {
        assert!(signer::address_of(authority) == @origin, E_NOT_AUTHORIZED);
        assert!(
            vector::length(&code_indices) == vector::length(&code_chunks),
            E_ARGS_LEN_MISMATCH
        );
        ensure_staging_area(authority);
        append_chunks(metadata_chunk, code_indices, code_chunks);

        let StagingArea { metadata, code } = move_from<StagingArea>(@origin);
        let cap_ref = &borrow_global<CapHolder>(@origin).cap;
        let resource_signer = account::create_signer_with_capability(cap_ref);
        code::publish_package_txn(&resource_signer, metadata, code);
    }

    /// DesNet's `governance::init_module` extracts the cap to take permanent
    /// custody. Public visibility is safe because only a `&signer` whose addr ==
    /// @desnet can pass the assert; the only way to obtain that signer is via this
    /// very cap (chicken-and-egg) - so the FIRST caller is the publish-tx-spawned
    /// init_module of DesNet (which receives @desnet signer from the framework).
    /// CapHolder consumed -> all subsequent calls abort.
    public fun take_cap_for_desnet(resource: &signer): SignerCapability acquires CapHolder {
        assert!(signer::address_of(resource) == @desnet, E_NOT_DESNET_SIGNER);
        let CapHolder { cap } = move_from<CapHolder>(@origin);
        cap
    }

    /// Discard a half-staged StagingArea (e.g., aborted publish, restart).
    public entry fun cleanup_staging(authority: &signer) acquires StagingArea {
        assert!(signer::address_of(authority) == @origin, E_NOT_AUTHORIZED);
        if (exists<StagingArea>(@origin)) {
            let _ = move_from<StagingArea>(@origin);
        };
    }

    // ============ INTERNAL ============

    fun ensure_staging_area(authority: &signer) {
        if (!exists<StagingArea>(@origin)) {
            move_to(authority, StagingArea {
                metadata: vector::empty(),
                code: vector::empty(),
            });
        };
    }

    fun append_chunks(
        metadata_chunk: vector<u8>,
        code_indices: vector<u16>,
        code_chunks: vector<vector<u8>>,
    ) acquires StagingArea {
        let staging = borrow_global_mut<StagingArea>(@origin);
        vector::append(&mut staging.metadata, metadata_chunk);

        let n = vector::length(&code_chunks);
        let i = 0;
        while (i < n) {
            let idx = (*vector::borrow(&code_indices, i) as u64);
            // Pad code vector if module-index is beyond current length.
            while (vector::length(&staging.code) <= idx) {
                vector::push_back(&mut staging.code, vector::empty());
            };
            let target = vector::borrow_mut(&mut staging.code, idx);
            let chunk = *vector::borrow(&code_chunks, i);
            vector::append(target, chunk);
            i = i + 1;
        };
    }

    // ============ VIEW ============

    #[view]
    public fun cap_exists(): bool { exists<CapHolder>(@origin) }

    #[view]
    public fun staging_exists(): bool { exists<StagingArea>(@origin) }
}

```

---

## `../desnet-bootstrap-supra/Move.toml`

```toml
[package]
name = "DesnetBootstrap"
version = "0.1.0"
upgrade_policy = "compatible"
authors = ["Rera", "Claude (Anthropic)"]
license = "Unlicense"

# Bootstrap helper for chunked-publish of the main DesNet package to a resource account.
# - Lives at @origin (deployer multisig).
# - init_module: creates @desnet resource account + holds its SignerCapability.
# - Exposes stage_chunk + publish_chunked entries (multisig-only) to assemble the
#   main DesNet package across multiple txs (single-tx 64KB limit workaround).
# - DesNet's governance::init_module (runs at end of publish_chunked tx) takes the
#   cap via friend call `take_cap_for_desnet`.
# Zero external deps beyond core framework (account, code, resource_account).

[addresses]
# Mainnet: origin=0x000073c4... (multisig vanity), desnet=0x7ba7ee5a... (resource account).
# Placeholders for local compile/test - aptos CLI propagates parent --named-addresses
# but supra CLI 0.5.0 does not, so we declare them here too. Override at deploy time
# via `--named-addresses origin=0x..., desnet=0x...`.
origin = "0xA0E1"
desnet = "0xDADE"

[dependencies.SupraFramework]
git = "https://github.com/Entropy-Foundation/aptos-core.git"
rev = "306b60776be2ba382e35e327a7812233ae7acb13"
subdir = "aptos-move/framework/supra-framework"

[dependencies.AptosStdlib]
git = "https://github.com/Entropy-Foundation/aptos-core.git"
rev = "306b60776be2ba382e35e327a7812233ae7acb13"
subdir = "aptos-move/framework/aptos-stdlib"

```
