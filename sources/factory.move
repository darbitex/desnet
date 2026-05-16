/// Token Factory — atomic spawn of $TOKEN + vault + IPO pool.
///
/// Full atomic register_handle flow. One tx = PID + token + vault + IPO.
/// 100% of supply goes to IPO pool. No emission reserves, no AMM pool at register.
///
/// Caller flow:
///   profile::register_handle (charges handle_fee, sets IPO params) →
///   factory::create_token_atomic(handle, pid_addr, target_tvl, entry_price) →
///     mints 1B $TOKEN → creates vault → creates IPO pool with all 1B $TOKEN
module desnet::factory {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset};
    use supra_framework::object::{Self};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::supra_vault;
    use desnet::governance;
    use desnet::ipo;

    use supra_framework::fungible_asset::MutateMetadataRef;

    friend desnet::registration;

    // ============ CONSTANTS ============

    /// Total supply per spawned token: 1B at 8 dec.
    const TOTAL_SUPPLY: u64 = 100_000_000_000_000_000;
    const TOKEN_DECIMALS: u8 = 8;

    const SPEC_VERSION_V3: u32 = 3;

    /// Handle character constraints (1-64 chars, lowercase + digits + hyphens).
    const HANDLE_MIN_LEN: u64 = 1;
    const HANDLE_MAX_LEN: u64 = 64;

    const SEED_TOKEN: vector<u8> = b"token::";

    // ============ ERROR CODES ============

    const E_HANDLE_TAKEN: u64 = 3;
    const E_HANDLE_TOO_SHORT: u64 = 4;
    const E_HANDLE_TOO_LONG: u64 = 5;
    const E_HANDLE_INVALID_CHAR: u64 = 6;
    const E_FACTORY_PAUSED: u64 = 8;
    const E_PID_NOT_REGISTERED: u64 = 10;
    const E_NOT_ADMIN: u64 = 13;
    const E_INVALID_ADDRESS: u64 = 14;
    const E_NAME_TOO_LONG: u64 = 15;
    const E_SYMBOL_TOO_LONG: u64 = 16;
    const E_ICON_URI_TOO_LONG: u64 = 17;
    const E_NOT_PID_OWNER: u64 = 18;
    const E_TOKEN_NOT_FOUND: u64 = 19;
    const E_PROJECT_URI_TOO_LONG: u64 = 20;

    /// Mirror Supra `fungible_asset` framework limits — pre-validate so callers
    /// get a clear abort instead of a deep-stack framework error.
    const MAX_NAME_LEN: u64 = 32;
    const MAX_SYMBOL_LEN: u64 = 32;
    const MAX_URI_LEN: u64 = 512;

    // ============ TYPES ============

    struct FactoryState has key {
        spawn_count: u64,
        paused: bool,
        /// R3 fix (Gemini HIGH): rotatable pause/admin authority. Initialized to
        /// `@origin` at deploy. Can be rotated to a DAO-governed addr post-launch
        /// to align with `governance::disable_multisig_upgrade` (avoiding the
        /// post-DAO-transition deadlock where @origin retains a permanent
        /// kill-switch or, if dissolved, pause becomes permanently bricked).
        admin: address,
    }

    /// Per-spawned-token registry record.
    struct TokenRecord has store, copy, drop {
        handle: String,
        token_metadata: address,
        owner_addr: address,                          // PID Object addr (transferable)
        supra_vault: address,
        ipo_addr: address,                            // IPO pool address
        spec_version: u32,
        spawned_at_secs: u64,
    }

    struct FactoryRegistry has key {
        records: SmartTable<String, TokenRecord>,
        metadata_index: SmartTable<address, String>,    // token_metadata → handle
        owner_index: SmartTable<address, String>,        // owner_addr (pid) → handle
    }

    /// Holds the `MutateMetadataRef` for a spawned token's FA Metadata. Stored at
    /// the FA Metadata object addr (one-to-one with the token). The ref's only
    /// authorized use is `update_token_icon`, gated by PID-NFT-owner signer
    /// (cold wallet — same authority tier as `withdraw_pid_token`).
    /// Name/symbol/decimals/project_uri are NOT mutable by design.
    struct TokenMetadataMutRef has key {
        mutate_ref: MutateMetadataRef,
    }

    // ============ EVENTS ============

    #[event]
    struct FactoryInitialized has drop, store {
        factory_addr: address,
        deployer: address,
    }

    #[event]
    struct TokenSpawned has drop, store {
        handle: String,
        token_metadata: address,
        owner_addr: address,
        ipo_addr: address,
        supra_vault: address,
        spec_version: u32,
        timestamp_secs: u64,
    }

    // ============ INIT ============

    fun init_module(account: &signer) {
        let factory_addr = signer::address_of(account);

        move_to(account, FactoryState {
            spawn_count: 0,
            paused: false,
            admin: @origin,
        });

        move_to(account, FactoryRegistry {
            records: smart_table::new(),
            metadata_index: smart_table::new(),
            owner_index: smart_table::new(),
        });

        event::emit(FactoryInitialized {
            factory_addr,
            deployer: @origin,
        });
    }

    // ============ MAIN ENTRY (FRIEND-ONLY) ============

    /// Atomic token + vault + IPO pool.
    /// Friend-only: sole caller is `desnet::profile::register_handle`.
    ///
    /// Caller MUST:
    /// - Have already minted PID NFT at `pid_addr`
    /// - Have already collected handle_fee from end-user
    /// - Pass `name`/`symbol` (≤32 b each, PERMANENT) and `icon_uri`/`project_uri`
    ///   (≤512 b each, mutable post-mint via `update_token_icon` /
    ///   `update_token_project_uri`, both PID-NFT-owner gated).
    /// - Pass IPO params (target_tvl, entry_price_x, entry_price_y)
    public(friend) fun create_token_atomic(
        handle: vector<u8>,
        pid_addr: address,
        name: String,
        symbol: String,
        icon_uri: String,
        project_uri: String,
        target_tvl: u64,
        entry_price_x: u64,
        entry_price_y: u64,
    ) acquires FactoryState, FactoryRegistry {
        validate_handle(&handle);
        validate_token_metadata_strings(&name, &symbol, &icon_uri, &project_uri);
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(!smart_table::contains(&registry.records, handle_str), E_HANDLE_TAKEN);

        let state = borrow_global<FactoryState>(@desnet);
        assert!(!state.paused, E_FACTORY_PAUSED);

        let factory_signer = governance::derive_pkg_signer();

        // Step 1: Mint $TOKEN FA at deterministic addr.
        let token_seed = make_token_seed(&handle);
        let constructor_ref = object::create_named_object(&factory_signer, token_seed);
        let token_metadata_addr = object::address_from_constructor_ref(&constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some((TOTAL_SUPPLY as u128)),
            name,
            symbol,
            TOKEN_DECIMALS,
            icon_uri,
            project_uri,
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let mutate_ref = fungible_asset::generate_mutate_metadata_ref(&constructor_ref);
        let metadata_signer = object::generate_signer(&constructor_ref);
        move_to(&metadata_signer, TokenMetadataMutRef { mutate_ref });

        let metadata_obj_transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&metadata_obj_transfer_ref);
        let _ = object::object_from_constructor_ref<fungible_asset::Metadata>(&constructor_ref);

        // Step 2: Mint full supply — 100% goes to IPO (no more 50M/50M/900M split).
        let ipo_token_fa = fungible_asset::mint(&mint_ref, TOTAL_SUPPLY);

        // Step 3: Deploy vault (sealed, holds BurnRef for future buyback).
        // AMM pool belum ada saat register; vault diberi @0x0, di-set kemudian.
        let supra_vault_addr = supra_vault::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            @0x0,                                      // pool addr: di-set setelah IPO complete
            pid_addr,
            burn_ref,
        );

        // Step 4: Create IPO pool with 100% token supply.
        ipo::create_ipo(
            handle,
            token_metadata_addr,
            ipo_token_fa,
            target_tvl,
            entry_price_x,
            entry_price_y,
        );
        let ipo_addr = ipo::ipo_address_of_handle(handle);

        // Step 5: Destroy MintRef (fixed_supply forever).
        let _ = mint_ref;

        // Step 6: Record TokenRecord.
        let now_secs = timestamp::now_seconds();
        let record = TokenRecord {
            handle: handle_str,
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            supra_vault: supra_vault_addr,
            ipo_addr,
            spec_version: SPEC_VERSION_V3,
            spawned_at_secs: now_secs,
        };

        let registry = borrow_global_mut<FactoryRegistry>(@desnet);
        smart_table::add(&mut registry.records, string::utf8(handle), record);
        smart_table::add(&mut registry.metadata_index, token_metadata_addr, string::utf8(handle));
        smart_table::add(&mut registry.owner_index, pid_addr, string::utf8(handle));

        let state = borrow_global_mut<FactoryState>(@desnet);
        state.spawn_count = state.spawn_count + 1;

        event::emit(TokenSpawned {
            handle: string::utf8(handle),
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            ipo_addr,
            supra_vault: supra_vault_addr,
            spec_version: SPEC_VERSION_V3,
            timestamp_secs: now_secs,
        });
    }

    // ============ TOKEN METADATA UPDATE — PID-NFT-OWNER ONLY ============

    /// Update the FA `icon_uri` for a spawned token. Authority = PID-NFT-owner
    /// (cold wallet, same tier as `withdraw_pid_token`). Name/symbol are NOT
    /// mutable. New icon_uri must be ≤ 512 bytes (Supra framework cap).
    public entry fun update_token_icon(
        owner: &signer,
        handle: vector<u8>,
        new_icon_uri: String,
    ) acquires FactoryRegistry, TokenMetadataMutRef {
        assert!(string::length(&new_icon_uri) <= MAX_URI_LEN, E_ICON_URI_TOO_LONG);
        let mut_ref = assert_owner_and_get_mut_ref(owner, handle);
        fungible_asset::mutate_metadata(
            mut_ref,
            option::none(), option::none(), option::none(),
            option::some(new_icon_uri),            // icon_uri — UPDATE
            option::none(),
        );
    }

    /// Update the FA `project_uri` for a spawned token. Same authority as
    /// `update_token_icon` (PID-NFT-owner). Symmetric mutability for the two
    /// non-load-bearing display fields.
    public entry fun update_token_project_uri(
        owner: &signer,
        handle: vector<u8>,
        new_project_uri: String,
    ) acquires FactoryRegistry, TokenMetadataMutRef {
        assert!(string::length(&new_project_uri) <= MAX_URI_LEN, E_PROJECT_URI_TOO_LONG);
        let mut_ref = assert_owner_and_get_mut_ref(owner, handle);
        fungible_asset::mutate_metadata(
            mut_ref,
            option::none(), option::none(), option::none(),
            option::none(),
            option::some(new_project_uri),         // project_uri — UPDATE
        );
    }

    /// Shared auth + lookup helper for owner-gated metadata updates.
    /// Returns a reference to the token's MutateMetadataRef.
    inline fun assert_owner_and_get_mut_ref(
        owner: &signer,
        handle: vector<u8>,
    ): &MutateMetadataRef {
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(smart_table::contains(&registry.records, handle_str), E_TOKEN_NOT_FOUND);
        let record = smart_table::borrow(&registry.records, handle_str);
        let pid_addr = record.owner_addr;
        let token_metadata_addr = record.token_metadata;

        let pid_object = object::address_to_object<object::ObjectCore>(pid_addr);
        let pid_owner = object::owner(pid_object);
        assert!(signer::address_of(owner) == pid_owner, E_NOT_PID_OWNER);

        &borrow_global<TokenMetadataMutRef>(token_metadata_addr).mutate_ref
    }

    // ============ HANDLE VALIDATION ============

    fun validate_token_metadata_strings(
        name: &String,
        symbol: &String,
        icon_uri: &String,
        project_uri: &String,
    ) {
        assert!(string::length(name) <= MAX_NAME_LEN, E_NAME_TOO_LONG);
        assert!(string::length(symbol) <= MAX_SYMBOL_LEN, E_SYMBOL_TOO_LONG);
        assert!(string::length(icon_uri) <= MAX_URI_LEN, E_ICON_URI_TOO_LONG);
        assert!(string::length(project_uri) <= MAX_URI_LEN, E_PROJECT_URI_TOO_LONG);
    }


    fun validate_handle(handle: &vector<u8>) {
        let len = vector::length(handle);
        assert!(len >= HANDLE_MIN_LEN, E_HANDLE_TOO_SHORT);
        assert!(len <= HANDLE_MAX_LEN, E_HANDLE_TOO_LONG);

        let i = 0;
        while (i < len) {
            let ch = *vector::borrow(handle, i);
            let is_lowercase = ch >= 0x61 && ch <= 0x7A;
            let is_digit = ch >= 0x30 && ch <= 0x39;
            let is_hyphen = ch == 0x2D;
            assert!(is_lowercase || is_digit || is_hyphen, E_HANDLE_INVALID_CHAR);
            i = i + 1;
        };
    }

    // ============ ADDRESS DERIVATION (PURE) ============

    #[view]
    public fun derive_token_metadata_addr(handle: vector<u8>): address {
        let seed = make_token_seed(&handle);
        object::create_object_address(&@desnet, seed)
    }

    fun make_token_seed(handle: &vector<u8>): vector<u8> {
        let seed = vector::empty<u8>();
        vector::append(&mut seed, SEED_TOKEN);
        vector::append(&mut seed, *handle);
        seed
    }


    // ============ VIEW FNS ============

    #[view]
    public fun get_token_record(handle: vector<u8>): TokenRecord acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        // v0.3.2 (F1): semantic-correct error code (was E_HANDLE_TAKEN — misleading).
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        *smart_table::borrow(&registry.records, key)
    }

    #[view]
    public fun handle_registered(handle: vector<u8>): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.records, string::utf8(handle))
    }

    #[view]
    public fun is_factory_token(token_metadata: address): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.metadata_index, token_metadata)
    }

    #[view]
    public fun handle_of_token(token_metadata: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.metadata_index, token_metadata),
            E_TOKEN_NOT_FOUND
        );
        *smart_table::borrow(&registry.metadata_index, token_metadata)
    }

    /// Note: `owner_addr` is the PID Object addr (= the registered owner_index key),
    /// NOT the wallet that holds the PID NFT. Use `handle_of_wallet` for wallet→handle.
    #[view]
    public fun handle_of_owner(owner_addr: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        *smart_table::borrow(&registry.owner_index, owner_addr)
    }

    // (v0.3.2 F1b: handle_of_wallet lives in profile.move to avoid factory→profile
    // dependency cycle. Profile already uses factory; reverse direction would cycle.)

    #[view]
    public fun token_metadata_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        // v0.3.2 (F1): semantic-correct error code.
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).token_metadata
    }

    #[view]
    public fun ipo_addr_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_TOKEN_NOT_FOUND
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).ipo_addr
    }

    #[view]
    public fun owner_has_token(owner_addr: address): bool acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        smart_table::contains(&registry.owner_index, owner_addr)
    }

    #[view]
    public fun spawn_count(): u64 acquires FactoryState {
        borrow_global<FactoryState>(@desnet).spawn_count
    }

    #[view]
    public fun is_paused(): bool acquires FactoryState {
        borrow_global<FactoryState>(@desnet).paused
    }

    /// Kimi F2 fix (audit R1): admin pause/unpause control.
    /// Gemini R2 HIGH fix (R3): authority read from rotatable `FactoryState.admin`
    /// (initially `@origin`, rotatable via `rotate_admin` to a DAO-governed addr).
    public entry fun set_paused(admin: &signer, new_paused: bool) acquires FactoryState {
        let state = borrow_global_mut<FactoryState>(@desnet);
        assert!(signer::address_of(admin) == state.admin, E_NOT_ADMIN);
        state.paused = new_paused;
    }

    /// Rotate the factory admin (pause authority) to a new address.
    /// Used to transfer pause control to the DAO post-bootstrap.
    /// Mirrors the `profile::rotate_admin` pattern.
    public entry fun rotate_admin(
        current_admin: &signer,
        new_admin: address,
    ) acquires FactoryState {
        assert!(new_admin != @0x0, E_INVALID_ADDRESS);
        let state = borrow_global_mut<FactoryState>(@desnet);
        assert!(signer::address_of(current_admin) == state.admin, E_NOT_ADMIN);
        state.admin = new_admin;
    }

    #[view]
    public fun admin(): address acquires FactoryState {
        borrow_global<FactoryState>(@desnet).admin
    }

    #[view]
    public fun vault_addr_of_pid(pid_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        smart_table::borrow(&registry.records, handle).supra_vault
    }

    /// v0.3.2 F9: single-hop handle → supra_vault lookup. Used by supra_fee_vault::settle
    /// to delegate-burn DESNET via desnet's supra_vault BurnRef.
    #[view]
    public fun vault_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        smart_table::borrow(&registry.records, key).supra_vault
    }

    #[view]
    public fun ipo_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        let key = string::utf8(handle);
        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
        smart_table::borrow(&registry.records, key).ipo_addr
    }
}
