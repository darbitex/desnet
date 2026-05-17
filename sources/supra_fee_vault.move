module desnet::supra_fee_vault {
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, ExtendRef};
    use std::vector;
    use supra_framework::primary_fungible_store;

    use desnet::amm;
    use desnet::supra_vault;
    use desnet::governance;

    friend desnet::profile;

    const SEED_VAULT: vector<u8> = b"supra_fee_vault";
    const DESNET_HANDLE: vector<u8> = b"desnet";

    const SPLIT_DEPLOYER_BPS: u64 = 1000;
    const SPLIT_BURN_BPS: u64 = 9000;
    const BPS_DENOM: u64 = 10000;

    const SUPRA_SETTLE_THRESHOLD: u64 = 10_000_000;

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_INITIALIZED: u64 = 2;
    const E_USE_TWO_PHASE: u64 = 3;
    const E_PENDING_SETTLE_NOT_FOUND: u64 = 4;
    const E_PENDING_SETTLE_NOT_RIPE: u64 = 5;
    const E_PENDING_SETTLE_EXPIRED: u64 = 6;
    const E_PENDING_SETTLE_ALREADY_EXISTS: u64 = 7;
    const E_VAULT_SHRUNK_BELOW_SNAPSHOT: u64 = 8;

    const SETTLE_DELAY_SECS: u64 = 60;
    const SETTLE_REQUEST_GRACE_SECS: u64 = 600;
    const SETTLE_SLIPPAGE_BPS: u64 = 9500;
    const BPS_FULL: u64 = 10000;

    struct SupraFeeVault has key {
        deployer_beneficiary: address,
        extend_ref: ExtendRef,
    }

    struct PendingSettle has key, drop {
        requested_at_secs: u64,
        supra_balance_at_request: u64,
        to_deployer_at_request: u64,
        to_burn_at_request: u64,
        min_desnet_out: u64,
    }

    #[event]
    struct Settled has drop, store {
        total_supra: u64,
        to_deployer: u64,
        desnet_burned: u64,
    }

    fun init_module(account: &signer) {
        let constructor = object::create_named_object(account, SEED_VAULT);
        let vault_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        move_to(&vault_signer, SupraFeeVault {
            deployer_beneficiary: @origin,
            extend_ref,
        });
    }

    #[view]
    public fun vault_addr(): address {
        object::create_object_address(&@desnet, SEED_VAULT)
    }

    #[view]
    public fun vault_exists(): bool {
        exists<SupraFeeVault>(vault_addr())
    }

    public(friend) fun deposit_supra_fa(fa: fungible_asset::FungibleAsset) {
        primary_fungible_store::deposit(vault_addr(), fa);
    }

    public entry fun deposit_supra(depositor: &signer, amount: u64) {
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let fa = primary_fungible_store::withdraw(depositor, supra_meta, amount);
        deposit_supra_fa(fa);
    }

    public entry fun settle(_caller: &signer) acquires SupraFeeVault {
        let _ = borrow_global<SupraFeeVault>(vault_addr());
        abort E_USE_TWO_PHASE
    }

    public entry fun request_settle(_caller: &signer) acquires SupraFeeVault {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(!exists<PendingSettle>(v_addr), E_PENDING_SETTLE_ALREADY_EXISTS);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let total = primary_fungible_store::balance(v_addr, supra_meta);
        assert!(total >= SUPRA_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
        let to_burn = total - to_deployer;

        let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
        let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;

        let vault = borrow_global<SupraFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        move_to(&vault_signer, PendingSettle {
            requested_at_secs: supra_framework::timestamp::now_seconds(),
            supra_balance_at_request: total,
            to_deployer_at_request: to_deployer,
            to_burn_at_request: to_burn,
            min_desnet_out: min_out,
        });
    }

    public entry fun execute_settle(_caller: &signer) acquires SupraFeeVault, PendingSettle {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(exists<PendingSettle>(v_addr), E_PENDING_SETTLE_NOT_FOUND);

        let now = supra_framework::timestamp::now_seconds();
        let pending_ref = borrow_global<PendingSettle>(v_addr);
        let requested_at = pending_ref.requested_at_secs;
        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_PENDING_SETTLE_NOT_RIPE);
        assert!(now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS, E_PENDING_SETTLE_EXPIRED);

        let PendingSettle {
            requested_at_secs: _,
            supra_balance_at_request,
            to_deployer_at_request,
            to_burn_at_request,
            min_desnet_out,
        } = move_from<PendingSettle>(v_addr);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let current_total = primary_fungible_store::balance(v_addr, supra_meta);
        assert!(current_total >= supra_balance_at_request, E_VAULT_SHRUNK_BELOW_SNAPSHOT);

        let vault = borrow_global<SupraFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);

        let supra_for_deployer = primary_fungible_store::withdraw(&vault_signer, supra_meta, to_deployer_at_request);
        primary_fungible_store::deposit(vault.deployer_beneficiary, supra_for_deployer);

        let supra_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, supra_meta, to_burn_at_request);
        let desnet_fa = amm::swap_exact_supra_in(DESNET_HANDLE, supra_for_burn_fa, min_desnet_out);
        let desnet_burned = fungible_asset::amount(&desnet_fa);

        let vault_seed = vector::empty<u8>();
        vector::append(&mut vault_seed, b"vault::");
        vector::append(&mut vault_seed, DESNET_HANDLE);
        let desnet_supra_vault = object::create_object_address(&@desnet, vault_seed);
        supra_vault::burn_via_vault(desnet_supra_vault, desnet_fa);

        event::emit(Settled {
            total_supra: supra_balance_at_request,
            to_deployer: to_deployer_at_request,
            desnet_burned,
        });
    }

    public entry fun cancel_pending_settle(_caller: &signer) acquires PendingSettle {
        let v_addr = vault_addr();
        if (exists<PendingSettle>(v_addr)) {
            let _ = move_from<PendingSettle>(v_addr);
        };
    }

    #[view]
    public fun pending_settle_exists(): bool { exists<PendingSettle>(vault_addr()) }

    #[view]
    public fun pending_settle_executable_at_secs(): u64 acquires PendingSettle {
        let v_addr = vault_addr();
        if (!exists<PendingSettle>(v_addr)) return 0;
        borrow_global<PendingSettle>(v_addr).requested_at_secs + SETTLE_DELAY_SECS
    }

    #[view]
    public fun pending_settle_min_out(): u64 acquires PendingSettle {
        let v_addr = vault_addr();
        if (!exists<PendingSettle>(v_addr)) return 0;
        borrow_global<PendingSettle>(v_addr).min_desnet_out
    }

    public entry fun migrate_legacy_fees(_caller: &signer) {
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let balance = primary_fungible_store::balance(@desnet, supra_meta);
        if (balance == 0) return;
        let pkg_signer = governance::derive_pkg_signer();
        let fa = primary_fungible_store::withdraw(&pkg_signer, supra_meta, balance);
        deposit_supra_fa(fa);
    }

    #[view]
    public fun deployer_beneficiary(): address acquires SupraFeeVault {
        let v_addr = vault_addr();
        assert!(exists<SupraFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        borrow_global<SupraFeeVault>(v_addr).deployer_beneficiary
    }

    #[view]
    public fun supra_balance(): u64 {
        let v_addr = vault_addr();
        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        primary_fungible_store::balance(v_addr, supra_meta)
    }

    #[view]
    public fun split_deployer_bps(): u64 { SPLIT_DEPLOYER_BPS }

    #[view]
    public fun split_burn_bps(): u64 { SPLIT_BURN_BPS }

    #[view]
    public fun settle_threshold(): u64 { SUPRA_SETTLE_THRESHOLD }
}
