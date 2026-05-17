/// Press - NFT collectible wrapping a Mint (LOCKED 2026-05-01).
///
/// Vinyl-pressing metaphor: original recording (Mint) -> physical vinyl (Press NFT).
/// Press IS technically a mint, but at NFT layer (different scope from Mint event).
///
/// Per-mint opt-in PressConfig (LOCKED):
///   - supply_cap: u16 (1-1000, no unlimited v1)
///   - window_days: u8 (1-7, no permanent open)
///   - emission curve: linear INCREASING per press order (anti-FOMO design):
///       emission(n) = n  (press #1 = 1 token, press #1000 = 1000 tokens)
///       Total per post: cap * (cap+1) / 2 (= 500,500 at cap=1000)
///
/// Per-actor uniqueness: each wallet can press a given mint ONLY once.
/// Author may self-press own mint, max 1 (same one-per-actor rule).
///
/// Royalty: 5% Supra NFT v2 native, payee = PID Object addr (current owner).
/// Marketplace patuh otomatis. Future Press royalty 10% routed to vault (v2 spec).
///
/// First press = FREE (gas only). v1 tidak ada paid press; monetization = secondary market.
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

    // ============ CONSTANTS ============

    const SUPPLY_CAP_MIN: u16 = 1;
    const SUPPLY_CAP_MAX: u16 = 1000;
    const WINDOW_DAYS_MIN: u8 = 1;
    const WINDOW_DAYS_MAX: u8 = 7;
    const ROYALTY_BPS: u64 = 500;            // 5% Supra NFT v2 native

    // ============ ERROR CODES ============

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

    // ============ TYPES ============

    /// Per-mint Press configuration. Stored at author's PID, keyed by mint seq.
    struct PressConfig has store, copy, drop {
        supply_cap: u16,                     // 1-1000
        window_us: u64,                      // creation_ts + window_us = deadline
        pressed_count: u16,                  // mutable counter
        emission_consumed_total: u64,        // running sum of emissions
        deadline_us: u64,                    // creation_ts + window
    }

    /// Per-mint pressed registry (per-actor uniqueness check).
    /// Lives at author_pid, keyed by mint seq.
    struct PressedRegistry has store {
        pressed_by: SmartTable<address, bool>,  // actor -> true after press
    }

    /// Per-author Press storage. SmartTable<seq, (PressConfig, PressedRegistry)>.
    struct PidPressStorage has key {
        configs: SmartTable<u64, PressConfig>,
        registries: SmartTable<u64, PressedRegistry>,
    }

    /// Per-author Press NFT Collection. Lazy-init at first press of any of author's mints.
    /// beta-pattern (LOCKED 2026-04-30): "<handle>'s Presses" collection, all of author's
    /// Press NFTs minted into this single collection. Marketplaces auto-list them
    /// under author's brand.
    struct PressCollection has key {
        collection_addr: address,
        extend_ref: ExtendRef,                // for minting child tokens via Collection signer
        name: String,                          // e.g., "alice's Presses"
    }

    // ============ EVENTS ============

    #[event]
    struct PressEnabled has drop, store {
        author_pid: address,
        mint_seq: u64,
        supply_cap: u16,
        window_us: u64,
        deadline_us: u64,
        timestamp_secs: u64,
    }

    /// Press record. Replaces former #[event] - now BCS-encoded into
    /// history::Entry.payload at presser's PID. Struct retained for canonical encoding.
    struct PressMinted has drop, store {
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        press_order: u16,                    // n-th press (1-indexed)
        emission_amount: u64,                // = press_order (linear increasing)
        nft_object_addr: address,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT - on-demand per-PID storage ============

    /// Lazy-create PidPressStorage at PID addr. Called from enable_press on first-write.
    /// Idempotent. Cycle-safe via profile::derive_pid_signer friend pattern.
    fun ensure_press_storage(pid_addr: address) {
        if (!exists<PidPressStorage>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidPressStorage {
                configs: smart_table::new(),
                registries: smart_table::new(),
            });
        };
    }

    /// Lazy-create PressCollection at PID addr. Called from press() on first press of
    /// any of author's mints. Creates "<handle>'s Presses" collection with 5% royalty
    /// to author_pid.
    fun ensure_press_collection(author_pid: address): address acquires PressCollection {
        if (exists<PressCollection>(author_pid)) {
            return borrow_global<PressCollection>(author_pid).collection_addr
        };

        let pid_signer = profile::derive_pid_signer(author_pid);
        let handle = profile::handle_of(author_pid);
        let collection_name = build_collection_name(&handle);

        // 5% royalty payee = author's Vault addr -> marketplace royalties land at vault,
        // triggering the 50/50 buyback-burn + PID-owner split flow on settle.
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
        // Empty URI - frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    fun build_token_name(handle: &String, mint_seq: u64, press_order: u16): String {
        // Format: "<handle> #<mint_seq> press #<press_order>"
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
        // Empty URI - frontend constructs at render time. No hardcoded domain in source.
        string::utf8(b"")
    }

    /// Simple u64 -> decimal String. Supra stdlib doesn't have utoa, hand-roll.
    fun u64_to_string(n: u64): String {
        if (n == 0) return string::utf8(b"0");
        let buf = std::vector::empty<u8>();
        while (n > 0) {
            let d = ((n % 10) as u8) + 0x30;  // '0' = 0x30
            std::vector::push_back(&mut buf, d);
            n = n / 10;
        };
        std::vector::reverse(&mut buf);
        string::utf8(buf)
    }

    // ============ ENABLE PRESS - author opt-in per mint ============

    /// Author opts in to Press for a specific mint. Sets supply_cap + window.
    /// One-time per mint; cannot reconfigure after first press.
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

        // Validate mint_seq corresponds to a real mint. Without this, author can
        // enable_press on bogus seqs and farm reaction emission via secondary wallets.
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

    // ============ PRESS - anyone can press, gates checked ============

    /// Press a mint. Mints Supra NFT v2 collectible to presser's wallet.
    /// Atomic: register press -> mint NFT -> emit event -> emission bonus (if pool seeded).
    ///
    /// Validation chain:
    /// 1. PressConfig exists for (author_pid, mint_seq) - author opted in
    /// 2. Window not expired
    /// 3. Supply not exhausted
    /// 4. Per-actor uniqueness - presser hasn't pressed this mint before
    /// 5. Mint-level ReferenceGate (if any) passes for presser
    ///
    /// Emission bonus path: if author's $TOKEN/D pool seeded -> mint emission(n) tokens
    /// to presser. If pool not seeded -> press succeeds without emission. (LOCKED.)
    public entry fun press(
        presser: &signer,
        presser_pid: address,
        author_pid: address,
        mint_seq: u64,
        presser_stake_position_addr: address,    // @0x0 if no LP-stake gate or no position
    ) acquires PidPressStorage, PressCollection {
        profile::assert_authorized(presser, presser_pid);
        let presser_addr = signer::address_of(presser);

        assert!(exists<PidPressStorage>(author_pid), E_PRESS_NOT_ENABLED);

        // Mint-level ReferenceGate (self-exempt: author always passes own gate).
        // Done before mut-borrow phase to keep storage scope pure.
        // Self-exempt via PID; gate check via wallet addr (presser_addr) per locked semantic
        // 2026-05-01: balance + LP-stake ownership at wallet that holds PID NFT.
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

        // Validation phase - check + bump counters in mut-borrow scope
        let press_order: u16;
        {
            let storage = borrow_global_mut<PidPressStorage>(author_pid);
            assert!(smart_table::contains(&storage.configs, mint_seq), E_PRESS_NOT_ENABLED);

            let config = smart_table::borrow_mut(&mut storage.configs, mint_seq);
            let now_us = timestamp::now_seconds() * 1_000_000;
            assert!(now_us < config.deadline_us, E_PRESS_WINDOW_EXPIRED);
            assert!(config.pressed_count < config.supply_cap, E_PRESS_SUPPLY_EXHAUSTED);

            // Per-actor uniqueness
            let registry = smart_table::borrow_mut(&mut storage.registries, mint_seq);
            assert!(!smart_table::contains(&registry.pressed_by, presser_pid), E_ALREADY_PRESSED);

            // Register press + bump counters
            smart_table::add(&mut registry.pressed_by, presser_pid, true);
            config.pressed_count = config.pressed_count + 1;
            press_order = config.pressed_count;
            let emission_amount_local = (press_order as u64);
            config.emission_consumed_total = config.emission_consumed_total + emission_amount_local;
        };  // PidPressStorage borrow released here

        // ============ NFT v2 mint ============

        // Lazy-init "<handle>'s Presses" Collection (beta-pattern locked 2026-04-30).
        // Collection is created with pid_signer (= creator addr = author_pid).
        let _collection_addr = ensure_press_collection(author_pid);

        let handle = profile::handle_of(author_pid);
        let token_name = build_token_name(&handle, mint_seq, press_order);
        let token_description = build_token_description(&handle, mint_seq);
        let token_uri = build_token_uri(&handle, mint_seq);

        let collection_state = borrow_global<PressCollection>(author_pid);
        let collection_name = collection_state.name;

        // CRITICAL: token::create derives Collection address from (creator_addr, name).
        // Must use pid_signer (the SAME signer that created the Collection in
        // ensure_press_collection), not collection_signer - otherwise derivation
        // mismatches and aborts EOBJECT_DOES_NOT_EXIST.
        let pid_signer = profile::derive_pid_signer(author_pid);

        // Mint Token Object inside collection. None royalty = inherit from collection (5%).
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

        // Transfer to presser. token::create with pid_signer -> token owned by author_pid.
        // pid_signer authorizes transfer to presser.
        object::transfer(&pid_signer, token_object, presser_addr);

        // ============ Emission bonus ============
        // Reaction gauge is keyed by author_pid (not handle), so each PID -
        // main or subdomain - has its own independent reaction pool. No
        // handle-string collision between a main "alice" and a subdomain
        // `alice@bob`.
        //
        // Self-press blocked: NFT mint still happens (author can collect own
        // work) but emission to author's own wallet is suppressed - would
        // otherwise let author drain their own pool via a single self-press.
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
        // History at presser's PID (the actor performing the verb), target = author_pid.
        history::append(
            presser_pid,
            history::new_entry(history::verb_press(), now_secs, option::some(author_pid), payload, option::none<address>()),
        );
    }

    // ============ VIEWS ============

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
