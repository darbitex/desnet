/// HandleFeeVault — handle reg fees: 10% deployer, 90% buy DESNET + burn.
/// Destinations immutable. No admin.
module desnet::handle_fee_vault {
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::primary_fungible_store;

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::factory;
    use desnet::governance;

    friend desnet::profile;

    const SEED_VAULT: vector<u8> = b"handle_fee_vault";
    const DESNET_HANDLE: vector<u8> = b"desnet";
    const APT_FA_ADDR: address = @0xa;

    /// 10% to deployer beneficiary, 90% to DESNET buyback-burn.
    const SPLIT_DEPLOYER_BPS: u64 = 1000;
    const SPLIT_BURN_BPS: u64 = 9000;
    const BPS_DENOM: u64 = 10000;

    /// Min APT balance for settle (anti-dust). 0.1 APT.
    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;

    const E_BELOW_THRESHOLD: u64 = 1;
    const E_VAULT_NOT_INITIALIZED: u64 = 2;
    /// v0.3.3 (G3): old single-tx settle deprecated for MEV-safety. Use two-phase.
    const E_USE_TWO_PHASE: u64 = 3;
    const E_PENDING_SETTLE_NOT_FOUND: u64 = 4;
    const E_PENDING_SETTLE_NOT_RIPE: u64 = 5;
    const E_PENDING_SETTLE_EXPIRED: u64 = 6;
    const E_PENDING_SETTLE_ALREADY_EXISTS: u64 = 7;
    /// v0.3.3 (Qwen R6 M1): distinct from E_BELOW_THRESHOLD — semantic clarity for
    /// off-chain monitors. Fires when execute_settle finds vault balance has shrunk
    /// below the request-time snapshot (structurally impossible since vault has no
    /// withdraw path, but kept as defensive guard).
    const E_VAULT_SHRUNK_BELOW_SNAPSHOT: u64 = 8;

    /// v0.3.3 (G3): commit-reveal delay parameters mirror R3 H3 fix on apt_vault.
    /// 60s delay defeats single-tx sandwich (atomic same-tx grief impossible);
    /// cross-tx pre-positioning bounded by 5% slippage tolerance baked at request.
    /// Grace window: 600s before request expires (prevents stale baseline exploit).
    const SETTLE_DELAY_SECS: u64 = 60;
    const SETTLE_REQUEST_GRACE_SECS: u64 = 600;
    const SETTLE_SLIPPAGE_BPS: u64 = 9500;
    const BPS_FULL: u64 = 10000;

    struct HandleFeeVault has key {
        deployer_beneficiary: address,
        extend_ref: ExtendRef,
    }

    /// v0.3.3 (G3 + S1 fix): two-phase commit-reveal settle state. Lives at `vault_addr()`.
    /// All amounts LOCKED at request time — execute uses these (NOT current balance) so
    /// (swap_amount, min_out) stay paired from same snapshot. Without this S1 fix, balance
    /// growing during the 60s window would let attacker sandwich the larger swap with
    /// trivially-satisfied stale min_out (anchored to smaller request-time amount).
    /// Excess balance accrued during window stays in vault for next settle cycle.
    struct PendingSettle has key, drop {
        requested_at_secs: u64,
        apt_balance_at_request: u64,
        to_deployer_at_request: u64,
        to_burn_at_request: u64,
        min_desnet_out: u64,
    }

    #[event]
    struct Settled has drop, store {
        total_apt: u64,
        to_deployer: u64,
        desnet_burned: u64,
    }

    /// Auto-fires on compat-upgrade publish since this module is new.
    /// `account` is @desnet (resource account signer assembled by code::publish_package_txn).
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

    /// v0.3.3 (G6, R5 Claude C8): added #[view] so frontend can call gas-free.
    #[view]
    public fun vault_addr(): address {
        object::create_object_address(&@desnet, SEED_VAULT)
    }

    /// v0.3.3 (G6): added #[view].
    #[view]
    public fun vault_exists(): bool {
        exists<HandleFeeVault>(vault_addr())
    }

    /// Friend-only: APT FA → vault primary store. Called by profile::register_handle.
    public(friend) fun deposit_apt_fa(fa: fungible_asset::FungibleAsset) {
        primary_fungible_store::deposit(vault_addr(), fa);
    }

    /// Public top-up — anyone can deposit APT to vault.
    public entry fun deposit_apt(depositor: &signer, amount: u64) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let fa = primary_fungible_store::withdraw(depositor, apt_meta, amount);
        deposit_apt_fa(fa);
    }

    /// v0.3.3 (G3, R5 CONV-1 MED-HIGH fix): old single-tx settle DEPRECATED for
    /// MEV-safety. The original `min_out=0` swap was atomically sandwich-attackable;
    /// any caller could front-run by skewing the AMM pool, trigger settle to swap
    /// at unfavorable rate, then back-run to extract APT and leak protocol revenue.
    /// Replaced by two-phase commit-reveal: `request_settle()` (records reserves
    /// snapshot + 5% slippage min_out) → 60s delay → `execute_settle()` (enforces
    /// pre-recorded min_out). Single-tx sandwich now structurally impossible;
    /// cross-tx pre-positioning bounded by 5% baked tolerance.
    /// Body kept (with abort) for compat preservation of `acquires HandleFeeVault`
    /// annotation parity. Callers MUST switch to two-phase flow.
    public entry fun settle(_caller: &signer) acquires HandleFeeVault {
        let _ = borrow_global<HandleFeeVault>(vault_addr());
        abort E_USE_TWO_PHASE
    }

    /// v0.3.3 (G3): Phase 1 of MEV-safe settle. Records current pool quote +
    /// 5% slippage tolerance. After SETTLE_DELAY_SECS, anyone can call
    /// `execute_settle` to consume this snapshot. If cross-tx attacker shifts pool
    /// >5% during the 60s window, execute_settle aborts (pool moved too far).
    /// Pending settle expires after grace (cleanable via `cancel_pending_settle`).
    public entry fun request_settle(_caller: &signer) acquires HandleFeeVault {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(!exists<PendingSettle>(v_addr), E_PENDING_SETTLE_ALREADY_EXISTS);

        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let total = primary_fungible_store::balance(v_addr, apt_meta);
        assert!(total >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);

        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
        let to_burn = total - to_deployer;

        // Quote DESNET-out for to_burn at current reserves; bake 5% slippage tolerance.
        let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
        let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;

        let vault = borrow_global<HandleFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        move_to(&vault_signer, PendingSettle {
            requested_at_secs: aptos_framework::timestamp::now_seconds(),
            apt_balance_at_request: total,
            to_deployer_at_request: to_deployer,
            to_burn_at_request: to_burn,
            min_desnet_out: min_out,
        });
    }

    /// v0.3.3 (G3): Phase 2 of MEV-safe settle. Requires pending request from
    /// at least SETTLE_DELAY_SECS ago, within grace window. Enforces baked min_out
    /// — if pool moved >5% adversely since request, swap aborts (caller must
    /// `cancel_pending_settle` and `request_settle` again at fresh reserves).
    public entry fun execute_settle(_caller: &signer) acquires HandleFeeVault, PendingSettle {
        let v_addr = vault_addr();
        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
        assert!(exists<PendingSettle>(v_addr), E_PENDING_SETTLE_NOT_FOUND);

        let now = aptos_framework::timestamp::now_seconds();
        let pending_ref = borrow_global<PendingSettle>(v_addr);
        let requested_at = pending_ref.requested_at_secs;
        let min_out = pending_ref.min_desnet_out;
        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_PENDING_SETTLE_NOT_RIPE);
        assert!(now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS, E_PENDING_SETTLE_EXPIRED);

        // S1 fix: extract LOCKED amounts from snapshot — do NOT recompute from current balance.
        // Excess balance (current - apt_balance_at_request) stays in vault for next cycle.
        let PendingSettle {
            requested_at_secs: _,
            apt_balance_at_request,
            to_deployer_at_request,
            to_burn_at_request,
            min_desnet_out,
        } = move_from<PendingSettle>(v_addr);

        // Sanity check: vault must still have ≥ snapshot amount (vault has no withdraw path
        // other than this fn, so balance can only grow via deposits — never shrink).
        // v0.3.3 (Qwen R6 M1): distinct error from anti-dust threshold for monitor clarity.
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let current_total = primary_fungible_store::balance(v_addr, apt_meta);
        assert!(current_total >= apt_balance_at_request, E_VAULT_SHRUNK_BELOW_SNAPSHOT);

        let vault = borrow_global<HandleFeeVault>(v_addr);
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);

        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer_at_request);
        primary_fungible_store::deposit(vault.deployer_beneficiary, apt_for_deployer);

        // 90% APT swap with min_out enforcement — sandwich-safe per snapshot.
        // Swap amount AND min_out paired from same request snapshot — slippage check
        // properly bounds the actual swap size (S1 fix vs anchor-mismatch bug).
        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn_at_request);
        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, min_desnet_out);
        let desnet_burned = fungible_asset::amount(&desnet_fa);

        let desnet_apt_vault = factory::vault_addr_of_handle(DESNET_HANDLE);
        apt_vault::burn_via_vault(desnet_apt_vault, desnet_fa);

        // Settled.total_apt reflects snapshot amount actually settled (not current vault balance).
        event::emit(Settled {
            total_apt: apt_balance_at_request,
            to_deployer: to_deployer_at_request,
            desnet_burned,
        });
    }

    /// v0.3.3 (G3): permissionless cancel of stale/grief'd pending settle. Cost = gas only.
    /// Anyone can call to clear a stuck PendingSettle (e.g., griefer requested then
    /// abandoned, blocking honest caller from new request_settle).
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

    /// One-time poke: migrate stranded pre-upgrade fees from @desnet primary store.
    /// Pre-v0.3.1, register_handle deposited fees to `state.fee_receiver` (= @desnet
    /// at init). This pulls those funds into the vault for proper 10/90 split.
    public entry fun migrate_legacy_fees(_caller: &signer) {
        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
        let balance = primary_fungible_store::balance(@desnet, apt_meta);
        if (balance == 0) return;
        let pkg_signer = governance::derive_pkg_signer();
        let fa = primary_fungible_store::withdraw(&pkg_signer, apt_meta, balance);
        deposit_apt_fa(fa);
    }

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
