module desnet::voter_history {
    use std::signer;
    use std::vector;
    use supra_framework::event;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    friend desnet::governance;
    friend desnet::lp_staking;
    friend desnet::ipo;

    const VOTING_WINDOW_SECS: u64 = 30 * 86_400;

    const HISTORY_PRUNE_AFTER_SECS: u64 = 60 * 86_400;

    const E_NOT_FACTORY_AUTHORITY: u64 = 1;
    const E_REGISTRY_NOT_INITIALIZED: u64 = 2;
    const E_ALREADY_INITIALIZED: u64 = 3;

    struct VoterHistory has store, drop {
        rewards_history: vector<RewardEntry>,
        total_received: u64,
    }

    struct RewardEntry has copy, drop, store {
        timestamp_secs: u64,
        amount: u64,
    }

    struct Registry has key {
        voters: SmartTable<address, VoterHistory>,
    }

    struct RegistryByToken has key {
        voters: SmartTable<address, SmartTable<address, VoterHistory>>,
    }

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

    public(friend) fun record_reward_received_for_token(
        factory_authority: &signer,
        voter_addr: address,
        token_addr: address,
        amount: u64,
    ) acquires Registry, RegistryByToken {
        record_reward_received(factory_authority, voter_addr, amount);

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

    #[view]
    public fun has_per_token_registry(): bool { exists<RegistryByToken>(@desnet) }

    #[view]
    public fun has_per_token_entry(voter_addr: address): bool acquires RegistryByToken {
        if (!exists<RegistryByToken>(@desnet)) return false;
        let registry = borrow_global<RegistryByToken>(@desnet);
        smart_table::contains(&registry.voters, voter_addr)
    }

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
