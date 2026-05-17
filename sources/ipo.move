module desnet::ipo {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use desnet::amm;
    use desnet::governance;
    use desnet::voter_history;
    use desnet::profile;
    use desnet::lp_emission;

    friend desnet::factory;
    friend desnet::registration;

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
    const E_EXCEEDS_MAX_ALLOCATION: u64 = 16;
    const E_TARGET_TOO_LOW: u64 = 17;

    const MAX_PER_ADDRESS_BPS: u64 = 100;
    const MAX_CREATOR_BPS: u64 = 1000;
    const MIN_TARGET_TVL: u64 = 100_000_000_000_000;

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
        depositor_totals: SmartTable<address, u64>,
        creator_wallet: address,
    }

    struct Position has key {
        ipo_addr: address,
        depositor: address,
        supra_deposited: u64,
        shares: u128,
        fee_debt_supra: u128,
        fee_debt_token: u128,
        reward_debts: SmartTable<address, u128>,
        subdomain: String,
    }

    struct SubdomainRegistry has key {
        domain: String,
        entries: SmartTable<String, address>,
    }

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

    #[event]
    struct LpRewardsClaimed has drop, store {
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
        reward_token: address,
        amount: u64,
    }

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

    public(friend) fun create_ipo(
        handle: vector<u8>,
        token_metadata_addr: address,
        token_fa: FungibleAsset,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
        creator_wallet: address,
    ) {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(!exists<IPOPool>(ipo_addr), E_IPO_ALREADY_EXISTS);
        assert!(target_tvl >= MIN_TARGET_TVL, E_TARGET_TOO_LOW);
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
            depositor_totals: smart_table::new(),
            creator_wallet,
        });

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
        let addr_total = if (smart_table::contains(&ipo.depositor_totals, caller_addr)) {
            *smart_table::borrow(&ipo.depositor_totals, caller_addr)
        } else { 0 };
        let bps = if (caller_addr == ipo.creator_wallet) { MAX_CREATOR_BPS } else { MAX_PER_ADDRESS_BPS };
        let max_per_addr = (ipo.target_tvl * bps) / 10000;
        assert!(addr_total + amount <= max_per_addr, E_EXCEEDS_MAX_ALLOCATION);
        smart_table::upsert(&mut ipo.depositor_totals, caller_addr, addr_total + amount);

        let token_amount = (((amount as u128) * (ipo.entry_price_y as u128)
            / (ipo.entry_price_x as u128)) as u64);
        assert!(token_amount > 0, E_ZERO_DEPOSIT);

        let supra_meta = object::address_to_object<Metadata>(governance::native_fa_metadata());
        let supra_fa = primary_fungible_store::withdraw(caller, supra_meta, amount);
        let ipo_signer = object::generate_signer_for_extending(&ipo.extend_ref);
        let token_fa = fungible_asset::withdraw(&ipo_signer, ipo.token_store, token_amount);

        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
        assert!(!smart_table::contains(&reg.entries, sub_name), E_SUBDOMAIN_TAKEN);
        smart_table::add(&mut reg.entries, sub_name, caller_addr);

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
                primary_fungible_store::deposit(caller_addr, supra_refund);
            } else {
                fungible_asset::destroy_zero(supra_refund);
            };
            if (fungible_asset::amount(&token_refund) > 0) {
                primary_fungible_store::deposit(caller_addr, token_refund);
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

        let reward_tokens = lp_emission::reward_tokens_of(handle);
        let reward_debts = smart_table::new<address, u128>();
        let rt_i = 0;
        let rt_n = vector::length(&reward_tokens);
        while (rt_i < rt_n) {
            let rt = *vector::borrow(&reward_tokens, rt_i);
            let acc = lp_emission::acc_per_share_of(handle, rt);
            smart_table::add(&mut reward_debts, rt, (lp_minted as u128) * acc);
            rt_i = rt_i + 1;
        };

        lp_emission::on_share_increase(handle, lp_minted);

        let protocol_signer = governance::derive_pkg_signer();
        profile::create_subdomain_profile(
            &protocol_signer, string::utf8(handle), sub_name, caller_addr, !ipo.completed,
        );
        let pos_addr = profile::derive_subdomain_pid_address(string::utf8(handle), sub_name);
        let pos_signer = profile::derive_pid_signer(pos_addr);

        move_to(&pos_signer, Position {
            ipo_addr,
            depositor: caller_addr,
            supra_deposited: amount,
            shares: lp_minted,
            fee_debt_supra: fee_supra,
            fee_debt_token: fee_token,
            reward_debts,
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

    public entry fun burn_for_refund(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
        min_supra_out: u64,
        min_token_out: u64,
    ) acquires IPOPool, Position, SubdomainRegistry {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

        claim_lp_rewards_internal(handle, position_addr, caller_addr);

        let pos = borrow_global<Position>(position_addr);
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(pos.ipo_addr == ipo_addr, E_IPO_NOT_FOUND);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_IPO_COMPLETED);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);

        let lp_amount = pos.shares;
        let (supra_out, token_out) = amm::remove_liquidity_internal(
            handle, lp_amount, min_supra_out, min_token_out,
        );

        let supra_refund_amt = fungible_asset::amount(&supra_out);
        if (supra_refund_amt > 0) {
            primary_fungible_store::deposit(caller_addr, supra_out);
        } else {
            fungible_asset::destroy_zero(supra_out);
        };
        if (fungible_asset::amount(&token_out) > 0) {
            fungible_asset::deposit(ipo.token_store, token_out);
        } else {
            fungible_asset::destroy_zero(token_out);
        };

        ipo.total_lp = ipo.total_lp - lp_amount;
        ipo.total_supra_raised = ipo.total_supra_raised - pos.supra_deposited;

        if (caller_addr == pos.depositor) {
            let original_depositor = pos.depositor;
            let remaining = *smart_table::borrow(&ipo.depositor_totals, original_depositor) - pos.supra_deposited;
            if (remaining == 0) {
                smart_table::remove(&mut ipo.depositor_totals, original_depositor);
            } else {
                *smart_table::borrow_mut(&mut ipo.depositor_totals, original_depositor) = remaining;
            };
        };

        let reg_addr = subdomain_registry_address(&handle);
        if (exists<SubdomainRegistry>(reg_addr)) {
            let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
            if (smart_table::contains(&reg.entries, pos.subdomain)) {
                smart_table::remove(&mut reg.entries, pos.subdomain);
            };
        };

        lp_emission::on_share_decrease(handle, lp_amount);

        let Position {
            ipo_addr: _,
            depositor: _,
            supra_deposited: _,
            shares: _,
            fee_debt_supra: _,
            fee_debt_token: _,
            reward_debts,
            subdomain: _,
        } = move_from<Position>(position_addr);
        smart_table::destroy(reward_debts);

        event::emit(Refunded {
            handle,
            position_addr,
            depositor: caller_addr,
            supra_returned: supra_refund_amt,
            lp_burned: lp_amount,
        });
    }

    public entry fun complete_ipo(
        _caller: &signer,
        handle: vector<u8>,
    ) acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global_mut<IPOPool>(ipo_addr);
        assert!(!ipo.completed, E_ALREADY_COMPLETED);
        assert!(ipo.pool_addr != @0x0, E_NO_POOL);
        assert!(ipo.total_supra_raised >= ipo.target_tvl, E_BELOW_TARGET);

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

    public entry fun claim_fees(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires Position, IPOPool {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

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
        let token_fee_amount = fungible_asset::amount(&token_fa);
        if (token_fee_amount > 0) {
            primary_fungible_store::deposit(caller_addr, token_fa);
            if (ipo.token_metadata_addr == governance::desnet_fa_addr()) {
                let pkg_signer = governance::derive_pkg_signer();
                voter_history::record_reward_received_for_token(
                    &pkg_signer, caller_addr, governance::desnet_fa_addr(), token_fee_amount,
                );
            };
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

    public entry fun claim_lp_rewards(
        _caller: &signer,
        handle: vector<u8>,
        position_addr: address,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        let owner = object::owner(pid_obj);
        claim_lp_rewards_internal(handle, position_addr, owner);
    }

    fun claim_lp_rewards_internal(
        handle: vector<u8>,
        position_addr: address,
        recipient: address,
    ) acquires Position {
        let reward_tokens = lp_emission::reward_tokens_of(handle);
        let n = vector::length(&reward_tokens);
        if (n == 0) return;

        let pos = borrow_global_mut<Position>(position_addr);
        let shares = pos.shares;
        let scale = lp_emission::acc_scale();
        let desnet_fa = governance::desnet_fa_addr();

        let i = 0;
        while (i < n) {
            let token_addr = *vector::borrow(&reward_tokens, i);
            let acc = lp_emission::acc_per_share_of(handle, token_addr);
            let owed_raw = (shares as u128) * acc;
            let debt = if (smart_table::contains(&pos.reward_debts, token_addr)) {
                *smart_table::borrow(&pos.reward_debts, token_addr)
            } else {
                0u128
            };
            if (owed_raw > debt) {
                let pending = (((owed_raw - debt) / scale) as u64);
                if (pending > 0) {
                    let token_meta = object::address_to_object<Metadata>(token_addr);
                    let fa = lp_emission::withdraw_reward(handle, token_meta, pending);
                    primary_fungible_store::deposit(recipient, fa);

                    if (smart_table::contains(&pos.reward_debts, token_addr)) {
                        *smart_table::borrow_mut(&mut pos.reward_debts, token_addr) = owed_raw;
                    } else {
                        smart_table::add(&mut pos.reward_debts, token_addr, owed_raw);
                    };

                    if (token_addr == desnet_fa) {
                        let pkg_signer = governance::derive_pkg_signer();
                        voter_history::record_reward_received_for_token(
                            &pkg_signer, recipient, token_addr, pending,
                        );
                    };

                    event::emit(LpRewardsClaimed {
                        handle,
                        position_addr,
                        recipient,
                        reward_token: token_addr,
                        amount: pending,
                    });
                };
            };
            i = i + 1;
        };
    }

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

    public entry fun claim_subdomain_pid(
        caller: &signer,
        handle: vector<u8>,
        position_addr: address,
        subdomain: vector<u8>,
    ) acquires IPOPool, SubdomainRegistry {
        let caller_addr = signer::address_of(caller);
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pid_obj = object::address_to_object<profile::Profile>(position_addr);
        assert!(object::owner(pid_obj) == caller_addr, E_NOT_OWNER);

        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        assert!(ipo.completed, E_IPO_NOT_COMPLETED);

        let sub_name = string::utf8(subdomain);
        validate_subdomain(&sub_name);

        let reg_addr = subdomain_registry_address(&handle);
        assert!(exists<SubdomainRegistry>(reg_addr), E_IPO_NOT_FOUND);
        let reg = borrow_global_mut<SubdomainRegistry>(reg_addr);
        assert!(!smart_table::contains(&reg.entries, sub_name), E_SUBDOMAIN_TAKEN);
        smart_table::add(&mut reg.entries, sub_name, caller_addr);

        let protocol_signer = governance::derive_pkg_signer();
        profile::create_subdomain_profile(
            &protocol_signer, string::utf8(handle), sub_name, caller_addr, false,
        );
    }

    #[view]
    public fun position_info(position_addr: address): (
        address, address, u64, u128, u128, u128, String,
    ) acquires Position {
        assert!(exists<Position>(position_addr), E_POSITION_NOT_FOUND);
        let pos = borrow_global<Position>(position_addr);
        (
            pos.ipo_addr,
            pos.depositor,
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
        let raw_pending_supra = ((pos.shares as u128) * fee_supra) / scale;
        let raw_debt_supra = ((pos.shares as u128) * pos.fee_debt_supra) / scale;
        let pending_supra = if (raw_pending_supra > raw_debt_supra) {
            raw_pending_supra - raw_debt_supra
        } else { 0 };
        let raw_pending_token = ((pos.shares as u128) * fee_token) / scale;
        let raw_debt_token = ((pos.shares as u128) * pos.fee_debt_token) / scale;
        let pending_token = if (raw_pending_token > raw_debt_token) {
            raw_pending_token - raw_debt_token
        } else { 0 };
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

    #[view]
    public fun depositor_total(handle: vector<u8>, depositor: address): u64
    acquires IPOPool {
        let ipo_addr = ipo_address_of_handle(handle);
        assert!(exists<IPOPool>(ipo_addr), E_IPO_NOT_FOUND);
        let ipo = borrow_global<IPOPool>(ipo_addr);
        if (smart_table::contains(&ipo.depositor_totals, depositor)) {
            *smart_table::borrow(&ipo.depositor_totals, depositor)
        } else { 0 }
    }

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

    spec module {
        invariant update [suspendable]
            forall ipo_p: address:
                (old(exists<IPOPool>(ipo_p)) && exists<IPOPool>(ipo_p))
                ==> (old(borrow_global<IPOPool>(ipo_p).pool_addr) != @0x0
                     ==> borrow_global<IPOPool>(ipo_p).pool_addr == old(borrow_global<IPOPool>(ipo_p).pool_addr));

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).completed ==> borrow_global<IPOPool>(ipo_p).pool_addr != @0x0;

        invariant update [suspendable]
            forall ipo_p: address:
                (old(exists<IPOPool>(ipo_p)) && exists<IPOPool>(ipo_p))
                ==> (old(borrow_global<IPOPool>(ipo_p).completed) ==> borrow_global<IPOPool>(ipo_p).completed);

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                !borrow_global<IPOPool>(ipo_p).completed
                ==> borrow_global<IPOPool>(ipo_p).total_supra_raised <= borrow_global<IPOPool>(ipo_p).target_tvl;

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).target_tvl >= MIN_TARGET_TVL;

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).entry_price_x > 0
                && borrow_global<IPOPool>(ipo_p).entry_price_y > 0;

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).total_lp <= 340282366920938463463374607431768211455;

        invariant [suspendable]
            forall ipo_p: address where exists<IPOPool>(ipo_p):
                borrow_global<IPOPool>(ipo_p).token_metadata_addr != @0x0;
    }

    spec fun spec_ipo_seed(handle: vector<u8>): vector<u8> {
        concat(SEED_IPO, handle)
    }

    spec fun spec_subdomain_seed(handle: vector<u8>): vector<u8> {
        concat(SEED_SUBDOMAIN, handle)
    }

    spec position_info {
        aborts_if !exists<Position>(position_addr);
    }
    spec pending_fees {
        aborts_if !exists<Position>(position_addr);
    }
}
