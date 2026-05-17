module desnet::supra_vault {
    use std::signer;
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, BurnRef};
    use supra_framework::object::{Self, ExtendRef};
    use supra_framework::timestamp;

    use desnet::amm;

    friend desnet::factory;
    friend desnet::supra_fee_vault;
    friend desnet::opinion;

    const SUPRA_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 4;

    const SEED_VAULT: vector<u8> = b"vault::";

    const SETTLE_DELAY_SECS: u64 = 60;

    const SETTLE_REQUEST_GRACE_SECS: u64 = 3600;

    const BPS_DENOM: u64 = 10000;
    const BPS_FULL: u64 = 10000;
    const SETTLE_SLIPPAGE_BPS: u64 = 9500;

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_SWAP_FAILED: u64 = 3;
    const E_BURN_FAILED: u64 = 4;
    const E_POOL_ADDR_DRIFT: u64 = 5;
    const E_NO_PENDING_SETTLE: u64 = 6;
    const E_SETTLE_NOT_READY: u64 = 7;
    const E_SETTLE_REQUEST_PENDING: u64 = 8;
    const E_SETTLE_REQUEST_EXPIRED: u64 = 9;
    const E_VAULT_SHRUNK_BELOW_SNAPSHOT: u64 = 10;

    struct Vault has key {
        supra_balance: Coin<SupraCoin>,
        burn_ref: BurnRef,
        token_metadata_addr: address,
        handle: vector<u8>,
        amm_pool_addr: address,
        pid_object_addr: address,
        spec_version: u32,
        extend_ref: ExtendRef,
    }

    struct PendingSettle has key, drop {
        requested_at_secs: u64,
        total_supra_at_request: u64,
        buyback_at_request: u64,
        owner_at_request: u64,
        min_token_out: u64,
    }

    #[event]
    struct SupraDeposited has drop, store {
        vault_addr: address,
        depositor: address,
        amount: u64,
    }

    #[event]
    struct SupraSettled has drop, store {
        vault_addr: address,
        total_supra: u64,
        to_buyback: u64,
        to_owner: u64,
        owner_addr: address,
        token_burned: u64,
    }

    #[event]
    struct SettleRequested has drop, store {
        vault_addr: address,
        requested_at_secs: u64,
        executable_at_secs: u64,
    }

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
            supra_balance: coin::zero<SupraCoin>(),
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

    public entry fun deposit_supra(
        depositor: &signer,
        vault_addr: address,
        amount: u64,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        let supra_in = coin::withdraw<SupraCoin>(depositor, amount);
        coin::merge(&mut vault.supra_balance, supra_in);

        event::emit(SupraDeposited {
            vault_addr,
            depositor: signer::address_of(depositor),
            amount,
        });
    }

    public entry fun request_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        assert!(!exists<PendingSettle>(vault_addr), E_SETTLE_REQUEST_PENDING);
        let vault = borrow_global<Vault>(vault_addr);

        let total_supra = coin::value(&vault.supra_balance);
        assert!(total_supra >= SUPRA_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let buyback_amount = total_supra / 2;
        let owner_amount = total_supra - buyback_amount;

        let quoted_out = amm::quote_swap_exact_in(vault.handle, buyback_amount, true);
        let min_token_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;

        let now = timestamp::now_seconds();
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        move_to(&vault_signer, PendingSettle {
            requested_at_secs: now,
            total_supra_at_request: total_supra,
            buyback_at_request: buyback_amount,
            owner_at_request: owner_amount,
            min_token_out,
        });

        event::emit(SettleRequested {
            vault_addr,
            requested_at_secs: now,
            executable_at_secs: now + SETTLE_DELAY_SECS,
        });
    }

    public entry fun execute_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault, PendingSettle {
        assert!(exists<PendingSettle>(vault_addr), E_NO_PENDING_SETTLE);
        let now = timestamp::now_seconds();
        let pending_ref = borrow_global<PendingSettle>(vault_addr);
        let requested_at = pending_ref.requested_at_secs;
        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_SETTLE_NOT_READY);
        assert!(
            now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS,
            E_SETTLE_REQUEST_EXPIRED
        );

        let PendingSettle {
            requested_at_secs: _,
            total_supra_at_request,
            buyback_at_request,
            owner_at_request,
            min_token_out,
        } = move_from<PendingSettle>(vault_addr);

        let vault = borrow_global_mut<Vault>(vault_addr);

        assert!(
            amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
            E_POOL_ADDR_DRIFT
        );

        let current_total = coin::value(&vault.supra_balance);
        assert!(current_total >= total_supra_at_request, E_VAULT_SHRUNK_BELOW_SNAPSHOT);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        let supra_for_buyback = coin::extract(&mut vault.supra_balance, buyback_at_request);
        let supra_for_owner = coin::extract(&mut vault.supra_balance, owner_at_request);

        let supra_fa_buyback = coin::coin_to_fungible_asset(supra_for_buyback);
        let token_received = amm::swap_exact_supra_in(
            vault.handle,
            supra_fa_buyback,
            min_token_out,
        );
        let burned_amount = fungible_asset::amount(&token_received);
        fungible_asset::burn(&vault.burn_ref, token_received);

        coin::deposit(owner_addr, supra_for_owner);

        event::emit(SupraSettled {
            vault_addr,
            total_supra: total_supra_at_request,
            to_buyback: buyback_at_request,
            to_owner: owner_at_request,
            owner_addr,
            token_burned: burned_amount,
        });
    }

    public entry fun cancel_pending_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires PendingSettle {
        if (exists<PendingSettle>(vault_addr)) {
            let _ = move_from<PendingSettle>(vault_addr);
        };
    }

    #[view]
    public fun supra_balance(vault_addr: address): u64 acquires Vault {
        coin::value(&borrow_global<Vault>(vault_addr).supra_balance)
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

    #[view]
    public fun pending_settle_at_secs(vault_addr: address): u64 acquires PendingSettle {
        if (!exists<PendingSettle>(vault_addr)) return 0;
        borrow_global<PendingSettle>(vault_addr).requested_at_secs
    }

    #[view]
    public fun settle_executable_at_secs(vault_addr: address): u64 acquires PendingSettle {
        if (!exists<PendingSettle>(vault_addr)) return 0;
        borrow_global<PendingSettle>(vault_addr).requested_at_secs + SETTLE_DELAY_SECS
    }

    #[view]
    public fun pending_min_token_out(vault_addr: address): u64 acquires PendingSettle {
        if (!exists<PendingSettle>(vault_addr)) return 0;
        borrow_global<PendingSettle>(vault_addr).min_token_out
    }

    public(friend) fun burn_via_vault(
        vault_addr: address,
        fa: fungible_asset::FungibleAsset,
    ) acquires Vault {
        let vault = borrow_global<Vault>(vault_addr);
        fungible_asset::burn(&vault.burn_ref, fa);
    }

    #[test_only]
    public fun deploy_for_test(
        factory_signer: &signer,
        token_handle: vector<u8>,
        token_metadata_addr: address,
        amm_pool_addr: address,
        pid_object_addr: address,
        burn_ref: BurnRef,
    ): address {
        deploy(factory_signer, token_handle, token_metadata_addr, amm_pool_addr, pid_object_addr, burn_ref)
    }

    #[test_only]
    public fun deposit_supra_coin_for_test(
        vault_addr: address,
        supra_coin: Coin<SupraCoin>,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        coin::merge(&mut vault.supra_balance, supra_coin);
    }
}
