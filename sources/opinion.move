/// Opinion Pool — perpetual no-settle prediction substrate (SCAFFOLD 2026-05-03).
///
/// Each "opinion" = a tokenized claim posted by a PID author. Y (yes-belief)
/// and N (no-belief) FA tokens trade on a CPMM pool that bootstraps from (0,0)
/// without any creator-supplied seed liquidity.
///
/// Curve: "Mirror-Mint Bootstrap" — pure x*y=k.
/// Single rule (every deposit, from block 0):
///   deposit c APT → mint c Y + c N atomically.
///   user keeps c of chosen side. opposite c auto-deposits to pool.
///
/// Phase transitions automatic:
///   (0,0)         empty            no trading
///   (c,0) | (0,c) one-sided        no trading (k undefined)
///   (>0, >0)      two-sided        CPMM live, k = pool_y * pool_n
///
/// Conservation invariant (always):
///   vault_apt_balance == total_y_supply == total_n_supply
///   (each c APT mints exactly c Y + c N; redeem burns equal pair)
///
/// NO oracle. NO settle. NO expiry. NO redemption against ground truth.
/// Exit path: user swaps to balanced (Y, N) pair on pool, then `redeem_complete_set`
/// burns the pair to release c APT from vault.
///
/// Social-feed integration: each action (create / deposit / swap / redeem)
/// appends to actor's history with VERB_OPINION + BCS-encoded payload, so the
/// post and all engagement appear in the standard feed alongside mint/voice/etc.
/// Payload structs carry `is_opinion: bool = true` sentinel per user-spec.
///
/// See: docs/opinion-pool-amm-design.md for full design lock + math reference.
module desnet::opinion {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata, MintRef, BurnRef};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::history;

    // ============ CONSTANTS ============

    /// APT FA Metadata address (Aptos framework constant).
    const APT_FA_ADDR: address = @0xa;

    /// Content text cap mirrors mint::CONTENT_TEXT_MAX_BYTES for feed consistency.
    const CONTENT_TEXT_MAX_BYTES: u64 = 333;

    /// Side discriminator for deposit / event encoding.
    const SIDE_NONE: u8 = 0;
    const SIDE_Y: u8 = 1;
    const SIDE_N: u8 = 2;

    /// Event-kind discriminator inside OpinionFeedEntry payload.
    const KIND_CREATE: u8 = 0;
    const KIND_DEPOSIT: u8 = 1;
    const KIND_SWAP_Y_FOR_N: u8 = 2;
    const KIND_SWAP_N_FOR_Y: u8 = 3;
    const KIND_REDEEM: u8 = 4;

    /// FA decimals for opinion tokens (mirror APT for clean 1:1 collateral math).
    const OPN_DECIMALS: u8 = 8;

    /// Default fee = 0 bps. Open knob #6 (TBD); friend-settable hook reserved for v2.
    const DEFAULT_FEE_BPS: u64 = 0;
    const FEE_DENOM: u64 = 10000;

    /// Object seed prefixes (deterministic addrs).
    const SEED_MARKET_PREFIX: vector<u8> = b"opinion_market::";
    const SEED_Y: vector<u8> = b"Y";
    const SEED_N: vector<u8> = b"N";

    // ============ ERROR CODES ============

    const E_CONTENT_TOO_LONG: u64 = 1;
    const E_PROFILE_REQUIRED: u64 = 2;
    const E_MARKET_NOT_FOUND: u64 = 3;
    const E_INVALID_SIDE: u64 = 4;
    const E_AMOUNT_ZERO: u64 = 5;
    const E_POOL_NOT_ACTIVE: u64 = 6;
    const E_SLIPPAGE_EXCEEDED: u64 = 7;
    const E_CONSERVATION_BROKEN: u64 = 8;
    const E_INITIAL_PICK_INVALID: u64 = 9;
    const E_INSUFFICIENT_VAULT: u64 = 10;
    const E_INVALID_FEE: u64 = 11;

    // ============ TYPES ============

    /// Per-PID opinion sequence + cached counters. Stored at PID Object addr.
    struct PidOpinionMeta has key {
        next_seq: u64,
        opinion_count: u64,
    }

    /// Per-PID directory of seq → market_addr (frontend convenience + on-chain lookup).
    struct PidOpinionIndex has key {
        markets: SmartTable<u64, address>,
    }

    /// THE opinion-market resource. Lives at deterministic market_addr derived
    /// from (author_pid, seq). Holds Y/N mint+burn refs and pool reserves.
    struct OpinionMarket has key {
        author_pid: address,
        seq: u64,
        creator_wallet: address,
        content_text: vector<u8>,           // ≤333B, immutable
        // FA token addrs (deterministic children of market_addr)
        y_metadata: address,
        n_metadata: address,
        // Capabilities (sealed inside resource — only this module can mint/burn)
        y_mint_ref: MintRef,
        y_burn_ref: BurnRef,
        n_mint_ref: MintRef,
        n_burn_ref: BurnRef,
        // Pool reserves: FungibleStore objects owned by market_addr.
        pool_y: Object<FungibleStore>,
        pool_n: Object<FungibleStore>,
        // Collateral vault (APT FungibleStore owned by market_addr)
        vault_apt: Object<FungibleStore>,
        // Conservation accounting (sanity-checked on every mutating op)
        total_y_supply: u64,
        total_n_supply: u64,
        // Fee hook (currently 0; reserved for v2)
        fee_bps: u64,
        created_at_secs: u64,
        // Market signer derivation (rarely needed post-create; kept for future ops)
        market_extend_ref: ExtendRef,
    }

    // ============ EVENTS (#[event] Aptos events for indexers) ============

    /// Sentinel marker per user-spec: `is_opinion: bool = true`.
    /// Frontend MUST check this flag to distinguish from regular mint events.
    #[event]
    struct OpinionMintCreated has drop, store {
        is_opinion: bool,                   // = true (sentinel)
        author_pid: address,
        seq: u64,
        market_addr: address,
        y_metadata: address,
        n_metadata: address,
        content_text: vector<u8>,
        creator_wallet: address,
        timestamp_secs: u64,
    }

    /// Vote-like action (deposit / swap / redeem). Aggregator-friendly.
    #[event]
    struct OpinionAction has drop, store {
        is_opinion: bool,                   // = true (sentinel)
        kind: u8,                           // KIND_DEPOSIT | KIND_SWAP_* | KIND_REDEEM
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,                           // SIDE_Y/N for deposit, SIDE_NONE for swap/redeem
        amount_in: u64,
        amount_out: u64,
        new_pool_y: u64,
        new_pool_n: u64,
        new_total_y_supply: u64,
        new_total_n_supply: u64,
        timestamp_secs: u64,
    }

    // ============ HISTORY-PAYLOAD STRUCTS (BCS-encoded into Entry.payload) ============

    /// Payload for VERB_OPINION entries with kind=KIND_CREATE.
    /// Frontend BCS-decodes Entry.payload into this when verb=7 and kind byte = 0.
    struct OpinionFeedCreate has copy, drop, store {
        is_opinion: bool,                   // = true (sentinel; user-spec)
        kind: u8,                           // = KIND_CREATE
        author_pid: address,
        seq: u64,
        market_addr: address,
        y_metadata: address,
        n_metadata: address,
        content_text: vector<u8>,
        creator_wallet: address,
        timestamp_secs: u64,
    }

    /// Payload for VERB_OPINION entries with kind in {DEPOSIT, SWAP_*, REDEEM}.
    struct OpinionFeedAction has copy, drop, store {
        is_opinion: bool,                   // = true (sentinel; user-spec)
        kind: u8,
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        new_pool_y: u64,
        new_pool_n: u64,
        new_total_y_supply: u64,
        new_total_n_supply: u64,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — per-PID storage ============

    fun ensure_opinion_storage(pid_addr: address) {
        if (!exists<PidOpinionMeta>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidOpinionMeta { next_seq: 0, opinion_count: 0 });
        };
        if (!exists<PidOpinionIndex>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidOpinionIndex { markets: smart_table::new() });
        };
    }

    // ============ CREATE OPINION — main entry ============

    /// Create an opinion market with content. Optionally pick a side and seed
    /// initial deposit in the same tx (if `initial_pick_apt > 0`).
    ///
    /// `initial_pick_side`:
    ///   - SIDE_NONE (0): no auto-deposit; pool stays empty (0,0)
    ///   - SIDE_Y (1) or SIDE_N (2): atomically deposits `initial_pick_apt` APT
    ///     and runs phase-1 accumulation on chosen side.
    public entry fun create_opinion(
        author: &signer,
        content_text: vector<u8>,
        initial_pick_side: u8,
        initial_pick_apt: u64,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);

        assert!(
            vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES,
            E_CONTENT_TOO_LONG,
        );

        ensure_opinion_storage(author_pid);

        // Allocate seq
        let meta = borrow_global_mut<PidOpinionMeta>(author_pid);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.opinion_count = meta.opinion_count + 1;

        // Bootstrap market object as named child of pid_addr → deterministic addr.
        let pid_signer = profile::derive_pid_signer(author_pid);
        let market_seed = make_market_seed(seq);
        let market_constructor = object::create_named_object(&pid_signer, market_seed);
        let market_addr = object::address_from_constructor_ref(&market_constructor);
        let market_signer = object::generate_signer(&market_constructor);
        let market_extend_ref = object::generate_extend_ref(&market_constructor);
        // Disable ungated transfer — market object is bound to PID
        let mkt_transfer = object::generate_transfer_ref(&market_constructor);
        object::disable_ungated_transfer(&mkt_transfer);

        // Mint Y FA as named child of market → deterministic addr
        let y_constructor = object::create_named_object(&market_signer, SEED_Y);
        let y_metadata = object::address_from_constructor_ref(&y_constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &y_constructor,
            option::none<u128>(),                       // unlimited supply (bounded by APT inflow)
            string::utf8(b"Opinion YES Share"),
            string::utf8(b"OPN-Y"),
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let y_mint_ref = fungible_asset::generate_mint_ref(&y_constructor);
        let y_burn_ref = fungible_asset::generate_burn_ref(&y_constructor);

        // Mint N FA
        let n_constructor = object::create_named_object(&market_signer, SEED_N);
        let n_metadata = object::address_from_constructor_ref(&n_constructor);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &n_constructor,
            option::none<u128>(),
            string::utf8(b"Opinion NO Share"),
            string::utf8(b"OPN-N"),
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let n_mint_ref = fungible_asset::generate_mint_ref(&n_constructor);
        let n_burn_ref = fungible_asset::generate_burn_ref(&n_constructor);

        // Create empty FungibleStores at market_addr for pool reserves + vault.
        let y_metadata_obj = object::address_to_object<Metadata>(y_metadata);
        let n_metadata_obj = object::address_to_object<Metadata>(n_metadata);
        let apt_metadata_obj = object::address_to_object<Metadata>(APT_FA_ADDR);
        let pool_y_store = create_store_at_market(market_addr, y_metadata_obj);
        let pool_n_store = create_store_at_market(market_addr, n_metadata_obj);
        let vault_apt_store = create_store_at_market(market_addr, apt_metadata_obj);

        let now_secs = timestamp::now_seconds();
        move_to(&market_signer, OpinionMarket {
            author_pid,
            seq,
            creator_wallet: author_addr,
            content_text,
            y_metadata,
            n_metadata,
            y_mint_ref,
            y_burn_ref,
            n_mint_ref,
            n_burn_ref,
            pool_y: pool_y_store,
            pool_n: pool_n_store,
            vault_apt: vault_apt_store,
            total_y_supply: 0,
            total_n_supply: 0,
            fee_bps: DEFAULT_FEE_BPS,
            created_at_secs: now_secs,
            market_extend_ref,
        });

        // Register in PID's opinion index
        let idx = borrow_global_mut<PidOpinionIndex>(author_pid);
        smart_table::add(&mut idx.markets, seq, market_addr);

        // Append to history (verb=OPINION, payload=BCS(OpinionFeedCreate), asset=market_addr)
        // Re-borrow content for payload (move-semantics: we already consumed it into resource)
        let market_ref = borrow_global<OpinionMarket>(market_addr);
        let feed_payload = OpinionFeedCreate {
            is_opinion: true,                           // SENTINEL (user-spec)
            kind: KIND_CREATE,
            author_pid,
            seq,
            market_addr,
            y_metadata,
            n_metadata,
            content_text: market_ref.content_text,
            creator_wallet: author_addr,
            timestamp_secs: now_secs,
        };
        history::append(
            author_pid,
            history::new_entry(
                history::verb_opinion(),
                now_secs,
                option::none<address>(),
                bcs::to_bytes(&feed_payload),
                option::some(market_addr),
            ),
        );
        event::emit(OpinionMintCreated {
            is_opinion: true,
            author_pid,
            seq,
            market_addr,
            y_metadata,
            n_metadata,
            content_text: feed_payload.content_text,
            creator_wallet: author_addr,
            timestamp_secs: now_secs,
        });

        // Optional initial deposit in same tx
        if (initial_pick_apt > 0) {
            assert!(
                initial_pick_side == SIDE_Y || initial_pick_side == SIDE_N,
                E_INITIAL_PICK_INVALID,
            );
            deposit_pick_side(author, author_pid, seq, initial_pick_side, initial_pick_apt);
        } else {
            // If apt=0 then side must also be NONE (no half-spec)
            assert!(initial_pick_side == SIDE_NONE, E_INITIAL_PICK_INVALID);
        };
    }

    // ============ DEPOSIT (Mirror-Mint) ============

    /// Deposit `amount_apt` APT, mint `amount_apt` Y + `amount_apt` N, keep
    /// chosen side, opposite side auto-deposits to pool. Activates phase 2
    /// trading on the first opposite-side deposit.
    public entry fun deposit_pick_side(
        user: &signer,
        author_pid: address,
        seq: u64,
        side: u8,
        amount_apt: u64,
    ) acquires OpinionMarket {
        assert!(amount_apt > 0, E_AMOUNT_ZERO);
        assert!(side == SIDE_Y || side == SIDE_N, E_INVALID_SIDE);

        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let user_addr = signer::address_of(user);

        // Pull APT collateral
        let apt_metadata_obj = object::address_to_object<Metadata>(APT_FA_ADDR);
        let apt_in = primary_fungible_store::withdraw(user, apt_metadata_obj, amount_apt);
        fungible_asset::deposit(mkt.vault_apt,apt_in);

        // Mint complete pair
        let y_minted = fungible_asset::mint(&mkt.y_mint_ref, amount_apt);
        let n_minted = fungible_asset::mint(&mkt.n_mint_ref, amount_apt);
        mkt.total_y_supply = mkt.total_y_supply + amount_apt;
        mkt.total_n_supply = mkt.total_n_supply + amount_apt;

        // User keeps chosen side; opposite goes to pool
        if (side == SIDE_Y) {
            primary_fungible_store::deposit(user_addr, y_minted);
            fungible_asset::deposit(mkt.pool_n,n_minted);
        } else {
            primary_fungible_store::deposit(user_addr, n_minted);
            fungible_asset::deposit(mkt.pool_y,y_minted);
        };

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_y = fungible_asset::balance(mkt.pool_y);
        let new_pool_n = fungible_asset::balance(mkt.pool_n);
        emit_action(
            mkt,
            user_addr,
            KIND_DEPOSIT,
            side,
            amount_apt,
            amount_apt,
            new_pool_y,
            new_pool_n,
            now_secs,
        );
    }

    // ============ SWAP (CPMM, x*y=k) ============

    /// Swap `amount_in` of Y to receive N from pool. Phase-2 only.
    public entry fun swap_y_for_n(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_y_r = fungible_asset::balance(mkt.pool_y);
        let pool_n_r = fungible_asset::balance(mkt.pool_n);
        assert!(pool_y_r > 0 && pool_n_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_y_r, pool_n_r, amount_in, mkt.fee_bps);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        // Pull Y from user → pool
        let y_metadata_obj = object::address_to_object<Metadata>(mkt.y_metadata);
        let y_in = primary_fungible_store::withdraw(user, y_metadata_obj, amount_in);
        fungible_asset::deposit(mkt.pool_y, y_in);

        // Send N to user (derive market signer to authorize FungibleStore withdraw)
        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let n_out = fungible_asset::withdraw(&market_signer, mkt.pool_n, amount_out);
        primary_fungible_store::deposit(user_addr, n_out);

        let now_secs = timestamp::now_seconds();
        let new_pool_y = fungible_asset::balance(mkt.pool_y);
        let new_pool_n = fungible_asset::balance(mkt.pool_n);
        emit_action(
            mkt,
            user_addr,
            KIND_SWAP_Y_FOR_N,
            SIDE_NONE,
            amount_in,
            amount_out,
            new_pool_y,
            new_pool_n,
            now_secs,
        );
    }

    /// Swap `amount_in` of N to receive Y from pool. Phase-2 only.
    public entry fun swap_n_for_y(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount_in: u64,
        min_out: u64,
    ) acquires OpinionMarket {
        assert!(amount_in > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        let pool_y_r = fungible_asset::balance(mkt.pool_y);
        let pool_n_r = fungible_asset::balance(mkt.pool_n);
        assert!(pool_y_r > 0 && pool_n_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_n_r, pool_y_r, amount_in, mkt.fee_bps);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        let n_metadata_obj = object::address_to_object<Metadata>(mkt.n_metadata);
        let n_in = primary_fungible_store::withdraw(user, n_metadata_obj, amount_in);
        fungible_asset::deposit(mkt.pool_n, n_in);

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let y_out = fungible_asset::withdraw(&market_signer, mkt.pool_y, amount_out);
        primary_fungible_store::deposit(user_addr, y_out);

        let now_secs = timestamp::now_seconds();
        let new_pool_y = fungible_asset::balance(mkt.pool_y);
        let new_pool_n = fungible_asset::balance(mkt.pool_n);
        emit_action(
            mkt,
            user_addr,
            KIND_SWAP_N_FOR_Y,
            SIDE_NONE,
            amount_in,
            amount_out,
            new_pool_y,
            new_pool_n,
            now_secs,
        );
    }

    // ============ REDEEM COMPLETE SET ============

    /// Burn `amount` Y + `amount` N from user, return `amount` APT from vault.
    /// Conservation invariant maintained.
    public entry fun redeem_complete_set(
        user: &signer,
        author_pid: address,
        seq: u64,
        amount: u64,
    ) acquires OpinionMarket {
        assert!(amount > 0, E_AMOUNT_ZERO);
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        assert!(fungible_asset::balance(mkt.vault_apt) >= amount, E_INSUFFICIENT_VAULT);

        let user_addr = signer::address_of(user);

        // Pull Y and N from user, burn both
        let y_metadata_obj = object::address_to_object<Metadata>(mkt.y_metadata);
        let n_metadata_obj = object::address_to_object<Metadata>(mkt.n_metadata);
        let y_in = primary_fungible_store::withdraw(user, y_metadata_obj, amount);
        let n_in = primary_fungible_store::withdraw(user, n_metadata_obj, amount);
        fungible_asset::burn(&mkt.y_burn_ref, y_in);
        fungible_asset::burn(&mkt.n_burn_ref, n_in);
        mkt.total_y_supply = mkt.total_y_supply - amount;
        mkt.total_n_supply = mkt.total_n_supply - amount;

        // Release APT from vault (derive market signer to authorize withdraw)
        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let apt_out = fungible_asset::withdraw(&market_signer, mkt.vault_apt, amount);
        primary_fungible_store::deposit(user_addr, apt_out);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_y = fungible_asset::balance(mkt.pool_y);
        let new_pool_n = fungible_asset::balance(mkt.pool_n);
        emit_action(
            mkt,
            user_addr,
            KIND_REDEEM,
            SIDE_NONE,
            amount,
            amount,
            new_pool_y,
            new_pool_n,
            now_secs,
        );
    }

    // ============ INTERNAL — math + invariants + emit helpers ============

    /// CPMM constant-product: pure quote with optional bps fee.
    /// Mirrors amm::compute_amount_out shape (darbitex-shape signature kept).
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
        fee_bps: u64,
    ): u64 {
        assert!(fee_bps < FEE_DENOM, E_INVALID_FEE);
        let amount_in_after_fee = (amount_in as u128) * ((FEE_DENOM - fee_bps) as u128);
        let numerator = amount_in_after_fee * (reserve_out as u128);
        let denominator = (reserve_in as u128) * (FEE_DENOM as u128) + amount_in_after_fee;
        ((numerator / denominator) as u64)
    }

    /// Conservation invariant: vault_apt == total_y_supply == total_n_supply.
    /// Held by atomic mint-pair / burn-pair semantics. Sanity-checked on every mutating op.
    fun assert_conservation(mkt: &OpinionMarket) {
        let vault_amt = fungible_asset::balance(mkt.vault_apt);
        assert!(mkt.total_y_supply == mkt.total_n_supply, E_CONSERVATION_BROKEN);
        assert!(vault_amt == mkt.total_y_supply, E_CONSERVATION_BROKEN);
    }

    fun emit_action(
        mkt: &OpinionMarket,
        actor_wallet: address,
        kind: u8,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        new_pool_y: u64,
        new_pool_n: u64,
        now_secs: u64,
    ) {
        // History append (under actor's PID for "who did what" social-feed semantics)
        let actor_pid = profile::derive_pid_address(actor_wallet);
        // If actor has no profile, skip history append (events still emit)
        if (profile::profile_exists(actor_pid)) {
            let feed_payload = OpinionFeedAction {
                is_opinion: true,
                kind,
                actor_wallet,
                author_pid: mkt.author_pid,
                seq: mkt.seq,
                market_addr: market_addr_of(mkt.author_pid, mkt.seq),
                side,
                amount_in,
                amount_out,
                new_pool_y,
                new_pool_n,
                new_total_y_supply: mkt.total_y_supply,
                new_total_n_supply: mkt.total_n_supply,
                timestamp_secs: now_secs,
            };
            history::append(
                actor_pid,
                history::new_entry(
                    history::verb_opinion(),
                    now_secs,
                    option::some(mkt.author_pid),
                    bcs::to_bytes(&feed_payload),
                    option::some(market_addr_of(mkt.author_pid, mkt.seq)),
                ),
            );
        };

        event::emit(OpinionAction {
            is_opinion: true,
            kind,
            actor_wallet,
            author_pid: mkt.author_pid,
            seq: mkt.seq,
            market_addr: market_addr_of(mkt.author_pid, mkt.seq),
            side,
            amount_in,
            amount_out,
            new_pool_y,
            new_pool_n,
            new_total_y_supply: mkt.total_y_supply,
            new_total_n_supply: mkt.total_n_supply,
            timestamp_secs: now_secs,
        });
    }

    fun make_market_seed(seq: u64): vector<u8> {
        let s = SEED_MARKET_PREFIX;
        vector::append(&mut s, bcs::to_bytes(&seq));
        s
    }

    /// Create an empty FungibleStore as a child object of market_addr for `metadata`.
    /// Mirrors amm::create_store_at_pool pattern.
    fun create_store_at_market(market_addr: address, metadata: Object<Metadata>): Object<FungibleStore> {
        let store_constructor = object::create_object(market_addr);
        fungible_asset::create_store<Metadata>(&store_constructor, metadata)
    }

    // ============ VIEWS ============

    #[view]
    public fun market_addr_of(author_pid: address, seq: u64): address {
        object::create_object_address(&author_pid, make_market_seed(seq))
    }

    #[view]
    public fun market_exists(author_pid: address, seq: u64): bool {
        exists<OpinionMarket>(market_addr_of(author_pid, seq))
    }

    #[view]
    public fun next_seq(author_pid: address): u64 acquires PidOpinionMeta {
        if (!exists<PidOpinionMeta>(author_pid)) return 0;
        borrow_global<PidOpinionMeta>(author_pid).next_seq
    }

    #[view]
    public fun opinion_count(author_pid: address): u64 acquires PidOpinionMeta {
        if (!exists<PidOpinionMeta>(author_pid)) return 0;
        borrow_global<PidOpinionMeta>(author_pid).opinion_count
    }

    #[view]
    public fun pool_reserves(author_pid: address, seq: u64): (u64, u64)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (fungible_asset::balance(mkt.pool_y), fungible_asset::balance(mkt.pool_n))
    }

    #[view]
    public fun total_supplies(author_pid: address, seq: u64): (u64, u64)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.total_y_supply, mkt.total_n_supply)
    }

    #[view]
    public fun vault_balance(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.vault_apt)
    }

    #[view]
    public fun token_addrs(author_pid: address, seq: u64): (address, address)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.y_metadata, mkt.n_metadata)
    }

    #[view]
    public fun content_text(author_pid: address, seq: u64): vector<u8>
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.content_text
    }

    /// Returns true once both reserves > 0 (CPMM phase 2 active, trading enabled).
    #[view]
    public fun is_pool_active(author_pid: address, seq: u64): bool
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        if (!exists<OpinionMarket>(market_addr)) return false;
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.pool_y) > 0 && fungible_asset::balance(mkt.pool_n) > 0
    }

    /// Marginal Y price in APT (basis: total = 1 APT per complete set).
    /// Returned as u64 in 1e8 fixed-point ("APT raw"). 1.0 APT = 100_000_000.
    /// Aborts if pool inactive.
    #[view]
    public fun y_price_apt_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (y_r, n_r) = pool_reserves(author_pid, seq);
        assert!(y_r > 0 && n_r > 0, E_POOL_NOT_ACTIVE);
        // Y_price = N_r / (Y_r + N_r), expressed in 1e8
        (((n_r as u128) * 100_000_000u128) / ((y_r as u128) + (n_r as u128)) as u64)
    }

    #[view]
    public fun n_price_apt_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (y_r, n_r) = pool_reserves(author_pid, seq);
        assert!(y_r > 0 && n_r > 0, E_POOL_NOT_ACTIVE);
        (((y_r as u128) * 100_000_000u128) / ((y_r as u128) + (n_r as u128)) as u64)
    }

    // Side / kind constant getters

    #[view]
    public fun side_y(): u8 { SIDE_Y }
    #[view]
    public fun side_n(): u8 { SIDE_N }
    #[view]
    public fun side_none(): u8 { SIDE_NONE }
    #[view]
    public fun kind_create(): u8 { KIND_CREATE }
    #[view]
    public fun kind_deposit(): u8 { KIND_DEPOSIT }
    #[view]
    public fun kind_swap_y_for_n(): u8 { KIND_SWAP_Y_FOR_N }
    #[view]
    public fun kind_swap_n_for_y(): u8 { KIND_SWAP_N_FOR_Y }
    #[view]
    public fun kind_redeem(): u8 { KIND_REDEEM }
    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }

    // ============ TESTS ============

    #[test]
    fun test_compute_amount_out_no_fee() {
        // Pool (10, 100), buy Y by sending N. Fee=0.
        // out = 10 * 1 / (100 + 1) = 0 (rounded down) for amount_in=1
        // out = 10 * 100 / (100 + 100) = 5 for amount_in=100
        let out = compute_amount_out(100, 10, 100, 0);
        assert!(out == 5, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        let out = compute_amount_out(100, 10, 0, 0);
        assert!(out == 0, 1);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_FEE, location = Self)]
    fun test_compute_amount_out_invalid_fee() {
        let _ = compute_amount_out(100, 100, 50, 10000);    // fee == DENOM rejected
    }

    #[test]
    fun test_make_market_seed_deterministic() {
        let s1 = make_market_seed(0);
        let s2 = make_market_seed(0);
        let s3 = make_market_seed(1);
        assert!(s1 == s2, 1);
        assert!(s1 != s3, 2);
    }

    #[test]
    fun test_market_addr_deterministic() {
        let a1 = market_addr_of(@0xCAFE, 5);
        let a2 = market_addr_of(@0xCAFE, 5);
        let b1 = market_addr_of(@0xCAFE, 6);
        let c1 = market_addr_of(@0xBEEF, 5);
        assert!(a1 == a2, 1);
        assert!(a1 != b1, 2);
        assert!(a1 != c1, 3);
    }

    #[test]
    fun test_constants_distinct() {
        assert!(SIDE_Y != SIDE_N, 1);
        assert!(SIDE_Y != SIDE_NONE, 2);
        assert!(SIDE_N != SIDE_NONE, 3);
        assert!(KIND_CREATE != KIND_DEPOSIT, 4);
        assert!(KIND_DEPOSIT != KIND_SWAP_Y_FOR_N, 5);
        assert!(KIND_SWAP_Y_FOR_N != KIND_SWAP_N_FOR_Y, 6);
        assert!(KIND_SWAP_N_FOR_Y != KIND_REDEEM, 7);
    }
}
