/// IPO (Initial Pool Offering) — replaces 90%-5%-5% with 100% pooled distribution.
///
/// ── Konsep ──
/// Buyer deposit SUPRA di harga entry tetap selama fase IPO. Setiap deposit
/// mint Position NFT (transferable) yang merepresentasikan LP shares di AMM pool.
///
/// ── Target TVL belum tercapai ──
///   Burn Position → refund 100% SUPRA (token kembali ke IPO reserve).
///
/// ── Target TVL tercapai ──
///   Pool unlock (swap enabled). LP holders earn swap fees via MasterChef
///   accumulator (amm::fee_per_lp_supra / fee_per_lp_token).
///   Principal tetap di pool — tidak bisa withdraw.
///
/// ── Subdomain Profile ──
///   IPO creator dapat main handle (PID NFT).
///   Peserta IPO dapat subdomain: `peserta@domain`.
module desnet::ipo {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use supra_framework::object::{Self, ExtendRef, DeleteRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::governance;

    friend desnet::factory;

    const SEED_IPO: vector<u8> = b"desnet::ipo::pool::";
    const SEED_SUBDOMAIN: vector<u8> = b"desnet::subdomain::";

    const E_IPO_NOT_FOUND: u64 = 1;
    const E_IPO_ALREADY_EXISTS: u64 = 2;
    const E_IPO_COMPLETED: u64 = 3;
    const E_IPO_NOT_COMPLETED: u64 = 4;
    const E_ZERO_DEPOSIT: u64 = 5;
    const E_OVER_TARGET: u64 = 6;
    const E_BELOW_TARGET: u64 = 7;
    const E_POSITION_NOT_FOUND: u64 = 8;
    const E_NOT_OWNER: u64 = 9;
    const E_NO_POOL: u64 = 10;
    const E_ALREADY_COMPLETED: u64 = 11;
    const E_NOTHING_TO_CLAIM: u64 = 12;
    const E_BAD_RATIO: u64 = 13;
    const E_SUBDOMAIN_TAKEN: u64 = 14;
    const E_INVALID_SUBDOMAIN: u64 = 15;

    /// ───── Types ─────

    struct IPOPool has key {
        handle: vector<u8>,
        token_metadata_addr: address,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
        total_supra_raised: u64,
        total_token_deployed: u64,
        completed: bool,
        supra_store: Object<FungibleStore>,
        token_store: Object<FungibleStore>,
        extend_ref: ExtendRef,
        pool_addr: address,
        total_lp: u128,
    }

    struct Position has key {
        ipo_addr: address,
        supra_deposited: u64,
        shares: u128,
        fee_debt_supra: u128,
        fee_debt_token: u128,
        delete_ref: DeleteRef,
        subdomain: String,
    }

    /// Subdomain registry per handle.
    struct SubdomainRegistry has key {
        domain: String,
        entries: SmartTable<String, address>,
    }

    /// ───── Events ─────

    #[event]
    struct IPOCreated has drop, store {
        handle: vector<u8>,
        ipo_addr: address,
        token_metadata_addr: address,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
    }

    #[event]
    struct DepositMade has drop, store {
        handle: vector<u8>,
        depositor: address,
        position_addr: address,
        supra_amount: u64,
        token_amount: u64,
        lp_minted: u128,
        total_supra_raised: u64,
        subdomain: String,
    }

    #[event]
    struct Refunded has drop, store {
        handle: vector<u8>,
        position_addr: address,
        depositor: address,
        supra_returned: u64,
        lp_burned: u128,
    }

    #[event]
    struct IPOCompleted has drop, store {
        handle: vector<u8>,
        pool_addr: address,
        total_supra: u64,
        total_token: u64,
        total_lp: u128,
    }

    #[event]
    struct FeesClaimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        supra_amount: u64,
        token_amount: u64,
    }

    #[event]
    struct SubdomainRegistered has drop, store {
        domain: String,
        subdomain: String,
        owner: address,
    }

    /// ───── Address derivation ─────

    public fun ipo_address_of_handle(handle: vector<u8>): address {
        object::create_object_address(&@desnet, ipo_seed(&handle))
    }

    fun ipo_seed(handle: &vector<u8>): vector<u8> {
        let s = SEED_IPO;
        vector::append(&mut s, *handle);
        s
    }

    fun subdomain_registry_address(handle: &vector<u8>): address {
        let s = SEED_SUBDOMAIN;
        vector::append(&mut s, *handle);
        object::create_object_address(&@desnet, s)
    }

    /// ───── Init (friend-only, dipanggil factory) ─────

    public(friend) fun create_ipo(
        handle: vector<u8>,
        token_metadata_addr: address,
        token_fa: FungibleAsset,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
    ) {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(!exists<IPOPool>(ipo_addr), E_IPO_ALREADY_EXISTS);
        assert!(target_tvl > 0, 1);
        assert!(entry_price_x > 0 && entry_price_y > 0, E_BAD_RATIO);
        assert!(fungible_asset::amount(&token_fa) > 0, 2);

        let pkg_signer = governance::derive_pkg_signer();
        let constructor = object::create_named_object(&pkg_signer, ipo_seed(&handle));
        let ipo_signer = object::generate_signer(&constructor);
        let extend_ref = object::generate_extend_ref(&constructor);
        let transfer_ref = object::generate_transfer_ref(&constructor);
        object::disable_ungated_transfer(&transfer_ref);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let supra_store = fungible_asset::create_store(&constructor, supra_meta);
        let token_meta = object::address_to_object<Metadata>(token_metadata_addr);
        let token_store = fungible_asset::create_store(&constructor, token_meta);

        fungible_asset::deposit(token_store, token_fa);

        move_to(&ipo_signer, IPOPool {
            handle,
            token_metadata_addr,
            target_tvl,
            entry_price_x,
            entry_price_y,
            total_supra_raised: 0,
            total_token_deployed: 0,
            completed: false,
            supra_store,
            token_store,
            extend_ref,
            pool_addr: @0x0,
            total_lp: 0,
        });

        // Init subdomain registry
        let reg_addr = subdomain_registry_address(&handle);
        if (!exists<SubdomainRegistry>(reg_addr)) {
            let reg_constructor = object::create_named_object(&pkg_signer, {
                let s = SEED_SUBDOMAIN;
                vector::append(&mut s, handle);
                s
            });
            let reg_signer = object::generate_signer(&reg_constructor);
            move_to(&reg_signer, SubdomainRegistry {
                domain: string::utf8(handle),
                entries: smart_table::new(),
            });
        };

        event::emit(IPOCreated {
            handle,
            ipo_addr,
            token_metadata_addr,
            target_tvl,
            entry_price_x,
            entry_price_y,
        });
    }

    /// ───── Deposit SUPRA ─────

    public entry fun deposit_supra(
        caller: &signer,
        handle: vector<u8>,
        amount: u64,
        subdomain: vector<u8>,
    ) acquires IPOPool, SubdomainRegistry {
        let caller_addr = signer::address_of(caller);
        assert!(amount > 0, E_ZERO_DEPOSIT);
        let sub_name = string::utf8(subdomain);
        validate_subdomain(&sub_name);

        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_IPO_COMPLETED);
        let new_total = ipo.total_supra_raised + amount;
        assert!(new_total <= ipo.target_tvl, E_OVER_TARGET);

        // Register subdomain
        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
        assert!(!smart_table::contains(&reg.entries, sub_name), E_SUBDOMAIN_TAKEN);
        smart_table::add(&mut reg.entries, sub_name, caller_addr);

        let token_amount = ((amount as u128) * (ipo.entry_price_y as u128)
            / (ipo.entry_price_x as u128)) as u64;
        assert!(token_amount > 0, E_ZERO_DEPOSIT);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let supra_fa = primary_fungible_store::withdraw(caller, supra_meta, amount);
        let ipo_signer = object::generate_signer_for_extending(&ipo.extend_ref);
        let token_fa = fungible_asset::withdraw(&ipo_signer, ipo.token_store, token_amount);

        let lp_minted: u128;
        if (ipo.pool_addr == @0x0) {
            ipo.pool_addr = amm::pool_address_of_handle(handle);
            lp_minted = amm::create_pool_atomic(handle, supra_fa, token_fa, ipo_addr, false);
        } else {
            let (lp, supra_refund, token_refund) = amm::add_liquidity_internal(
                handle, supra_fa, token_fa, 0,
            );
            lp_minted = lp;
            if (fungible_asset::amount(&supra_refund) > 0) {
                fungible_asset::deposit(ipo.supra_store, supra_refund);
            } else {
                fungible_asset::destroy_zero(supra_refund);
            };
            if (fungible_asset::amount(&token_refund) > 0) {
                fungible_asset::deposit(ipo.token_store, token_refund);
            } else {
                fungible_asset::destroy_zero(token_refund);
            };
        };

        ipo.total_supra_raised = new_total;
        ipo.total_token_deployed = ipo.total_token_deployed + token_amount;
        ipo.total_lp = ipo.total_lp + lp_minted;

        let (fee_supra, fee_token) = if (ipo.pool_addr != @0x0) {
            amm::fee_per_lp(handle)
        } else {
            (0u128, 0u128)
        };

        let pos_constructor = object::create_object(caller_addr);
        let pos_signer = object::generate_signer(&pos_constructor);
        let pos_addr = signer::address_of(&pos_signer);
        let pos_delete = object::generate_delete_ref(&pos_constructor);

        move_to(&pos_signer, Position {
            ipo_addr,
            supra_deposited: amount,
            shares: lp_minted,
            fee_debt_supra: fee_supra,
            fee_debt_token: fee_token,
            delete_ref: pos_delete,
            subdomain: sub_name,
        });

        event::emit(DepositMade {
            handle,
            depositor: caller_addr,
            position_addr: pos_addr,
            supra_amount: amount,
            token_amount,
            lp_minted,
            total_supra_raised: new_total,
            subdomain: sub_name,
        });

        event::emit(SubdomainRegistered {
            domain: reg.domain,
            subdomain: sub_name,
            owner: caller_addr,
        });
    }

    /// ───── Burn Position → refund SUPRA ─────

    public entry fun burn_for_refund(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires IPOPool, Position, SubdomainRegistry {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let pos_obj = object::address_to_object<Position>(position_addr);
        assert!(object::owner(pos_obj) == caller_addr, E_NOT_OWNER);

        let pos = borrow_global<Position>(position_addr);
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(pos.ipo_addr == ipo_addr, E_IPO_NOT_FOUND);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_IPO_COMPLETED);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);

        let lp_amount = pos.shares;
        let (supra_out, token_out) = amm::remove_liquidity_internal(handle, lp_amount, 0, 0);

        let ipo_signer = object::generate_signer_for_extending(&ipo.extend_ref);
        let supra_refund_amt = fungible_asset::amount(&supra_out);
        fungible_asset::deposit(ipo.token_store, token_out);

        primary_fungible_store::deposit(caller_addr, supra_out);

        ipo.total_lp = ipo.total_lp - lp_amount;
        ipo.total_supra_raised = ipo.total_supra_raised - pos.supra_deposited;

        // Release subdomain
        let reg_addr = subdomain_registry_address(&handle);
        if (exists<SubdomainRegistry>(reg_addr)) {
            let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
            if (smart_table::contains(&reg.entries, pos.subdomain)) {
                smart_table::remove(&mut reg.entries, pos.subdomain);
            };
        };

        let sub_name = pos.subdomain;
        let Position {
            ipo_addr: _,
            supra_deposited: _,
            shares: _,
            fee_debt_supra: _,
            fee_debt_token: _,
            delete_ref,
            subdomain: _,
        } = move_from<Position>(position_addr);
        object::delete(delete_ref);

        event::emit(Refunded {
            handle,
            position_addr,
            depositor: caller_addr,
            supra_returned: supra_refund_amt,
            lp_burned: lp_amount,
        });
    }

    /// ───── Complete IPO ─────

    public entry fun complete_ipo(
        _caller: &signer,
        handle: vector<u8>,
    ) acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_ALREADY_COMPLETED);
        assert!(ipo.total_supra_raised >= ipo.target_tvl, E_BELOW_TARGET);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);

        ipo.completed = true;
        amm::enable_swaps(handle);

        event::emit(IPOCompleted {
            handle,
            pool_addr: ipo.pool_addr,
            total_supra: ipo.total_supra_raised,
            total_token: ipo.total_token_deployed,
            total_lp: ipo.total_lp,
        });
    }

    /// ───── Claim fees ─────

    public entry fun claim_fees(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let pos_obj = object::address_to_object<Position>(position_addr);
        assert!(object::owner(pos_obj) == caller_addr, E_NOT_OWNER);

        let pos = borrow_global_mut<Position>(position_addr);
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(pos.ipo_addr == ipo_addr, E_IPO_NOT_FOUND);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        assert!(ipo.completed, E_IPO_NOT_COMPLETED);

        let (fee_supra, fee_token) = amm::fee_per_lp(handle);
        let scale = amm::fee_acc_scale();

        let raw_pending_supra = (pos.shares as u128) * fee_supra;
        let raw_debt_supra = (pos.shares as u128) * pos.fee_debt_supra;
        let pending_supra = (raw_pending_supra / scale) - (raw_debt_supra / scale);

        let raw_pending_token = (pos.shares as u128) * fee_token;
        let raw_debt_token = (pos.shares as u128) * pos.fee_debt_token;
        let pending_token = (raw_pending_token / scale) - (raw_debt_token / scale);

        assert!((pending_supra + pending_token) > 0, E_NOTHING_TO_CLAIM);

        pos.fee_debt_supra = fee_supra;
        pos.fee_debt_token = fee_token;

        let (supra_fa, token_fa) = amm::extract_fees_for_claim(
            handle, (pending_supra as u64), (pending_token as u64),
        );

        if (fungible_asset::amount(&supra_fa) > 0) {
            primary_fungible_store::deposit(caller_addr, supra_fa);
        } else {
            fungible_asset::destroy_zero(supra_fa);
        };
        if (fungible_asset::amount(&token_fa) > 0) {
            primary_fungible_store::deposit(caller_addr, token_fa);
        } else {
            fungible_asset::destroy_zero(token_fa);
        };

        event::emit(FeesClaimed {
            handle,
            position_addr,
            recipient: caller_addr,
            supra_amount: (pending_supra as u64),
            token_amount: (pending_token as u64),
        });
    }

    /// ───── Views ─────

    #[view]
    public fun ipo_info(handle: vector<u8>): (
        address, u64, u64, u64, u64, u64, bool, address, u128,
    ) acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        (
            ipo.token_metadata_addr,
            ipo.target_tvl,
            ipo.entry_price_x,
            ipo.entry_price_y,
            ipo.total_supra_raised,
            ipo.total_token_deployed,
            ipo.completed,
            ipo.pool_addr,
            ipo.total_lp,
        )
    }

    #[view]
    public fun position_info(position_addr: address): (
        address, u64, u128, u128, u128, String,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pos = borrow_global<Position>(position_addr);
        (
            pos.ipo_addr,
            pos.supra_deposited,
            pos.shares,
            pos.fee_debt_supra,
            pos.fee_debt_token,
            pos.subdomain,
        )
    }

    #[view]
    public fun pending_fees(
        handle: vector<u8>,
        position_addr: address,
    ): (u64, u64) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pos = borrow_global<Position>(position_addr);
        let (fee_supra, fee_token) = amm::fee_per_lp(handle);
        let scale = amm::fee_acc_scale();
        let pending_supra = ((pos.shares as u128) * fee_supra / scale)
            .saturating_sub((pos.shares as u128) * pos.fee_debt_supra / scale);
        let pending_token = ((pos.shares as u128) * fee_token / scale)
            .saturating_sub((pos.shares as u128) * pos.fee_debt_token / scale);
        ((pending_supra as u64), (pending_token as u64))
    }

    #[view]
    public fun resolve_subdomain(handle: vector<u8>, subdomain: String): address
    acquires SubdomainRegistry {
        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global<SubdomainRegistry>(reg_addr);
        assert!(smart_table::contains(&reg.entries, subdomain), E_SUBDOMAIN_TAKEN);
        *smart_table::borrow(&reg.entries, subdomain)
    }

    #[view]
    public fun has_subdomain(handle: vector<u8>, subdomain: String): bool
    acquires SubdomainRegistry {
        let reg_addr = subdomain_registry_address(&handle);
        if (!exists<SubdomainRegistry>(reg_addr)) return false;
        let reg = borrow_global<SubdomainRegistry>(reg_addr);
        smart_table::contains(&reg.entries, subdomain)
    }

    /// ───── Validation ─────

    fun validate_subdomain(name: &String) {
        let len = string::length(name);
        assert!(len >= 1 && len <= 32, E_INVALID_SUBDOMAIN);
        let bytes = string::bytes(name);
        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(bytes, i);
            let ok = (ch >= 0x61 && ch <= 0x7A)
                  || (ch >= 0x30 && ch <= 0x39)
                  || ch == 0x2D;
            assert!(ok, E_INVALID_SUBDOMAIN);
            i = i + 1;
        };
    }
}
