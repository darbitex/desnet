/// Profile — PID Object NFT primitive (LOCKED 2026-05-01).
///
/// PID = Profile ID. Supra Object NFT, deterministic addr from wallet:
///   pid_addr = derive_pid_address(wallet) = create_object_address(@desnet, bcs(wallet))
///
/// Three-tier capability hierarchy (Opsi 1 ExtendRef pattern, locked v1):
/// 1. Owner = address holding PID NFT (cold wallet / multisig). Can transfer NFT,
///    rotate controller, emergency-revoke signers.
/// 2. Controller = hot wallet. Adds/removes signers, updates metadata. Cannot transfer NFT.
/// 3. Signers = per-app Ed25519 keys. Sign mints/reactions off-chain; app submits with sig.
///
/// Handle registry: bare `alice` lowercase, 1-64 chars, charset a-z/0-9/-.
/// Length-tier D pricing (1-100 D), one-time, immutable post-registration.
///
/// Atomic register_handle: derives PID Object → stores Profile → calls factory::create_token
/// to spawn $TOKEN and dual-vault for this PID.
///
/// sync_gate: opt-in `Profile.sync_gate: Option<ReferenceGate>` field. Gates incoming
/// Sync requests. NOT a privacy primitive — mints stay public; only Sync action gated.
///
/// Implicit-then-named magic: mention 0xBOB while bob is guest → bob registers later
/// → indexer auto-resolves historical mentions to @bob.
module desnet::profile {
    use std::bcs;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};
    use supra_framework::event;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::{Self, ExtendRef, TransferRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::governance;
    use desnet::supra_fee_vault;

    friend desnet::mint;
    friend desnet::link;
    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;
    friend desnet::history;
    friend desnet::opinion;
    friend desnet::ipo;


    // ============ CONSTANTS ============

    const HANDLE_MIN_LEN: u64 = 1;
    const HANDLE_MAX_LEN: u64 = 64;

    /// Length-tier SUPRA pricing (one-time, no renewal). Raw u64 (SUPRA has 8 decimals).
    /// Tiers calibrated for SUPRA≈$1: 100/50/20/10/5/1 SUPRA.
    const PRICE_1_CHAR_SUPRA: u64 = 100_000_000_000_000;     // 1M SUPRA
    const PRICE_2_CHAR_SUPRA: u64 =  10_000_000_000_000;     // 100K SUPRA
    const PRICE_3_CHAR_SUPRA: u64 =   1_000_000_000_000;     // 10K SUPRA
    const PRICE_4_CHAR_SUPRA: u64 =     100_000_000_000;     // 1K SUPRA
    const PRICE_5_CHAR_SUPRA: u64 =      10_000_000_000;     // 100 SUPRA
    const PRICE_6PLUS_CHAR_SUPRA: u64 =   1_000_000_000;     // 10 SUPRA

    /// Caps for inline metadata at registration.
    const AVATAR_MAX_BYTES: u64 = 8192;       // ≤8KB inline (LOCKED)
    const BIO_MAX_BYTES: u64 = 333;           // ≤333B inline (LOCKED)

    const SEED_PID: vector<u8> = b"pid::";
    const SEED_SUBPID: vector<u8> = b"subpid::";

    // ============ ERROR CODES ============

    const E_HANDLE_TAKEN: u64 = 1;
    const E_HANDLE_TOO_SHORT: u64 = 2;
    const E_HANDLE_TOO_LONG: u64 = 3;
    const E_HANDLE_INVALID_CHAR: u64 = 4;
    const E_PID_ALREADY_EXISTS: u64 = 5;
    const E_NOT_CONTROLLER: u64 = 6;
    const E_NOT_OWNER: u64 = 7;
    const E_PROFILE_NOT_FOUND: u64 = 8;
    const E_INSUFFICIENT_FEE: u64 = 9;
    const E_REGISTRY_NOT_INITIALIZED: u64 = 10;
    const E_GUEST_CANNOT_WRITE: u64 = 11;
    const E_AVATAR_TOO_LARGE: u64 = 12;
    const E_BIO_TOO_LARGE: u64 = 13;
    const E_NOT_ADMIN: u64 = 14;
    const E_NOT_CONTROLLER_OR_OWNER: u64 = 15;
    const E_SYNC_GATE_ALREADY_SET: u64 = 16;
    const E_RESERVED_HANDLE: u64 = 17;
    const E_INVALID_ADDRESS: u64 = 18;
    /// v0.3.2 (F10): update_fee_receiver neutered after supra_fee_vault (F9) takes over fee routing.
    const E_NEUTERED: u64 = 19;

    // ============ TYPES ============

    /// Single 4-field primitive struct for engagement policy. Stored as Option<ReferenceGate>.
    struct ReferenceGate has copy, drop, store {
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    }

    public fun reference_gate_new(
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ): ReferenceGate {
        ReferenceGate { target_pid, min_token_balance, max_token_balance, min_lp_stake }
    }

    public fun reference_gate_target_pid(gate: &ReferenceGate): address { gate.target_pid }
    public fun reference_gate_min_token_balance(gate: &ReferenceGate): u64 { gate.min_token_balance }
    public fun reference_gate_max_token_balance(gate: &ReferenceGate): u64 { gate.max_token_balance }
    public fun reference_gate_min_lp_stake(gate: &ReferenceGate): u64 { gate.min_lp_stake }

    /// PID Profile resource at PID Object addr.
    struct Profile has key {
        handle: String,                            // bare lowercase, immutable post-reg
        controller: address,                       // hot wallet (delegated daily ops)
        signers_: SmartTable<vector<u8>, SignerEntry>,  // Ed25519 pubkey → metadata
        metadata_uri: String,                      // mutable, pointer to off-chain profile JSON
        avatar_blob_id: vector<u8>,                // mutable, Shelby/Walrus blob ref
        banner_blob_id: vector<u8>,                // mutable
        bio: String,                               // mutable, inline ≤333B
        sync_gate: Option<ReferenceGate>,          // opt-in node-membership policy
        extend_ref: ExtendRef,                     // for ExtendRef-derived signer (Opsi 1)
        registered_at_secs: u64,
        pre_ipo_cohort: bool,                      // true = pre-IPO / IPO-phase, false = post-IPO
    }

    /// Per-app signer registry entry. Controller-managed.
    struct SignerEntry has copy, drop, store {
        app_label: String,                         // human-readable identifier
        added_at_secs: u64,
        last_used_secs: u64,
    }

    /// PID NFT transferability vault — TransferRef stored separately so only
    /// owner-initiated transfers go through (controller has profile signer but
    /// not transfer power). Stored at PID addr alongside Profile.
    struct TransferVault has key {
        transfer_ref: TransferRef,
    }

    /// Protocol-level state singleton at @desnet.
    /// The package signer_cap lives in `desnet::governance`;
    /// profile acquires the package signer at runtime via
    /// `governance::derive_pkg_signer()`.
    struct ProtocolState has key {
        fee_receiver: address,                    // initial: @desnet; post-DESNET: vault addr
        admin: address,                           // multisig (rotated to governance later)
    }

    /// Global handle registry singleton at @desnet.
    /// handle (bare lowercase) → wallet (PID Object addr derivable from wallet).
    struct HandleRegistry has key {
        handle_to_wallet: SmartTable<String, address>,
    }

    // ============ EVENTS ============

    #[event]
    struct ProtocolInitialized has drop, store {
        protocol_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct HandleRegistered has drop, store {
        handle: String,
        wallet: address,
        pid_addr: address,
        fee_paid_supra: u64,
        timestamp_secs: u64,
    }

    #[event]
    struct ControllerRotated has drop, store {
        pid_addr: address,
        old_controller: address,
        new_controller: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SignerAdded has drop, store {
        pid_addr: address,
        pubkey: vector<u8>,
        app_label: String,
        timestamp_secs: u64,
    }

    #[event]
    struct SignerRevoked has drop, store {
        pid_addr: address,
        pubkey: vector<u8>,
        timestamp_secs: u64,
    }

    #[event]
    struct ProfileMetadataUpdated has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SyncGateAttached has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct SyncGateCleared has drop, store {
        pid_addr: address,
        timestamp_secs: u64,
    }

    #[event]
    struct PidTokenWithdrawn has drop, store {
        pid_addr: address,
        token_metadata: address,
        amount: u64,
        recipient: address,
        timestamp_secs: u64,
    }

    // ============ INIT — resource_account deploy pattern (mirror factory) ============

    /// SUPRA FA metadata addr (Supra paired-coin convention).
    const SUPRA_FA_METADATA: address = @0xa;

    /// Init callback. The package SignerCapability is owned by
    /// `desnet::governance`; profile just initializes its singleton resources
    /// using the resource_account signer that Supra passes in here.
    fun init_module(account: &signer) {
        let protocol_addr = signer::address_of(account);

        move_to(account, ProtocolState {
            fee_receiver: protocol_addr,           // initially route fees to protocol addr
            admin: @origin,                        // deployer multisig
        });

        move_to(account, HandleRegistry {
            handle_to_wallet: smart_table::new(),
        });

        event::emit(ProtocolInitialized {
            protocol_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ADMIN — config updates (multisig → governance later) ============

    /// Admin updates fee_receiver. Used pre-supra_fee_vault to point fees somewhere.
    /// Post-vault upgrade, register_handle body bypasses this field — supra_fee_vault
    /// is the immutable destination. Kept here for v0.3.0 baseline; body becomes
    /// `abort 0` in v0.3.1 compat upgrade.
    /// v0.3.2 (F10): NEUTERED. With supra_fee_vault (F9), `state.fee_receiver` field
    /// is no longer read by `register_handle` body — fees route directly to the vault.
    /// Field retained as vestigial (compat-only). Eliminates the last admin knob over
    /// fee destination once F9 is live.
    public entry fun update_fee_receiver(
        _admin: &signer,
        _new_fee_receiver: address,
    ) acquires ProtocolState {
        let _ = borrow_global<ProtocolState>(@desnet);
        abort E_NEUTERED
    }

    /// Admin rotates admin (e.g., to governance contract). One-way after PMF transition.
    public entry fun rotate_admin(
        current_admin: &signer,
        new_admin: address,
    ) acquires ProtocolState {
        // Gemini MED fix (audit R1): zero-addr check.
        assert!(new_admin != @0x0, E_INVALID_ADDRESS);
        let state = borrow_global_mut<ProtocolState>(@desnet);
        assert!(signer::address_of(current_admin) == state.admin, E_NOT_ADMIN);
        state.admin = new_admin;
    }

    // Package upgrade lives in `desnet::governance` (multisig_upgrade +
    // execute_proposal). No per-module do_upgrade entry needed in monolith.

    // ============ ADDRESS DERIVATION ============

    /// Pure fn — deterministic PID Object addr from wallet.
    /// Single canonical PID per wallet (constraint: same wallet cannot register multiple handles).
    #[view]
    public fun derive_pid_address(wallet: address): address {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
        object::create_object_address(&@desnet, seed)
    }

    /// Derives a deterministic PID address for a subdomain relative to a domain handle.
    #[view]
    public fun derive_subdomain_pid_address(handle: String, subdomain: String): address {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_SUBPID);
        vector::append(&mut seed, bcs::to_bytes(&handle));
        vector::append(&mut seed, bcs::to_bytes(&subdomain));
        object::create_object_address(&@desnet, seed)
    }

    // ============ HANDLE VALIDATION ============

    fun validate_handle(handle: &vector<u8>) {
        let len = vector::length(handle);
        assert!(len >= HANDLE_MIN_LEN, E_HANDLE_TOO_SHORT);
        assert!(len <= HANDLE_MAX_LEN, E_HANDLE_TOO_LONG);

        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(handle, i);
            // Allowed: a-z, 0-9, '-'
            let ok = (ch >= 0x61 && ch <= 0x7A)
                  || (ch >= 0x30 && ch <= 0x39)
                  || (ch == 0x2D);
            assert!(ok, E_HANDLE_INVALID_CHAR);
            i = i + 1;
        };
    }

    /// Length-tier SUPRA pricing. Returns raw u64 (8 decimals).
    public fun handle_fee_supra(handle_len: u64): u64 {
        if (handle_len == 1) PRICE_1_CHAR_SUPRA
        else if (handle_len == 2) PRICE_2_CHAR_SUPRA
        else if (handle_len == 3) PRICE_3_CHAR_SUPRA
        else if (handle_len == 4) PRICE_4_CHAR_SUPRA
        else if (handle_len == 5) PRICE_5_CHAR_SUPRA
        else PRICE_6PLUS_CHAR_SUPRA
    }

    // ============ REGISTER HANDLE — atomic with token spawn ============

    /// Atomic registration. Single-tx flow:
    ///   1. Validate handle (charset + length) + sizes (avatar ≤8KB, bio ≤333B)
    ///   2. Check uniqueness (handle not taken, PID Object addr not occupied)
    ///   3. Compute fee in D (length-tier 1-100), withdraw from wallet → fee_receiver
    ///   4. Create PID Object via protocol_signer at deterministic addr derive(wallet)
    ///   5. Generate ExtendRef + TransferRef
    ///   6. move_to Profile (controller, signers SmartTable, metadata, sync_gate=none)
    ///   7. move_to TransferVault (transfer_ref isolated from Profile fields)
    ///   8. Insert handle → wallet in HandleRegistry
    ///   9. Cross-package call factory::create_token(wallet, handle, pid_addr)
    ///       Factory atomically spawns $TOKEN FA + SUPRA/D vaults + reaction/LP reserves;
    ///       deposits 5% creator allocation (50M $TOKEN) to pid_addr's primary store.
    ///  10. Emit HandleRegistered event
    ///
    /// Constraint: same wallet cannot register multiple handles. derive(wallet) is
    /// occupied for life. Multi-identity = multi-wallet (standard web3 hygiene).
    ///
    /// Sibling storage (PidMintMeta, PidSyncSet, etc.) NOT initialized here — sibling
    /// modules lazy-init on first-write via `derive_pid_signer` friend helper.
    /// Cycle prevention: profile.move doesn't depend on sibling modules.
    public entry fun register_handle(
        wallet: &signer,
        handle: vector<u8>,
        controller_addr: address,
        avatar_b64: vector<u8>,
        bio: vector<u8>,
    ) acquires HandleRegistry, ProtocolState {
        // 1. Validate
        validate_handle(&handle);
        assert!(vector::length(&avatar_b64) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&bio) <= BIO_MAX_BYTES, E_BIO_TOO_LARGE);

        let wallet_addr = signer::address_of(wallet);

        // Reserved handles — each bound to one specific claimer address (per-handle).
        // Prevents front-run squatting between package publish and project's claim tx.
        // Once claimed by the authorized addr, E_HANDLE_TAKEN takes over for any
        // subsequent attempt regardless of caller. PID-per-wallet constraint preserved
        // (each reserved handle has a different claimer addr → no PID collision).
        let claimer_opt = reserved_handle_claimer(&handle);
        if (option::is_some(&claimer_opt)) {
            let required_claimer = *option::borrow(&claimer_opt);
            assert!(wallet_addr == required_claimer, E_RESERVED_HANDLE);
        };
        let pid_addr = derive_pid_address(wallet_addr);
        let handle_str = string::utf8(handle);

        // 2. Uniqueness
        let registry = borrow_global_mut<HandleRegistry>(@desnet);
        assert!(
            !smart_table::contains(&registry.handle_to_wallet, handle_str),
            E_HANDLE_TAKEN
        );
        assert!(!exists<Profile>(pid_addr), E_PID_ALREADY_EXISTS);

        // 3. Fee in SUPRA — route directly to supra_fee_vault
        let _state = borrow_global<ProtocolState>(@desnet);
        let fee_raw = handle_fee_supra(vector::length(&handle));
        let supra_metadata = object::address_to_object<Metadata>(SUPRA_FA_METADATA);
        if (fee_raw > 0) {
            let fee_fa = primary_fungible_store::withdraw(wallet, supra_metadata, fee_raw);
            supra_fee_vault::deposit_supra_fa(fee_fa);
        };

        // 4. Create PID Object via package signer (governance-derived)
        let protocol_signer = governance::derive_pkg_signer();
        let seed = make_pid_seed(wallet_addr);
        let constructor_ref = object::create_named_object(&protocol_signer, seed);

        // 5. Generate refs
        let pid_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        // 6. Profile resource at PID addr
        let now_secs = timestamp::now_seconds();
        move_to(&pid_signer, Profile {
            handle: handle_str,
            controller: controller_addr,
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: avatar_b64,
            banner_blob_id: vector::empty(),
            bio: string::utf8(bio),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: now_secs,
            pre_ipo_cohort: false,
        });

        // 7. TransferVault — transfer_ref isolated (controller cannot transfer NFT)
        move_to(&pid_signer, TransferVault { transfer_ref });

        // 7.5 Transfer Object ownership to wallet (NFT-style).
        let pid_object = object::address_to_object<Profile>(pid_addr);
        object::transfer(&protocol_signer, pid_object, wallet_addr);

        // 8. Register handle → wallet mapping
        smart_table::add(&mut registry.handle_to_wallet, string::utf8(handle), wallet_addr);

        // 9. Emit
        event::emit(HandleRegistered {
            handle: string::utf8(handle),
            wallet: wallet_addr,
            pid_addr,
            fee_paid_supra: fee_raw,
            timestamp_secs: now_secs,
        });
    }

    /// Reserved handle → authorized claimer. Each reserved handle has its OWN claimer
    /// address (different per handle to preserve PID-per-wallet uniqueness). Returns
    /// `Option::none` if handle is not reserved (= public registration).
    ///
    /// - "desnet" → @desnet_claimer (= @origin = deployer multisig)
    /// - "darbitex" → Darbitex Final publisher multisig 3/5 (cross-project)
    /// - "d" → D Supra pkg (sealed resource_account, no signer ever — permanent burn)
    /// - "supra" → Darbitex treasury multisig 3/5
    /// - "supra" → dedicated supra-claimer multisig
    fun reserved_handle_claimer(handle: &vector<u8>): option::Option<address> {
        let h = *handle;
        if (h == b"desnet")        option::some(@desnet_claimer)
        else if (h == b"darbitex") option::some(@darbitex_claimer)
        else if (h == b"d")        option::some(@d_claimer)
        else if (h == b"supra")    option::some(@supra_claimer)
        else option::none()
    }

    fun make_pid_seed(wallet: address): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_PID);
        vector::append(&mut seed, bcs::to_bytes(&wallet));
        seed
    }

    /// Creates a PID NFT for a subdomain registrant (called by `desnet::ipo`).
    ///
    /// Deterministic addr via `derive_subdomain_pid_address(handle, subdomain)`.
    /// Profile.handle = subdomain (bare name), controller = depositor.
    /// Ownership transferred to depositor wallet.
    ///
    /// Caller must provide the protocol_signer (obtained via governance::derive_pkg_signer).
    /// Internally creates the named object, stores Profile + TransferVault, transfers NFT,
    /// and emits HandleRegistered. No caller-side seed or ref management needed.
    public fun create_subdomain_profile(
        protocol_signer: &signer,
        handle: String,
        subdomain: String,
        controller: address,
        pre_ipo_cohort: bool,
    ) {
        let pid_addr = derive_subdomain_pid_address(handle, subdomain);
        assert!(!exists<Profile>(pid_addr), E_PID_ALREADY_EXISTS);
        let _state = borrow_global<ProtocolState>(@desnet);

        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_SUBPID);
        vector::append(&mut seed, bcs::to_bytes(&handle));
        vector::append(&mut seed, bcs::to_bytes(&subdomain));
        let constructor_ref = object::create_named_object(protocol_signer, seed);

        let pid_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);

        let now_secs = timestamp::now_seconds();
        move_to(&pid_signer, Profile {
            handle: subdomain,
            controller,
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: vector::empty(),
            banner_blob_id: vector::empty(),
            bio: string::utf8(b""),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: now_secs,
            pre_ipo_cohort,
        });

        move_to(&pid_signer, TransferVault { transfer_ref });

        let pid_object = object::address_to_object<Profile>(pid_addr);
        object::transfer(protocol_signer, pid_object, controller);

        event::emit(HandleRegistered {
            handle,
            wallet: controller,
            pid_addr,
            fee_paid_supra: 0,
            timestamp_secs: now_secs,
        });
    }

    // ============ CONTROLLER + SIGNER MANAGEMENT ============

    /// Owner rotates controller. Only PID NFT owner can call.
    public entry fun rotate_controller(
        owner: &signer,
        pid_addr: address,
        new_controller: address,
    ) acquires Profile {
        assert_owner(owner, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        let old = profile.controller;
        profile.controller = new_controller;

        event::emit(ControllerRotated {
            pid_addr,
            old_controller: old,
            new_controller,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// Controller adds per-app Ed25519 signer. Off-chain signing path (Opsi 1).
    public entry fun add_signer(
        controller: &signer,
        pid_addr: address,
        pubkey: vector<u8>,
        app_label: vector<u8>,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);

        let entry = SignerEntry {
            app_label: string::utf8(app_label),
            added_at_secs: 0,
            last_used_secs: 0,
        };
        smart_table::add(&mut profile.signers_, pubkey, entry);

        event::emit(SignerAdded {
            pid_addr,
            pubkey,
            app_label: string::utf8(app_label),
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    /// Controller revokes signer. Owner can also revoke as emergency override.
    /// Auth: caller must be Profile.controller OR current PID NFT holder (object::owner).
    public entry fun revoke_signer(
        controller_or_owner: &signer,
        pid_addr: address,
        pubkey: vector<u8>,
    ) acquires Profile {
        assert_controller_or_owner(controller_or_owner, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        if (smart_table::contains(&profile.signers_, pubkey)) {
            smart_table::remove(&mut profile.signers_, pubkey);
        };

        event::emit(SignerRevoked {
            pid_addr,
            pubkey,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ METADATA UPDATES (controller-callable, mutable) ============

    /// Controller updates mutable profile metadata (avatar/banner/bio).
    /// FA-level icon_uri stays immutable (locked at create_token); profile-level
    /// avatar resolves dynamically via DeSNet frontend.
    public entry fun update_metadata(
        controller: &signer,
        pid_addr: address,
        new_avatar_blob: vector<u8>,
        new_banner_blob: vector<u8>,
        new_bio: vector<u8>,
        new_metadata_uri: vector<u8>,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        // Mirror register_handle's validation — caps must apply on both initial-set and update.
        // banner uses same 8KB cap as avatar (both inline media of similar nature).
        assert!(vector::length(&new_avatar_blob) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&new_banner_blob) <= AVATAR_MAX_BYTES, E_AVATAR_TOO_LARGE);
        assert!(vector::length(&new_bio) <= BIO_MAX_BYTES, E_BIO_TOO_LARGE);
        let profile = borrow_global_mut<Profile>(pid_addr);
        profile.avatar_blob_id = new_avatar_blob;
        profile.banner_blob_id = new_banner_blob;
        profile.bio = string::utf8(new_bio);
        profile.metadata_uri = string::utf8(new_metadata_uri);

        event::emit(ProfileMetadataUpdated {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ SYNC GATE (node-membership policy) ============

    /// Controller attaches sync_gate. Gates who can Sync to this PID.
    /// IMMUTABLE post-attach (rugpull-engagement-rules prevention).
    /// To clear, call clear_sync_gate (also one-way to none).
    /// Args flattened to primitives — Supra entry fns can't take struct params.
    public entry fun attach_sync_gate(
        controller: &signer,
        pid_addr: address,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        // Immutability: cannot overwrite an existing gate. To replace, controller must
        // first call clear_sync_gate (2-step replacement = friction = anti-rugpull).
        assert!(option::is_none(&profile.sync_gate), E_SYNC_GATE_ALREADY_SET);
        let gate = reference_gate_new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
        profile.sync_gate = option::some(gate);

        event::emit(SyncGateAttached {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ TREASURY (owner-only) ============

    /// Owner withdraws any FA from PID's primary store to a recipient address.
    /// Used by creators to access their 50M creator allocation (deposited to PID at
    /// register_handle time) + future donations + governance treasury that lands at PID.
    ///
    /// Auth: PID NFT OWNER ONLY (cold wallet). Treasury access is high-value and
    /// must NOT be reachable from controller (hot wallet) — controller compromise
    /// limited to social ops (Spark/Voice/etc), not financial drain. This is the
    /// inverse of the daily-ops-via-controller pattern: TREASURY = OWNER ALWAYS.
    ///
    /// Note: D vault dispurse goes directly to current NFT owner's WALLET (auto-resolved
    /// at settle), not to PID's primary store — so D dispurse income doesn't need
    /// withdraw_pid_token. This fn is for: creator allocation, donations, governance
    /// treasury, anything else accumulated at PID's primary store.
    ///
    /// Buyback-burn safety: structural — buyback portion lives at vault, never deposits
    /// to PID. This withdraw cannot reach it.
    public entry fun withdraw_pid_token(
        owner: &signer,
        pid_addr: address,
        token_metadata_addr: address,
        amount: u64,
        recipient: address,
    ) acquires Profile {
        assert_owner(owner, pid_addr);
        let pid_signer = derive_pid_signer(pid_addr);
        let token_meta = object::address_to_object<Metadata>(token_metadata_addr);
        let fa = primary_fungible_store::withdraw(&pid_signer, token_meta, amount);
        primary_fungible_store::deposit(recipient, fa);

        event::emit(PidTokenWithdrawn {
            pid_addr,
            token_metadata: token_metadata_addr,
            amount,
            recipient,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    public entry fun clear_sync_gate(
        controller: &signer,
        pid_addr: address,
    ) acquires Profile {
        assert_controller(controller, pid_addr);
        let profile = borrow_global_mut<Profile>(pid_addr);
        profile.sync_gate = option::none();

        event::emit(SyncGateCleared {
            pid_addr,
            timestamp_secs: timestamp::now_seconds(),
        });
    }

    // ============ ASSERTIONS ============

    /// Assert caller is the current owner of the PID NFT.
    /// Owner = address holding the Object NFT (per Supra object framework).
    /// Initially set in register_handle via object::transfer(protocol_signer, ..., wallet).
    /// Owner can rotate via marketplace transfer (ungated_transfer enabled), so always
    /// query current state via object::owner.
    fun assert_owner(caller: &signer, pid_addr: address) {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(
            object::owner(pid_object) == signer::address_of(caller),
            E_NOT_OWNER
        );
    }

    fun assert_controller(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let profile = borrow_global<Profile>(pid_addr);
        assert!(profile.controller == signer::address_of(caller), E_NOT_CONTROLLER);
    }

    /// Caller must be controller OR current NFT owner. Used for signer-key revocation
    /// (owner emergency override path) — owner can revoke any signer even if controller
    /// is compromised.
    fun assert_controller_or_owner(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let profile = borrow_global<Profile>(pid_addr);
        if (profile.controller == caller_addr) return;
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(object::owner(pid_object) == caller_addr, E_NOT_CONTROLLER_OR_OWNER);
    }

    /// Internal — friend access for other DeSNet modules to assert PID exists at addr.
    public(friend) fun assert_pid_exists(pid_addr: address) {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
    }

    /// Verb-auth gate. Caller is allowed to act AS this PID if they are either the
    /// current NFT owner or the configured controller. Used by every verb entry
    /// (mint/pulse/link/press/opinion/giveaway) so that subdomain-PID holders and
    /// main-handle holders are treated identically — the verb modules never derive
    /// pid_addr from the caller's wallet, the caller passes it in.
    public(friend) fun assert_authorized(caller: &signer, pid_addr: address) acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let caller_addr = signer::address_of(caller);
        let profile = borrow_global<Profile>(pid_addr);
        if (profile.controller == caller_addr) return;
        let pid_object = object::address_to_object<Profile>(pid_addr);
        assert!(object::owner(pid_object) == caller_addr, E_NOT_CONTROLLER_OR_OWNER);
    }

    /// Internal — friend access for sync_gate evaluation in link.move.
    public(friend) fun get_sync_gate(pid_addr: address): Option<ReferenceGate> acquires Profile {
        if (!exists<Profile>(pid_addr)) return option::none();
        borrow_global<Profile>(pid_addr).sync_gate
    }

    /// Internal — friend helper for sibling modules' lazy-init pattern.
    /// Returns ExtendRef-derived signer of the PID Object so siblings can
    /// move_to their own storage resources at PID addr.
    /// Cycle prevention: profile.move doesn't `use` siblings; siblings declare
    /// no friend back. One-way dep: siblings → profile only.
    public(friend) fun derive_pid_signer(pid_addr: address): signer acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        let p = borrow_global<Profile>(pid_addr);
        object::generate_signer_for_extending(&p.extend_ref)
    }

    // ============ VIEWS ============

    #[view]
    public fun is_registered(handle: vector<u8>): bool acquires HandleRegistry {
        let registry = borrow_global<HandleRegistry>(@desnet);
        smart_table::contains(&registry.handle_to_wallet, string::utf8(handle))
    }

    #[view]
    public fun handle_to_wallet(handle: vector<u8>): address acquires HandleRegistry {
        let registry = borrow_global<HandleRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.handle_to_wallet, key), E_PROFILE_NOT_FOUND);
        *smart_table::borrow(&registry.handle_to_wallet, key)
    }

    #[view]
    public fun profile_exists(pid_addr: address): bool {
        exists<Profile>(pid_addr)
    }

    #[view]
    public fun controller_of(pid_addr: address): address acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        borrow_global<Profile>(pid_addr).controller
    }

    #[view]
    public fun handle_of(pid_addr: address): String acquires Profile {
        assert!(exists<Profile>(pid_addr), E_PROFILE_NOT_FOUND);
        borrow_global<Profile>(pid_addr).handle
    }

    /// v0.3.2 (F1b): wallet→handle convenience. Derives PID from wallet, looks up
    /// handle. Aborts E_PROFILE_NOT_FOUND if wallet has no registered PID.
    /// (Lives here, not in factory.move, because profile→factory but not the reverse.)
    #[view]
    public fun handle_of_wallet(wallet_addr: address): String acquires Profile {
        let pid_addr = derive_pid_address(wallet_addr);
        handle_of(pid_addr)
    }

    #[view]
    public fun has_signer(pid_addr: address, pubkey: vector<u8>): bool acquires Profile {
        if (!exists<Profile>(pid_addr)) return false;
        smart_table::contains(&borrow_global<Profile>(pid_addr).signers_, pubkey)
    }

    #[view]
    public fun handle_max_len(): u64 { HANDLE_MAX_LEN }

    // ============ TEST-ONLY WRAPPERS ============

    /// Bootstrap a minimal Profile resource at a fresh Object addr. Used by other
    /// modules' integration tests that need a valid PID without going through
    /// register_handle (which requires factory + ProtocolState init).
    /// Returns pid_addr.
    #[test_only]
    public fun setup_test_pid(creator: &signer): address {
        let constructor_ref = object::create_object(signer::address_of(creator));
        let pid_signer = object::generate_signer(&constructor_ref);
        let pid_addr = signer::address_of(&pid_signer);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&pid_signer, Profile {
            handle: string::utf8(b"test"),
            controller: signer::address_of(creator),
            signers_: smart_table::new(),
            metadata_uri: string::utf8(b""),
            avatar_blob_id: vector::empty(),
            banner_blob_id: vector::empty(),
            bio: string::utf8(b""),
            sync_gate: option::none(),
            extend_ref,
            registered_at_secs: 0,
            pre_ipo_cohort: false,
        });
        pid_addr
    }

    // ============ TESTS ============

    #[test]
    fun test_handle_fee_supra_tiers() {
        assert!(handle_fee_supra(1) == PRICE_1_CHAR_SUPRA, 1);     // 100 SUPRA
        assert!(handle_fee_supra(2) == PRICE_2_CHAR_SUPRA, 2);     //  50 SUPRA
        assert!(handle_fee_supra(3) == PRICE_3_CHAR_SUPRA, 3);     //  20 SUPRA
        assert!(handle_fee_supra(4) == PRICE_4_CHAR_SUPRA, 4);     //  10 SUPRA
        assert!(handle_fee_supra(5) == PRICE_5_CHAR_SUPRA, 5);     //   5 SUPRA
        assert!(handle_fee_supra(6) == PRICE_6PLUS_CHAR_SUPRA, 6); //   1 SUPRA
        assert!(handle_fee_supra(64) == PRICE_6PLUS_CHAR_SUPRA, 7);
    }

    #[test]
    fun test_validate_handle_accept_valid() {
        validate_handle(&b"alice");
        validate_handle(&b"a-1");
        validate_handle(&b"a");                            // min length
        validate_handle(&b"abc-def-123");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_INVALID_CHAR, location = Self)]
    fun test_validate_handle_reject_uppercase() {
        validate_handle(&b"Alice");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_INVALID_CHAR, location = Self)]
    fun test_validate_handle_reject_underscore() {
        validate_handle(&b"alice_bob");
    }

    #[test]
    #[expected_failure(abort_code = E_HANDLE_TOO_SHORT, location = Self)]
    fun test_validate_handle_reject_empty() {
        validate_handle(&b"");
    }

    #[test]
    fun test_derive_pid_address_deterministic() {
        let a1 = derive_pid_address(@0x1);
        let a2 = derive_pid_address(@0x1);
        let b1 = derive_pid_address(@0x2);
        assert!(a1 == a2, 1);
        assert!(a1 != b1, 2);
    }
}

// Suppress unused signature reference in skeleton — TransferVault wired during impl pass.
