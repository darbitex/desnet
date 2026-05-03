/// Opinion Pool — perpetual no-settle prediction substrate (rev4 2026-05-03).
///
/// Each "opinion" = a tokenized claim posted by a PID author with a registered
/// factory token. YAY (yes-belief) and NAY (no-belief) FA tokens trade on a
/// CPMM pool denominated in the creator's $token. Pool seeded symmetrically at
/// create — active from block 0.
///
/// Curve: pure x*y=k.
/// Vault collateral: creator's $token (factory::token_metadata_of_owner).
/// Tax: same $creator_token, BURNED via apt_vault::burn_via_vault.
///
/// CREATE — single mechanic, creator pays initial_mc:
///   pull initial_mc $creator_token → vault store
///   mint initial_mc YAY + initial_mc NAY → both to pool stores
///   creator wallet: 0 YAY, 0 NAY
///   pool: (initial_mc, initial_mc), k = initial_mc² — TRADABLE day 1
///   vault: initial_mc (LOCKED forever for creator — alias di-burn dari POV creator)
///
/// SUBSEQUENT TRADER OPS (anyone, including creator post-create):
///   deposit_pick_side(side, c)  : pay c + tax c×tax_bps; mint c YAY + c NAY;
///                                  user keeps c of chosen side; opposite c → pool
///   swap_yay_for_nay / swap_nay_for_yay : pure CPMM + tax burn
///   redeem_complete_set(amt)    : burn amt YAY + amt NAY; receive amt $token
///                                  + tax amt×tax_bps burned
///
/// Conservation invariant (always):
///   vault_$creator_token == total_yay_supply == total_nay_supply
///   (every mint adds equally to vault & both supplies; redeem subtracts equally;
///    swaps don't touch vault or total supplies)
///
/// NO oracle. NO settle. NO expiry. NO LP shares. NO LP fee.
/// NO press↔opinion coupling (orthogonal verbs by design).
/// Pool is coordination state, not ownable claim.
/// Creator's initial_mc is permanently locked in vault (no redeem path for creator).
///
/// Social-feed integration: each action (create/deposit/swap/redeem) appends
/// to actor's history with VERB_OPINION + BCS payload + #[event].
/// Payload structs carry `is_opinion: bool = true` sentinel.
///
/// See: docs/opinion-pool-amm-design.md (rev4) for full design lock + math.
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
    use aptos_std::string_utils;

    use desnet::apt_vault;
    use desnet::factory;
    use desnet::history;
    use desnet::profile;

    // ============ CONSTANTS ============

    /// Content text cap mirrors mint::CONTENT_TEXT_MAX_BYTES for feed consistency.
    const CONTENT_TEXT_MAX_BYTES: u64 = 333;

    /// Side discriminator for deposit / event encoding.
    const SIDE_NONE: u8 = 0;             // event-payload only (swap/redeem have no side)
    const SIDE_YAY: u8 = 1;
    const SIDE_NAY: u8 = 2;

    /// Event-kind discriminator inside OpinionFeedEntry payload.
    const KIND_CREATE: u8 = 0;
    const KIND_DEPOSIT: u8 = 1;
    const KIND_SWAP_YAY_FOR_NAY: u8 = 2;
    const KIND_SWAP_NAY_FOR_YAY: u8 = 3;
    const KIND_REDEEM: u8 = 4;

    /// FA decimals for opinion tokens. Matches factory token decimals (8) so
    /// 1 YAY redeems 1:1 with 1 $creator_token (with 1 NAY) via complete-set burn.
    const OPN_DECIMALS: u8 = 8;

    /// initial_mc bounds: [1M, 100M] WHOLE $creator_token.
    /// Factory tokens have 8 decimals + 1B total supply, so:
    ///   MIN = 1M  whole token = 0.1% of 1B supply per opinion (anti-dust)
    ///   MAX = 100M whole token = 10%  of 1B supply per opinion (anti-monopoly)
    const MIN_INITIAL_MC: u64 = 100_000_000_000_000;       //   1M token at 8 decimals = 1e14 raw
    const MAX_INITIAL_MC: u64 = 10_000_000_000_000_000;    // 100M token at 8 decimals = 1e16 raw

    /// Tax bps (creator-set per-opinion, immutable post-create).
    const DEFAULT_TAX_BPS: u64 = 10;     // 0.1% — applied to deposit/swap/redeem amounts
    const MAX_TAX_BPS: u64 = 1000;       // 10% cap (anti-trap)
    const BPS_DENOM: u64 = 10000;

    /// Per-PID cap on # opinion markets a single PID can spawn.
    /// Prevents storage-rent grief via opinion spam (each create allocates 1 market
    /// object + 3 FungibleStore children + 2 FA Metadata objects + SmartTable entry).
    /// 10_000 chosen as practical ceiling — far above any realistic creator's lifetime
    /// opinion count, while bounding worst-case state bloat at ~10k entries.
    const MAX_OPINIONS_PER_PID: u64 = 10_000;

    /// Object seed prefixes (deterministic addrs).
    const SEED_MARKET_PREFIX: vector<u8> = b"opinion_market::";
    const SEED_YAY: vector<u8> = b"YAY";
    const SEED_NAY: vector<u8> = b"NAY";

    // ============ ERROR CODES ============

    const E_CONTENT_TOO_LONG: u64 = 1;
    const E_PROFILE_REQUIRED: u64 = 2;
    const E_MARKET_NOT_FOUND: u64 = 3;
    const E_INVALID_SIDE: u64 = 4;
    const E_AMOUNT_ZERO: u64 = 5;
    const E_POOL_NOT_ACTIVE: u64 = 6;
    const E_SLIPPAGE_EXCEEDED: u64 = 7;
    const E_CONSERVATION_BROKEN: u64 = 8;
    const E_INSUFFICIENT_VAULT: u64 = 9;
    const E_NO_FACTORY_TOKEN: u64 = 10;
    const E_INITIAL_MC_OUT_OF_RANGE: u64 = 11;
    const E_TAX_BPS_TOO_HIGH: u64 = 12;
    const E_OPINION_LIMIT_REACHED: u64 = 13;
    /// rc2 D-M2 / Claude M-N2: prevents zero-output swap with naive min_out=0.
    const E_ZERO_OUTPUT: u64 = 14;
    /// rc2 Claude M-N1 sanity (impossible while MAX_TAX_BPS=1000<10000, but guards against future bps cap raise).
    const E_TAX_EXCEEDS_AMOUNT: u64 = 15;

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
    /// from (author_pid, seq). Holds YAY/NAY mint+burn refs and pool reserves.
    struct OpinionMarket has key {
        author_pid: address,
        seq: u64,
        creator_wallet: address,
        content_text: vector<u8>,                  // ≤333B, immutable
        // Creator's $token denomination (cached at create — immutable lookup)
        creator_token: address,                    // factory::token_metadata_of_owner(author_pid)
        creator_initial_mc: u64,                   // visible commitment signal (immutable)
        // Tax (creator-set at create, immutable, applies to subsequent trader ops)
        tax_bps: u64,
        // YAY / NAY FA addrs (deterministic children of market_addr)
        yay_metadata: address,
        nay_metadata: address,
        // Capabilities (sealed inside resource — only this module can mint/burn)
        yay_mint_ref: MintRef,
        yay_burn_ref: BurnRef,
        nay_mint_ref: MintRef,
        nay_burn_ref: BurnRef,
        // Pool reserves (FungibleStore objects owned by market_addr)
        pool_yay: Object<FungibleStore>,
        pool_nay: Object<FungibleStore>,
        // Collateral vault ($creator_token FungibleStore owned by market_addr)
        vault_token: Object<FungibleStore>,
        // Conservation accounting (sanity-checked on every mutating op)
        total_yay_supply: u64,
        total_nay_supply: u64,
        created_at_secs: u64,
        // Market signer derivation for FungibleStore withdraws
        market_extend_ref: ExtendRef,
    }

    // ============ EVENTS (#[event] Aptos events for indexers) ============

    /// Sentinel marker per user-spec: `is_opinion: bool = true`.
    /// Frontend MUST check this flag to distinguish from regular mint events.
    #[event]
    struct OpinionMintCreated has drop, store {
        is_opinion: bool,                          // = true (sentinel)
        author_pid: address,
        seq: u64,
        market_addr: address,
        creator_token: address,
        creator_initial_mc: u64,
        tax_bps: u64,
        yay_metadata: address,
        nay_metadata: address,
        content_text: vector<u8>,
        creator_wallet: address,
        timestamp_secs: u64,
    }

    /// Vote-like action (deposit / swap / redeem). Aggregator-friendly.
    #[event]
    struct OpinionAction has drop, store {
        is_opinion: bool,                          // = true (sentinel)
        kind: u8,                                  // KIND_DEPOSIT | KIND_SWAP_* | KIND_REDEEM
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,                                  // SIDE_YAY/NAY for deposit, SIDE_NONE for swap/redeem
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,                           // $creator_token burned in this op
        new_pool_yay: u64,
        new_pool_nay: u64,
        new_total_yay_supply: u64,
        new_total_nay_supply: u64,
        timestamp_secs: u64,
    }

    // ============ HISTORY-PAYLOAD STRUCTS (BCS-encoded into Entry.payload) ============

    /// Payload for VERB_OPINION entries with kind=KIND_CREATE.
    struct OpinionFeedCreate has copy, drop, store {
        is_opinion: bool,                          // = true (sentinel)
        kind: u8,                                  // = KIND_CREATE
        author_pid: address,
        seq: u64,
        market_addr: address,
        creator_token: address,
        creator_initial_mc: u64,
        tax_bps: u64,
        yay_metadata: address,
        nay_metadata: address,
        content_text: vector<u8>,
        creator_wallet: address,
        timestamp_secs: u64,
    }

    /// Payload for VERB_OPINION entries with kind in {DEPOSIT, SWAP_*, REDEEM}.
    struct OpinionFeedAction has copy, drop, store {
        is_opinion: bool,                          // = true (sentinel)
        kind: u8,
        actor_wallet: address,
        author_pid: address,
        seq: u64,
        market_addr: address,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,
        new_pool_yay: u64,
        new_pool_nay: u64,
        new_total_yay_supply: u64,
        new_total_nay_supply: u64,
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

    /// Create an opinion market with symmetric pool seed.
    /// Creator pays `initial_mc` $creator_token; mints initial_mc YAY + initial_mc NAY,
    /// BOTH go to pool. Creator wallet receives nothing (0 YAY, 0 NAY).
    /// Pool active from block 0 (k = initial_mc²). Vault locks initial_mc forever.
    ///
    /// Restrictions:
    /// - Author MUST have a Profile (mint::E_GUEST_CANNOT_MINT analog)
    /// - Author's wallet MUST have a registered factory token (E_NO_FACTORY_TOKEN)
    /// - initial_mc ∈ [1M, 100M] WHOLE $token (raw [1e14, 1e16] at 8 decimals)
    /// - tax_bps ≤ MAX_TAX_BPS (1000 = 10%)
    public entry fun create_opinion(
        author: &signer,
        content_text: vector<u8>,
        initial_mc: u64,
        tax_bps: u64,
    ) acquires PidOpinionMeta, PidOpinionIndex, OpinionMarket {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);

        // Validate content + bounds
        assert!(
            vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES,
            E_CONTENT_TOO_LONG,
        );
        assert!(
            initial_mc >= MIN_INITIAL_MC && initial_mc <= MAX_INITIAL_MC,
            E_INITIAL_MC_OUT_OF_RANGE,
        );
        assert!(tax_bps <= MAX_TAX_BPS, E_TAX_BPS_TOO_HIGH);

        // Guest restriction: author must have a registered factory token (the
        // opinion's denomination). If not, abort.
        // H1 FIX: factory::owner_index is keyed by PID address (not wallet) — see
        // factory.move:474-475 docstring. Use author_pid throughout for consistency
        // with vault_addr_of_pid call in burn_tax (which already uses PID).
        assert!(factory::owner_has_token(author_pid), E_NO_FACTORY_TOKEN);
        let creator_token = factory::token_metadata_of_owner(author_pid);

        ensure_opinion_storage(author_pid);

        // Allocate seq + enforce per-PID cap (M5: anti opinion-spam grief)
        let meta = borrow_global_mut<PidOpinionMeta>(author_pid);
        assert!(meta.opinion_count < MAX_OPINIONS_PER_PID, E_OPINION_LIMIT_REACHED);
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

        // L2 FIX: include seq in FA name + symbol for wallet UI uniqueness across
        // opinions. Without this, all YAY tokens display as identical "OPN-YAY"
        // in wallets which makes multi-opinion holdings impossible to distinguish.
        let seq_str = string_utils::to_string<u64>(&seq);

        // Mint YAY FA as named child of market → deterministic addr
        let yay_constructor = object::create_named_object(&market_signer, SEED_YAY);
        let yay_metadata = object::address_from_constructor_ref(&yay_constructor);
        let yay_name = string::utf8(b"Opinion YAY Share #");
        string::append(&mut yay_name, seq_str);
        let yay_symbol = string::utf8(b"OPN-YAY#");
        string::append(&mut yay_symbol, seq_str);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &yay_constructor,
            option::none<u128>(),                  // unlimited supply (bounded by collateral inflow)
            yay_name,
            yay_symbol,
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let yay_mint_ref = fungible_asset::generate_mint_ref(&yay_constructor);
        let yay_burn_ref = fungible_asset::generate_burn_ref(&yay_constructor);

        // Mint NAY FA as named child of market
        let nay_constructor = object::create_named_object(&market_signer, SEED_NAY);
        let nay_metadata = object::address_from_constructor_ref(&nay_constructor);
        let nay_name = string::utf8(b"Opinion NAY Share #");
        string::append(&mut nay_name, seq_str);
        let nay_symbol = string::utf8(b"OPN-NAY#");
        string::append(&mut nay_symbol, seq_str);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &nay_constructor,
            option::none<u128>(),
            nay_name,
            nay_symbol,
            OPN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let nay_mint_ref = fungible_asset::generate_mint_ref(&nay_constructor);
        let nay_burn_ref = fungible_asset::generate_burn_ref(&nay_constructor);

        // Create FungibleStores at market_addr for pool reserves + vault.
        let yay_metadata_obj = object::address_to_object<Metadata>(yay_metadata);
        let nay_metadata_obj = object::address_to_object<Metadata>(nay_metadata);
        let creator_token_obj = object::address_to_object<Metadata>(creator_token);
        let pool_yay_store = create_store_at_market(market_addr, yay_metadata_obj);
        let pool_nay_store = create_store_at_market(market_addr, nay_metadata_obj);
        let vault_token_store = create_store_at_market(market_addr, creator_token_obj);

        // ============ Symmetric pool seed ============
        // Pull initial_mc $creator_token from author → vault (locked forever for creator)
        let collateral_in = primary_fungible_store::withdraw(
            author, creator_token_obj, initial_mc,
        );
        fungible_asset::deposit(vault_token_store, collateral_in);

        // Mint initial_mc YAY + initial_mc NAY → BOTH go to pool (creator gets 0)
        let yay_seed = fungible_asset::mint(&yay_mint_ref, initial_mc);
        let nay_seed = fungible_asset::mint(&nay_mint_ref, initial_mc);
        fungible_asset::deposit(pool_yay_store, yay_seed);
        fungible_asset::deposit(pool_nay_store, nay_seed);

        let now_secs = timestamp::now_seconds();
        move_to(&market_signer, OpinionMarket {
            author_pid,
            seq,
            creator_wallet: author_addr,
            content_text,
            creator_token,
            creator_initial_mc: initial_mc,
            tax_bps,
            yay_metadata,
            nay_metadata,
            yay_mint_ref,
            yay_burn_ref,
            nay_mint_ref,
            nay_burn_ref,
            pool_yay: pool_yay_store,
            pool_nay: pool_nay_store,
            vault_token: vault_token_store,
            total_yay_supply: initial_mc,
            total_nay_supply: initial_mc,
            created_at_secs: now_secs,
            market_extend_ref,
        });

        // Conservation post-create: vault == total_yay == total_nay == initial_mc ✓
        let mkt_ref = borrow_global<OpinionMarket>(market_addr);
        assert_conservation(mkt_ref);

        // Register in PID's opinion index
        let idx = borrow_global_mut<PidOpinionIndex>(author_pid);
        smart_table::add(&mut idx.markets, seq, market_addr);

        // Append to history
        let feed_payload = OpinionFeedCreate {
            is_opinion: true,
            kind: KIND_CREATE,
            author_pid,
            seq,
            market_addr,
            creator_token,
            creator_initial_mc: initial_mc,
            tax_bps,
            yay_metadata,
            nay_metadata,
            content_text: mkt_ref.content_text,
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
            creator_token,
            creator_initial_mc: initial_mc,
            tax_bps,
            yay_metadata,
            nay_metadata,
            content_text: feed_payload.content_text,
            creator_wallet: author_addr,
            timestamp_secs: now_secs,
        });
    }

    // ============ DEPOSIT (Mirror-Mint pair-mint, anyone) ============

    /// Deposit `amount_token` $creator_token, mint amount_token YAY + amount_token NAY,
    /// keep chosen side, opposite side auto-deposits to pool.
    /// Tax: ceil(amount_token × tax_bps / 10000) $creator_token, BURNED on top.
    /// Creator NOT banned — boleh participate as normal trader.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount_token + tax_amount` $creator_token
    /// in primary store before tx — abort otherwise (atomic revert).
    public entry fun deposit_pick_side(
        user: &signer,
        author_pid: address,
        seq: u64,
        side: u8,
        amount_token: u64,
    ) acquires OpinionMarket {
        assert!(amount_token > 0, E_AMOUNT_ZERO);
        assert!(side == SIDE_YAY || side == SIDE_NAY, E_INVALID_SIDE);

        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global_mut<OpinionMarket>(market_addr);

        // M2 FIX: defense-in-depth pool-active check. Pool is always active post-create
        // (initial_mc symmetric seed > 0), but assert here catches any future regression.
        assert!(
            fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0,
            E_POOL_NOT_ACTIVE,
        );

        let user_addr = signer::address_of(user);

        // Pull collateral
        let creator_token_obj = object::address_to_object<Metadata>(mkt.creator_token);
        let token_in = primary_fungible_store::withdraw(user, creator_token_obj, amount_token);
        fungible_asset::deposit(mkt.vault_token, token_in);

        // Mint complete pair
        let yay_minted = fungible_asset::mint(&mkt.yay_mint_ref, amount_token);
        let nay_minted = fungible_asset::mint(&mkt.nay_mint_ref, amount_token);
        mkt.total_yay_supply = mkt.total_yay_supply + amount_token;
        mkt.total_nay_supply = mkt.total_nay_supply + amount_token;

        // User keeps chosen side; opposite goes to pool
        if (side == SIDE_YAY) {
            primary_fungible_store::deposit(user_addr, yay_minted);
            fungible_asset::deposit(mkt.pool_nay, nay_minted);
        } else {
            primary_fungible_store::deposit(user_addr, nay_minted);
            fungible_asset::deposit(mkt.pool_yay, yay_minted);
        };

        // Tax burn: extra creator_token from user, burned via apt_vault delegate
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_token, mkt.tax_bps);

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            user_addr,
            KIND_DEPOSIT,
            side,
            amount_token,
            amount_token,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    // ============ SWAP (CPMM, x*y=k) ============

    /// Swap `amount_in` of YAY to receive NAY from pool. No swap fee in YAY/NAY
    /// (pool stays clean); separate $creator_token tax burn.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount_in` YAY in primary store AND
    /// `ceil(amount_in × tax_bps / 10000)` $creator_token for the tax burn — both
    /// checked atomically; abort if either insufficient.
    public entry fun swap_yay_for_nay(
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

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_yay_r, pool_nay_r, amount_in);
        // rc2 D-M2 / M-N2 FIX (convergent DeepSeek+Claude): hard floor on amount_out
        // prevents zero-output swap (user pays input + tax for 0 output) when naive
        // frontend defaults min_out=0. Catches CPMM truncation at extreme pool ratios.
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        // Pull YAY from user → pool
        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_yay, yay_in);

        // Send NAY to user (derive market signer to authorize FungibleStore withdraw)
        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let nay_out = fungible_asset::withdraw(&market_signer, mkt.pool_nay, amount_out);
        primary_fungible_store::deposit(user_addr, nay_out);

        // rc2 D-M1 FIX (convergent Gemini+DeepSeek): tax base = $creator_token equivalent
        // of amount_in via opinion pool spot price, NOT raw YAY units. 1 YAY ≠ 1 $token
        // standalone (only PAIR redeems 1:1). Spot value: 1 YAY = nay_r/(yay_r+nay_r) $token.
        // Pool reserves captured pre-swap (pool_yay_r, pool_nay_r) for accurate spot.
        let amount_in_token_equiv = (((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64;
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        // M1 FIX: defense-in-depth conservation check. Swap shouldn't change vault
        // or total supplies, but assert here catches any future regression.
        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            user_addr,
            KIND_SWAP_YAY_FOR_NAY,
            SIDE_NONE,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    /// Swap `amount_in` of NAY to receive YAY from pool.
    /// UX (M4): user needs `amount_in` NAY + `ceil(amount_in × tax_bps / 10000)` $creator_token.
    public entry fun swap_nay_for_yay(
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

        let pool_yay_r = fungible_asset::balance(mkt.pool_yay);
        let pool_nay_r = fungible_asset::balance(mkt.pool_nay);
        assert!(pool_yay_r > 0 && pool_nay_r > 0, E_POOL_NOT_ACTIVE);

        let amount_out = compute_amount_out(pool_nay_r, pool_yay_r, amount_in);
        assert!(amount_out >= min_out, E_SLIPPAGE_EXCEEDED);

        let user_addr = signer::address_of(user);

        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount_in);
        fungible_asset::deposit(mkt.pool_nay, nay_in);

        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let yay_out = fungible_asset::withdraw(&market_signer, mkt.pool_yay, amount_out);
        primary_fungible_store::deposit(user_addr, yay_out);

        // rc2 D-M1 FIX: same as swap_yay_for_nay but reverse direction.
        // 1 NAY spot value = yay_r/(yay_r+nay_r) $token.
        let amount_in_token_equiv = (((amount_in as u128) * (pool_yay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64;
        let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in_token_equiv, mkt.tax_bps);

        // M1 FIX: defense-in-depth conservation check (same rationale as swap_yay_for_nay).
        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            user_addr,
            KIND_SWAP_NAY_FOR_YAY,
            SIDE_NONE,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    // ============ REDEEM COMPLETE SET ============

    /// Burn `amount` YAY + `amount` NAY from user, return `amount` $creator_token from vault.
    /// Tax: ceil(amount × tax_bps / 10000) $creator_token additional burn.
    /// Conservation invariant maintained.
    /// Note: creator typically has 0 YAY / 0 NAY (post-create), so they can't redeem
    /// unless they accumulate balanced pair via deposits/swaps as a regular trader.
    ///
    /// UX REQUIREMENT (M4): user must hold `amount` YAY + `amount` NAY + `ceil(amount × tax_bps / 10000)`
    /// $creator_token in primary stores. Atomic abort if any insufficient.
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

        assert!(fungible_asset::balance(mkt.vault_token) >= amount, E_INSUFFICIENT_VAULT);

        let user_addr = signer::address_of(user);

        // rc2 Claude M-N1 FIX: skim tax FROM VAULT OUTPUT instead of pulling extra
        // $creator_token from user. Preserves pair-mint AMM "always-exit" safety:
        // user holding (X YAY, X NAY, 0 $token) can now redeem (gets amount-tax,
        // tax sourced from vault). Economic effect identical (tax_amount $token
        // burned per redemption); funds source shifts user-wallet → vault output.
        let tax_amount = compute_tax(amount, mkt.tax_bps);
        assert!(tax_amount <= amount, E_TAX_EXCEEDS_AMOUNT);    // sanity (impossible at MAX_TAX_BPS=1000)

        // Pull YAY and NAY from user, burn both
        let yay_obj = object::address_to_object<Metadata>(mkt.yay_metadata);
        let nay_obj = object::address_to_object<Metadata>(mkt.nay_metadata);
        let yay_in = primary_fungible_store::withdraw(user, yay_obj, amount);
        let nay_in = primary_fungible_store::withdraw(user, nay_obj, amount);
        fungible_asset::burn(&mkt.yay_burn_ref, yay_in);
        fungible_asset::burn(&mkt.nay_burn_ref, nay_in);
        mkt.total_yay_supply = mkt.total_yay_supply - amount;
        mkt.total_nay_supply = mkt.total_nay_supply - amount;

        // Release collateral from vault, split into user-output + tax-burn (M-N1).
        let market_signer = object::generate_signer_for_extending(&mkt.market_extend_ref);
        let user_out_amount = amount - tax_amount;

        if (user_out_amount > 0) {
            let user_fa = fungible_asset::withdraw(&market_signer, mkt.vault_token, user_out_amount);
            primary_fungible_store::deposit(user_addr, user_fa);
        };

        let tax_burned = if (tax_amount > 0) {
            let tax_fa = fungible_asset::withdraw(&market_signer, mkt.vault_token, tax_amount);
            let vault_addr = factory::vault_addr_of_pid(mkt.author_pid);
            apt_vault::burn_via_vault(vault_addr, tax_fa);
            tax_amount
        } else {
            0
        };

        assert_conservation(mkt);

        let now_secs = timestamp::now_seconds();
        let new_pool_yay = fungible_asset::balance(mkt.pool_yay);
        let new_pool_nay = fungible_asset::balance(mkt.pool_nay);
        emit_action(
            mkt,
            user_addr,
            KIND_REDEEM,
            SIDE_NONE,
            amount,
            amount,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            now_secs,
        );
    }

    // ============ INTERNAL — math + invariants + helpers ============

    /// CPMM constant-product: pure quote (no LP fee — opinion pool has no LP role).
    /// Mirrors amm::compute_amount_out shape (darbitex-shape signature kept).
    /// L1 FIX: #[view] annotation for off-chain SDK / indexer call.
    /// rc2 Claude L-N1 FIX: defensive early-return on degenerate inputs to avoid
    /// framework div-by-zero abort when called from off-chain SDK.
    #[view]
    public fun compute_amount_out(
        reserve_in: u64,
        reserve_out: u64,
        amount_in: u64,
    ): u64 {
        if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;
        // No fee: amount_in_after_fee = amount_in
        let amount_in_u128 = amount_in as u128;
        let numerator = amount_in_u128 * (reserve_out as u128);
        let denominator = (reserve_in as u128) + amount_in_u128;
        ((numerator / denominator) as u64)
    }

    /// M3 FIX: ceiling tax computation. Prevents zero-tax sub-dust trades.
    /// Returns ceil(amount × tax_bps / BPS_DENOM). Pure function for testability.
    /// If tax_bps = 0 returns 0 (free market). If amount = 0 returns 0.
    /// For amount > 0 and tax_bps > 0, always returns >= 1 (anti-dust floor).
    /// rc2 Claude L-N2 FIX: assert tax_bps bound on public surface (matches
    /// internal create_opinion validation).
    #[view]
    public fun compute_tax(amount: u64, tax_bps: u64): u64 {
        assert!(tax_bps <= MAX_TAX_BPS, E_TAX_BPS_TOO_HIGH);
        if (tax_bps == 0 || amount == 0) return 0;
        let numerator = (amount as u128) * (tax_bps as u128) + (BPS_DENOM as u128) - 1;
        (numerator / (BPS_DENOM as u128)) as u64
    }

    /// Conservation invariant: vault == total_yay_supply == total_nay_supply.
    /// Held by atomic pair-mint (deposit/create) and pair-burn (redeem) semantics.
    /// rc2 Claude L-N3 FIX: cross-check module-local counter against FA framework
    /// supply view. Defense-in-depth catches any future regression in mint/burn
    /// pairing where local counter drifts from FA framework supply.
    fun assert_conservation(mkt: &OpinionMarket) {
        let vault_amt = fungible_asset::balance(mkt.vault_token);
        assert!(mkt.total_yay_supply == mkt.total_nay_supply, E_CONSERVATION_BROKEN);
        assert!(vault_amt == mkt.total_yay_supply, E_CONSERVATION_BROKEN);

        // L-N3 cross-check: FA framework supply must match tracked counter.
        // For supplies that don't track (unlimited unconstrained), framework returns
        // None — skip the cross-check in that case (still safe via local counter).
        let yay_meta = object::address_to_object<Metadata>(mkt.yay_metadata);
        let nay_meta = object::address_to_object<Metadata>(mkt.nay_metadata);
        let yay_supply_opt = fungible_asset::supply(yay_meta);
        let nay_supply_opt = fungible_asset::supply(nay_meta);
        if (option::is_some(&yay_supply_opt)) {
            let yay_fa_supply = option::extract(&mut yay_supply_opt);
            assert!(yay_fa_supply == (mkt.total_yay_supply as u128), E_CONSERVATION_BROKEN);
        };
        if (option::is_some(&nay_supply_opt)) {
            let nay_fa_supply = option::extract(&mut nay_supply_opt);
            assert!(nay_fa_supply == (mkt.total_nay_supply as u128), E_CONSERVATION_BROKEN);
        };
    }

    /// Pull `compute_tax(amount, tax_bps)` $creator_token from user and burn it via
    /// apt_vault::burn_via_vault. Returns the actual amount burned (for event payload).
    /// M3: uses ceiling rounding via compute_tax — prevents zero-tax dust trades.
    fun burn_tax(
        user: &signer,
        creator_token_addr: address,
        author_pid: address,
        amount: u64,
        tax_bps: u64,
    ): u64 {
        let tax_amount = compute_tax(amount, tax_bps);
        if (tax_amount == 0) return 0;
        let creator_token_obj = object::address_to_object<Metadata>(creator_token_addr);
        let tax_fa = primary_fungible_store::withdraw(user, creator_token_obj, tax_amount);
        let vault_addr = factory::vault_addr_of_pid(author_pid);
        apt_vault::burn_via_vault(vault_addr, tax_fa);
        tax_amount
    }

    fun emit_action(
        mkt: &OpinionMarket,
        actor_wallet: address,
        kind: u8,
        side: u8,
        amount_in: u64,
        amount_out: u64,
        tax_burned: u64,
        new_pool_yay: u64,
        new_pool_nay: u64,
        now_secs: u64,
    ) {
        let market_addr = market_addr_of(mkt.author_pid, mkt.seq);
        let actor_pid = profile::derive_pid_address(actor_wallet);
        // If actor has no profile, skip history append (events still emit)
        if (profile::profile_exists(actor_pid)) {
            let feed_payload = OpinionFeedAction {
                is_opinion: true,
                kind,
                actor_wallet,
                author_pid: mkt.author_pid,
                seq: mkt.seq,
                market_addr,
                side,
                amount_in,
                amount_out,
                tax_burned,
                new_pool_yay,
                new_pool_nay,
                new_total_yay_supply: mkt.total_yay_supply,
                new_total_nay_supply: mkt.total_nay_supply,
                timestamp_secs: now_secs,
            };
            history::append(
                actor_pid,
                history::new_entry(
                    history::verb_opinion(),
                    now_secs,
                    option::some(mkt.author_pid),
                    bcs::to_bytes(&feed_payload),
                    option::some(market_addr),
                ),
            );
        };

        event::emit(OpinionAction {
            is_opinion: true,
            kind,
            actor_wallet,
            author_pid: mkt.author_pid,
            seq: mkt.seq,
            market_addr,
            side,
            amount_in,
            amount_out,
            tax_burned,
            new_pool_yay,
            new_pool_nay,
            new_total_yay_supply: mkt.total_yay_supply,
            new_total_nay_supply: mkt.total_nay_supply,
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
        (fungible_asset::balance(mkt.pool_yay), fungible_asset::balance(mkt.pool_nay))
    }

    #[view]
    public fun total_supplies(author_pid: address, seq: u64): (u64, u64)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.total_yay_supply, mkt.total_nay_supply)
    }

    #[view]
    public fun vault_balance(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.vault_token)
    }

    #[view]
    public fun token_addrs(author_pid: address, seq: u64): (address, address)
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        (mkt.yay_metadata, mkt.nay_metadata)
    }

    #[view]
    public fun creator_token_of(author_pid: address, seq: u64): address
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.creator_token
    }

    #[view]
    public fun creator_initial_mc(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.creator_initial_mc
    }

    #[view]
    public fun tax_bps_of(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        assert!(exists<OpinionMarket>(market_addr), E_MARKET_NOT_FOUND);
        let mkt = borrow_global<OpinionMarket>(market_addr);
        mkt.tax_bps
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

    #[view]
    public fun is_pool_active(author_pid: address, seq: u64): bool
        acquires OpinionMarket
    {
        let market_addr = market_addr_of(author_pid, seq);
        if (!exists<OpinionMarket>(market_addr)) return false;
        let mkt = borrow_global<OpinionMarket>(market_addr);
        fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0
    }

    /// Marginal YAY price in $creator_token (basis: 1 YAY + 1 NAY = 1 $token via redeem).
    /// Returned as u64 in 1e8 fixed-point ("token raw"). 1.0 token = 100_000_000.
    #[view]
    public fun yay_price_token_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (yay_r, nay_r) = pool_reserves(author_pid, seq);
        assert!(yay_r > 0 && nay_r > 0, E_POOL_NOT_ACTIVE);
        (((nay_r as u128) * 100_000_000u128) / ((yay_r as u128) + (nay_r as u128)) as u64)
    }

    #[view]
    public fun nay_price_token_1e8(author_pid: address, seq: u64): u64
        acquires OpinionMarket
    {
        let (yay_r, nay_r) = pool_reserves(author_pid, seq);
        assert!(yay_r > 0 && nay_r > 0, E_POOL_NOT_ACTIVE);
        (((yay_r as u128) * 100_000_000u128) / ((yay_r as u128) + (nay_r as u128)) as u64)
    }

    // Side / kind constant getters

    #[view]
    public fun side_yay(): u8 { SIDE_YAY }
    #[view]
    public fun side_nay(): u8 { SIDE_NAY }
    #[view]
    public fun side_none(): u8 { SIDE_NONE }
    #[view]
    public fun kind_create(): u8 { KIND_CREATE }
    #[view]
    public fun kind_deposit(): u8 { KIND_DEPOSIT }
    #[view]
    public fun kind_swap_yay_for_nay(): u8 { KIND_SWAP_YAY_FOR_NAY }
    #[view]
    public fun kind_swap_nay_for_yay(): u8 { KIND_SWAP_NAY_FOR_YAY }
    #[view]
    public fun kind_redeem(): u8 { KIND_REDEEM }
    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }
    #[view]
    public fun min_initial_mc(): u64 { MIN_INITIAL_MC }
    #[view]
    public fun max_initial_mc(): u64 { MAX_INITIAL_MC }
    #[view]
    public fun default_tax_bps(): u64 { DEFAULT_TAX_BPS }
    #[view]
    public fun max_tax_bps(): u64 { MAX_TAX_BPS }

    // ============ TESTS ============

    #[test]
    fun test_compute_amount_out_no_fee() {
        // Pool (100, 10), buy YAY by sending NAY. Fee=0 (Mirror-Mint has no LP fee).
        // out = 10 * 100 / (100 + 100) = 5 for amount_in=100
        let out = compute_amount_out(100, 10, 100);
        assert!(out == 5, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_in() {
        let out = compute_amount_out(100, 10, 0);
        assert!(out == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_symmetric_pool() {
        // (100, 100), swap 10 → expected close to 10*100/(100+10) ≈ 9
        let out = compute_amount_out(100, 100, 10);
        assert!(out == 9, 1);    // 1000/110 = 9.09 → 9
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
        assert!(SIDE_YAY != SIDE_NAY, 1);
        assert!(SIDE_YAY != SIDE_NONE, 2);
        assert!(SIDE_NAY != SIDE_NONE, 3);
        assert!(KIND_CREATE != KIND_DEPOSIT, 4);
        assert!(KIND_DEPOSIT != KIND_SWAP_YAY_FOR_NAY, 5);
        assert!(KIND_SWAP_YAY_FOR_NAY != KIND_SWAP_NAY_FOR_YAY, 6);
        assert!(KIND_SWAP_NAY_FOR_YAY != KIND_REDEEM, 7);
    }

    #[test]
    fun test_initial_mc_bounds() {
        // 1M whole token at 8 decimals = 1e14 raw
        assert!(MIN_INITIAL_MC == 100_000_000_000_000, 1);
        // 100M whole token at 8 decimals = 1e16 raw
        assert!(MAX_INITIAL_MC == 10_000_000_000_000_000, 2);
        // 1B (factory total supply) = 1e17 raw, so MAX = 10% of supply
        assert!(MAX_INITIAL_MC * 10 == 100_000_000_000_000_000, 3);
    }

    #[test]
    fun test_tax_bps_constants() {
        assert!(DEFAULT_TAX_BPS == 10, 1);          // 0.1%
        assert!(MAX_TAX_BPS == 1000, 2);            // 10%
        assert!(BPS_DENOM == 10000, 3);
        // Sanity: default tax on 1M token deposit = 1000 raw (10/10000 = 0.1%)
        let tax = ((MIN_INITIAL_MC as u128) * (DEFAULT_TAX_BPS as u128) / (BPS_DENOM as u128)) as u64;
        assert!(tax == 100_000_000_000, 4);          // 0.1% of 1M token
    }

    // ============ M3 FIX TESTS — compute_tax ceiling rounding ============

    #[test]
    fun test_compute_tax_zero_inputs() {
        // tax_bps = 0 → 0 (free market)
        assert!(compute_tax(1_000_000_000, 0) == 0, 1);
        // amount = 0 → 0 (no op to tax)
        assert!(compute_tax(0, 30) == 0, 2);
        // both zero → 0
        assert!(compute_tax(0, 0) == 0, 3);
    }

    #[test]
    fun test_compute_tax_ceiling_dust_protection() {
        // M3 anti-dust: any nonzero (amount, tax_bps) yields >= 1 raw tax.
        // Without ceiling: 99 × 10 / 10000 = 0 (truncated to 0 = free trade).
        // With ceiling: ceil(99 × 10 / 10000) = ceil(0.099) = 1.
        assert!(compute_tax(99, 10) == 1, 1);
        assert!(compute_tax(1, 1) == 1, 2);          // ceil(1/10000) = 1
        assert!(compute_tax(500, 10) == 1, 3);       // ceil(0.5) = 1
        assert!(compute_tax(999, 10) == 1, 4);       // ceil(0.999) = 1
        assert!(compute_tax(1000, 10) == 1, 5);      // exact 1.0 → 1
        assert!(compute_tax(1001, 10) == 2, 6);      // ceil(1.001) = 2
    }

    #[test]
    fun test_compute_tax_normal_amounts() {
        // 1M token (1e14 raw) at 10 bps = 1e14 × 10 / 10000 = 1e11 = 100_000_000_000
        assert!(compute_tax(100_000_000_000_000, 10) == 100_000_000_000, 1);
        // 100M token (1e16 raw) at 30 bps = 1e16 × 30 / 10000 = 3e13 = 30_000_000_000_000
        assert!(compute_tax(10_000_000_000_000_000, 30) == 30_000_000_000_000, 2);
        // 1 token (1e8 raw) at max 10% (1000 bps) = 1e8 × 1000 / 10000 = 1e7 = 10_000_000
        assert!(compute_tax(100_000_000, 1000) == 10_000_000, 3);
    }

    #[test]
    fun test_compute_tax_max_bounds_no_overflow() {
        // amount = u64 max (~1.8e19), tax_bps = MAX (1000)
        // numerator = 1.8e19 × 1000 + 9999 ≈ 1.8e22, well under u128 (3.4e38)
        // result = 1.8e22 / 10000 = 1.8e18, fits in u64
        let max_amt = 18_446_744_073_709_551_615u64;     // u64::MAX
        let tax = compute_tax(max_amt, MAX_TAX_BPS);
        // Sanity: tax should be ~10% of max_amt
        assert!(tax > max_amt / 10 - 1, 1);
        assert!(tax <= max_amt / 10 + 1, 2);
    }

    // ============ M5 FIX TEST — opinion limit constant ============

    #[test]
    fun test_max_opinions_per_pid_constant() {
        assert!(MAX_OPINIONS_PER_PID == 10_000, 1);
        // Sanity: at MIN_INITIAL_MC per opinion (1M token), max 10k opinions
        // would lock 10k × 1M = 10B token, which exceeds 1B factory supply ×10.
        // So limit is bound by token supply long before the count cap kicks in.
        // The cap is defense against state-rent grief, not capital griefing.
    }

    // ============ rc2 FIX TESTS ============

    // --- L-N1: compute_amount_out defensive early returns ---

    #[test]
    fun test_compute_amount_out_zero_reserve_in() {
        // L-N1: would div-by-zero in old code; now early-returns 0
        assert!(compute_amount_out(0, 100, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_zero_reserve_out() {
        // L-N1: zero output reserve → output 0 (no liquidity to give)
        assert!(compute_amount_out(100, 0, 50) == 0, 1);
    }

    #[test]
    fun test_compute_amount_out_all_zero() {
        // L-N1: degenerate (0,0,0) safe early-return
        assert!(compute_amount_out(0, 0, 0) == 0, 1);
    }

    // --- L-N2: compute_tax public-surface tax_bps bound ---

    #[test]
    #[expected_failure(abort_code = E_TAX_BPS_TOO_HIGH, location = Self)]
    fun test_compute_tax_rejects_excessive_tax_bps() {
        // L-N2: public surface enforces tax_bps <= MAX_TAX_BPS even from external callers
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS + 1);
    }

    #[test]
    fun test_compute_tax_accepts_max_tax_bps() {
        // boundary: MAX_TAX_BPS itself is allowed
        let _ = compute_tax(1_000_000_000, MAX_TAX_BPS);
    }

    // --- D-M1 sanity: spot-price equivalent computation ---

    #[test]
    fun test_swap_tax_spot_value_correctness() {
        // D-M1 / G-H1: at pool (10, 100), spot price of YAY = nay_r/(yay_r+nay_r) = 100/110 ≈ 0.909
        // Swapping 11 YAY: spot value = 11 × 100/110 = 10 $token
        // Compared to old (face-value): tax was on 11 YAY raw. Now: tax on 10 $token.
        let pool_yay_r = 10u64;
        let pool_nay_r = 100u64;
        let amount_in = 11u64;
        let amount_in_token_equiv = (((amount_in as u128) * (pool_nay_r as u128))
            / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64;
        // 11 × 100 / 110 = 1100 / 110 = 10 exactly
        assert!(amount_in_token_equiv == 10, 1);
        // Tax on 10 at default 10 bps = ceil(10*10/10000) = 1
        assert!(compute_tax(amount_in_token_equiv, 10) == 1, 2);
    }

    #[test]
    fun test_swap_tax_extreme_skew_value() {
        // D-M1: extreme skew (1, 999) — 1 YAY worth almost full $token
        // amount_in = 1, spot value = 1 × 999/1000 ≈ 0 (rounds down)
        // amount_in = 1000 (10× pool_yay), spot value = 1000 × 999 / 1001 ≈ 998
        let v = (((1000u128) * (999u128)) / ((1u128) + (999u128))) as u64;
        // 999000 / 1000 = 999
        assert!(v == 999, 1);
    }

    // --- M-N1 sanity: redeem skim math ---

    #[test]
    fun test_redeem_skim_math() {
        // M-N1: redeem 1000 with tax_bps=10
        // tax_amount = ceil(1000 × 10 / 10000) = 1
        // user receives 1000 - 1 = 999
        // tax_burned = 1 (from vault output, not user external)
        let amount = 1000u64;
        let tax_amount = compute_tax(amount, 10);
        assert!(tax_amount == 1, 1);
        let user_out = amount - tax_amount;
        assert!(user_out == 999, 2);
        // Pool dust scenario: redeem 1, tax=1, user_out=0
        let dust_tax = compute_tax(1, 10);
        assert!(dust_tax == 1, 3);
        assert!(1 - dust_tax == 0, 4);            // user gets nothing on dust redeem
    }

    // --- D-M2: zero-output swap detection (constant only — full integration deferred) ---

    #[test]
    fun test_zero_output_detection_math() {
        // D-M2 / M-N2: pool (1e18, 1) swapping 1 YAY for NAY
        // amount_out = 1 × 1 / (1e18 + 1) = 0
        // The swap entry now asserts amount_out > 0 before mutation
        let huge_reserve_in = 1_000_000_000_000_000_000u64;        // 1e18
        let amount_in = 1u64;
        let amount_out = compute_amount_out(huge_reserve_in, 1, amount_in);
        assert!(amount_out == 0, 1);
        // E_ZERO_OUTPUT would abort the swap — verified at module-level constant
        assert!(E_ZERO_OUTPUT == 14, 2);
    }
}
