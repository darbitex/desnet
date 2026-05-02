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
