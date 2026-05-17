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

    const SETTLE_BOUNTY_BPS: u64 = 5;

    const KIND_FA: u8 = 1;
    const KIND_NFT: u8 = 2;

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

    struct Giveaway has key, store {
        sponsor_pid: address,
        sponsor_wallet: address,
        kind: u8,
        deadline_secs: u64,
        fa_token_metadata: address,
        fa_amount_per_claim: u64,
        fa_total_budget: u64,
        nft_collection_addr: address,
        nft_addrs: vector<address>,
        claims_made: u64,
        follower_only: bool,
        nft_gate: Option<address>,
        lp_stake_gate: Option<address>,
        claimers: SmartTable<address, bool>,
        extend_ref: ExtendRef,
    }

    struct PidGiveawayStorage has key {
        giveaways: SmartTable<u64, address>,
    }

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

        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        let escrow_fa = primary_fungible_store::withdraw(sponsor, token_metadata, total_budget);

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

        assert!(mint_seq < mint::next_seq(sponsor_pid), E_MINT_NOT_FOUND);

        let constructor_ref = object::create_object(sponsor_addr);
        let giveaway_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        let n_nfts = vector::length(&nft_addrs);
        assert!(n_nfts > 0, E_GIVEAWAY_EXHAUSTED);
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

        let now = timestamp::now_seconds();
        assert!(now < giveaway.deadline_secs, E_GIVEAWAY_EXPIRED);
        assert!(!smart_table::contains(&giveaway.claimers, claimer_pid), E_ALREADY_CLAIMED);

        check_gates(giveaway, claimer_pid, claimer_addr, claimer_nft_proof_addr, claimer_stake_position_addr);

        let giveaway_signer = object::generate_signer_for_extending(&giveaway.extend_ref);

        if (giveaway.kind == KIND_FA) {
            let token_metadata = object::address_to_object<Metadata>(giveaway.fa_token_metadata);
            let remaining = primary_fungible_store::balance(giveaway_addr, token_metadata);
            assert!(remaining >= giveaway.fa_amount_per_claim, E_GIVEAWAY_EXHAUSTED);

            let claim_fa = primary_fungible_store::withdraw(
                &giveaway_signer,
                token_metadata,
                giveaway.fa_amount_per_claim,
            );
            primary_fungible_store::deposit(claimer_addr, claim_fa);
        } else if (giveaway.kind == KIND_NFT) {
            assert!(!vector::is_empty(&giveaway.nft_addrs), E_GIVEAWAY_EXHAUSTED);
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
            let count = vector::length(&giveaway.nft_addrs);
            refund_amount = count;
            while (!vector::is_empty(&giveaway.nft_addrs)) {
                let nft_addr = vector::pop_back(&mut giveaway.nft_addrs);
                let nft_object = object::address_to_object<ObjectCore>(nft_addr);
                object::transfer(&giveaway_signer, nft_object, sponsor_wallet);
            };
        };

        event::emit(GiveawaySettled {
            giveaway_addr,
            sponsor_pid: giveaway.sponsor_pid,
            settler: settler_addr,
            refund_amount,
            bounty_paid: bounty,
            timestamp_secs: now,
        });
    }

    fun check_gates(
        giveaway: &Giveaway,
        claimer_pid: address,
        claimer_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) {
        if (giveaway.follower_only) {
            assert!(
                link::is_synced(claimer_pid, giveaway.sponsor_pid),
                E_FOLLOWER_GATE_FAILED
            );
        };

        if (option::is_some(&giveaway.nft_gate)) {
            let required_collection = *option::borrow(&giveaway.nft_gate);
            assert!(claimer_nft_proof_addr != @0x0, E_NFT_GATE_FAILED);
            assert!(
                object::object_exists<token::Token>(claimer_nft_proof_addr),
                E_NFT_GATE_FAILED
            );
            let nft_obj = object::address_to_object<token::Token>(claimer_nft_proof_addr);
            assert!(object::owner(nft_obj) == claimer_addr, E_NFT_GATE_FAILED);
            let collection_obj = token::collection_object(nft_obj);
            assert!(
                object::object_address(&collection_obj) == required_collection,
                E_NFT_GATE_FAILED
            );
        };

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

    fun ensure_giveaway_storage(pid_addr: address) {
        if (!exists<PidGiveawayStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidGiveawayStorage {
                giveaways: smart_table::new(),
            });
        };
    }

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
