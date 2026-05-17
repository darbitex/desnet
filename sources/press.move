module desnet::press {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use supra_framework::event;
    use supra_framework::object::{Self, ExtendRef};
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty;
    use aptos_token_objects::token;

    use desnet::profile;
    use desnet::mint;
    use desnet::link;
    use desnet::reference_gate;
    use desnet::history;
    use desnet::factory;
    use desnet::reaction_emission;

    const SUPPLY_CAP_MIN: u16 = 1;
    const SUPPLY_CAP_MAX: u16 = 1000;
    const WINDOW_DAYS_MIN: u8 = 1;
    const WINDOW_DAYS_MAX: u8 = 7;
    const ROYALTY_BPS: u64 = 500;

    const E_PRESS_NOT_ENABLED: u64 = 1;
    const E_PRESS_WINDOW_EXPIRED: u64 = 2;
    const E_PRESS_SUPPLY_EXHAUSTED: u64 = 3;
    const E_ALREADY_PRESSED: u64 = 4;
    const E_GATE_FAILED: u64 = 5;
    const E_INVALID_SUPPLY_CAP: u64 = 6;
    const E_INVALID_WINDOW_DAYS: u64 = 7;
    const E_PRESS_REGISTRY_NOT_FOUND: u64 = 8;
    const E_NOT_AUTHOR: u64 = 9;
    const E_PRESS_ALREADY_CONFIGURED: u64 = 10;
    const E_MINT_NOT_FOUND: u64 = 11;

    struct PressConfig has store, copy, drop {
        supply_cap: u16,
        window_us: u64,
        pressed_count: u16,
        emission_consumed_total: u64,
        deadline_us: u64,
    }

    struct PressedRegistry has store {
        pressed_by: SmartTable<address, bool>,
    }

    struct PidPressStorage has key {
        configs: SmartTable<u64, PressConfig>,
        registries: SmartTable<u64, PressedRegistry>,
    }

    struct PressCollection has key {
        collection_addr: address,
        extend_ref: ExtendRef,
        name: String,
    }

    #[event]
    struct PressEnabled has drop, store {
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_us: u64,
        deadline_us: u64,
        timestamp_secs: u64,
    }

    struct PressMinted has drop, store {
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        press_order: u16,
        emission_amount: u64,
        nft_object_addr: address,
        timestamp_secs: u64,
    }

    fun ensure_press_storage(pid_addr: address) {
        if (!exists<PidPressStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidPressStorage {
                configs: smart_table::new(),
                registries: smart_table::new(),
            });
        };
    }

    fun ensure_press_collection(author_pid: address): address acquires PressCollection {
        if (exists<PressCollection>(author_pid)) {
            return borrow_global<PressCollection>(author_pid).collection_addr
        };

        let pid_signer = profile::derive_pid_signer(author_pid);
        let handle = profile::handle_of(author_pid);
        let collection_name = build_collection_name(&handle);

        let payee = factory::vault_addr_of_pid(author_pid);
        let r = royalty::create(ROYALTY_BPS, 10000, payee);

        let constructor_ref = collection::create_unlimited_collection(
            &pid_signer,
            build_collection_description(&handle),
            collection_name,
            option::some(r),
            build_collection_uri(&handle),
        );

        let collection_addr = object::address_from_constructor_ref(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(&pid_signer, PressCollection {
            collection_addr,
            extend_ref,
            name: collection_name,
        });

        collection_addr
    }

    fun build_collection_name(handle: &String): String {
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s Presses");
        s
    }

    fun build_collection_description(handle: &String): String {
        let s = string::utf8(b"Press NFTs collected from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mints on DeSNet.");
        s
    }

    fun build_collection_uri(_handle: &String): String {
        string::utf8(b"")
    }

    fun build_token_name(handle: &String, mint_seq: u64, press_order: u16): String {
        let s = string::utf8(b"");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b" #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b" press #");
        string::append(&mut s, u64_to_string((press_order as u64)));
        s
    }

    fun build_token_description(handle: &String, mint_seq: u64): String {
        let s = string::utf8(b"Pressed from ");
        string::append(&mut s, *handle);
        string::append_utf8(&mut s, b"'s mint #");
        string::append(&mut s, u64_to_string(mint_seq));
        string::append_utf8(&mut s, b".");
        s
    }

    fun build_token_uri(_handle: &String, _mint_seq: u64): String {
        string::utf8(b"")
    }

    fun u64_to_string(n: u64): String {
        if (n == 0) return string::utf8(b"0");
        let buf = std::vector::empty<u8>();
        while (n > 0) {
            let d = ((n % 10) as u8) + 0x30;
            std::vector::push_back(&mut buf, d);
            n = n / 10;
        };
        std::vector::reverse(&mut buf);
        string::utf8(buf)
    }

    public entry fun enable_press(
        author: &signer,
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_days: u8,
    ) acquires PidPressStorage {
        assert!(supply_cap >= SUPPLY_CAP_MIN && supply_cap <= SUPPLY_CAP_MAX, E_INVALID_SUPPLY_CAP);
        assert!(window_days >= WINDOW_DAYS_MIN && window_days <= WINDOW_DAYS_MAX, E_INVALID_WINDOW_DAYS);

        profile::assert_authorized(author, author_pid);

        assert!(mint_seq < mint::next_seq(author_pid), E_MINT_NOT_FOUND);

        ensure_press_storage(author_pid);

        let storage = borrow_global_mut<PidPressStorage>(author_pid);
        assert!(!smart_table::contains(&storage.configs, mint_seq), E_PRESS_ALREADY_CONFIGURED);

        let now_us = timestamp::now_seconds() * 1_000_000;
        let window_us = (window_days as u64) * 86_400 * 1_000_000;
        let deadline_us = now_us + window_us;

        let config = PressConfig {
            supply_cap,
            window_us,
            pressed_count: 0,
            emission_consumed_total: 0,
            deadline_us,
        };

        smart_table::add(&mut storage.configs, mint_seq, config);
        smart_table::add(&mut storage.registries, mint_seq, PressedRegistry {
            pressed_by: smart_table::new(),
        });

        event::emit(PressEnabled {
            author_pid,
            mint_seq,
            supply_cap,
            window_us,
            deadline_us,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    public entry fun press(
        presser: &signer,
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        presser_stake_position_addr: address,
    ) acquires PidPressStorage, PressCollection {
        profile::assert_authorized(presser, presser_pid);
        let presser_addr = signer::address_of(presser);

        assert!(exists<PidPressStorage>(author_pid), E_PRESS_NOT_ENABLED);

        if (presser_pid != author_pid) {
            let gate_opt = mint::get_mint_gate(author_pid, mint_seq);
            if (option::is_some(&gate_opt)) {
                let target_pid = profile::reference_gate_target_pid(option::borrow(&gate_opt));
                let synced = link::is_synced(presser_pid, target_pid);
                let gate = option::extract(&mut gate_opt);
                assert!(
                    reference_gate::check(&gate, presser_addr, synced, false, presser_stake_position_addr),
                    E_GATE_FAILED
                );
            };
        };

        let press_order: u16;
        {
            let storage = borrow_global_mut<PidPressStorage>(author_pid);
            assert!(smart_table::contains(&storage.configs, mint_seq), E_PRESS_NOT_ENABLED);

            let config = smart_table::borrow_mut(&mut storage.configs, mint_seq);
            let now_us = timestamp::now_seconds() * 1_000_000;
            assert!(now_us < config.deadline_us, E_PRESS_WINDOW_EXPIRED);
            assert!(config.pressed_count < config.supply_cap, E_PRESS_SUPPLY_EXHAUSTED);

            let registry = smart_table::borrow_mut(&mut storage.registries, mint_seq);
            assert!(!smart_table::contains(&registry.pressed_by, presser_pid), E_ALREADY_PRESSED);

            smart_table::add(&mut registry.pressed_by, presser_pid, true);
            config.pressed_count = config.pressed_count + 1;
            press_order = config.pressed_count;
            let emission_amount_local = (press_order as u64);
            config.emission_consumed_total = config.emission_consumed_total + emission_amount_local;
        };

        let _collection_addr = ensure_press_collection(author_pid);

        let handle = profile::handle_of(author_pid);
        let token_name = build_token_name(&handle, mint_seq, press_order);
        let token_description = build_token_description(&handle, mint_seq);
        let token_uri = build_token_uri(&handle, mint_seq);

        let collection_state = borrow_global<PressCollection>(author_pid);
        let collection_name = collection_state.name;

        let pid_signer = profile::derive_pid_signer(author_pid);

        let token_constructor_ref = token::create(
            &pid_signer,
            collection_name,
            token_description,
            token_name,
            option::none(),
            token_uri,
        );

        let nft_object_addr = object::address_from_constructor_ref(&token_constructor_ref);
        let token_object = object::object_from_constructor_ref<token::Token>(&token_constructor_ref);

        object::transfer(&pid_signer, token_object, presser_addr);

        let emission_amount = if (presser_pid == author_pid) {
            0u64
        } else {
            reaction_emission::distribute_to_presser(author_pid, presser_addr)
        };

        let now_secs = timestamp::now_seconds();
        let record = PressMinted {
            presser_pid,
            author_pid,
            mint_seq,
            press_order,
            emission_amount,
            nft_object_addr,
            timestamp_secs: now_secs,
        };
        let payload = bcs::to_bytes(&record);
        history::append(
            presser_pid,
            history::new_entry(history::verb_press(), now_secs, option::some(author_pid), payload, option::none<address>()),
        );
    }

    #[view]
    public fun is_press_enabled(author_pid: address, mint_seq: u64): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        smart_table::contains(&borrow_global<PidPressStorage>(author_pid).configs, mint_seq)
    }

    #[view]
    public fun pressed_count(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return 0;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.configs, mint_seq)) return 0;
        smart_table::borrow(&storage.configs, mint_seq).pressed_count
    }

    #[view]
    public fun supply_cap(author_pid: address, mint_seq: u64): u16 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).supply_cap
    }

    #[view]
    public fun deadline_us(author_pid: address, mint_seq: u64): u64 acquires PidPressStorage {
        let storage = borrow_global<PidPressStorage>(author_pid);
        smart_table::borrow(&storage.configs, mint_seq).deadline_us
    }

    #[view]
    public fun has_pressed(
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
    ): bool acquires PidPressStorage {
        if (!exists<PidPressStorage>(author_pid)) return false;
        let storage = borrow_global<PidPressStorage>(author_pid);
        if (!smart_table::contains(&storage.registries, mint_seq)) return false;
        let registry = smart_table::borrow(&storage.registries, mint_seq);
        smart_table::contains(&registry.pressed_by, presser_pid)
    }

    #[view]
    public fun royalty_bps(): u64 { ROYALTY_BPS }
}
