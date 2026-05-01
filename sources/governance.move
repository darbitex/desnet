/// Governance — DAO orchestrator for the DeSNet monolith package.
///
/// All DeSNet modules (factory, profile, mint/pulse/press/...) share a single
/// resource_account at @desnet. Governance is the SOLE holder of the resource_account
/// `SignerCapability`; sibling modules acquire a package signer at runtime via
/// `derive_pkg_signer()` (friend-only).
///
/// Two upgrade paths:
///   1. `multisig_upgrade(@origin signer, ...)` — bootstrap path, no DAO vote.
///      Used pre-PMF while the team iterates rapidly. Off-chain: simply stop
///      calling this once DAO is trusted.
///   2. `propose_upgrade` → `cast_vote` → `ratify` → `execute_proposal` —
///      full DAO flow with voting, quorum, approval threshold, and 30d timelock.
///      Calls `aptos_framework::code::publish_package_txn` directly with the
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
    use std::option::{Self, Option};
    use std::signer;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::code;
    use aptos_framework::event;
    use aptos_framework::resource_account;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::voter_history;

    friend desnet::factory;
    friend desnet::profile;
    friend desnet::amm;
    friend desnet::lp_staking;
    friend desnet::handle_fee_vault;

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

    // ============ TYPES ============

    /// Governance singleton state at @desnet. Sole holder of pkg signer_cap.
    struct GovernanceState has key {
        signer_cap: SignerCapability,
        proposal_count: u64,
        proposals: SmartTable<u64, Proposal>,
        // DESNET FA addr for voting_power balance check.
        // @0x0 = NOT YET CONFIGURED (voting_power returns 0).
        desnet_fa_metadata: address,
        // 30d emission estimate (denominator for threshold/quorum).
        // 0 = NOT YET CONFIGURED (proposals can't be submitted).
        total_30d_emission: u64,
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

    // ============ INIT — called by resource_account at deploy ============

    fun init_module(account: &signer) {
        let signer_cap = resource_account::retrieve_resource_account_cap(account, @origin);
        let governance_addr = signer::address_of(account);

        move_to(account, GovernanceState {
            signer_cap,
            proposal_count: 0,
            proposals: smart_table::new(),
            desnet_fa_metadata: @0x0,
            total_30d_emission: 0,
        });

        // Initialize centralized voter_history Registry at @desnet.
        voter_history::init_registry(account);

        event::emit(GovernanceInitialized {
            governance_addr,
            deployer: @origin,
            timestamp_secs: timestamp::now_seconds(),
        });
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
    public entry fun multisig_upgrade(
        multisig: &signer,
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);

        let pkg_signer = derive_pkg_signer();
        code::publish_package_txn(&pkg_signer, metadata, code_bytes);

        event::emit(MultisigUpgrade {
            multisig: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ DAO-PHASE PROPOSAL LIFECYCLE ============

    public entry fun propose_upgrade(
        proposer: &signer,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
    ) acquires GovernanceState {
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
    ) acquires GovernanceState {
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
    /// `code::publish_package_txn` directly with the derived package signer —
    /// monolith means there's only one target (@desnet), no per-package dispatch.
    public entry fun execute_proposal(
        caller: &signer,
        proposal_id: u64,
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ) acquires GovernanceState {
        // Derive pkg signer FIRST (acquires GovernanceState) before mut-borrow below.
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

    // ============ VIEWS ============

    /// voting_power = min(rewards_earned_30d, current DESNET balance).
    /// If `desnet_fa_metadata` not yet configured (= @0x0), returns 0.
    #[view]
    public fun voting_power(voter_addr: address): u64 acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        if (state.desnet_fa_metadata == @0x0) return 0;

        let earned = voter_history::rewards_earned_30d(voter_addr);
        let fa_meta = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(
            state.desnet_fa_metadata
        );
        let balance = aptos_framework::primary_fungible_store::balance(voter_addr, fa_meta);
        if (earned < balance) earned else balance
    }

    #[view]
    public fun proposal_threshold_amount(): u64 acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        if (state.total_30d_emission == 0) return 18446744073709551615u64;
        (state.total_30d_emission * PROPOSAL_THRESHOLD_BPS) / 10000
    }

    #[view]
    public fun quorum_amount(): u64 acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        if (state.total_30d_emission == 0) return 18446744073709551615u64;
        (state.total_30d_emission * QUORUM_BPS) / 10000
    }

    // ============ ADMIN SETTERS (multisig-only) ============

    const E_NOT_MULTISIG_ADMIN: u64 = 100;

    /// Multisig sets DESNET FA metadata addr post-deploy. Required to activate
    /// voting_power. Idempotent (admin can re-point if needed).
    public entry fun update_desnet_fa_metadata(
        multisig: &signer,
        fa_addr: address,
    ) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG_ADMIN);
        borrow_global_mut<GovernanceState>(@desnet).desnet_fa_metadata = fa_addr;
    }

    /// Multisig sets 30d emission estimate (denominator for threshold/quorum).
    public entry fun update_total_30d_emission(
        multisig: &signer,
        amount: u64,
    ) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG_ADMIN);
        borrow_global_mut<GovernanceState>(@desnet).total_30d_emission = amount;
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
        use aptos_framework::account;
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
            total_30d_emission: 0,
        });
        voter_history::init_registry(&desnet_signer);
    }
}
