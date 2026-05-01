# DeSNet v0.3.0-r2 — Full Source for External Audit (Round 2 appendix)

**Companion to `AUDIT-DESNET-V030-R2-SUBMISSION.md` + `AUDIT-DESNET-V030-R2-DIFF.md`.**

Complete Move source for the 17 modules of v0.3.0-r2 (post-R1-fix patch). Provided as appendix in case auditors want to re-trace specific call paths after reviewing the focused diff. The DIFF file is the recommended primary read.

**Total:** 17 Move files, ~7434 LoC, all compile clean. 68/68 unit + integration tests pass.


---

## `sources/governance.move`

```move
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
    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
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

    // ============ DAO-PHASE PROPOSAL LIFECYCLE ============

    public entry fun propose_upgrade(
        proposer: &signer,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
    ) acquires GovernanceState {
        // Kimi F4 fix (audit R1): require DAO config before accepting proposals.
        let cfg = borrow_global<GovernanceState>(@desnet);
        assert!(cfg.desnet_fa_metadata != @0x0, E_NOT_INITIALIZED);
        assert!(cfg.total_30d_emission > 0, E_NOT_INITIALIZED);

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
    /// `code::publish_package_txn` with the derived package signer.
    ///
    /// H1 fix (audit R1): the executor MUST submit metadata + code_bytes whose
    /// digest matches `proposal.new_module_bytes_hash` recorded at propose time.
    /// Without this check, executor can ship arbitrary code post-timelock — full
    /// DAO bypass. Digest scheme: sha3_256(bcs(metadata) ++ concat(bcs(code_bytes[i])))
    /// — `propose_upgrade` callers MUST use the same scheme to compute their hash.
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

    /// Canonical digest of upgrade payload. Used by both `propose_upgrade` (off-chain
    /// callers compute this on the intended payload) and `execute_proposal` (verifies
    /// submitted bytes match). Scheme: sha3_256(bcs(metadata) || concat(bcs(code_bytes[i]))).
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
            multisig_upgrade_disabled: false,
        });
        voter_history::init_registry(&desnet_signer);
    }
}
```

---

## `sources/factory.move`

```move
/// Token Factory — atomic spawn of $TOKEN + vault + emission reserves + AMM pool + locked LP stake.
///
/// Full atomic register_handle flow. One tx = PID + token + pool + lock + stake.
/// Uses in-house `desnet::amm` (pool create) + `desnet::lp_staking` (forever-lock creator's initial LP).
///
/// Caller flow:
///   profile::register_handle (charges handle_fee + 5 APT) →
///   factory::create_token_atomic(handle, pid_addr, pool_seed_apt_fa) →
///     mints 1B $TOKEN → splits 50M/50M/900M → creates AMM pool with 5 APT + 50M $TOKEN →
///     forever-locks initial LP into PID NFT object via lp_staking → done.
///
/// Allocation:
///   - 50M (5%) → pool seed (paired with 5 APT in AMM)
///   - 50M (5%) → reaction emission reserve
///   - 900M (90%) → LP emission reserve
///   Sum = 1B exactly.
module desnet::factory {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use aptos_framework::object::{Self};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::governance;
    use desnet::lp_emission;
    use desnet::lp_staking;
    use desnet::reaction_emission;

    friend desnet::profile;

    // ============ CONSTANTS ============

    /// Total supply per spawned token: 1B at 8 dec.
    const TOTAL_SUPPLY: u64 = 100_000_000_000_000_000;
    const TOKEN_DECIMALS: u8 = 8;

    /// Allocation: 50M (pool seed) / 50M (reaction reserve) / 900M (LP emission). Sum = 1B.
    const POOL_SEED_TOKEN_AMOUNT: u64 = 5_000_000_000_000_000;       // 50M × 10^8
    const REACTION_RESERVE_AMOUNT: u64 = 5_000_000_000_000_000;       // 50M × 10^8
    const LP_EMISSION_AMOUNT: u64 = 90_000_000_000_000_000;           // 900M × 10^8

    /// Pool seed APT amount (paired with 50M $TOKEN). User pays this in addition to handle_fee.
    const POOL_SEED_APT_AMOUNT: u64 = 500_000_000;                    // 5 APT × 10^8

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
    const E_INVALID_POOL_SEED_APT: u64 = 12;
    const E_NOT_ADMIN: u64 = 13;

    // ============ TYPES ============

    struct FactoryState has key {
        spawn_count: u64,
        paused: bool,
    }

    /// Per-spawned-token registry record.
    struct TokenRecord has store, copy, drop {
        handle: String,
        token_metadata: address,
        owner_addr: address,                          // PID Object addr (transferable)
        apt_vault: address,
        reaction_reserve: address,
        lp_reserve: address,
        lp_staking_pool: address,                     // populated atomically (no longer @0x0)
        amm_pool: address,                            // in-house AMM pool addr
        spec_version: u32,
        spawned_at_secs: u64,
    }

    struct FactoryRegistry has key {
        records: SmartTable<String, TokenRecord>,
        metadata_index: SmartTable<address, String>,    // token_metadata → handle
        owner_index: SmartTable<address, String>,        // owner_addr (pid) → handle
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
        amm_pool: address,
        lp_staking_pool: address,
        apt_vault: address,
        lp_reserve: address,
        reaction_reserve: address,
        spec_version: u32,
        timestamp_secs: u64,
    }

    // ============ INIT ============

    fun init_module(account: &signer) {
        let factory_addr = signer::address_of(account);

        move_to(account, FactoryState {
            spawn_count: 0,
            paused: false,
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

    /// Atomic token + vault + reserves + AMM pool + locked LP stake.
    /// Friend-only: sole caller is `desnet::profile::register_handle`.
    ///
    /// Caller MUST:
    /// - Have already minted PID NFT at `pid_addr`
    /// - Have already collected handle_fee_apt + POOL_SEED_APT_AMOUNT from end-user
    /// - Pass exactly POOL_SEED_APT_AMOUNT (5 APT) as `pool_seed_apt`
    public(friend) fun create_token_atomic(
        handle: vector<u8>,
        pid_addr: address,
        pid_signer: &signer,
        pool_seed_apt: FungibleAsset,
    ) acquires FactoryState, FactoryRegistry {
        validate_handle(&handle);
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(!smart_table::contains(&registry.records, handle_str), E_HANDLE_TAKEN);

        let state = borrow_global<FactoryState>(@desnet);
        assert!(!state.paused, E_FACTORY_PAUSED);

        // Validate pool seed amount
        assert!(
            fungible_asset::amount(&pool_seed_apt) == POOL_SEED_APT_AMOUNT,
            E_INVALID_POOL_SEED_APT
        );

        let factory_signer = governance::derive_pkg_signer();

        // Step 1: Mint $TOKEN FA at deterministic addr.
        let token_seed = make_token_seed(&handle);
        let constructor_ref = object::create_named_object(&factory_signer, token_seed);
        let token_metadata_addr = object::address_from_constructor_ref(&constructor_ref);

        let name_str = string::utf8(handle);
        let symbol_str = string::utf8(handle);
        // FA icon_uri / project_uri left empty — frontend constructs at render time
        // from on-chain PID metadata. No hardcoded domain in source.
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some((TOTAL_SUPPLY as u128)),
            name_str,
            symbol_str,
            TOKEN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let metadata_obj_transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&metadata_obj_transfer_ref);

        let _ = object::object_from_constructor_ref<fungible_asset::Metadata>(&constructor_ref);

        // Step 2: Mint full supply into 3 tranches (50M / 50M / 900M = 1B exactly).
        let pool_seed_token_fa = fungible_asset::mint(&mint_ref, POOL_SEED_TOKEN_AMOUNT);
        let reaction_fa = fungible_asset::mint(&mint_ref, REACTION_RESERVE_AMOUNT);
        let lp_emission_fa = fungible_asset::mint(&mint_ref, LP_EMISSION_AMOUNT);

        // Step 3: Deploy LP emission reserve (sealed, holds 900M).
        let lp_reserve_addr = lp_emission::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            lp_emission_fa,
        );

        // Step 4: Deploy reaction emission reserve (sealed, holds 50M).
        let reaction_reserve_addr = reaction_emission::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            reaction_fa,
        );

        // Step 5: Compute AMM pool addr (deterministic from handle).
        let amm_pool_addr = amm::pool_address_of_handle(handle);

        // Step 6: Deploy vault (sealed, holds BurnRef + APT balance).
        let apt_vault_addr = apt_vault::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            amm_pool_addr,                            // vault buyback target
            pid_addr,                                  // PID owner resolver
            burn_ref,
        );

        // Step 7: Atomic AMM pool create (5 APT + 50M $TOKEN). Returns shares (u128).
        let initial_shares = amm::create_pool_atomic(
            handle,
            pool_seed_apt,
            pool_seed_token_fa,
            pid_addr,
        );

        // Step 8: Forever-lock initial shares into Position at PID NFT object.
        let lp_staking_pool_addr = lp_staking::create_pool_and_lock(
            handle,
            token_metadata_addr,
            lp_reserve_addr,
            pid_addr,
            pid_signer,
            initial_shares,
        );

        // Step 9: Destroy MintRef (fixed_supply forever).
        let _ = mint_ref;

        // Step 10: Record TokenRecord.
        let now_secs = timestamp::now_seconds();
        let record = TokenRecord {
            handle: handle_str,
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            apt_vault: apt_vault_addr,
            reaction_reserve: reaction_reserve_addr,
            lp_reserve: lp_reserve_addr,
            lp_staking_pool: lp_staking_pool_addr,
            amm_pool: amm_pool_addr,
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
            amm_pool: amm_pool_addr,
            lp_staking_pool: lp_staking_pool_addr,
            apt_vault: apt_vault_addr,
            lp_reserve: lp_reserve_addr,
            reaction_reserve: reaction_reserve_addr,
            spec_version: SPEC_VERSION_V3,
            timestamp_secs: now_secs,
        });
    }

    // ============ HANDLE VALIDATION ============

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
        assert!(smart_table::contains(&registry.records, key), E_HANDLE_TAKEN);
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
        assert!(
            smart_table::contains(&registry.metadata_index, token_metadata),
            E_HANDLE_TAKEN
        );
        *smart_table::borrow(&registry.metadata_index, token_metadata)
    }

    #[view]
    public fun handle_of_owner(owner_addr: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        *smart_table::borrow(&registry.owner_index, owner_addr)
    }

    #[view]
    public fun token_metadata_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).token_metadata
    }

    #[view]
    public fun lp_staking_pool_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).lp_staking_pool
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

    /// Kimi F2 fix (audit R1): admin pause/unpause control. @origin-only.
    /// Without this, paused=true was a one-way kill-switch with no recovery.
    public entry fun set_paused(admin: &signer, new_paused: bool) acquires FactoryState {
        assert!(signer::address_of(admin) == @origin, E_NOT_ADMIN);
        borrow_global_mut<FactoryState>(@desnet).paused = new_paused;
    }

    #[view]
    public fun vault_addr_of_pid(pid_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        smart_table::borrow(&registry.records, handle).apt_vault
    }

    #[view]
    public fun pool_seed_apt_amount(): u64 { POOL_SEED_APT_AMOUNT }

    #[view]
    public fun pool_seed_token_amount(): u64 { POOL_SEED_TOKEN_AMOUNT }

    // ============ CROSS-MODULE EMISSION (called by press) ============

    /// Press handler in `desnet::press` calls this to fire the reaction emission.
    /// Auth: caller passes pid_signer (ExtendRef-derived). Only `desnet::profile`
    /// friends can construct such a signer. Confirms caller controls a real PID.
    public fun emit_press_to_presser(
        pid_signer: &signer,
        recipient: address,
        post_id: vector<u8>,
        press_order: u64,
        supply_cap: u64,
    ): u64 acquires FactoryRegistry {
        let pid_addr = signer::address_of(pid_signer);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        let record = smart_table::borrow(&registry.records, handle);
        reaction_emission::emit_to_presser(
            record.reaction_reserve,
            recipient,
            post_id,
            press_order,
            supply_cap,
        )
    }
}
```

---

## `sources/profile.move`

```move
/// Profile — PID Object NFT primitive (LOCKED 2026-05-01).
///
/// PID = Profile ID. Aptos Object NFT, deterministic addr from wallet:
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
/// Atomic register_handle: derives PID Object → stores Profile → calls factory::create_token
/// to spawn $TOKEN and dual-vault for this PID.
///
/// sync_gate: opt-in `Profile.sync_gate: Option<ReferenceGate>` field. Gates incoming
/// Sync requests. NOT a privacy primitive — mints stay public; only Sync action gated.
///
/// Implicit-then-named magic: mention 0xBOB while bob is guest → bob registers later
/// → indexer auto-resolves historical mentions to @bob.
module desnet::profile {
    use std::bcs;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, TransferRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::reference_gate::{Self, ReferenceGate};
    use desnet::factory;
    use desnet::governance;

    friend desnet::mint;
    friend desnet::link;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;
    friend desnet::history;

    // ============ CONSTANTS ============

    const HANDLE_MIN_LEN: u64 = 1;
    const HANDLE_MAX_LEN: u64 = 64;

    /// Length-tier APT pricing (one-time, no renewal). Raw u64 (APT has 8 decimals).
    /// Tiers calibrated for APT≈$1: 100/50/20/10/5/1 APT.
    const PRICE_1_CHAR_APT: u64 = 10_000_000_000;     // 100 APT
    const PRICE_2_CHAR_APT: u64 =  5_000_000_000;     //  50 APT
    const PRICE_3_CHAR_APT: u64 =  2_000_000_000;     //  20 APT
    const PRICE_4_CHAR_APT: u64 =  1_000_000_000;     //  10 APT
    const PRICE_5_CHAR_APT: u64 =    500_000_000;     //   5 APT
    const PRICE_6PLUS_CHAR_APT: u64 = 100_000_000;    //   1 APT

    /// Caps for inline metadata at registration.
    const AVATAR_MAX_BYTES: u64 = 8192;       // ≤8KB inline (LOCKED)
    const BIO_MAX_BYTES: u64 = 333;           // ≤333B inline (LOCKED)

    const SEED_PID: vector<u8> = b"pid::";

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

    // ============ TYPES ============

    /// PID Profile resource at PID Object addr.
    struct Profile has key {
        handle: String,                            // bare lowercase, immutable post-reg
        controller: address,                       // hot wallet (delegated daily ops)
        signers_: SmartTable<vector<u8>, SignerEntry>,  // Ed25519 pubkey → metadata
        metadata_uri: String,                      // mutable, pointer to off-chain profile JSON
        avatar_blob_id: vector<u8>,                // mutable, Shelby/Walrus blob ref
        banner_blob_id: vector<u8>,                // mutable
        bio: String,                               // mutable, inline ≤333B
        sync_gate: Option<ReferenceGate>,          // opt-in node-membership policy
        extend_ref: ExtendRef,                     // for ExtendRef-derived signer (Opsi 1)
        registered_at_secs: u64,
    }

    /// Per-app signer registry entry. Controller-managed.
    struct SignerEntry has copy, drop, store {
        app_label: String,                         // human-readable identifier
        added_at_secs: u64,
        last_used_secs: u64,
    }

    /// PID NFT transferability vault — TransferRef stored separately so only
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
    /// handle (bare lowercase) → wallet (PID Object addr derivable from wallet).
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
        fee_paid_apt: u64,
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

    // ============ INIT — resource_account deploy pattern (mirror factory) ============

    /// APT FA metadata addr (Aptos paired-coin convention).
    const APT_FA_METADATA: address = @0xa;

    /// Init callback. The package SignerCapability is owned by
    /// `desnet::governance`; profile just initializes its singleton resources
    /// using the resource_account signer that Aptos passes in here.
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

    // ============ ADMIN — config updates (multisig → governance later) ============

    /// Admin updates fee_receiver. Used pre-handle_fee_vault to point fees somewhere.
    /// Post-vault upgrade, register_handle body bypasses this field — handle_fee_vault
    /// is the immutable destination. Kept here for v0.3.0 baseline; body becomes
    /// `abort 0` in v0.3.1 compat upgrade.
    public entry fun update_fee_receiver(
        admin: &signer,
        new_fee_receiver: address,
    ) acquires ProtocolState {
        // Gemini MED fix (audit R1): zero-addr check.
        assert!(new_fee_receiver != @0x0, E_INVALID_ADDRESS);
        let state = borrow_global_mut<ProtocolState>(@desnet);
        assert!(signer::address_of(admin) == state.admin, E_NOT_ADMIN);
        state.fee_receiver = new_fee_receiver;
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

    /// Pure fn — deterministic PID Object addr from wallet.
    /// Single canonical PID per wallet (constraint: same wallet cannot register multiple handles).
    #[view]
    public fun derive_pid_address(wallet: address): address {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
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

    /// Length-tier APT pricing. Returns raw u64 (8 decimals).
    public fun handle_fee_apt(handle_len: u64): u64 {
        if (handle_len == 1) PRICE_1_CHAR_APT
        else if (handle_len == 2) PRICE_2_CHAR_APT
        else if (handle_len == 3) PRICE_3_CHAR_APT
        else if (handle_len == 4) PRICE_4_CHAR_APT
        else if (handle_len == 5) PRICE_5_CHAR_APT
        else PRICE_6PLUS_CHAR_APT
    }

    // ============ REGISTER HANDLE — atomic with token spawn ============

    /// Atomic registration. Single-tx flow:
    ///   1. Validate handle (charset + length) + sizes (avatar ≤8KB, bio ≤333B)
    ///   2. Check uniqueness (handle not taken, PID Object addr not occupied)
    ///   3. Compute fee in D (length-tier 1-100), withdraw from wallet → fee_receiver
    ///   4. Create PID Object via protocol_signer at deterministic addr derive(wallet)
    ///   5. Generate ExtendRef + TransferRef
    ///   6. move_to Profile (controller, signers SmartTable, metadata, sync_gate=none)
    ///   7. move_to TransferVault (transfer_ref isolated from Profile fields)
    ///   8. Insert handle → wallet in HandleRegistry
    ///   9. Cross-package call factory::create_token(wallet, handle, pid_addr)
    ///       Factory atomically spawns $TOKEN FA + APT/D vaults + reaction/LP reserves;
    ///       deposits 5% creator allocation (50M $TOKEN) to pid_addr's primary store.
    ///  10. Emit HandleRegistered event
    ///
    /// Constraint: same wallet cannot register multiple handles. derive(wallet) is
    /// occupied for life. Multi-identity = multi-wallet (standard web3 hygiene).
    ///
    /// Sibling storage (PidMintMeta, PidSyncSet, etc.) NOT initialized here — sibling
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

        // Reserved handles — each bound to one specific claimer address (per-handle).
        // Prevents front-run squatting between package publish and project's claim tx.
        // Once claimed by the authorized addr, E_HANDLE_TAKEN takes over for any
        // subsequent attempt regardless of caller. PID-per-wallet constraint preserved
        // (each reserved handle has a different claimer addr → no PID collision).
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

        // 3. Fee in APT — withdraw from wallet, deposit to fee_receiver.
        //    Plus pool_seed_apt (5 APT) — withdrawn as separate FA, passed to factory
        //    for atomic AMM pool seed.
        //    Note: fee_receiver = @desnet at init. Compat upgrade adds handle_fee_vault
        //    that pulls fees from this primary store via migrate_legacy_fees + reroutes
        //    register_handle body to deposit directly to vault (post-upgrade body).
        let state = borrow_global<ProtocolState>(@desnet);
        let fee_raw = handle_fee_apt(vector::length(&handle));
        let apt_metadata = object::address_to_object<Metadata>(APT_FA_METADATA);
        if (fee_raw > 0) {
            let fee_fa = primary_fungible_store::withdraw(wallet, apt_metadata, fee_raw);
            primary_fungible_store::deposit(state.fee_receiver, fee_fa);
        };
        let pool_seed_amount = factory::pool_seed_apt_amount();
        let pool_seed_fa = primary_fungible_store::withdraw(wallet, apt_metadata, pool_seed_amount);

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
            avatar_blob_id: avatar_b64,            // inline base64 stored as bytes
            banner_blob_id: vector::empty(),
            bio: string::utf8(bio),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: now_secs,
        });

        // 7. TransferVault — transfer_ref isolated (controller cannot transfer NFT)
        move_to(&pid_signer, TransferVault { transfer_ref });

        // 7.5 Transfer Object ownership to wallet (NFT-style).
        // After create_named_object, initial owner = protocol_signer (creator).
        // Transfer to wallet so wallet becomes the PID NFT holder. ungated_transfer
        // remains enabled → marketplace-listable (Wapal/BlueMove/Tradeport).
        let pid_object = object::address_to_object<Profile>(pid_addr);
        object::transfer(&protocol_signer, pid_object, wallet_addr);

        // 8. Register handle → wallet mapping
        smart_table::add(&mut registry.handle_to_wallet, string::utf8(handle), wallet_addr);

        // 9. Atomic token + AMM pool + locked LP (factory).
        //    factory::create_token_atomic is friend-only (only desnet::profile may call),
        //    so APT collection above cannot be bypassed by external callers.
        factory::create_token_atomic(handle, pid_addr, &pid_signer, pool_seed_fa);

        // 10. Emit
        event::emit(HandleRegistered {
            handle: string::utf8(handle),
            wallet: wallet_addr,
            pid_addr,
            fee_paid_apt: fee_raw,
            timestamp_secs: now_secs,
        });
    }

    /// Reserved handle → authorized claimer. Each reserved handle has its OWN claimer
    /// address (different per handle to preserve PID-per-wallet uniqueness). Returns
    /// `Option::none` if handle is not reserved (= public registration).
    ///
    /// - "desnet" → @desnet_claimer (= @origin = deployer multisig)
    /// - "darbitex" → Darbitex Final publisher multisig 3/5 (cross-project)
    /// - "d" → D Aptos pkg (sealed resource_account, no signer ever — permanent burn)
    /// - "aptos" → Darbitex treasury multisig 3/5
    /// - "apt" → dedicated apt-claimer multisig
    fun reserved_handle_claimer(handle: &vector<u8>): option::Option<address> {
        let h = *handle;
        if (h == b"desnet")        option::some(@desnet_claimer)
        else if (h == b"darbitex") option::some(@darbitex_claimer)
        else if (h == b"d")        option::some(@d_claimer)
        else if (h == b"aptos")    option::some(@aptos_claimer)
        else if (h == b"apt")      option::some(@apt_claimer)
        else option::none()
    }

    fun make_pid_seed(wallet: address): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
        seed
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
        // Mirror register_handle's validation — caps must apply on both initial-set and update.
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
    /// Args flattened to primitives — Aptos entry fns can't take struct params.
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
        let gate = reference_gate::new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
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
    /// must NOT be reachable from controller (hot wallet) — controller compromise
    /// limited to social ops (Spark/Voice/etc), not financial drain. This is the
    /// inverse of the daily-ops-via-controller pattern: TREASURY = OWNER ALWAYS.
    ///
    /// Note: D vault dispurse goes directly to current NFT owner's WALLET (auto-resolved
    /// at settle), not to PID's primary store — so D dispurse income doesn't need
    /// withdraw_pid_token. This fn is for: creator allocation, donations, governance
    /// treasury, anything else accumulated at PID's primary store.
    ///
    /// Buyback-burn safety: structural — buyback portion lives at vault, never deposits
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
    /// Owner = address holding the Object NFT (per Aptos object framework).
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
    /// (owner emergency override path) — owner can revoke any signer even if controller
    /// is compromised.
    fun assert_controller_or_owner(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let profile = borrow_global<Profile>(pid_addr);
        if (profile.controller == caller_addr) return;
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(object::owner(pid_object) == caller_addr, E_NOT_CONTROLLER_OR_OWNER);
    }

    /// Internal — friend access for other DeSNet modules to assert PID exists at addr.
    public(friend) fun assert_pid_exists(pid_addr: address) {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
    }

    /// Internal — friend access for sync_gate evaluation in link.move.
    public(friend) fun get_sync_gate(pid_addr: address): Option<ReferenceGate> acquires Profile {
        if (!exists<Profile>(pid_addr)) return option::none();
        borrow_global<Profile>(pid_addr).sync_gate
    }

    /// Internal — friend helper for sibling modules' lazy-init pattern.
    /// Returns ExtendRef-derived signer of the PID Object so siblings can
    /// move_to their own storage resources at PID addr.
    /// Cycle prevention: profile.move doesn't `use` siblings; siblings declare
    /// no friend back. One-way dep: siblings → profile only.
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
        });
        pid_addr
    }

    // ============ TESTS ============

    #[test]
    fun test_handle_fee_apt_tiers() {
        assert!(handle_fee_apt(1) == PRICE_1_CHAR_APT, 1);     // 100 APT
        assert!(handle_fee_apt(2) == PRICE_2_CHAR_APT, 2);     //  50 APT
        assert!(handle_fee_apt(3) == PRICE_3_CHAR_APT, 3);     //  20 APT
        assert!(handle_fee_apt(4) == PRICE_4_CHAR_APT, 4);     //  10 APT
        assert!(handle_fee_apt(5) == PRICE_5_CHAR_APT, 5);     //   5 APT
        assert!(handle_fee_apt(6) == PRICE_6PLUS_CHAR_APT, 6); //   1 APT
        assert!(handle_fee_apt(64) == PRICE_6PLUS_CHAR_APT, 7);
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

// Suppress unused signature reference in skeleton — TransferVault wired during impl pass.
```

---

## `sources/amm.move`

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
    const WARNING: vector<u8> = b"DESNET AMM x*y=k. AI-audited only. Use at own risk.";

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
        let token_out_fa = swap_exact_apt_in(handle, apt_fa, min_out);
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
        let apt_out_fa = swap_exact_token_in(handle, token_fa, min_out);
        primary_fungible_store::deposit(caller_addr, apt_out_fa);
    }

    public fun swap_exact_apt_in(
        handle: vector<u8>,
        apt_in: FungibleAsset,
        min_out: u64,
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
            actor: @0x0,
            apt_to_token: true,
            amount_in,
            amount_out,
            fee_amount,
            new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
            new_token_reserve: fungible_asset::balance(pool.token_reserve),
        });

        token_out_fa
    }

    public fun swap_exact_token_in(
        handle: vector<u8>,
        token_in: FungibleAsset,
        min_out: u64,
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
            actor: @0x0,
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
        // Tests don't care about refunds; destroy them
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

## `sources/lp_staking.move`

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
                voter_history::record_reward_received(&pkg_signer, recipient, actual_paid);
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

## `sources/mint.move`

```move
/// Mint — the creation primitive (LOCKED 2026-05-01).
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
/// - content_text ≤ 333 bytes
/// - media: if Inline, data ≤ 8KB hard cap
/// - mentions ≤ 10 (any Aptos addr — flexible: PID/hex/ANS-resolved)
/// - tags ≤ 5, each 1-32 bytes lowercase a-z/0-9/-
/// - tickers ≤ 5, each MUST be factory-spawned FA (factory::is_factory_token assert)
/// - tips ≤ 10, each token MUST be FA-standard (no legacy coin)
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
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::reference_gate::{Self, ReferenceGate};
    use desnet::history;
    use desnet::assets;
    use desnet::factory;

    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS — caps locked 2026-05-01 ============

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
        inline_data: vector<u8>,           // if kind=Inline, ≤8KB
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
    /// Replaces former #[event] — now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct MintEvent has drop, store {
        author: address,                            // PID Object addr
        seq: u64,
        timestamp_us: u64,
        content_kind: u8,                           // type discriminator (text/etc)
        content_text: vector<u8>,                   // ≤333 bytes
        media: Option<MintMedia>,                   // optional inline OR ref
        parent_mint_id: Option<MintId>,             // Voice mode if Some
        root_mint_id: Option<MintId>,               // thread-head jump optimization
        quote_mint_id: Option<MintId>,              // Remix mode if Some
        mentions: vector<address>,                  // ≤10
        tags: vector<vector<u8>>,                   // ≤5, lowercase a-z/0-9/-
        tickers: vector<address>,                   // ≤5 factory-spawned FA addrs
        tips: vector<Tip>,                          // ≤10 atomic transfers
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

    // ============ LAZY-INIT — on-demand per-PID storage ============

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

    // ============ CREATE MINT — main entry ============

    /// Atomic mint creation with all optional extensions.
    /// Mode determined by parent_mint_id + quote_mint_id (caller passes None for unused).
    ///
    /// Tips (if any): each tip transfers from author's primary store to recipient
    /// in same tx. Tx aborts if any tip lacks balance — atomic all-or-nothing.
    public entry fun create_mint(
        author: &signer,
        content_kind: u8,
        content_text: vector<u8>,
        // Media (optional, packed as 4 args; caller passes empty vec for unused)
        media_kind: u8,                             // 0 = no media, else MEDIA_KIND_*
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        // Threading (caller passes 0/empty for None)
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        // Engagement vectors
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        // Tips (parallel arrays for Move 1.x compat — vector<Tip> at frontend builds)
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        // desnet::assets attached media (>8KB). When asset_master_set=true, overrides
        // media_* args: media auto-built with kind=Ref, backend=BACKEND_DESNET_ASSETS,
        // mime=assets::mime_of(asset_master_addr), ref_blob_id=bcs(asset_master_addr).
        asset_master_addr: address,
        asset_master_set: bool,
    ) acquires PidMintMeta {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // ============ Validate content + media ============

        assert!(vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES, E_CONTENT_TOO_LONG);

        let media: Option<MintMedia> = if (asset_master_set) {
            // desnet::assets path — Master must be sealed (immutable). MIME read from Master.
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

        // Execute tips atomically — abort whole mint if any fails
        let tips_vec = execute_tips(author, &tip_recipients, &tip_tokens, &tip_amounts, seq);

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
    }

    // ============ INTERNAL — tip execution ============

    fun execute_tips(
        author: &signer,
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
                from_pid: profile::derive_pid_address(signer::address_of(author)),
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

    // ============ INTERNAL — validators ============

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
    /// Args flattened to primitives — Aptos entry fns can't take struct params.
    public entry fun attach_mint_gate(
        author: &signer,
        seq: u64,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires PidMintMeta, PidMintExtras {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // Validate seq corresponds to a real mint by author
        assert!(seq < next_seq(author_pid), E_MINT_NOT_FOUND);

        let gate = reference_gate::new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
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

    // ============ INTERNAL — gate evaluation for friend modules ============

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
        vector::push_back(&mut tags, b"aptos-move");
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

## `sources/pulse.move`

```move
/// Pulse — reactions umbrella event (Spark + Echo) (LOCKED 2026-05-01).
///
/// Spark = like → reaction_kind=SPARK
/// Echo = repost forward-as-is → reaction_kind=ECHO
/// Voice (reply) and Remix (quote) live in mint.move (they create new MintEvents).
/// Press (NFT collectible) lives in press.move (different scope: NFT mint).
///
/// State pattern: PulseEvent { reaction_kind, state: ADD/REMOVE }. Aptos events
/// are append-only on emit — un-action emits state=REMOVE same kind. Asymmetric
/// "abort" pattern rejected (events immutable).
///
/// Mint-level gate (ReferenceGate) checked here before allowing reaction.
/// Self-exempt: mint creator always allowed (e.g., self-spark on own mint).
module desnet::pulse {
    use std::bcs;
    use std::signer;
    use std::option;
    use aptos_framework::timestamp;
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
    /// Keyed by (target_author, target_seq, reaction_kind) tuple → bool (ADD).
    /// SmartTable key encoded as packed bytes for compound key.
    struct PidReactionRegistry has key {
        // (target_author || target_seq || reaction_kind) bytes → true if currently active
        active: SmartTable<vector<u8>, bool>,
        spark_count_given: u64,
        echo_count_given: u64,
    }

    // ============ EVENTS ============

    /// Unified Pulse record for Spark + Echo. State ADD on first emit, REMOVE on un-action.
    /// Replaces former #[event] — now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct PulseEvent has drop, store {
        actor_pid: address,
        target_author: address,
        target_seq: u64,
        reaction_kind: u8,                // REACTION_SPARK | REACTION_ECHO
        state: u8,                        // STATE_ADD | STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

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
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        let actor_addr = signer::address_of(actor);
        let actor_pid = profile::derive_pid_address(actor_addr);
        profile::assert_pid_exists(actor_pid);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, true);
    }

    public entry fun unspark(
        actor: &signer,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        let actor_pid = profile::derive_pid_address(signer::address_of(actor));
        let key = make_key(target_author, target_seq, REACTION_SPARK);
        toggle_reaction(actor_pid, &key, REACTION_SPARK, target_author, target_seq, false);
    }

    // ============ ECHO + UNECHO ============

    public entry fun echo(
        actor: &signer,
        target_author: address,
        target_seq: u64,
        actor_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidReactionRegistry {
        let actor_addr = signer::address_of(actor);
        let actor_pid = profile::derive_pid_address(actor_addr);
        profile::assert_pid_exists(actor_pid);

        check_mint_gate_or_self_exempt(actor_addr, actor_pid, target_author, target_seq, actor_stake_position_addr);
        ensure_reaction_registry(actor_pid);

        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, true);
    }

    public entry fun unecho(
        actor: &signer,
        target_author: address,
        target_seq: u64,
    ) acquires PidReactionRegistry {
        let actor_pid = profile::derive_pid_address(signer::address_of(actor));
        let key = make_key(target_author, target_seq, REACTION_ECHO);
        toggle_reaction(actor_pid, &key, REACTION_ECHO, target_author, target_seq, false);
    }

    // ============ INTERNAL — gate + toggle ============

    /// Self-exempt comparison via PID (target_author is a PID addr).
    /// Sync check uses PID-space (link::is_synced takes PIDs).
    /// reference_gate::check uses WALLET addr (actor_addr) — semantic locked 2026-05-01:
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
        let target_pid = reference_gate::target_pid(option::borrow(&gate_opt));
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

## `sources/press.move`

```move
/// Press — NFT collectible wrapping a Mint (LOCKED 2026-05-01).
///
/// Vinyl-pressing metaphor: original recording (Mint) → physical vinyl (Press NFT).
/// Press IS technically a mint, but at NFT layer (different scope from Mint event).
///
/// Per-mint opt-in PressConfig (LOCKED):
///   - supply_cap: u16 (1-1000, no unlimited v1)
///   - window_days: u8 (1-7, no permanent open)
///   - emission curve: linear INCREASING per press order (anti-FOMO design):
///       emission(n) = n  (press #1 = 1 token, press #1000 = 1000 tokens)
///       Total per post: cap × (cap+1) / 2 (= 500,500 at cap=1000)
///
/// Per-actor uniqueness: each wallet can press a given mint ONLY once.
/// Author may self-press own mint, max 1 (same one-per-actor rule).
///
/// Royalty: 5% Aptos NFT v2 native, payee = PID Object addr (current owner).
/// Marketplace patuh otomatis. Future Press royalty 10% routed to vault (v2 spec).
///
/// First press = FREE (gas only). v1 tidak ada paid press; monetization = secondary market.
module desnet::press {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::event;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::timestamp;
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

    // ============ CONSTANTS ============

    const SUPPLY_CAP_MIN: u16 = 1;
    const SUPPLY_CAP_MAX: u16 = 1000;
    const WINDOW_DAYS_MIN: u8 = 1;
    const WINDOW_DAYS_MAX: u8 = 7;
    const ROYALTY_BPS: u64 = 500;            // 5% Aptos NFT v2 native

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
        pressed_by: SmartTable<address, bool>,  // actor → true after press
    }

    /// Per-author Press storage. SmartTable<seq, (PressConfig, PressedRegistry)>.
    struct PidPressStorage has key {
        configs: SmartTable<u64, PressConfig>,
        registries: SmartTable<u64, PressedRegistry>,
    }

    /// Per-author Press NFT Collection. Lazy-init at first press of any of author's mints.
    /// β-pattern (LOCKED 2026-04-30): "<handle>'s Presses" collection, all of author's
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

    /// Press record. Replaces former #[event] — now BCS-encoded into
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

    // ============ LAZY-INIT — on-demand per-PID storage ============

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

        // 5% royalty payee = author's Vault addr → marketplace royalties land at vault,
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
        // Empty URI — frontend constructs at render time. No hardcoded domain in source.
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
        // Empty URI — frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    /// Simple u64 → decimal String. Aptos stdlib doesn't have utoa, hand-roll.
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

    // ============ ENABLE PRESS — author opt-in per mint ============

    /// Author opts in to Press for a specific mint. Sets supply_cap + window.
    /// One-time per mint; cannot reconfigure after first press.
    public entry fun enable_press(
        author: &signer,
        mint_seq: u64,
        supply_cap: u16,
        window_days: u8,
    ) acquires PidPressStorage {
        assert!(supply_cap >= SUPPLY_CAP_MIN && supply_cap <= SUPPLY_CAP_MAX, E_INVALID_SUPPLY_CAP);
        assert!(window_days >= WINDOW_DAYS_MIN && window_days <= WINDOW_DAYS_MAX, E_INVALID_WINDOW_DAYS);

        let author_pid = profile::derive_pid_address(signer::address_of(author));
        profile::assert_pid_exists(author_pid);

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

    // ============ PRESS — anyone can press, gates checked ============

    /// Press a mint. Mints Aptos NFT v2 collectible to presser's wallet.
    /// Atomic: register press → mint NFT → emit event → emission bonus (if pool seeded).
    ///
    /// Validation chain:
    /// 1. PressConfig exists for (author_pid, mint_seq) — author opted in
    /// 2. Window not expired
    /// 3. Supply not exhausted
    /// 4. Per-actor uniqueness — presser hasn't pressed this mint before
    /// 5. Mint-level ReferenceGate (if any) passes for presser
    ///
    /// Emission bonus path: if author's $TOKEN/D pool seeded → mint emission(n) tokens
    /// to presser. If pool not seeded → press succeeds without emission. (LOCKED.)
    public entry fun press(
        presser: &signer,
        author_pid: address,
        mint_seq: u64,
        presser_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidPressStorage, PressCollection {
        let presser_addr = signer::address_of(presser);
        let presser_pid = profile::derive_pid_address(presser_addr);
        profile::assert_pid_exists(presser_pid);

        assert!(exists<PidPressStorage>(author_pid), E_PRESS_NOT_ENABLED);

        // Mint-level ReferenceGate (self-exempt: author always passes own gate).
        // Done before mut-borrow phase to keep storage scope pure.
        // Self-exempt via PID; gate check via wallet addr (presser_addr) per locked semantic
        // 2026-05-01: balance + LP-stake ownership at wallet that holds PID NFT.
        if (presser_pid != author_pid) {
            let gate_opt = mint::get_mint_gate(author_pid, mint_seq);
            if (option::is_some(&gate_opt)) {
                let target_pid = reference_gate::target_pid(option::borrow(&gate_opt));
                let synced = link::is_synced(presser_pid, target_pid);
                let gate = option::extract(&mut gate_opt);
                assert!(
                    reference_gate::check(&gate, presser_addr, synced, false, presser_stake_position_addr),
                    E_GATE_FAILED
                );
            };
        };

        // Validation phase — check + bump counters in mut-borrow scope
        let press_order: u16;
        let supply_cap: u16;        // captured for emission call below
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
            supply_cap = config.supply_cap;
            let emission_amount_local = press_order as u64;
            config.emission_consumed_total = config.emission_consumed_total + emission_amount_local;
        };  // PidPressStorage borrow released here

        // ============ NFT v2 mint ============

        // Lazy-init "<handle>'s Presses" Collection (β-pattern locked 2026-04-30).
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
        // ensure_press_collection), not collection_signer — otherwise derivation
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

        // Transfer to presser. token::create with pid_signer → token owned by author_pid.
        // pid_signer authorizes transfer to presser.
        object::transfer(&pid_signer, token_object, presser_addr);

        // ============ Emission bonus ============
        // Call factory wrapper which proxies to reaction_emission::emit_to_presser.
        // Returns actual amount distributed (≤ press_order × REACTION_BASE_VALUE; capped
        // at remaining reserve balance). Reserve depletion = emission 0 but press still
        // succeeds (graceful degradation).
        //
        // BLOCK self-press emission. NFT mint allowed (author can collect own work) but
        // emission to author's own wallet is denied — would let author drain their own
        // reaction reserve via single self-press. Per-actor uniqueness prevents multi-press
        // by same wallet; mint_seq validation above prevents bogus-seq farming.
        let emission_amount = if (presser_pid == author_pid) {
            0
        } else {
            // post_id encoding: bcs(author_pid) || bcs(mint_seq) — opaque to factory,
            // used for indexer correlation in ReactionEmitted event.
            let post_id = bcs::to_bytes(&author_pid);
            std::vector::append(&mut post_id, bcs::to_bytes(&mint_seq));
            factory::emit_press_to_presser(
                &pid_signer,
                presser_addr,
                post_id,
                (press_order as u64),
                (supply_cap as u64),
            )
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

## `sources/link.move`

```move
/// Link — Sync action + PidSyncSet on-chain state (LOCKED 2026-05-01).
///
/// Sync = subscribe to a PID's mints. Unidirectional like node-syncs-to-chain.
/// ENDORSE removed from link_kind enum (= derived view from LP staking position).
///
/// LinkEvent { link_kind: SYNC, state: ADD/REMOVE } — kept ADD/REMOVE pattern
/// (Aptos events immutable on emit; un-action emits state=REMOVE).
///
/// PidSyncSet at syncer's PID (NOT target's). Target has count only — popular
/// accounts can't afford full follower-list resource. Indexer derives "who syncs
/// me" from event stream.
///
/// sync_gate (profile-level) gates incoming Sync requests: must pass
/// ReferenceGate.check(actor, target_pid, skip_sync_check=true). Sync precondition
/// itself is skipped (chicken-egg avoidance — first sync to gated PID).
module desnet::link {
    use std::bcs;
    use std::signer;
    use std::option;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::reference_gate::{Self, ReferenceGate};
    use desnet::history;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS ============

    /// link_kind enum (LinkEvent.link_kind)
    const LINK_SYNC: u8 = 1;
    // ENDORSE removed 2026-05-01 — derived from LP staking, not on-chain link_kind.

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
    /// `syncs: SmartTable<target_pid, true>` — set semantic, value unused.
    struct PidSyncSet has key {
        syncs: SmartTable<address, bool>,
        sync_count: u64,                    // # of PIDs I sync (= len of syncs table)
        synced_by_count: u64,               // # of PIDs that sync to me (incremented externally via friend)
    }

    // ============ EVENTS ============

    /// Link record (Sync/Unsync). Replaces former #[event] — now BCS-encoded into
    /// history::Entry.payload. Struct retained for canonical encoding.
    struct LinkEvent has drop, store {
        actor_pid: address,
        target_pid: address,
        link_kind: u8,                      // LINK_SYNC only (others removed)
        state: u8,                          // STATE_ADD or STATE_REMOVE
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

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
        target_pid: address,
        syncer_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidSyncSet {
        let syncer_addr = signer::address_of(syncer);
        let syncer_pid = profile::derive_pid_address(syncer_addr);

        profile::assert_pid_exists(syncer_pid);
        profile::assert_pid_exists(target_pid);
        assert!(syncer_pid != target_pid, E_SELF_SYNC_DISALLOWED);

        // sync_gate check — skip_sync_check=true (chicken-egg avoidance: can't require
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
        target_pid: address,
    ) acquires PidSyncSet {
        let syncer_addr = signer::address_of(syncer);
        let syncer_pid = profile::derive_pid_address(syncer_addr);

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

## `sources/history.move`

```move
/// History — per-PID append-only on-chain log (LOCKED 2026-05-01).
///
/// Replaces event::emit for the 7-verb palette (Mint/Spark/Voice/Echo/Remix/Press/Sync).
/// Class-B primitive: Move runtime CAN read entries via view fns for gating logic
/// (Endorse, ReferenceGate cross-checks) without indexer dependency.
///
/// Storage: HistoryLog at PID Object addr (lazy-init via profile::derive_pid_signer).
/// Entries grouped into HistoryChunks (separate Objects owned by PID); current chunk
/// rotates when ~30KB threshold reached. Sealed chunks immutable from this module.
///
/// Cached counters per verb (O(1) view) — count_verb(pid, verb) for gating.
///
/// Encoding: Entry.payload = BCS-encoded verb-specific data (e.g., bcs::to_bytes(&MintEvent{..})).
/// Frontend / indexer decodes payload via Move struct definitions in respective modules.
module desnet::history {
    use std::option::Option;
    use std::signer;
    use std::vector;
    use aptos_framework::object;

    use desnet::profile;

    friend desnet::mint;
    friend desnet::pulse;
    friend desnet::link;
    friend desnet::press;

    // ============ CONSTANTS ============

    /// Verb enum (history Entry.verb).
    const VERB_MINT: u8 = 0;
    const VERB_SPARK: u8 = 1;
    const VERB_VOICE: u8 = 2;
    const VERB_ECHO: u8 = 3;
    const VERB_REMIX: u8 = 4;
    const VERB_PRESS: u8 = 5;
    const VERB_SYNC: u8 = 6;

    /// Chunk rotation threshold: when current chunk's tracked size exceeds this,
    /// seal it and allocate a new one. ~30KB ≈ 375 small entries.
    const CHUNK_ROTATE_THRESHOLD: u64 = 30000;

    /// Per-Entry payload hard cap (BCS bytes only; Entry.asset is separate ref).
    /// Sized to fit worst-case BCS-encoded MintEvent: inline media (8192) + content (333) +
    /// 5 tags + 10 mentions + 5 tickers + 10 tips + Option overhead ≈ 10075 bytes. 12000
    /// gives 1925-byte headroom. CHUNK_ROTATE_THRESHOLD (30000) still > 2× this so chunk
    /// rotation calculus remains sane.
    const MAX_PAYLOAD_BYTES: u64 = 12000;

    /// Per-entry overhead estimate (verb + ts + target option + asset option +
    /// vector length headers). Used for chunk size accounting.
    const ENTRY_OVERHEAD_BYTES: u64 = 64;

    // ============ ERROR CODES ============

    const E_PAYLOAD_TOO_LARGE: u64 = 1;
    // E_PID_NOT_FOUND removed (was unused — profile module owns PID-existence checks).
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
        payload: vector<u8>,               // BCS-encoded verb-specific data, ≤MAX_PAYLOAD_BYTES
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
        assert!(verb <= VERB_SYNC, E_INVALID_VERB);
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

    /// Cached per-verb counter — O(1) for gating logic.
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
        let _e = new_entry(7, 0, std::option::none<address>(), vector::empty(), std::option::none<address>());
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
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use std::option;

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
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

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
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

    #[test(framework = @aptos_framework, creator = @0xa11ce)]
    fun test_history_chunk_rotates_at_threshold(framework: &signer, creator: &signer)
        acquires HistoryLog, HistoryChunk
    {
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(signer::address_of(creator));
        let pid_addr = profile::setup_test_pid(creator);

        // Each entry: 8000B payload + 64B overhead = 8064B. Threshold = 30000B.
        // 3 entries: 24192B (under). 4th append: would-be 32256B > 30000 → rotate fires.
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

## `sources/assets.move`

```move
/// Assets — fractal-tree on-chain storage for media >8KB (LOCKED 2026-05-01).
///
/// Class-A primitive: bytes are stored on-chain so client loaders can reassemble,
/// but Move runtime never reads payload bytes (only references via Master addr).
///
/// Storage model: file split into ≤30KB Chunks. Single chunk → depth=0, root=chunk_addr.
/// Multiple chunks → grouped under Node(s), recursively until single root Node.
/// Master records (root, depth, total_size, mime). After finalize() Master.sealed=true,
/// no further mutation allowed via this module.
///
/// MIME whitelist (aligned with mint.move): PNG/JPEG/GIF/WebP/SVG. SVG INCLUDED
/// 2026-05-01 for on-chain generative art — XSS = frontend responsibility via
/// <img>-tag sandbox.
/// MAX_TOTAL_SIZE = 5MB hard cap. CHUNK_SIZE_MAX = 30000 bytes.
///
/// Asset ownership = anyone-can-reference (sealed Master is public good — Echo/Remix
/// can attach any sealed Master regardless of creator). Defamation/illegal-content
/// moderation = frontend responsibility, not protocol.
module desnet::assets {
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::object;
    use aptos_framework::timestamp;

    // ============ CONSTANTS ============

    const CHUNK_SIZE_MAX: u64 = 30000;
    const MAX_TOTAL_SIZE: u64 = 5_000_000;     // 5MB

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

    // ============ TYPES ============

    /// Master record at Master Object addr. Tracks asset metadata + sealed status.
    /// After finalize(), sealed=true and root/depth set; module mutators abort.
    /// **anyone-can-REFERENCE** semantic applies POST-FINALIZE only (sealed Master is
    /// public good for Echo/Remix). DURING upload, only `creator_addr` may deploy
    /// chunks/nodes and finalize — prevents asymmetric DoS griefing where an attacker
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

    /// Leaf chunk — bytes payload ≤30KB. Created via deploy_chunk.
    struct Chunk has key {
        data: vector<u8>,
    }

    /// Internal node (tree depth ≥1) — vector of child addresses (chunks or sub-nodes).
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
    public entry fun start_upload(
        uploader: &signer,
        mime: u8,
        total_size: u64,
        creator_pid: address,
    ) {
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
    }

    // ============ ENTRY: deploy_chunk ============

    /// Deploy a leaf chunk (≤30KB). Master must exist and not be sealed.
    /// Returns chunk_addr via emitted event.
    public entry fun deploy_chunk(
        uploader: &signer,
        master_addr: address,
        data: vector<u8>,
    ) acquires Master {
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
    }

    // ============ ENTRY: deploy_node ============

    /// Deploy an internal Node pointing to children (chunk addrs or sub-node addrs).
    /// Used for tree depth ≥1. Master must not be sealed.
    /// Returns node_addr via emitted event.
    public entry fun deploy_node(
        uploader: &signer,
        master_addr: address,
        children: vector<address>,
    ) acquires Master {
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
    }

    // ============ ENTRY: finalize ============

    /// Finalize Master: set root + depth, mark sealed=true. After this, the asset
    /// is permanently immutable from this module's perspective.
    /// Caller is responsible for having deployed root chunk/node beforehand.
    public entry fun finalize(
        uploader: &signer,
        master_addr: address,
        root: address,
        depth: u8,
    ) acquires Master {
        assert!(exists<Master>(master_addr), E_MASTER_NOT_FOUND);
        let master = borrow_global_mut<Master>(master_addr);
        assert!(!master.sealed, E_MASTER_SEALED);
        // CRITICAL auth: only the master's creator may finalize. Without this check,
        // any address could seal another's unsealed master with bogus root → permanent
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
        aptos_framework::account::create_account_for_test(signer::address_of(uploader));
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
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

    #[test(framework = @aptos_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_finalize_rejects_non_creator_A2_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        aptos_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_JPEG, 100, @0xfeed);
        // Attacker tries to finalize with bogus root — must fail per A2 fix.
        finalize(attacker, master_addr, @0xdeadbeef, 0);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce, attacker = @0xbad)]
    #[expected_failure(abort_code = E_NOT_CREATOR, location = Self)]
    fun test_deploy_chunk_rejects_non_creator_A3_regression(
        framework: &signer,
        uploader: &signer,
        attacker: &signer,
    ) acquires Master {
        setup_test_env(framework, uploader);
        aptos_framework::account::create_account_for_test(signer::address_of(attacker));

        let master_addr = start_upload_for_test(uploader, MIME_GIF, 100, @0xfeed);
        let data = vector::empty<u8>();
        vector::push_back(&mut data, 0x42);
        // Attacker deploys chunk for victim's master — must fail.
        deploy_chunk_for_test(attacker, master_addr, data);
    }

    #[test(framework = @aptos_framework, uploader = @0xa11ce)]
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
        // 5MB+1 byte → reject
        start_upload_for_test(uploader, MIME_SVG, 5_000_001, @0xfeed);
    }
}
```

---

## `sources/apt_vault.move`

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

    use desnet::amm;

    friend desnet::factory;

    // ============ CONSTANTS ============

    /// Min APT balance for settle to execute (anti-dust). 0.1 APT (8 decimals).
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 3;

    const SEED_VAULT: vector<u8> = b"vault::";

    /// H3 fix (audit R1): slippage tolerance for settle buyback.
    /// 300 bps = 3% — bounds single-tx sandwich loss. Larger drift = abort,
    /// settle re-callable later when pool recovers.
    const SETTLE_SLIPPAGE_BPS: u64 = 300;
    const BPS_DENOM: u64 = 10000;

    // ============ ERROR CODES ============

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_SWAP_FAILED: u64 = 3;
    const E_BURN_FAILED: u64 = 4;
    const E_POOL_ADDR_DRIFT: u64 = 5;

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

    // ============ SETTLE — permissionless ============

    /// Always 50/50 (pool always seeded atomically at register_handle).
    /// H3 fix (audit R1): swap uses 3% slippage tolerance to bound sandwich attacks.
    /// M5 fix: assert cached amm_pool_addr matches current handle-derived addr.
    public entry fun settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        // M5: cache consistency check
        assert!(
            amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
            E_POOL_ADDR_DRIFT
        );

        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        let buyback_amount = total_apt / 2;
        let owner_amount = total_apt - buyback_amount;

        // H3: compute expected output + apply 3% tolerance as min_out.
        let (apt_reserve, token_reserve) = amm::reserves(vault.handle);
        let expected_out = amm::compute_amount_out(apt_reserve, token_reserve, buyback_amount);
        let min_out = (expected_out * (BPS_DENOM - SETTLE_SLIPPAGE_BPS)) / BPS_DENOM;

        let apt_for_buyback = coin::extract(&mut vault.apt_balance, buyback_amount);
        let apt_for_owner = coin::extract(&mut vault.apt_balance, owner_amount);

        // Buyback path: APT → $TOKEN via in-house AMM 10 bps, then BURN.
        let apt_fa_buyback = coin::coin_to_fungible_asset(apt_for_buyback);
        let token_received = amm::swap_exact_apt_in(
            vault.handle,
            apt_fa_buyback,
            min_out,
        );
        let burned_amount = fungible_asset::amount(&token_received);
        fungible_asset::burn(&vault.burn_ref, token_received);

        // Owner path: APT direct to current PID owner.
        coin::deposit(owner_addr, apt_for_owner);

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
}
```

---

## `sources/lp_emission.move`

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

## `sources/reaction_emission.move`

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

## `sources/reference_gate.move`

```move
/// ReferenceGate — opt-in engagement policy primitive (LOCKED 2026-05-01).
///
/// Single primitive, 4 fields. Used by:
/// - Mint-level: gates Voice/Spark/Echo/Remix/Press of specific mint
/// - Profile-level (sync_gate): gates incoming Sync requests
///
/// Logic at gate check (ALL conditions must hold):
/// 1. actor.synced_to(target_pid) — sync precondition (SKIPPED for sync_gate itself, chicken-egg)
/// 2. min_token_balance ≤ actor.token_balance(target_pid_token) ≤ max_token_balance
/// 3. actor.lp_stake_balance(target_pid_lp_pool) ≥ min_lp_stake
///
/// Self-exemption: post creator always passes own gate (intuitive, prevents lock-out).
/// Sentinels for "no check": min=0, max=u64::MAX, lp_stake=0.
///
/// Cycle-safe API: caller pre-computes sync state (via link::is_synced) and passes
/// as param. reference_gate doesn't import link (would create cycle since link uses
/// reference_gate for sync_gate evaluation). Pure function design — caller orchestrates queries.
///
/// Naming consistency: ReferenceGate + MintGate + sync_gate = unified gate-family.
module desnet::reference_gate {
    use std::option::{Self, Option};
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ObjectCore};
    use aptos_framework::primary_fungible_store;

    use desnet::factory;
    use desnet::lp_staking;

    // ============ ERROR CODES ============

    const E_TARGET_HAS_NO_TOKEN: u64 = 2;

    /// Single 4-field primitive struct. Stored as Option<ReferenceGate> at attach points.
    struct ReferenceGate has copy, drop, store {
        target_pid: address,           // PID whose sync + token + LP-stake to check
        min_token_balance: u64,        // 0 = no spot-balance check
        max_token_balance: u64,        // u64::MAX = no max
        min_lp_stake: u64,             // 0 = no LP-stake check
    }

    /// Constructor — frontend assembles before attach call.
    public fun new(
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ): ReferenceGate {
        ReferenceGate {
            target_pid,
            min_token_balance,
            max_token_balance,
            min_lp_stake,
        }
    }

    public fun target_pid(gate: &ReferenceGate): address { gate.target_pid }
    public fun min_token_balance(gate: &ReferenceGate): u64 { gate.min_token_balance }
    public fun max_token_balance(gate: &ReferenceGate): u64 { gate.max_token_balance }
    public fun min_lp_stake(gate: &ReferenceGate): u64 { gate.min_lp_stake }

    /// Evaluate gate against an actor.
    ///
    /// `actor_synced_to_target` must be pre-computed by caller via `link::is_synced(actor_pid, gate.target_pid)`.
    /// reference_gate doesn't query link directly (would cycle since link uses reference_gate for sync_gate).
    ///
    /// `skip_sync_check=true` for profile sync_gate path (chicken-egg avoidance: gating Sync
    /// itself can't require sync precondition). For mint-level engagement gates, false.
    ///
    /// `actor_stake_position_addr`: caller-supplied `desnet::lp_staking::Position` addr. Pass `@0x0`
    /// when gate has no LP requirement OR actor has no position. When `gate.min_lp_stake > 0`
    /// and actor passes `@0x0`, gate fails (returns false). Multi-position holders pass their
    /// largest single position; protocol does not enumerate or sum across positions.
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
        let no_min = gate.min_token_balance == 0;
        let no_max = gate.max_token_balance == 18446744073709551615u64;  // u64::MAX
        if (!(no_min && no_max)) {
            // Resolve target's token via factory reverse lookup
            if (!factory::owner_has_token(gate.target_pid)) {
                // Target PID has no factory-spawned token → balance check impossible
                return false
            };
            let token_addr = factory::token_metadata_of_owner(gate.target_pid);
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let balance = primary_fungible_store::balance(actor_addr, token_metadata);
            if (balance < gate.min_token_balance) return false;
            if (balance > gate.max_token_balance) return false;
        };

        // 3. LP stake check (via desnet::lp_staking::Position)
        // Caller-supplied evidence pattern: actor passes their Position addr.
        // Trust-but-verify: we check pool linkage + ownership/recipient + shares.
        if (gate.min_lp_stake > 0) {
            if (actor_stake_position_addr == @0x0) return false;
            if (!lp_staking::has_position(actor_stake_position_addr)) return false;

            // Pool linkage: position's pool must match target_pid's lp_staking_pool
            if (!factory::owner_has_token(gate.target_pid)) return false;
            let expected_pool = factory::lp_staking_pool_of_owner(gate.target_pid);
            let pos_pool = lp_staking::position_pool(actor_stake_position_addr);
            if (pos_pool != expected_pool) return false;

            // Ownership: free/time-locked → object::owner(position) == actor.
            // Locked (recipient_pid != @0x0) → current PID owner == actor.
            let recipient_pid = lp_staking::position_recipient_pid(actor_stake_position_addr);
            if (recipient_pid == @0x0) {
                if (lp_staking::position_owner(actor_stake_position_addr) != actor_addr) return false;
            } else {
                let pid_obj = object::address_to_object<ObjectCore>(recipient_pid);
                if (object::owner(pid_obj) != actor_addr) return false;
            };

            // Shares ≥ threshold (u128 to u64 comparison)
            let shares = lp_staking::position_shares(actor_stake_position_addr);
            if (shares < (gate.min_lp_stake as u128)) return false;
        };

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
        let g = new(@0xfeed, 100, 1000, 50);
        assert!(target_pid(&g) == @0xfeed, 1);
        assert!(min_token_balance(&g) == 100, 2);
        assert!(max_token_balance(&g) == 1000, 3);
        assert!(min_lp_stake(&g) == 50, 4);
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
        // Gate with sentinel min/max balance + zero lp_stake → only sync matters
        let g = new(@0xfeed, 0, 18446744073709551615u64, 0);
        // Actor not synced + skip_sync_check=false → fail
        assert!(!check(&g, @0x1, false, false, @0x0), 1);
    }

    #[test]
    fun test_check_sync_skipped_passes_no_other_constraints() {
        // skip_sync_check=true (sync_gate path) + sentinels for balance + 0 lp_stake → pass
        let g = new(@0xfeed, 0, 18446744073709551615u64, 0);
        assert!(check(&g, @0x1, false, true, @0x0), 1);
    }
}
```

---

## `sources/giveaway.move`

```move
/// Giveaway — opt-in attached giveaway primitive (LOCKED 2026-05-01).
///
/// Two types: FA (fungible token, fixed amount per claim) + NFT (FCFS sequential).
/// Token scope = AGNOSTIC (any FA, any NFT collection — NOT factory-only).
///
/// Three optional gates (independent opt-in):
/// - follower_only: synced to sponsor
/// - nft_gate: NFT collection holder
/// - lp_stake_gate: LP staker in target_pid's pool (Endorse-tier integration)
///
/// Default = PID-only claim (tier model enforces guest exclusion — claim = write action).
/// NO citizen_only / guest_allowed field (redundant).
/// NO min_reputation field v1 (deferred until reputation primitive lands).
///
/// Refund flow: post-deadline permissionless `settle_giveaway(mint_id)` destroys
/// SmartTable, refunds unclaimed budget to sponsor, pays caller 5 bps bounty (FA mode)
/// or no bounty (NFT mode — sponsor incentive enough).
module desnet::giveaway {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef, Object, ObjectCore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
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
        // Per-actor dedup (PID Object addr → true)
        claimers: SmartTable<address, bool>,
        // Object signer (escrow holds funds for FA mode at this Object's primary store)
        extend_ref: ExtendRef,
    }

    /// Per-PID giveaway storage. SmartTable<mint_seq, Giveaway addr>.
    /// Each Giveaway lives at its own Object addr (escrow holds funds).
    struct PidGiveawayStorage has key {
        giveaways: SmartTable<u64, address>,  // mint_seq → giveaway Object addr
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

    // ============ CREATE — FA mode ============

    /// Sponsor creates FA giveaway attached to their mint. Atomic: deposits
    /// total_budget into giveaway escrow, registers under PidGiveawayStorage.
    public entry fun create_fa_giveaway(
        sponsor: &signer,
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
        let sponsor_addr = signer::address_of(sponsor);
        let sponsor_pid = profile::derive_pid_address(sponsor_addr);
        profile::assert_pid_exists(sponsor_pid);

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

    // ============ CREATE — NFT mode ============

    /// Sponsor creates NFT giveaway. Sponsor passes pre-collected NFT Object addrs
    /// in FCFS order. Each claim transfers next NFT in vector to claimer.
    /// **ATOMIC ESCROW (LOCKED 2026-05-01)**: at create-time, sponsor must own ALL NFTs
    /// in `nft_addrs`. Each is verified + transferred to `giveaway_addr` in this tx.
    /// Aborts whole tx if any NFT not owned by sponsor (no partial-escrow state).
    public entry fun create_nft_giveaway(
        sponsor: &signer,
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
        let sponsor_addr = signer::address_of(sponsor);
        let sponsor_pid = profile::derive_pid_address(sponsor_addr);
        profile::assert_pid_exists(sponsor_pid);

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
        giveaway_addr: address,
        claimer_nft_proof_addr: address,
        claimer_stake_position_addr: address,
    ) acquires Giveaway {
        let claimer_addr = signer::address_of(claimer);
        let claimer_pid = profile::derive_pid_address(claimer_addr);
        profile::assert_pid_exists(claimer_pid);

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

    // ============ SETTLE — permissionless post-deadline ============

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
        // Storage refund deferred — minor cost, idempotent re-settle returns 0/0.

        event::emit(GiveawaySettled {
            giveaway_addr,
            sponsor_pid: giveaway.sponsor_pid,
            settler: settler_addr,
            refund_amount,
            bounty_paid: bounty,
            timestamp_secs: now,
        });
    }

    // ============ INTERNAL — gate checks ============

    /// Three independent gates (LOCKED 2026-05-01: BUKAN unified ReferenceGate — different
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
        // 1. follower_only — claimer must be synced to sponsor's PID
        if (giveaway.follower_only) {
            assert!(
                link::is_synced(claimer_pid, giveaway.sponsor_pid),
                E_FOLLOWER_GATE_FAILED
            );
        };

        // 2. nft_gate — claimer must hold ≥1 NFT in the required collection
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

        // 3. lp_stake_gate — claimer must hold a Position on the required pool with shares > 0.
        // Ownership: free/time-locked → staker == claimer_addr; locked (creator's perma-lock) →
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

    // ============ LAZY-INIT — on-demand per-PID storage ============

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
}
```

---

## `sources/voter_history.move`

```move
/// Voter History — per-voter cumulative LP staking rewards record.
///
/// CRITICAL — voting power source authentication:
///
/// `record_reward_received` is the SOLE pathway for voting power generation. Called
/// EXCLUSIVELY by `desnet::lp_staking::claim_internal` after pulling emission from
/// the LP emission reserve. Other DESNET inflows (market buy, transfer, third-party
/// reward streams added to LP pool, cross-token rewards, etc.) do NOT populate this
/// history and do NOT count toward voting power.
///
/// Cross-module authentication via signer addr check:
///   record_reward_received(authority, voter, amount) asserts
///   signer::address_of(authority) == @desnet
///
/// Storage: centralized SmartTable<voter_addr, VoterHistory> at @desnet.
module desnet::voter_history {
    use std::signer;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    friend desnet::governance;
    friend desnet::lp_staking;

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

    // ============ INIT — called once by governance::init_module ============

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

    // ============ RECORD — called EXCLUSIVELY by desnet::lp_staking::claim_internal ============

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

        // Lazy-init voter entry on first reward (no voter signer required —
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

    // ============ PRUNE — permissionless storage bound ============

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
