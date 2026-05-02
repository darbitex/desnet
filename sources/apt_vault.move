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
    use aptos_framework::timestamp;

    use desnet::amm;

    friend desnet::factory;
    friend desnet::handle_fee_vault;

    // ============ CONSTANTS ============

    /// Min APT balance for settle to execute (anti-dust). 0.1 APT (8 decimals).
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const SPEC_VERSION: u32 = 4;

    const SEED_VAULT: vector<u8> = b"vault::";

    /// H3 fix (audit R3): two-phase commit-reveal settle.
    /// `request_settle` records timestamp; `execute_settle` requires ≥ delay elapsed.
    /// Same-tx sandwich is impossible because manipulator must hold position across
    /// blocks under arbitrage exposure (~200 blocks at Aptos ~0.3s block time).
    const SETTLE_DELAY_SECS: u64 = 60;

    /// Re-request grace: after delay + grace, anyone can override a stale pending
    /// request. Bounds DoS vector where a spammer keeps refreshing the timer.
    const SETTLE_REQUEST_GRACE_SECS: u64 = 3600;

    /// H3 fix R3 (defense-in-depth): cap buyback amount per settle at 1% of pool APT
    /// reserve. Bounds price impact → bounds attacker's pre-position profit envelope.
    /// Excess APT redirects to PID owner (owner_amount = total_apt - capped_buyback).
    const MAX_BUYBACK_BPS_OF_RESERVE: u64 = 100;
    const BPS_DENOM: u64 = 10000;

    // ============ ERROR CODES ============

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_SWAP_FAILED: u64 = 3;
    const E_BURN_FAILED: u64 = 4;
    const E_POOL_ADDR_DRIFT: u64 = 5;
    const E_NO_PENDING_SETTLE: u64 = 6;
    const E_SETTLE_NOT_READY: u64 = 7;
    const E_SETTLE_REQUEST_PENDING: u64 = 8;

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
        /// H3 fix R3: timestamp of last `request_settle`. 0 = no pending request.
        /// `execute_settle` requires `now >= pending_settle_at_secs + SETTLE_DELAY_SECS`.
        pending_settle_at_secs: u64,
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

    #[event]
    struct SettleRequested has drop, store {
        vault_addr: address,
        requested_at_secs: u64,
        executable_at_secs: u64,
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
            pending_settle_at_secs: 0,
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

    // ============ SETTLE — two-phase (R3 H3 fix) ============

    /// Phase 1: record request timestamp. Permissionless.
    /// `execute_settle` becomes callable after SETTLE_DELAY_SECS elapses.
    /// If a pending request already exists and is younger than
    /// `SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS`, this aborts (DoS guard).
    public entry fun request_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let now = timestamp::now_seconds();
        assert!(
            vault.pending_settle_at_secs == 0
                || now >= vault.pending_settle_at_secs + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS,
            E_SETTLE_REQUEST_PENDING
        );

        vault.pending_settle_at_secs = now;

        event::emit(SettleRequested {
            vault_addr,
            requested_at_secs: now,
            executable_at_secs: now + SETTLE_DELAY_SECS,
        });
    }

    /// Phase 2: execute the buyback-burn + owner payout. Permissionless.
    /// Requires a pending request older than `SETTLE_DELAY_SECS`.
    /// Buyback amount is capped at `MAX_BUYBACK_BPS_OF_RESERVE` (1%) of pool APT
    /// reserve as defense-in-depth against pre-positioning over the delay window.
    /// M5: cached amm_pool_addr matches current handle-derived addr.
    public entry fun execute_settle(
        _caller: &signer,
        vault_addr: address,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);

        // Two-phase guard: pending request must exist and have aged past delay.
        assert!(vault.pending_settle_at_secs > 0, E_NO_PENDING_SETTLE);
        let now = timestamp::now_seconds();
        assert!(
            now >= vault.pending_settle_at_secs + SETTLE_DELAY_SECS,
            E_SETTLE_NOT_READY
        );

        // M5: cache consistency check (assert before any swap).
        assert!(
            amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
            E_POOL_ADDR_DRIFT
        );

        let total_apt = coin::value(&vault.apt_balance);
        assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let pid_object = object::address_to_object<object::ObjectCore>(vault.pid_object_addr);
        let owner_addr = object::owner(pid_object);

        // H3 R3 defense-in-depth: cap buyback at 1% of pool APT reserve.
        // Excess APT redirects to PID owner. Bounds attacker pre-position profit
        // envelope (manipulation cost grows ~Δ², extractable profit grows ~Δ).
        let raw_buyback = total_apt / 2;
        let (apt_reserve, _token_reserve) = amm::reserves(vault.handle);
        let reserve_cap = (apt_reserve * MAX_BUYBACK_BPS_OF_RESERVE) / BPS_DENOM;
        let buyback_amount = if (raw_buyback > reserve_cap) reserve_cap else raw_buyback;
        let owner_amount = total_apt - buyback_amount;

        let apt_for_buyback = coin::extract(&mut vault.apt_balance, buyback_amount);
        let apt_for_owner = coin::extract(&mut vault.apt_balance, owner_amount);

        // Buyback path: APT → $TOKEN via in-house AMM 10 bps, then BURN.
        // No min_out slippage check — same-tx sandwich is impossible (two-phase delay)
        // and pre-position attack profitability is bounded by the buyback cap.
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

        // Consume the pending request.
        vault.pending_settle_at_secs = 0;

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

    #[view]
    public fun pending_settle_at_secs(vault_addr: address): u64 acquires Vault {
        borrow_global<Vault>(vault_addr).pending_settle_at_secs
    }

    #[view]
    public fun settle_executable_at_secs(vault_addr: address): u64 acquires Vault {
        let pending = borrow_global<Vault>(vault_addr).pending_settle_at_secs;
        if (pending == 0) 0 else pending + SETTLE_DELAY_SECS
    }

    // ============ DELEGATE BURN — friend (handle_fee_vault, v0.3.2 F9) ============

    /// handle_fee_vault swaps APT → DESNET via amm, then asks the DESNET per-token
    /// vault to burn the FA via its held BurnRef. Direction-locked: caller hands a FA
    /// whose metadata MUST match `vault.token_metadata_addr` (the fungible_asset::burn
    /// check enforces this — wrong-token FA aborts).
    /// No state mutation, no event (handle_fee_vault::Settled covers it).
    public(friend) fun burn_via_vault(
        vault_addr: address,
        fa: fungible_asset::FungibleAsset,
    ) acquires Vault {
        let vault = borrow_global<Vault>(vault_addr);
        fungible_asset::burn(&vault.burn_ref, fa);
    }

    // ============ TEST-ONLY HELPERS ============

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
    public fun deposit_apt_coin_for_test(
        vault_addr: address,
        apt_coin: Coin<AptosCoin>,
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(vault_addr);
        coin::merge(&mut vault.apt_balance, apt_coin);
    }
}
