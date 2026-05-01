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
