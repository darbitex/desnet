/// HandleFeeVault — handle reg fees: 10% deployer, 90% buy DESNET + burn.
/// Destinations immutable. No admin.
module desnet::handle_fee_vault {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::primary_fungible_store;

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::factory;
    use desnet::governance;

    friend desnet::profile;

    // ============ CONSTANTS ============

    const SEED_VAULT: vector<u8> = b"handle_fee_vault";
    const DESNET_HANDLE: vector<u8> = b"desnet";
    const APT_FA_ADDR: address = @0xa;

    /// 10% to deployer beneficiary, 90% to DESNET buyback-burn.
    const SPLIT_DEPLOYER_BPS: u64 = 1000;
    const SPLIT_BURN_BPS: u64 = 9000;
    const BPS_DENOM: u64 = 10000;

    /// Min APT balance for settle (anti-dust). 0.1 APT.
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    // ============ ERROR CODES ============

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_INITIALIZED: u64 = 2;

    // ============ TYPES ============

    struct HandleFeeVault has key {
        deployer_beneficiary: address,           // immutable, set at init = @origin
        extend_ref: ExtendRef,
    }

    // ============ EVENTS ============

    #[event]
    struct Settled has drop, store {
        total_apt: u64,
        to_deployer: u64,
        desnet_burned: u64,
    }

    // ============ INIT (auto-fires on compat upgrade publish) ============

    fun init_module(account: &signer) {
        let constructor = object::create_named_object(account, SEED_VAULT);
        let vault_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        move_to(&vault_signer, HandleFeeVault {
            deployer_beneficiary: @origin,
            extend_ref,
        });
    }

    // ============ ADDR DERIVATION ============

    public fun vault_addr(): address {
        object::create_object_address(&@desnet, SEED_VAULT)
    }

    public fun vault_exists(): bool {
        exists<HandleFeeVault>(vault_addr())
    }

    // ============ DEPOSIT ============

    /// Friend-only: APT FA → vault primary store.
    public(friend) fun deposit_apt_fa(fa: fungible_asset::FungibleAsset) {
        primary_fungible_store::deposit(vault_addr(), fa);
    }

    /// Public top-up — anyone can deposit APT to vault.
    public entry fun deposit_apt(depositor: &signer, amount: u64) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let fa = primary_fungible_store::withdraw(depositor, apt_meta, amount);
        deposit_apt_fa(fa);
    }

    // ============ SETTLE — permissionless ============

    /// 10% APT → deployer beneficiary, 90% APT → swap to DESNET → burn.
    public entry fun settle(_caller: &signer) acquires HandleFeeVault {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);

        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let total = primary_fungible_store::balance(v_addr, apt_meta);
        assert!(total >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
        let to_burn = total - to_deployer;

        let vault = borrow_global<HandleFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);

        // 10% APT direct to deployer beneficiary primary store
        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer);
        primary_fungible_store::deposit(vault.deployer_beneficiary, apt_for_deployer);

        // 90% APT swap to DESNET via amm pool → burn via DESNET apt_vault's BurnRef (delegation)
        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn);
        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, 0);
        let desnet_burned = fungible_asset::amount(&desnet_fa);

        let desnet_apt_vault = factory::vault_addr_of_handle(DESNET_HANDLE);
        apt_vault::burn_via_vault(desnet_apt_vault, desnet_fa);

        event::emit(Settled { total_apt: total, to_deployer, desnet_burned });
    }

    /// One-time poke: migrate stranded pre-upgrade fees from @desnet primary store.
    public entry fun migrate_legacy_fees(_caller: &signer) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let balance = primary_fungible_store::balance(@desnet, apt_meta);
        if (balance == 0) return;
        let pkg_signer = governance::derive_pkg_signer();
        let fa = primary_fungible_store::withdraw(&pkg_signer, apt_meta, balance);
        deposit_apt_fa(fa);
    }

    // ============ VIEWS ============

    #[view]
    public fun deployer_beneficiary(): address acquires HandleFeeVault {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        borrow_global<HandleFeeVault>(v_addr).deployer_beneficiary
    }

    #[view]
    public fun apt_balance(): u64 {
        let v_addr = vault_addr();
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        primary_fungible_store::balance(v_addr, apt_meta)
    }

    #[view]
    public fun split_deployer_bps(): u64 { SPLIT_DEPLOYER_BPS }

    #[view]
    public fun split_burn_bps(): u64 { SPLIT_BURN_BPS }

    #[view]
    public fun settle_threshold(): u64 { APT_SETTLE_THRESHOLD }
}
