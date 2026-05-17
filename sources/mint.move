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
    use desnet::profile::ReferenceGate;
    use desnet::reference_gate;
    use desnet::history;
    use desnet::assets;
    use desnet::factory;
    use desnet::opinion;

    friend desnet::pulse;
    friend desnet::press;
    friend desnet::giveaway;

    const CONTENT_TEXT_MAX_BYTES: u64 = 333;
    const MEDIA_INLINE_MAX_BYTES: u64 = 8192;
    const MENTIONS_MAX: u64 = 10;
    const TAGS_MAX: u64 = 5;
    const TAG_MAX_BYTES: u64 = 32;
    const TAG_MIN_BYTES: u64 = 1;
    const TICKERS_MAX: u64 = 5;
    const TIPS_MAX: u64 = 10;

    const MEDIA_KIND_INLINE: u8 = 1;
    const MEDIA_KIND_REF: u8 = 2;

    const MIME_PNG: u8 = 1;
    const MIME_JPEG: u8 = 2;
    const MIME_GIF: u8 = 3;
    const MIME_WEBP: u8 = 4;
    const MIME_SVG: u8 = 5;

    const BACKEND_SHELBY: u8 = 0;
    const BACKEND_WALRUS: u8 = 1;
    const BACKEND_IPFS: u8 = 2;
    const BACKEND_DESNET_ASSETS: u8 = 3;

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

    struct PidMintMeta has key {
        next_seq: u64,
        mint_count: u64,
    }

    struct PidMintExtras has key {
        extras: SmartTable<u64, MintExtras>,
    }

    struct MintExtras has store {
        gate: Option<ReferenceGate>,
    }

    struct MintId has copy, drop, store {
        author: address,
        seq: u64,
    }

    struct MintMedia has copy, drop, store {
        kind: u8,
        mime: u8,
        inline_data: vector<u8>,
        ref_backend: u8,
        ref_blob_id: vector<u8>,
        ref_hash: vector<u8>,
    }

    struct Tip has copy, drop, store {
        recipient: address,
        token_metadata: address,
        amount: u64,
    }

    struct MintEvent has drop, store {
        author: address,
        seq: u64,
        timestamp_us: u64,
        content_kind: u8,
        content_text: vector<u8>,
        media: Option<MintMedia>,
        parent_mint_id: Option<MintId>,
        root_mint_id: Option<MintId>,
        quote_mint_id: Option<MintId>,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tips: vector<Tip>,
    }

    #[event]
    struct TipExecuted has drop, store {
        from_pid: address,
        to_addr: address,
        token_metadata: address,
        amount: u64,
        mint_seq: u64,
        timestamp_secs: u64,
    }

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

    public entry fun create_mint(
        author: &signer,
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
    ) acquires PidMintMeta {
        let _ = do_create_mint(
            author, author_pid, content_kind, content_text,
            media_kind, media_mime, media_inline_data,
            media_ref_backend, media_ref_blob_id, media_ref_hash,
            parent_author, parent_seq, parent_set,
            quote_author, quote_seq, quote_set,
            mentions, tags, tickers,
            tip_recipients, tip_tokens, tip_amounts,
            asset_master_addr, asset_master_set,
        );
    }

    public entry fun create_opinion_mint(
        author: &signer,
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
        opinion_initial_mc: u64,
    ) acquires PidMintMeta {
        let seq = do_create_mint(
            author, author_pid, content_kind, content_text,
            media_kind, media_mime, media_inline_data,
            media_ref_backend, media_ref_blob_id, media_ref_hash,
            parent_author, parent_seq, parent_set,
            quote_author, quote_seq, quote_set,
            mentions, tags, tickers,
            tip_recipients, tip_tokens, tip_amounts,
            asset_master_addr, asset_master_set,
        );
        opinion::bootstrap_market_for_mint(author, author_pid, seq, opinion_initial_mc);
    }

    fun do_create_mint(
        author: &signer,
        author_pid: address,
        content_kind: u8,
        content_text: vector<u8>,
        media_kind: u8,
        media_mime: u8,
        media_inline_data: vector<u8>,
        media_ref_backend: u8,
        media_ref_blob_id: vector<u8>,
        media_ref_hash: vector<u8>,
        parent_author: address,
        parent_seq: u64,
        parent_set: bool,
        quote_author: address,
        quote_seq: u64,
        quote_set: bool,
        mentions: vector<address>,
        tags: vector<vector<u8>>,
        tickers: vector<address>,
        tip_recipients: vector<address>,
        tip_tokens: vector<address>,
        tip_amounts: vector<u64>,
        asset_master_addr: address,
        asset_master_set: bool,
    ): u64 acquires PidMintMeta {
        profile::assert_authorized(author, author_pid);
        ensure_mint_storage(author_pid);

        assert!(vector::length(&content_text) <= CONTENT_TEXT_MAX_BYTES, E_CONTENT_TOO_LONG);

        let media: Option<MintMedia> = if (asset_master_set) {
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

        let root_mint_id: Option<MintId> = option::none();

        assert!(vector::length(&mentions) <= MENTIONS_MAX, E_TOO_MANY_MENTIONS);

        validate_tags(&tags);
        validate_tickers(&tickers);

        let tips_len = vector::length(&tip_recipients);
        assert!(tips_len == vector::length(&tip_tokens), E_TOO_MANY_TIPS);
        assert!(tips_len == vector::length(&tip_amounts), E_TOO_MANY_TIPS);
        assert!(tips_len <= TIPS_MAX, E_TOO_MANY_TIPS);

        let meta = borrow_global_mut<PidMintMeta>(author_pid);
        let seq = meta.next_seq;
        meta.next_seq = seq + 1;
        meta.mint_count = meta.mint_count + 1;

        let tips_vec = execute_tips(author, author_pid, &tip_recipients, &tip_tokens, &tip_amounts, seq);

        let now_secs = timestamp::now_seconds();
        let event_record = MintEvent {
            author: author_pid,
            seq,
            timestamp_us: now_secs * 1_000_000,
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

        seq
    }

    fun execute_tips(
        author: &signer,
        author_pid: address,
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

            let token_metadata = object::address_to_object<Metadata>(token_addr);
            let fa_in = primary_fungible_store::withdraw(author, token_metadata, amount);
            primary_fungible_store::deposit(recipient, fa_in);

            event::emit(TipExecuted {
                from_pid: author_pid,
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

    public entry fun attach_mint_gate(
        author: &signer,
        author_pid: address,
        seq: u64,
        target_pid: address,
        min_token_balance: u64,
        max_token_balance: u64,
        min_lp_stake: u64,
    ) acquires PidMintMeta, PidMintExtras {
        profile::assert_authorized(author, author_pid);
        ensure_mint_storage(author_pid);

        assert!(seq < next_seq(author_pid), E_MINT_NOT_FOUND);

        let gate = profile::reference_gate_new(target_pid, min_token_balance, max_token_balance, min_lp_stake);
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

    public(friend) fun get_mint_gate(author_pid: address, seq: u64): Option<ReferenceGate>
        acquires PidMintExtras
    {
        if (!exists<PidMintExtras>(author_pid)) return option::none();
        let extras_store = borrow_global<PidMintExtras>(author_pid);
        if (!smart_table::contains(&extras_store.extras, seq)) return option::none();
        smart_table::borrow(&extras_store.extras, seq).gate
    }

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
        vector::push_back(&mut tags, b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        validate_tags(&tags);
    }
}
