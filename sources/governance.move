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
    /// v0.3.2 (F2): chunked-publish defense-in-depth — at least one module slot empty.
    const E_INCOMPLETE_CHUNKS: u64 = 23;
    /// v0.3.3 (G2): caller is not the original DAO stager for this proposal.
    const E_NOT_STAGER: u64 = 24;
    /// v0.3.2 (F6): 30-day rolling emission tracker constants.
    const SECONDS_PER_DAY: u64 = 86400;
    const ROLLING_WINDOW_DAYS: u64 = 30;
    /// v0.3.1 Item 3b: hardcoded DESNET FA addr — eliminates manipulation surface.
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
    /// multisig `UpgradeStaging` — DAO + multisig paths can no longer collide.
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

    /// v0.3.2 (F3): emitted on cleanup_upgrade_staging — observability for indexers.
    #[event]
    struct UpgradeStagingCleanup has drop, store {
        multisig: address,
        timestamp_secs: u64,
    }

    // ============ INIT — called by resource_account at deploy ============

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
    /// chunks order — final chunk landed by `multisig_publish_chunked_upgrade`.
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
        // v0.3.2 (F2): defense-in-depth — reject incomplete staging (any empty slot).
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
    /// digest equals `expected_digest` parameter — pin the hash off-chain (e.g., from a
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
            // Stale entry from prior cycle — reset before adding.
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
    /// `state.total_30d_emission` permanently ignored — eliminates latent overflow
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
    /// variant `compute_upgrade_digest_view`). Any other scheme — including the
    /// natural BCS encoding of the tuple `(metadata, code_bytes)` — produces a
    /// different digest, and the proposal will fail at `execute_proposal` with
    /// `E_HASH_MISMATCH` after the timelock window has elapsed.
    public entry fun propose_upgrade(
        proposer: &signer,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
    ) acquires GovernanceState, Emission30dRollingBucket {
        // v0.3.2 (F14, R2 Kimi R2-N1): defense-in-depth — only @desnet pkg upgrades
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
    //   2. Anyone calls `dao_publish_chunked_upgrade(proposal_id, last_chunk, ...)` —
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
                // Same proposal — must be original stager (anti-grief append).
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
        // Re-verify (defense-in-depth — staging may span days; conditions can change).
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

        // Defense-in-depth — same empty-slot check as multisig variant.
        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };

        // Verify assembled payload matches the hash voters approved.
        // v0.3.3 NOTE: on hash-fail, abort reverts entire tx including the move_from above
        // → DaoUpgradeStaging stays UNTOUCHED (Move atomicity), so legitimate publisher can
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
    /// wrapper, callable via `/v1/view`) — this reference variant is for on-chain use.
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
    /// rewards isolation) deferred to v0.3.2 — until then, voting power = min(LP-stake-
    /// earned-mixed, DESNET balance). Cross-token reward claims still inflate first
    /// term but bound by DESNET balance.
    /// v0.3.3 (G1, R5 CONV-3 HIGH fix): per-USER fallback eliminates lazy-flip
    /// disenfranchisement. Previous v0.3.2 logic checked GLOBAL `has_per_token_registry`
    /// — first claimer post-v0.3.2 flipped the flag for everyone, instantly zeroing
    /// voting_power for all other pre-existing voters until they claimed themselves.
    /// New logic: per-user — read per-token if THIS voter has a per-token entry; else
    /// fall back to legacy mixed for THIS voter. Each voter migrates individually
    /// when they next claim. No cross-voter flip event.
    ///
    /// v0.3.3 R6 NOTE (Qwen H1 vs Claude analysis): Qwen flagged that voter who
    /// claims only non-DESNET (e.g., $alice) gets has_per_token_entry==true →
    /// DESNET-only branch returns 0 → voting_power=0. Initial fix used per-token
    /// DESNET-specific check, but Claude correctly identified this would re-open
    /// the F7 cross-token inflation surface (legacy includes mixed). REVERTED to
    /// generic per-user check — F7-strict semantic preserved. A voter who claims
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
