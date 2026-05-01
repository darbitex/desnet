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
