# DeSNet v0.3.3 — Source Bundle (PART 1 governance auth)

**PRE-DEPLOY (LOCAL SOURCE) — not yet on chain. R6 audit submission.**

This is **1 of 3** parts. Each part covers a domain-grouped subset of modules.

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
| `voter_history` | 329 | 13,812 | `d9cc507be948a658a645d7f2e561299237b1a4436dd2a63f1e5e4aedfea246c1` |
| `governance` | 1083 | 46,747 | `0284da78cc45a64245734d0db9133819cae374f09ab8e1ed6c61356e9e21ed9a` |
| `factory` | 612 | 24,158 | `53ff5c807b636823b5f25918f203fee2cf054aa6ca6cf42165a3033f81cad766` |
| `profile` | 831 | 34,440 | `754142ec93e82fa147b2d4a7db5086ac008a5c902d40042f0b5b23f80f16027d` |

To verify each module's sha3 matches:
```bash
sha3sum sources/<name>.move
```

---


## Module `voter_history` (329 lines, 13812 bytes)

`sha3_256: d9cc507be948a658a645d7f2e561299237b1a4436dd2a63f1e5e4aedfea246c1`

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
/// Cross-module authentication via friend visibility + signer addr check:
///   - `record_reward_received` is `public(friend)` with `friend desnet::lp_staking;`
///     as the load-bearing barrier (compile-time enforcement).
///   - The runtime `signer::address_of(authority) == @desnet` assertion remains as
///     belt-and-braces defense-in-depth against future refactors that widen friend
///     scope or hypothetical compiler edge cases.
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
        // 1. Legacy path — keeps old indexers working.
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

    /// v0.3.2 (F7): exists check — gates governance::voting_power's choice of
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
    #[view]
    public fun has_per_token_entry(voter_addr: address): bool acquires RegistryByToken {
        if (!exists<RegistryByToken>(@desnet)) return false;
        let registry = borrow_global<RegistryByToken>(@desnet);
        smart_table::contains(&registry.voters, voter_addr)
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

## Module `governance` (1083 lines, 46747 bytes)

`sha3_256: 0284da78cc45a64245734d0db9133819cae374f09ab8e1ed6c61356e9e21ed9a`

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
    // Bootstrap publisher lives at @origin (deployer multisig). It holds the
    // SignerCapability for @desnet (created at bootstrap deploy) until our
    // init_module takes ownership via `take_cap_for_desnet` here. This indirection
    // is required because the main DesNet package exceeds the 64KB single-tx
    // publish limit and must be deployed via chunked publish through bootstrap.
    use origin::publisher;
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
    #[view]
    public fun voting_power(voter_addr: address): u64 acquires GovernanceState {
        let _ = borrow_global<GovernanceState>(@desnet);
        if (!aptos_framework::object::object_exists<aptos_framework::fungible_asset::Metadata>(DESNET_FA_ADDR))
            return 0;
        let earned = if (voter_history::has_per_token_entry(voter_addr)) {
            voter_history::rewards_earned_30d_for_token(voter_addr, DESNET_FA_ADDR)
        } else {
            voter_history::rewards_earned_30d(voter_addr)
        };
        let fa_meta = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(
            DESNET_FA_ADDR
        );
        let balance = aptos_framework::primary_fungible_store::balance(voter_addr, fa_meta);
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

## Module `factory` (612 lines, 24158 bytes)

`sha3_256: 53ff5c807b636823b5f25918f203fee2cf054aa6ca6cf42165a3033f81cad766`

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

    use aptos_framework::fungible_asset::MutateMetadataRef;

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
    const E_INVALID_ADDRESS: u64 = 14;
    const E_NAME_TOO_LONG: u64 = 15;
    const E_SYMBOL_TOO_LONG: u64 = 16;
    const E_ICON_URI_TOO_LONG: u64 = 17;
    const E_NOT_PID_OWNER: u64 = 18;
    const E_TOKEN_NOT_FOUND: u64 = 19;
    const E_PROJECT_URI_TOO_LONG: u64 = 20;

    /// Mirror Aptos `fungible_asset` framework limits — pre-validate so callers
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

    /// Holds the `MutateMetadataRef` for a spawned token's FA Metadata. Stored at
    /// the FA Metadata object addr (one-to-one with the token). The ref's only
    /// authorized use is `update_token_icon`, gated by PID-NFT-owner signer
    /// (cold wallet — same authority tier as `withdraw_pid_token`).
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

    /// Atomic token + vault + reserves + AMM pool + locked LP stake.
    /// Friend-only: sole caller is `desnet::profile::register_handle`.
    ///
    /// Caller MUST:
    /// - Have already minted PID NFT at `pid_addr`
    /// - Have already collected handle_fee_apt + POOL_SEED_APT_AMOUNT from end-user
    /// - Pass exactly POOL_SEED_APT_AMOUNT (5 APT) as `pool_seed_apt`
    /// - Pass `name`/`symbol` (≤32 b each, PERMANENT) and `icon_uri`/`project_uri`
    ///   (≤512 b each, mutable post-mint via `update_token_icon` /
    ///   `update_token_project_uri`, both PID-NFT-owner gated).
    public(friend) fun create_token_atomic(
        handle: vector<u8>,
        pid_addr: address,
        pid_signer: &signer,
        pool_seed_apt: FungibleAsset,
        name: String,
        symbol: String,
        icon_uri: String,
        project_uri: String,
    ) acquires FactoryState, FactoryRegistry {
        validate_handle(&handle);
        validate_token_metadata_strings(&name, &symbol, &icon_uri, &project_uri);
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

        // FA name/symbol caller-supplied (PERMANENT). icon_uri/project_uri
        // caller-supplied (MUTABLE via update_token_icon / update_token_project_uri,
        // PID-NFT-owner gated).
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

        // Capture MutateMetadataRef so PID-NFT-owner can update icon_uri later.
        let mutate_ref = fungible_asset::generate_mutate_metadata_ref(&constructor_ref);
        let metadata_signer = object::generate_signer(&constructor_ref);
        move_to(&metadata_signer, TokenMetadataMutRef { mutate_ref });

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

    // ============ TOKEN METADATA UPDATE — PID-NFT-OWNER ONLY ============

    /// Update the FA `icon_uri` for a spawned token. Authority = PID-NFT-owner
    /// (cold wallet, same tier as `withdraw_pid_token`). Name/symbol are NOT
    /// mutable. New icon_uri must be ≤ 512 bytes (Aptos framework cap).
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
            option::some(new_icon_uri),            // icon_uri — UPDATE
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
            option::some(new_project_uri),         // project_uri — UPDATE
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
        // v0.3.2 (F1): semantic-correct error code (was E_HANDLE_TAKEN — misleading).
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
    /// NOT the wallet that holds the PID NFT. Use `handle_of_wallet` for wallet→handle.
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

    // (v0.3.2 F1b: handle_of_wallet lives in profile.move to avoid factory→profile
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
    public fun lp_staking_pool_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
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
        smart_table::borrow(&registry.records, handle).apt_vault
    }

    /// v0.3.2 F9: single-hop handle → apt_vault lookup. Used by handle_fee_vault::settle
    /// to delegate-burn DESNET via desnet's apt_vault BurnRef.
    #[view]
    public fun vault_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        smart_table::borrow(&registry.records, key).apt_vault
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

## Module `profile` (831 lines, 34440 bytes)

`sha3_256: 754142ec93e82fa147b2d4a7db5086ac008a5c902d40042f0b5b23f80f16027d`

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
    use desnet::handle_fee_vault;

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
    /// v0.3.2 (F10): update_fee_receiver neutered after handle_fee_vault (F9) takes over fee routing.
    const E_NEUTERED: u64 = 19;

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
    /// v0.3.2 (F10): NEUTERED. With handle_fee_vault (F9), `state.fee_receiver` field
    /// is no longer read by `register_handle` body — fees route directly to the vault.
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
        token_name: vector<u8>,
        token_symbol: vector<u8>,
        token_icon_uri: vector<u8>,
        token_project_uri: vector<u8>,
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

        // 3. Fee in APT — v0.3.2 F9: route directly to handle_fee_vault
        //    (10% deployer beneficiary / 90% DESNET buyback-burn).
        //    state.fee_receiver field is now vestigial (compat-preserved); body bypasses it.
        //    Borrow kept (unused) to preserve `acquires ProtocolState` annotation parity
        //    with the deployed bytecode metadata.
        //    Plus pool_seed_apt (5 APT) — withdrawn as separate FA, passed to factory
        //    for atomic AMM pool seed.
        let _state = borrow_global<ProtocolState>(@desnet);
        let fee_raw = handle_fee_apt(vector::length(&handle));
        let apt_metadata = object::address_to_object<Metadata>(APT_FA_METADATA);
        if (fee_raw > 0) {
            let fee_fa = primary_fungible_store::withdraw(wallet, apt_metadata, fee_raw);
            handle_fee_vault::deposit_apt_fa(fee_fa);
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
        factory::create_token_atomic(
            handle,
            pid_addr,
            &pid_signer,
            pool_seed_fa,
            string::utf8(token_name),
            string::utf8(token_symbol),
            string::utf8(token_icon_uri),
            string::utf8(token_project_uri),
        );

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

    /// v0.3.2 (F1b): wallet→handle convenience. Derives PID from wallet, looks up
    /// handle. Aborts E_PROFILE_NOT_FOUND if wallet has no registered PID.
    /// (Lives here, not in factory.move, because profile→factory but not the reverse.)
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
