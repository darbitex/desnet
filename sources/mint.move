/// Mint — the creation primitive (LOCKED 2026-05-01).
///
/// MintEvent is the single emission for: Mint (original), Voice (reply), Remix (quote).
/// Mode determined by parent_mint_id + quote_mint_id fields:
///   - Mint:  parent=None, quote=None
///   - Voice: parent=Some, quote=None
///   - Remix: parent=None, quote=Some
///   (parent+quote both Some = invalid, abort)
///
/// Validation rules (LOCKED, on-chain enforced):
/// - author MUST have Profile (Named tier; guests can't mint)
/// - content_text ≤ 333 bytes
/// - media: if Inline, data ≤ 8KB hard cap
/// - mentions ≤ 10 (any Supra addr — flexible: PID/hex/ANS-resolved)
/// - tags ≤ 5, each 1-32 bytes lowercase a-z/0-9/-
/// - tickers ≤ 5, each MUST be factory-spawned FA (factory::is_factory_token assert)
/// - tips ≤ 10, each token MUST be FA-standard (no legacy coin)
///
/// Tags = ownerless folksonomy permanently. Tickers = factory-only scope (every $X
/// resolves to a PID). Mentions = flexible (implicit-then-named magic preserved).
///
/// Self-exempt for ReferenceGate: post creator always passes own mint-level gate.
module desnet::mint {
    use std::bcs;
    use std::signer;
    use std::option::{Self, Option};
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};

    use desnet::profile;
    use desnet::reference_gate::{Self, ReferenceGate};
    use desnet::history;
    use desnet::assets;
    use desnet::factory;

    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    // ============ CONSTANTS — caps locked 2026-05-01 ============

    const CONTENT_TEXT_MAX_BYTES: u64 = 333;
    const MEDIA_INLINE_MAX_BYTES: u64 = 8192;     // 8KB hard cap
    const MENTIONS_MAX: u64 = 10;
    const TAGS_MAX: u64 = 5;
    const TAG_MAX_BYTES: u64 = 32;
    const TAG_MIN_BYTES: u64 = 1;
    const TICKERS_MAX: u64 = 5;
    const TIPS_MAX: u64 = 10;

    /// MintMedia variant tags
    const MEDIA_KIND_INLINE: u8 = 1;
    const MEDIA_KIND_REF: u8 = 2;

    /// MIME u8 enum. SVG INCLUDED 2026-05-01 (on-chain generative art ethos;
    /// XSS = frontend responsibility via <img>-tag sandbox).
    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    /// Storage backend tags for MintMedia::Ref
    const BACKEND_SHELBY: u8 = 0;
    const BACKEND_WALRUS: u8 = 1;
    const BACKEND_IPFS: u8 = 2;
    const BACKEND_DESNET_ASSETS: u8 = 3;

    // ============ ERROR CODES ============

    const E_GUEST_CANNOT_MINT: u64 = 1;
    const E_BOTH_PARENT_AND_QUOTE: u64 = 2;
    const E_CONTENT_TOO_LONG: u64 = 3;
    const E_INLINE_MEDIA_TOO_LARGE: u64 = 4;
    const E_TOO_MANY_MENTIONS: u64 = 5;
    const E_TOO_MANY_TAGS: u64 = 6;
    const E_TAG_TOO_SHORT: u64 = 7;
    const E_TAG_TOO_LONG: u64 = 8;
    const E_TAG_INVALID_CHAR: u64 = 9;
    const E_TOO_MANY_TICKERS: u64 = 10;
    const E_TICKER_NOT_FACTORY_TOKEN: u64 = 11;
    const E_TOO_MANY_TIPS: u64 = 12;
    const E_INVALID_MIME: u64 = 13;
    const E_INVALID_BACKEND: u64 = 14;
    const E_PARENT_MINT_NOT_FOUND: u64 = 15;
    const E_QUOTE_MINT_NOT_FOUND: u64 = 16;
    const E_GATE_FAILED: u64 = 17;
    const E_MINT_META_NOT_INITIALIZED: u64 = 18;
    const E_MINT_NOT_FOUND: u64 = 20;
    const E_ASSET_NOT_SEALED: u64 = 19;

    // ============ TYPES ============

    /// Per-PID mint sequence + counters. Stored at PID Object addr.
    struct PidMintMeta has key {
        next_seq: u64,
        mint_count: u64,
    }

    /// Per-PID extras storage (PressConfig, Giveaway, MintGate per mint seq).
    /// Lazy-grown SmartTable<seq, MintExtras>.
    struct PidMintExtras has key {
        extras: SmartTable<u64, MintExtras>,
    }

    /// Per-mint optional extras. Stored in PidMintExtras.extras[seq].
    /// Press, Giveaway, ReferenceGate all live HERE (not in event for size reasons).
    struct MintExtras has store {
        gate: Option<ReferenceGate>,
        // Note: PressConfig + Giveaway stored separately in their own modules' resources
        // via mint_id key (= (author_pid, seq) tuple). Kept extensible here for future fields.
    }

    /// MintId compound key: (author_pid, seq). Used as parent_mint_id / quote_mint_id ref.
    struct MintId has copy, drop, store {
        author: address,
        seq: u64,
    }

    /// MintMedia tagged variant (Inline OR Ref, never both).
    struct MintMedia has copy, drop, store {
        kind: u8,                          // MEDIA_KIND_INLINE | MEDIA_KIND_REF
        mime: u8,                          // MIME_PNG | MIME_JPEG | MIME_GIF | MIME_WEBP
        // Inline path
        inline_data: vector<u8>,           // if kind=Inline, ≤8KB
        // Ref path
        ref_backend: u8,                   // if kind=Ref, BACKEND_*
        ref_blob_id: vector<u8>,
        ref_hash: vector<u8>,
    }

    /// Atomic tip embedded in mint.
    struct Tip has copy, drop, store {
        recipient: address,
        token_metadata: address,           // FA-only (legacy coin excluded)
        amount: u64,
    }

    // ============ EVENTS ============

    /// THE creation record (LOCKED).
    /// Modes: Mint (parent=None, quote=None) | Voice (parent=Some) | Remix (quote=Some).
    /// Replaces former #[event] — now BCS-encoded into history::Entry.payload.
    /// Struct retained for canonical encoding; frontend / indexer decodes via this layout.
    struct MintEvent has drop, store {
        author: address,                            // PID Object addr
        seq: u64,
        timestamp_us: u64,
        content_kind: u8,                           // type discriminator (text/etc)
        content_text: vector<u8>,                   // ≤333 bytes
        media: Option<MintMedia>,                   // optional inline OR ref
        parent_mint_id: Option<MintId>,             // Voice mode if Some
        root_mint_id: Option<MintId>,               // thread-head jump optimization
        quote_mint_id: Option<MintId>,              // Remix mode if Some
        mentions: vector<address>,                  // ≤10
        tags: vector<vector<u8>>,                   // ≤5, lowercase a-z/0-9/-
        tickers: vector<address>,                   // ≤5 factory-spawned FA addrs
        tips: vector<Tip>,                          // ≤10 atomic transfers
    }

    /// Atomic tip executed during mint creation (paired with MintEvent).
    #[event]
    struct TipExecuted has drop, store {
        from_pid: address,
        to_addr: address,
        token_metadata: address,
        amount: u64,
        mint_seq: u64,
        timestamp_secs: u64,
    }

    // ============ LAZY-INIT — on-demand per-PID storage ============

    /// Lazy-create PidMintMeta + PidMintExtras at PID addr.
    /// Called from entry fns on first-write per PID. Idempotent.
    /// Uses profile::derive_pid_signer friend helper (cycle-safe pattern).
    fun ensure_mint_storage(pid_addr: address) {
        if (!exists<PidMintMeta>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintMeta { next_seq: 0, mint_count: 0 });
        };
        if (!exists<PidMintExtras>(pid_addr)) {
            let pid_signer = profile::derive_pid_signer(pid_addr);
            move_to(&pid_signer, PidMintExtras { extras: smart_table::new() });
        };
    }

    // ============ CREATE MINT — main entry ============

    /// Atomic mint creation with all optional extensions.
    /// Mode determined by parent_mint_id + quote_mint_id (caller passes None for unused).
    ///
    /// Tips (if any): each tip transfers from author's primary store to recipient
    /// in same tx. Tx aborts if any tip lacks balance — atomic all-or-nothing.
    public entry fun create_mint(
        author: &signer,
        content_kind: u8,
        content_text: vector<u8>,
        // Media (optional, packed as 4 args; caller passes empty vec for unused)
        media_kind: u8,                             // 0 = no media, else MEDIA_KIND_*
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        // Threading (caller passes 0/empty for None)
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        // Engagement vectors
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        // Tips (parallel arrays for Move 1.x compat — vector<Tip> at frontend builds)
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        // desnet::assets attached media (>8KB). When asset_master_set=true, overrides
        // media_* args: media auto-built with kind=Ref, backend=BACKEND_DESNET_ASSETS,
        // mime=assets::mime_of(asset_master_addr), ref_blob_id=bcs(asset_master_addr).
        asset_master_addr: address,
        asset_master_set: bool,
    ) acquires PidMintMeta {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // ============ Validate content + media ============

        assert!(vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES, E_CONTENT_TOO_LONG);

        let media: Option<MintMedia> = if (asset_master_set) {
            // desnet::assets path — Master must be sealed (immutable). MIME read from Master.
            assert!(assets::is_sealed(asset_master_addr), E_ASSET_NOT_SEALED);
            let asset_mime = assets::mime_of(asset_master_addr);
            assert_valid_mime(asset_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: asset_mime,
                inline_data: vector::empty(),
                ref_backend: BACKEND_DESNET_ASSETS,
                ref_blob_id: bcs::to_bytes(&asset_master_addr),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == 0) {
            option::none()
        } else if (media_kind == MEDIA_KIND_INLINE) {
            assert!(vector::length(&media_inline_data) <= MEDIA_INLINE_MAX_BYTES, E_INLINE_MEDIA_TOO_LARGE);
            assert_valid_mime(media_mime);
            option::some(MintMedia {
                kind: MEDIA_KIND_INLINE,
                mime: media_mime,
                inline_data: media_inline_data,
                ref_backend: 0,
                ref_blob_id: vector::empty(),
                ref_hash: vector::empty(),
            })
        } else if (media_kind == MEDIA_KIND_REF) {
            assert_valid_mime(media_mime);
            assert_valid_backend(media_ref_backend);
            option::some(MintMedia {
                kind: MEDIA_KIND_REF,
                mime: media_mime,
                inline_data: vector::empty(),
                ref_backend: media_ref_backend,
                ref_blob_id: media_ref_blob_id,
                ref_hash: media_ref_hash,
            })
        } else {
            abort E_INVALID_MIME
        };

        // ============ Validate threading ============

        assert!(!(parent_set && quote_set), E_BOTH_PARENT_AND_QUOTE);

        let parent_mint_id: Option<MintId> = if (parent_set) {
            option::some(MintId { author: parent_author, seq: parent_seq })
        } else {
            option::none()
        };

        let quote_mint_id: Option<MintId> = if (quote_set) {
            option::some(MintId { author: quote_author, seq: quote_seq })
        } else {
            option::none()
        };

        // root_mint_id: derive via parent's root if Voice, else None for Mint/Remix
        let root_mint_id: Option<MintId> = option::none();
        // PRODUCTION: query parent's MintEvent root (or compute via indexer hint)

        // ============ Validate vectors ============

        assert!(vector::length(&mentions) <= MENTIONS_MAX, E_TOO_MANY_MENTIONS);
        // Mentions = flexible (no Profile-existence assert; indexer differentiates)

        validate_tags(&tags);
        validate_tickers(&tickers);

        let tips_len = vector::length(&tip_recipients);
        assert!(tips_len == vector::length(&tip_tokens), E_TOO_MANY_TIPS);
        assert!(tips_len == vector::length(&tip_amounts), E_TOO_MANY_TIPS);
        assert!(tips_len <= TIPS_MAX, E_TOO_MANY_TIPS);

        // ============ Allocate seq + execute tips ============

        let meta = borrow_global_mut<PidMintMeta>(author_pid);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.mint_count = meta.mint_count + 1;

        // Execute tips atomically — abort whole mint if any fails
        let tips_vec = execute_tips(author, &tip_recipients, &tip_tokens, &tip_amounts, seq);

        // ============ Build canonical MintEvent + write to history ============

        let now_secs = timestamp::now_seconds();
        let event_record = MintEvent {
            author: author_pid,
            seq,
            timestamp_us: now_secs * 1_000_000,    // microseconds (frontend convention)
            content_kind,
            content_text,
            media,
            parent_mint_id,
            root_mint_id,
            quote_mint_id,
            mentions,
            tags,
            tickers,
            tips: tips_vec,
        };

        // Verb dispatch: Mint=0 (no parent/quote), Voice=2 (parent_set), Remix=4 (quote_set).
        // parent_set + quote_set are mutually exclusive (asserted earlier).
        let verb = if (parent_set) {
            history::verb_voice()
        } else if (quote_set) {
            history::verb_remix()
        } else {
            history::verb_mint()
        };

        let target = if (parent_set) {
            option::some(parent_author)
        } else if (quote_set) {
            option::some(quote_author)
        } else {
            option::none<address>()
        };

        let asset_ref = if (asset_master_set) {
            option::some(asset_master_addr)
        } else {
            option::none<address>()
        };

        let payload = bcs::to_bytes(&event_record);
        history::append(
            author_pid,
            history::new_entry(verb, now_secs, target, payload, asset_ref),
        );
    }

    // ============ INTERNAL — tip execution ============

    fun execute_tips(
        author: &signer,
        recipients: &vector<address>,
        tokens: &vector<address>,
        amounts: &vector<u64>,
        seq: u64,
    ): vector<Tip> {
        let tips = vector::empty<Tip>();
        let n = vector::length(recipients);
        let i = 0;
        while (i < n) {
            let recipient = *vector::borrow(recipients, i);
            let token_addr = *vector::borrow(tokens, i);
            let amount = *vector::borrow(amounts, i);

            // Withdraw FA from author's primary store + deposit to recipient
            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let fa_in = primary_fungible_store::withdraw(author, token_metadata, amount);
            primary_fungible_store::deposit(recipient, fa_in);

            event::emit(TipExecuted {
                from_pid: profile::derive_pid_address(signer::address_of(author)),
                to_addr: recipient,
                token_metadata: token_addr,
                amount,
                mint_seq: seq,
                timestamp_secs: timestamp::now_seconds(),
            });

            vector::push_back(&mut tips, Tip {
                recipient,
                token_metadata: token_addr,
                amount,
            });

            i = i + 1;
        };
        tips
    }

    // ============ INTERNAL — validators ============

    fun validate_tags(tags: &vector<vector<u8>>) {
        assert!(vector::length(tags) <= TAGS_MAX, E_TOO_MANY_TAGS);
        let i = 0;
        let n = vector::length(tags);
        while (i < n) {
            let t = vector::borrow(tags, i);
            let len = vector::length(t);
            assert!(len >= TAG_MIN_BYTES, E_TAG_TOO_SHORT);
            assert!(len <= TAG_MAX_BYTES, E_TAG_TOO_LONG);

            let j = 0;
            while (j < len) {
                let ch = *vector::borrow(t, j);
                let ok = (ch >= 0x61 && ch <= 0x7A)
                      || (ch >= 0x30 && ch <= 0x39)
                      || (ch == 0x2D);
                assert!(ok, E_TAG_INVALID_CHAR);
                j = j + 1;
            };
            i = i + 1;
        };
    }

    /// Tickers must be factory-spawned FAs (DeSNet ticker spec lock 2026-05-01).
    /// Calls factory::is_factory_token view fn for each addr.
    fun validate_tickers(tickers: &vector<address>) {
        assert!(vector::length(tickers) <= TICKERS_MAX, E_TOO_MANY_TICKERS);
        let i = 0;
        let n = vector::length(tickers);
        while (i < n) {
            let addr = *vector::borrow(tickers, i);
            assert!(factory::is_factory_token(addr), E_TICKER_NOT_FACTORY_TOKEN);
            i = i + 1;
        };
    }

    fun assert_valid_mime(mime: u8) {
        assert!(
            mime == MIME_PNG || mime == MIME_JPEG || mime == MIME_GIF
                || mime == MIME_WEBP || mime == MIME_SVG,
            E_INVALID_MIME
        );
    }

    fun assert_valid_backend(backend: u8) {
        assert!(
            backend == BACKEND_SHELBY || backend == BACKEND_WALRUS
                || backend == BACKEND_IPFS || backend == BACKEND_DESNET_ASSETS,
            E_INVALID_BACKEND
        );
    }

    // ============ MINT-LEVEL GATE ATTACHMENT ============

    /// Attach ReferenceGate to a specific mint. Gates Voice/Spark/Echo/Remix/Press
    /// of this mint. Immutable post-attach.
    /// Args flattened to primitives — Supra entry fns can't take struct params.
    public entry fun attach_mint_gate(
        author: &signer,
        seq: u64,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires PidMintMeta, PidMintExtras {
        let author_addr = signer::address_of(author);
        let author_pid = profile::derive_pid_address(author_addr);
        profile::assert_pid_exists(author_pid);
        ensure_mint_storage(author_pid);

        // Validate seq corresponds to a real mint by author
        assert!(seq < next_seq(author_pid), E_MINT_NOT_FOUND);

        let gate = reference_gate::new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
        let extras_store = borrow_global_mut<PidMintExtras>(author_pid);
        if (smart_table::contains(&extras_store.extras, seq)) {
            let entry = smart_table::borrow_mut(&mut extras_store.extras, seq);
            entry.gate = option::some(gate);
        } else {
            smart_table::add(&mut extras_store.extras, seq, MintExtras {
                gate: option::some(gate),
            });
        };
    }

    // ============ INTERNAL — gate evaluation for friend modules ============

    /// Friend access for pulse/press/giveaway to check mint-level gate before
    /// allowing engagement.
    public(friend) fun get_mint_gate(author_pid: address, seq: u64): Option<ReferenceGate>
        acquires PidMintExtras
    {
        if (!exists<PidMintExtras>(author_pid)) return option::none();
        let extras_store = borrow_global<PidMintExtras>(author_pid);
        if (!smart_table::contains(&extras_store.extras, seq)) return option::none();
        smart_table::borrow(&extras_store.extras, seq).gate
    }

    // ============ VIEWS ============

    #[view]
    public fun mint_count(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).mint_count
    }

    #[view]
    public fun next_seq(pid_addr: address): u64 acquires PidMintMeta {
        if (!exists<PidMintMeta>(pid_addr)) return 0;
        borrow_global<PidMintMeta>(pid_addr).next_seq
    }

    #[view]
    public fun content_text_max_bytes(): u64 { CONTENT_TEXT_MAX_BYTES }

    #[view]
    public fun media_inline_max_bytes(): u64 { MEDIA_INLINE_MAX_BYTES }

    #[view]
    public fun mentions_max(): u64 { MENTIONS_MAX }

    #[view]
    public fun tags_max(): u64 { TAGS_MAX }

    #[view]
    public fun tickers_max(): u64 { TICKERS_MAX }

    #[view]
    public fun tips_max(): u64 { TIPS_MAX }

    // ============ TESTS ============

    #[test]
    fun test_assert_valid_mime_accepts_five() {
        assert_valid_mime(MIME_PNG);
        assert_valid_mime(MIME_JPEG);
        assert_valid_mime(MIME_GIF);
        assert_valid_mime(MIME_WEBP);
        assert_valid_mime(MIME_SVG);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_MIME, location = Self)]
    fun test_assert_valid_mime_rejects_zero() {
        assert_valid_mime(0);
    }

    #[test]
    fun test_assert_valid_backend_accepts_all_four() {
        assert_valid_backend(BACKEND_SHELBY);
        assert_valid_backend(BACKEND_WALRUS);
        assert_valid_backend(BACKEND_IPFS);
        assert_valid_backend(BACKEND_DESNET_ASSETS);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_BACKEND, location = Self)]
    fun test_assert_valid_backend_rejects_unknown() {
        assert_valid_backend(99);
    }

    #[test]
    fun test_validate_tags_accept_valid() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"defi");
        vector::push_back(&mut tags, b"supra-move");
        vector::push_back(&mut tags, b"web3-2026");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_INVALID_CHAR, location = Self)]
    fun test_validate_tags_reject_uppercase() {
        let tags = vector::empty<vector<u8>>();
        vector::push_back(&mut tags, b"DeFi");
        validate_tags(&tags);
    }

    #[test]
    #[expected_failure(abort_code = E_TAG_TOO_LONG, location = Self)]
    fun test_validate_tags_reject_too_long() {
        let tags = vector::empty<vector<u8>>();
        // 33 bytes (cap = 32)
        vector::push_back(&mut tags, b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        validate_tags(&tags);
    }
}
