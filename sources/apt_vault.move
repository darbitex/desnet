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
    friend desnet::handle_fee_vault;

    // ============ CONSTANTS ============

    /// Min APT balance for settle to execute (anti-dust). 0.1 APT (8 decimals).
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 3;

    const SEED_VAULT: vector<u8> = b"vault::";

    // ============ ERROR CODES ============

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_SWAP_FAILED: u64 = 3;
    const E_BURN_FAILED: u64 = 4;

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
    public entry fun settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        let buyback_amount = total_apt / 2;
        let owner_amount = total_apt - buyback_amount;

        let apt_for_buyback = coin::extract(&mut vault.apt_balance, buyback_amount);
        let apt_for_owner = coin::extract(&mut vault.apt_balance, owner_amount);

        // Buyback path: APT → $TOKEN via in-house AMM 10 bps, then BURN.
        let apt_fa_buyback = coin::coin_to_fungible_asset(apt_for_buyback);
        let token_received = amm::swap_exact_apt_in(
            vault.handle,
            apt_fa_buyback,
            0,
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

    /// Friend-only burn delegation. handle_fee_vault uses this to burn DESNET
    /// (BurnRef stays sealed in DESNET's apt_vault, no extraction needed).
    public(friend) fun burn_via_vault(
        vault_addr: address,
        fa: fungible_asset::FungibleAsset,
    ) acquires Vault {
        let vault = borrow_global<Vault>(vault_addr);
        fungible_asset::burn(&vault.burn_ref, fa);
    }
}
