module desnet::governance {
    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::code;
    use supra_framework::event;
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

    const PROPOSAL_THRESHOLD_BPS: u64 = 500;
    const QUORUM_BPS: u64 = 3500;
    const APPROVAL_THRESHOLD_BPS: u64 = 7000;
    const VOTING_PERIOD_SECS: u64 = 7 * 86_400;
    const TIMELOCK_SECS: u64 = 30 * 86_400;

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
    const E_ARGS_LEN_MISMATCH: u64 = 21;
    const E_NEUTERED: u64 = 22;
    const E_INCOMPLETE_CHUNKS: u64 = 23;
    const E_NOT_STAGER: u64 = 24;
    const SECONDS_PER_DAY: u64 = 86400;
    const ROLLING_WINDOW_DAYS: u64 = 30;
    const DESNET_FA_ADDR: address = @0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7;

    struct GovernanceState has key {
        signer_cap: SignerCapability,
        proposal_count: u64,
        proposals: SmartTable<u64, Proposal>,
        desnet_fa_metadata: address,
        native_fa_metadata: address,
        total_30d_emission: u64,
        multisig_upgrade_disabled: bool,
    }

    struct Proposal has store {
        id: u64,
        proposer: address,
        target_package_addr: address,
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

    struct UpgradeStaging has key, drop {
        metadata: vector<u8>,
        code: vector<vector<u8>>,
    }

    struct DaoUpgradeStaging has key, drop {
        proposal_id: u64,
        stager: address,
        metadata: vector<u8>,
        code: vector<vector<u8>>,
    }

    struct Emission30dRollingBucket has key {
        daily_amounts: vector<u64>,
        daily_day_nums: vector<u64>,
    }

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

    #[event]
    struct UpgradeStagingCleanup has drop, store {
        multisig: address,
        timestamp_secs: u64,
    }

    fun init_module(account: &signer) {
        let signer_cap = publisher::take_cap_for_desnet(account);
        let governance_addr = signer::address_of(account);

        move_to(account, GovernanceState {
            signer_cap,
            proposal_count: 0,
            proposals: smart_table::new(),
            desnet_fa_metadata: @0x0,
            native_fa_metadata: @0xa,
            total_30d_emission: 0,
            multisig_upgrade_disabled: false,
        });

        voter_history::init_registry(account);

        event::emit(GovernanceInitialized {
            governance_addr,
            deployer: @origin,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun native_fa_metadata(): address acquires GovernanceState {
        borrow_global<GovernanceState>(@desnet).native_fa_metadata
    }

    public(friend) fun derive_pkg_signer(): signer acquires GovernanceState {
        let state = borrow_global<GovernanceState>(@desnet);
        account::create_signer_with_capability(&state.signer_cap)
    }

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

    public entry fun disable_multisig_upgrade(multisig: &signer) acquires GovernanceState {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        borrow_global_mut<GovernanceState>(@desnet).multisig_upgrade_disabled = true;
        event::emit(MultisigUpgradeDisabled {
            disabled_by: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

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
        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };
        let assembled_digest = compute_upgrade_digest(&metadata, &code);
        assert!(assembled_digest == expected_digest, E_HASH_MISMATCH);
        code::publish_package_txn(&pkg_signer, metadata, code);
        event::emit(MultisigUpgrade {
            multisig: signer::address_of(multisig),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    public entry fun cleanup_upgrade_staging(multisig: &signer) acquires UpgradeStaging {
        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
        if (exists<UpgradeStaging>(@desnet)) {
            let _ = move_from<UpgradeStaging>(@desnet);
            event::emit(UpgradeStagingCleanup {
                multisig: signer::address_of(multisig),
                timestamp_secs: timestamp::now_seconds(),
            });
        };
    }

    #[view]
    public fun upgrade_staging_exists(): bool { exists<UpgradeStaging>(@desnet) }

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
            *vector::borrow_mut(&mut tracker.daily_amounts, idx) = 0;
            *vector::borrow_mut(&mut tracker.daily_day_nums, idx) = day;
        };
        let cur = *vector::borrow(&tracker.daily_amounts, idx);
        let new_val = if (cur > 18446744073709551615u64 - amount) {
            18446744073709551615u64
        } else {
            cur + amount
        };
        *vector::borrow_mut(&mut tracker.daily_amounts, idx) = new_val;
    }

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

    fun effective_30d_emission(): u64 acquires GovernanceState, Emission30dRollingBucket {
        let _ = borrow_global<GovernanceState>(@desnet);
        total_30d_emission_auto()
    }

    #[view]
    public fun effective_30d_emission_view(): u64 acquires GovernanceState, Emission30dRollingBucket {
        effective_30d_emission()
    }

    public entry fun propose_upgrade(
        proposer: &signer,
        target_package_addr: address,
        new_module_bytes_hash: vector<u8>,
    ) acquires GovernanceState, Emission30dRollingBucket {
        assert!(target_package_addr == @desnet, E_INVALID_ADDRESS);

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

    public entry fun ratify(
        _caller: &signer,
        proposal_id: u64,
    ) acquires GovernanceState, Emission30dRollingBucket {
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

    public entry fun execute_proposal(
        caller: &signer,
        proposal_id: u64,
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ) acquires GovernanceState {
        let submitted_digest = compute_upgrade_digest(&metadata, &code_bytes);

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

            assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);

            assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);

            proposal.executed_at_secs = option::some(now);
            target_package_addr = proposal.target_package_addr;
        };

        code::publish_package_txn(&pkg_signer, metadata, code_bytes);

        event::emit(ProposalExecuted {
            proposal_id,
            target_package_addr,
            executor: signer::address_of(caller),
        });
    }

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
        if (exists<DaoUpgradeStaging>(@desnet)) {
            let staging_ref = borrow_global<DaoUpgradeStaging>(@desnet);
            if (staging_ref.proposal_id != proposal_id) {
                let _ = move_from<DaoUpgradeStaging>(@desnet);
            } else {
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

        let i = 0;
        let n = vector::length(&code);
        while (i < n) {
            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
            i = i + 1;
        };

        let assembled_digest = compute_upgrade_digest(&metadata, &code);
        assert!(assembled_digest == stored_hash, E_HASH_MISMATCH);

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

    #[view]
    public fun compute_upgrade_digest_view(
        metadata: vector<u8>,
        code_bytes: vector<vector<u8>>,
    ): vector<u8> {
        compute_upgrade_digest(&metadata, &code_bytes)
    }

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
        let eff = effective_30d_emission();
        if (eff == 0) return 18446744073709551615u64;
        (eff * PROPOSAL_THRESHOLD_BPS) / 10000
    }

    #[view]
    public fun quorum_amount(): u64 acquires GovernanceState, Emission30dRollingBucket {
        let eff = effective_30d_emission();
        if (eff == 0) return 18446744073709551615u64;
        (eff * QUORUM_BPS) / 10000
    }

    const E_NOT_MULTISIG_ADMIN: u64 = 100;

    public entry fun update_desnet_fa_metadata(
        _multisig: &signer,
        _fa_addr: address,
    ) acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        abort E_NEUTERED
    }

    #[view]
    public fun desnet_fa_addr(): address { DESNET_FA_ADDR }

    public entry fun update_total_30d_emission(
        _multisig: &signer,
        _amount: u64,
    ) acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        abort E_NEUTERED
    }

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
