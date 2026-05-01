/// Token Factory — atomic spawn of $TOKEN + vault + emission reserves + AMM pool + locked LP stake.
///
/// Full atomic register_handle flow. One tx = PID + token + pool + lock + stake.
/// Uses in-house `desnet::amm` (pool create) + `desnet::lp_staking` (forever-lock creator's initial LP).
///
/// Caller flow:
///   profile::register_handle (charges handle_fee + 5 APT) →
///   factory::create_token_atomic(handle, pid_addr, pool_seed_apt_fa) →
///     mints 1B $TOKEN → splits 50M/50M/900M → creates AMM pool with 5 APT + 50M $TOKEN →
///     forever-locks initial LP into PID NFT object via lp_staking → done.
///
/// Allocation:
///   - 50M (5%) → pool seed (paired with 5 APT in AMM)
///   - 50M (5%) → reaction emission reserve
///   - 900M (90%) → LP emission reserve
///   Sum = 1B exactly.
module desnet::factory {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use aptos_framework::object::{Self};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::amm;
    use desnet::apt_vault;
    use desnet::governance;
    use desnet::lp_emission;
    use desnet::lp_staking;
    use desnet::reaction_emission;

    friend desnet::profile;

    // ============ CONSTANTS ============

    /// Total supply per spawned token: 1B at 8 dec.
    const TOTAL_SUPPLY: u64 = 100_000_000_000_000_000;
    const TOKEN_DECIMALS: u8 = 8;

    /// Allocation: 50M (pool seed) / 50M (reaction reserve) / 900M (LP emission). Sum = 1B.
    const POOL_SEED_TOKEN_AMOUNT: u64 = 5_000_000_000_000_000;       // 50M × 10^8
    const REACTION_RESERVE_AMOUNT: u64 = 5_000_000_000_000_000;       // 50M × 10^8
    const LP_EMISSION_AMOUNT: u64 = 90_000_000_000_000_000;           // 900M × 10^8

    /// Pool seed APT amount (paired with 50M $TOKEN). User pays this in addition to handle_fee.
    const POOL_SEED_APT_AMOUNT: u64 = 500_000_000;                    // 5 APT × 10^8

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
    const E_INVALID_POOL_SEED_APT: u64 = 12;

    // ============ TYPES ============

    struct FactoryState has key {
        spawn_count: u64,
        paused: bool,
    }

    /// Per-spawned-token registry record.
    struct TokenRecord has store, copy, drop {
        handle: String,
        token_metadata: address,
        owner_addr: address,                          // PID Object addr (transferable)
        apt_vault: address,
        reaction_reserve: address,
        lp_reserve: address,
        lp_staking_pool: address,                     // populated atomically (no longer @0x0)
        amm_pool: address,                            // in-house AMM pool addr
        spec_version: u32,
        spawned_at_secs: u64,
    }

    struct FactoryRegistry has key {
        records: SmartTable<String, TokenRecord>,
        metadata_index: SmartTable<address, String>,    // token_metadata → handle
        owner_index: SmartTable<address, String>,        // owner_addr (pid) → handle
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
        amm_pool: address,
        lp_staking_pool: address,
        apt_vault: address,
        lp_reserve: address,
        reaction_reserve: address,
        spec_version: u32,
        timestamp_secs: u64,
    }

    // ============ INIT ============

    fun init_module(account: &signer) {
        let factory_addr = signer::address_of(account);

        move_to(account, FactoryState {
            spawn_count: 0,
            paused: false,
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

    /// Atomic token + vault + reserves + AMM pool + locked LP stake.
    /// Friend-only: sole caller is `desnet::profile::register_handle`.
    ///
    /// Caller MUST:
    /// - Have already minted PID NFT at `pid_addr`
    /// - Have already collected handle_fee_apt + POOL_SEED_APT_AMOUNT from end-user
    /// - Pass exactly POOL_SEED_APT_AMOUNT (5 APT) as `pool_seed_apt`
    public(friend) fun create_token_atomic(
        handle: vector<u8>,
        pid_addr: address,
        pid_signer: &signer,
        pool_seed_apt: FungibleAsset,
    ) acquires FactoryState, FactoryRegistry {
        validate_handle(&handle);
        let handle_str = string::utf8(handle);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(!smart_table::contains(&registry.records, handle_str), E_HANDLE_TAKEN);

        let state = borrow_global<FactoryState>(@desnet);
        assert!(!state.paused, E_FACTORY_PAUSED);

        // Validate pool seed amount
        assert!(
            fungible_asset::amount(&pool_seed_apt) == POOL_SEED_APT_AMOUNT,
            E_INVALID_POOL_SEED_APT
        );

        let factory_signer = governance::derive_pkg_signer();

        // Step 1: Mint $TOKEN FA at deterministic addr.
        let token_seed = make_token_seed(&handle);
        let constructor_ref = object::create_named_object(&factory_signer, token_seed);
        let token_metadata_addr = object::address_from_constructor_ref(&constructor_ref);

        let name_str = string::utf8(handle);
        let symbol_str = string::utf8(handle);
        // FA icon_uri / project_uri left empty — frontend constructs at render time
        // from on-chain PID metadata. No hardcoded domain in source.
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some((TOTAL_SUPPLY as u128)),
            name_str,
            symbol_str,
            TOKEN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let metadata_obj_transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&metadata_obj_transfer_ref);

        let _ = object::object_from_constructor_ref<fungible_asset::Metadata>(&constructor_ref);

        // Step 2: Mint full supply into 3 tranches (50M / 50M / 900M = 1B exactly).
        let pool_seed_token_fa = fungible_asset::mint(&mint_ref, POOL_SEED_TOKEN_AMOUNT);
        let reaction_fa = fungible_asset::mint(&mint_ref, REACTION_RESERVE_AMOUNT);
        let lp_emission_fa = fungible_asset::mint(&mint_ref, LP_EMISSION_AMOUNT);

        // Step 3: Deploy LP emission reserve (sealed, holds 900M).
        let lp_reserve_addr = lp_emission::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            lp_emission_fa,
        );

        // Step 4: Deploy reaction emission reserve (sealed, holds 50M).
        let reaction_reserve_addr = reaction_emission::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            reaction_fa,
        );

        // Step 5: Compute AMM pool addr (deterministic from handle).
        let amm_pool_addr = amm::pool_address_of_handle(handle);

        // Step 6: Deploy vault (sealed, holds BurnRef + APT balance).
        let apt_vault_addr = apt_vault::deploy(
            &factory_signer,
            handle,
            token_metadata_addr,
            amm_pool_addr,                            // vault buyback target
            pid_addr,                                  // PID owner resolver
            burn_ref,
        );

        // Step 7: Atomic AMM pool create (5 APT + 50M $TOKEN). Returns shares (u128).
        let initial_shares = amm::create_pool_atomic(
            handle,
            pool_seed_apt,
            pool_seed_token_fa,
            pid_addr,
        );

        // Step 8: Forever-lock initial shares into Position at PID NFT object.
        let lp_staking_pool_addr = lp_staking::create_pool_and_lock(
            handle,
            token_metadata_addr,
            lp_reserve_addr,
            pid_addr,
            pid_signer,
            initial_shares,
        );

        // Step 9: Destroy MintRef (fixed_supply forever).
        let _ = mint_ref;

        // Step 10: Record TokenRecord.
        let now_secs = timestamp::now_seconds();
        let record = TokenRecord {
            handle: handle_str,
            token_metadata: token_metadata_addr,
            owner_addr: pid_addr,
            apt_vault: apt_vault_addr,
            reaction_reserve: reaction_reserve_addr,
            lp_reserve: lp_reserve_addr,
            lp_staking_pool: lp_staking_pool_addr,
            amm_pool: amm_pool_addr,
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
            amm_pool: amm_pool_addr,
            lp_staking_pool: lp_staking_pool_addr,
            apt_vault: apt_vault_addr,
            lp_reserve: lp_reserve_addr,
            reaction_reserve: reaction_reserve_addr,
            spec_version: SPEC_VERSION_V3,
            timestamp_secs: now_secs,
        });
    }

    // ============ HANDLE VALIDATION ============

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
        assert!(smart_table::contains(&registry.records, key), E_HANDLE_TAKEN);
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
        assert!(
            smart_table::contains(&registry.metadata_index, token_metadata),
            E_HANDLE_TAKEN
        );
        *smart_table::borrow(&registry.metadata_index, token_metadata)
    }

    #[view]
    public fun handle_of_owner(owner_addr: address): String acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        *smart_table::borrow(&registry.owner_index, owner_addr)
    }

    #[view]
    public fun token_metadata_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).token_metadata
    }

    #[view]
    public fun lp_staking_pool_of_owner(owner_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, owner_addr),
            E_HANDLE_TAKEN
        );
        let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
        smart_table::borrow(&registry.records, handle).lp_staking_pool
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

    #[view]
    public fun vault_addr_of_pid(pid_addr: address): address acquires FactoryRegistry {
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        smart_table::borrow(&registry.records, handle).apt_vault
    }

    #[view]
    public fun pool_seed_apt_amount(): u64 { POOL_SEED_APT_AMOUNT }

    #[view]
    public fun pool_seed_token_amount(): u64 { POOL_SEED_TOKEN_AMOUNT }

    // ============ CROSS-MODULE EMISSION (called by press) ============

    /// Press handler in `desnet::press` calls this to fire the reaction emission.
    /// Auth: caller passes pid_signer (ExtendRef-derived). Only `desnet::profile`
    /// friends can construct such a signer. Confirms caller controls a real PID.
    public fun emit_press_to_presser(
        pid_signer: &signer,
        recipient: address,
        post_id: vector<u8>,
        press_order: u64,
        supply_cap: u64,
    ): u64 acquires FactoryRegistry {
        let pid_addr = signer::address_of(pid_signer);
        let registry = borrow_global<FactoryRegistry>(@desnet);
        assert!(
            smart_table::contains(&registry.owner_index, pid_addr),
            E_PID_NOT_REGISTERED
        );
        let handle = *smart_table::borrow(&registry.owner_index, pid_addr);
        let record = smart_table::borrow(&registry.records, handle);
        reaction_emission::emit_to_presser(
            record.reaction_reserve,
            recipient,
            post_id,
            press_order,
            supply_cap,
        )
    }
}
