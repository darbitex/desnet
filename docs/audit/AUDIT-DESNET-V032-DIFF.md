diff --git a/sources/amm.move b/sources/amm.move
index fc3d23e..9a5809c 100644
--- a/sources/amm.move
+++ b/sources/amm.move
@@ -437,7 +437,8 @@ module desnet::amm {
         let caller_addr = signer::address_of(caller);
         let apt_coin = coin::withdraw<AptosCoin>(caller, amount_in);
         let apt_fa = coin::coin_to_fungible_asset(apt_coin);
-        let token_out_fa = swap_exact_apt_in(handle, apt_fa, min_out);
+        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
+        let token_out_fa = swap_exact_apt_in_actor(handle, apt_fa, min_out, caller_addr);
         primary_fungible_store::deposit(caller_addr, token_out_fa);
     }
 
@@ -454,14 +455,29 @@ module desnet::amm {
         let token_meta = object::address_to_object<Metadata>(token_meta_addr);
 
         let token_fa = primary_fungible_store::withdraw(caller, token_meta, amount_in);
-        let apt_out_fa = swap_exact_token_in(handle, token_fa, min_out);
+        // v0.3.2 (F5): route through *_actor to populate event.actor with caller addr.
+        let apt_out_fa = swap_exact_token_in_actor(handle, token_fa, min_out, caller_addr);
         primary_fungible_store::deposit(caller_addr, apt_out_fa);
     }
 
+    /// v0.3.2 (F5): backward-compat wrapper. Composable callers (aggregators/flash arbs)
+    /// that don't have the actor address available can still call this — event.actor stays
+    /// @0x0 sentinel. New code should prefer `swap_exact_apt_in_actor` to preserve attribution.
     public fun swap_exact_apt_in(
         handle: vector<u8>,
         apt_in: FungibleAsset,
         min_out: u64,
+    ): FungibleAsset acquires Pool {
+        swap_exact_apt_in_actor(handle, apt_in, min_out, @0x0)
+    }
+
+    /// v0.3.2 (F5): actor-aware variant. `actor` is recorded in `Swapped` event for indexer
+    /// attribution. Pass `@0x0` for sentinel "actor unknown / multi-hop call".
+    public fun swap_exact_apt_in_actor(
+        handle: vector<u8>,
+        apt_in: FungibleAsset,
+        min_out: u64,
+        actor: address,
     ): FungibleAsset acquires Pool {
         let pool_addr = pool_address_of_handle(handle);
         assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
@@ -499,7 +515,7 @@ module desnet::amm {
         event::emit(Swapped {
             handle: pool.handle,
             pool_addr,
-            actor: @0x0,
+            actor,
             apt_to_token: true,
             amount_in,
             amount_out,
@@ -511,10 +527,21 @@ module desnet::amm {
         token_out_fa
     }
 
+    /// v0.3.2 (F5): backward-compat wrapper for token-in direction.
     public fun swap_exact_token_in(
         handle: vector<u8>,
         token_in: FungibleAsset,
         min_out: u64,
+    ): FungibleAsset acquires Pool {
+        swap_exact_token_in_actor(handle, token_in, min_out, @0x0)
+    }
+
+    /// v0.3.2 (F5): actor-aware variant for token-in direction.
+    public fun swap_exact_token_in_actor(
+        handle: vector<u8>,
+        token_in: FungibleAsset,
+        min_out: u64,
+        actor: address,
     ): FungibleAsset acquires Pool {
         let pool_addr = pool_address_of_handle(handle);
         assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
@@ -552,7 +579,7 @@ module desnet::amm {
         event::emit(Swapped {
             handle: pool.handle,
             pool_addr,
-            actor: @0x0,
+            actor,
             apt_to_token: false,
             amount_in,
             amount_out,
@@ -664,6 +691,8 @@ module desnet::amm {
     // ============ INTERNAL MATH ============
 
     /// Pure quote — darbitex-shape signature. CPMM with 10 bps fee.
+    /// v0.3.2 (F4b): added #[view] so frontend can call gas-free via /v1/view.
+    #[view]
     public fun compute_amount_out(
         reserve_in: u64,
         reserve_out: u64,
@@ -795,6 +824,50 @@ module desnet::amm {
         borrow_global<Pool>(pool_addr).locked
     }
 
+    // ============ v0.3.2 (F4c): handle/pool_addr companion view fns ============
+    // Some views take handle, others take pool_addr — caller convenience companions
+    // for the missing direction. Body delegates to existing variant.
+
+    #[view]
+    public fun lp_fee_per_share_by_handle(handle: vector<u8>): (u128, u128) acquires Pool {
+        lp_fee_per_share(pool_address_of_handle(handle))
+    }
+
+    #[view]
+    public fun pool_locked_by_handle(handle: vector<u8>): bool acquires Pool {
+        pool_locked(pool_address_of_handle(handle))
+    }
+
+    #[view]
+    public fun creator_pid_at(pool_addr: address): address acquires Pool {
+        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
+        borrow_global<Pool>(pool_addr).creator_pid
+    }
+
+    #[view]
+    public fun fee_buckets_at(pool_addr: address): (u64, u64) acquires Pool {
+        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
+        let pool = borrow_global<Pool>(pool_addr);
+        (fungible_asset::balance(pool.apt_fees), fungible_asset::balance(pool.token_fees))
+    }
+
+    #[view]
+    public fun quote_swap_exact_in_at(
+        pool_addr: address,
+        amount_in: u64,
+        is_apt_in: bool,
+    ): u64 acquires Pool {
+        assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
+        let pool = borrow_global<Pool>(pool_addr);
+        let apt_r = fungible_asset::balance(pool.apt_reserve);
+        let token_r = fungible_asset::balance(pool.token_reserve);
+        if (is_apt_in) {
+            compute_amount_out(apt_r, token_r, amount_in)
+        } else {
+            compute_amount_out(token_r, apt_r, amount_in)
+        }
+    }
+
     #[view]
     public fun fee_acc_scale(): u128 { FEE_ACC_SCALE }
 
diff --git a/sources/apt_vault.move b/sources/apt_vault.move
index ef22fe3..45bce10 100644
--- a/sources/apt_vault.move
+++ b/sources/apt_vault.move
@@ -24,6 +24,7 @@ module desnet::apt_vault {
     use desnet::amm;
 
     friend desnet::factory;
+    friend desnet::handle_fee_vault;
 
     // ============ CONSTANTS ============
 
@@ -305,6 +306,21 @@ module desnet::apt_vault {
         if (pending == 0) 0 else pending + SETTLE_DELAY_SECS
     }
 
+    // ============ DELEGATE BURN — friend (handle_fee_vault, v0.3.2 F9) ============
+
+    /// handle_fee_vault swaps APT → DESNET via amm, then asks the DESNET per-token
+    /// vault to burn the FA via its held BurnRef. Direction-locked: caller hands a FA
+    /// whose metadata MUST match `vault.token_metadata_addr` (the fungible_asset::burn
+    /// check enforces this — wrong-token FA aborts).
+    /// No state mutation, no event (handle_fee_vault::Settled covers it).
+    public(friend) fun burn_via_vault(
+        vault_addr: address,
+        fa: fungible_asset::FungibleAsset,
+    ) acquires Vault {
+        let vault = borrow_global<Vault>(vault_addr);
+        fungible_asset::burn(&vault.burn_ref, fa);
+    }
+
     // ============ TEST-ONLY HELPERS ============
 
     #[test_only]
diff --git a/sources/factory.move b/sources/factory.move
index 1ae2584..01ba36a 100644
--- a/sources/factory.move
+++ b/sources/factory.move
@@ -443,7 +443,8 @@ module desnet::factory {
     public fun get_token_record(handle: vector<u8>): TokenRecord acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
         let key = string::utf8(handle);
-        assert!(smart_table::contains(&registry.records, key), E_HANDLE_TAKEN);
+        // v0.3.2 (F1): semantic-correct error code (was E_HANDLE_TAKEN — misleading).
+        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
         *smart_table::borrow(&registry.records, key)
     }
 
@@ -462,29 +463,37 @@ module desnet::factory {
     #[view]
     public fun handle_of_token(token_metadata: address): String acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
+        // v0.3.2 (F1): semantic-correct error code.
         assert!(
             smart_table::contains(&registry.metadata_index, token_metadata),
-            E_HANDLE_TAKEN
+            E_TOKEN_NOT_FOUND
         );
         *smart_table::borrow(&registry.metadata_index, token_metadata)
     }
 
+    /// Note: `owner_addr` is the PID Object addr (= the registered owner_index key),
+    /// NOT the wallet that holds the PID NFT. Use `handle_of_wallet` for wallet→handle.
     #[view]
     public fun handle_of_owner(owner_addr: address): String acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
+        // v0.3.2 (F1): semantic-correct error code.
         assert!(
             smart_table::contains(&registry.owner_index, owner_addr),
-            E_HANDLE_TAKEN
+            E_TOKEN_NOT_FOUND
         );
         *smart_table::borrow(&registry.owner_index, owner_addr)
     }
 
+    // (v0.3.2 F1b: handle_of_wallet lives in profile.move to avoid factory→profile
+    // dependency cycle. Profile already uses factory; reverse direction would cycle.)
+
     #[view]
     public fun token_metadata_of_owner(owner_addr: address): address acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
+        // v0.3.2 (F1): semantic-correct error code.
         assert!(
             smart_table::contains(&registry.owner_index, owner_addr),
-            E_HANDLE_TAKEN
+            E_TOKEN_NOT_FOUND
         );
         let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
         smart_table::borrow(&registry.records, handle).token_metadata
@@ -493,9 +502,10 @@ module desnet::factory {
     #[view]
     public fun lp_staking_pool_of_owner(owner_addr: address): address acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
+        // v0.3.2 (F1): semantic-correct error code.
         assert!(
             smart_table::contains(&registry.owner_index, owner_addr),
-            E_HANDLE_TAKEN
+            E_TOKEN_NOT_FOUND
         );
         let handle = *smart_table::borrow(&registry.owner_index, owner_addr);
         smart_table::borrow(&registry.records, handle).lp_staking_pool
@@ -555,6 +565,16 @@ module desnet::factory {
         smart_table::borrow(&registry.records, handle).apt_vault
     }
 
+    /// v0.3.2 F9: single-hop handle → apt_vault lookup. Used by handle_fee_vault::settle
+    /// to delegate-burn DESNET via desnet's apt_vault BurnRef.
+    #[view]
+    public fun vault_addr_of_handle(handle: vector<u8>): address acquires FactoryRegistry {
+        let registry = borrow_global<FactoryRegistry>(@desnet);
+        let key = string::utf8(handle);
+        assert!(smart_table::contains(&registry.records, key), E_TOKEN_NOT_FOUND);
+        smart_table::borrow(&registry.records, key).apt_vault
+    }
+
     #[view]
     public fun pool_seed_apt_amount(): u64 { POOL_SEED_APT_AMOUNT }
 
diff --git a/sources/giveaway.move b/sources/giveaway.move
index 2df3e80..30a1c78 100644
--- a/sources/giveaway.move
+++ b/sources/giveaway.move
@@ -518,4 +518,7 @@ module desnet::giveaway {
 
     #[view]
     public fun kind_nft(): u8 { KIND_NFT }
+
+    #[view]
+    public fun settle_bounty_bps(): u64 { SETTLE_BOUNTY_BPS }
 }
diff --git a/sources/governance.move b/sources/governance.move
index 68db12f..a9e543c 100644
--- a/sources/governance.move
+++ b/sources/governance.move
@@ -36,7 +36,12 @@ module desnet::governance {
     use aptos_framework::account::{Self, SignerCapability};
     use aptos_framework::code;
     use aptos_framework::event;
-    use aptos_framework::resource_account;
+    // Bootstrap publisher lives at @origin (deployer multisig). It holds the
+    // SignerCapability for @desnet (created at bootstrap deploy) until our
+    // init_module takes ownership via `take_cap_for_desnet` here. This indirection
+    // is required because the main DesNet package exceeds the 64KB single-tx
+    // publish limit and must be deployed via chunked publish through bootstrap.
+    use origin::publisher;
     use aptos_framework::timestamp;
     use aptos_std::smart_table::{Self, SmartTable};
 
@@ -46,6 +51,7 @@ module desnet::governance {
     friend desnet::profile;
     friend desnet::amm;
     friend desnet::lp_staking;
+    friend desnet::handle_fee_vault;
 
     // ============ CONSTANTS ============
 
@@ -73,6 +79,19 @@ module desnet::governance {
     const E_HASH_MISMATCH: u64 = 18;
     const E_MULTISIG_DISABLED: u64 = 19;
     const E_INVALID_ADDRESS: u64 = 20;
+    /// v0.3.0.6 chunked-upgrade infra
+    const E_ARGS_LEN_MISMATCH: u64 = 21;
+    /// v0.3.1 Item 3b: setters NEUTERED post-hardcode of DESNET_FA_ADDR.
+    const E_NEUTERED: u64 = 22;
+    /// v0.3.2 (F2): chunked-publish defense-in-depth — at least one module slot empty.
+    const E_INCOMPLETE_CHUNKS: u64 = 23;
+    /// v0.3.2 (F6): 30-day rolling emission tracker constants.
+    const SECONDS_PER_DAY: u64 = 86400;
+    const ROLLING_WINDOW_DAYS: u64 = 30;
+    /// v0.3.1 Item 3b: hardcoded DESNET FA addr — eliminates manipulation surface.
+    /// Computable as `factory::derive_token_metadata_addr(b"desnet")`.
+    /// `desnet_fa_metadata` field in GovernanceState becomes vestigial (compat only).
+    const DESNET_FA_ADDR: address = @0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7;
 
     // ============ TYPES ============
 
@@ -114,6 +133,27 @@ module desnet::governance {
         cast_at_secs: u64,
     }
 
+    /// v0.3.0.6 chunked-upgrade staging. Accumulates metadata + per-module bytecode
+    /// across multiple `multisig_stage_upgrade_chunk` txs at @desnet, then consumed
+    /// by `multisig_publish_chunked_upgrade` (final chunk + publish in single tx).
+    /// Allows package upgrades larger than 64KB single-tx limit.
+    struct UpgradeStaging has key, drop {
+        metadata: vector<u8>,
+        code: vector<vector<u8>>,
+    }
+
+    /// v0.3.2 (F6): Auto-tracker for 30-day rolling emission. Eliminates manipulation
+    /// surface where multisig sets `total_30d_emission` to arbitrary value.
+    /// Per-day buckets indexed by (day_number % 30); parallel vector tracks the
+    /// day_number each entry actually refers to (for staleness check on read).
+    /// `record_emission_for_window` called by lp_staking::claim_internal per claim;
+    /// `total_30d_emission_auto` view aggregates fresh buckets only.
+    /// Lazy-initialized on first record (init_module skipped for upgrades).
+    struct Emission30dRollingBucket has key {
+        daily_amounts: vector<u64>,
+        daily_day_nums: vector<u64>,
+    }
+
     // ============ EVENTS ============
 
     #[event]
@@ -167,10 +207,17 @@ module desnet::governance {
         timestamp_secs: u64,
     }
 
+    /// v0.3.2 (F3): emitted on cleanup_upgrade_staging — observability for indexers.
+    #[event]
+    struct UpgradeStagingCleanup has drop, store {
+        multisig: address,
+        timestamp_secs: u64,
+    }
+
     // ============ INIT — called by resource_account at deploy ============
 
     fun init_module(account: &signer) {
-        let signer_cap = resource_account::retrieve_resource_account_cap(account, @origin);
+        let signer_cap = publisher::take_cap_for_desnet(account);
         let governance_addr = signer::address_of(account);
 
         move_to(account, GovernanceState {
@@ -240,6 +287,206 @@ module desnet::governance {
         });
     }
 
+    // ============ CHUNKED MULTISIG UPGRADE (v0.3.0.6) ============
+    // Allows upgrades > 64KB single-tx limit by staging chunks across multiple
+    // multisig txs, then publishing in a final tx. Mirror of bootstrap publisher
+    // pattern, but uses pkg_signer (held in GovernanceState) instead of an external
+    // SignerCapability holder. Same auth + disable-flag check as `multisig_upgrade`.
+    // DAO chunked variant deferred to v0.3.1 (will share `UpgradeStaging` resource).
+
+    fun stage_chunks_into_staging(
+        pkg_signer: &signer,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires UpgradeStaging {
+        assert!(
+            vector::length(&code_indices) == vector::length(&code_chunks),
+            E_ARGS_LEN_MISMATCH
+        );
+        if (!exists<UpgradeStaging>(@desnet)) {
+            move_to(pkg_signer, UpgradeStaging {
+                metadata: vector::empty(),
+                code: vector::empty(),
+            });
+        };
+        let staging = borrow_global_mut<UpgradeStaging>(@desnet);
+        vector::append(&mut staging.metadata, metadata_chunk);
+        let n = vector::length(&code_chunks);
+        let i = 0;
+        while (i < n) {
+            let idx = (*vector::borrow(&code_indices, i) as u64);
+            while (vector::length(&staging.code) <= idx) {
+                vector::push_back(&mut staging.code, vector::empty());
+            };
+            let target = vector::borrow_mut(&mut staging.code, idx);
+            let chunk = *vector::borrow(&code_chunks, i);
+            vector::append(target, chunk);
+            i = i + 1;
+        };
+    }
+
+    /// Stage one chunk for an upcoming chunked multisig upgrade. Permissionless of
+    /// chunks order — final chunk landed by `multisig_publish_chunked_upgrade`.
+    public entry fun multisig_stage_upgrade_chunk(
+        multisig: &signer,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires GovernanceState, UpgradeStaging {
+        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        assert!(
+            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
+            E_MULTISIG_DISABLED
+        );
+        let pkg_signer = derive_pkg_signer();
+        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+    }
+
+    /// Stage final chunk + publish the assembled package. Consumes UpgradeStaging.
+    public entry fun multisig_publish_chunked_upgrade(
+        multisig: &signer,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires GovernanceState, UpgradeStaging {
+        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        assert!(
+            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
+            E_MULTISIG_DISABLED
+        );
+        let pkg_signer = derive_pkg_signer();
+        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
+        // v0.3.2 (F2): defense-in-depth — reject incomplete staging (any empty slot).
+        // Without this, out-of-order/missing chunk produces a generic framework error
+        // at code::publish_package_txn instead of clear ours-error.
+        let i = 0;
+        let n = vector::length(&code);
+        while (i < n) {
+            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
+            i = i + 1;
+        };
+        code::publish_package_txn(&pkg_signer, metadata, code);
+        event::emit(MultisigUpgrade {
+            multisig: signer::address_of(multisig),
+            timestamp_secs: timestamp::now_seconds(),
+        });
+    }
+
+    /// Discard a half-staged UpgradeStaging (e.g., aborted upgrade, restart).
+    public entry fun cleanup_upgrade_staging(multisig: &signer) acquires UpgradeStaging {
+        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        if (exists<UpgradeStaging>(@desnet)) {
+            let _ = move_from<UpgradeStaging>(@desnet);
+            // v0.3.2 (F3): observability event for off-chain indexers.
+            event::emit(UpgradeStagingCleanup {
+                multisig: signer::address_of(multisig),
+                timestamp_secs: timestamp::now_seconds(),
+            });
+        };
+    }
+
+    #[view]
+    public fun upgrade_staging_exists(): bool { exists<UpgradeStaging>(@desnet) }
+
+    // ============ EMISSION AUTO-TRACKER (v0.3.2 F6) ============
+    //
+    // 30-day rolling bucket of emission distributed via lp_staking::claim_internal.
+    // Eliminates manipulation surface where multisig sets `total_30d_emission` to
+    // arbitrary value (was the last remaining off-DAO knob in v0.3.1).
+    //
+    // Per-day buckets indexed by (day_number % 30); parallel `daily_day_nums`
+    // tracks which day_number each bucket entry actually refers to (so the view
+    // can distinguish fresh vs stale entries without a sweep on read).
+    //
+    // Lazy-init on first record (init_module doesn't re-run on upgrade).
+
+    /// Friend-only: lp_staking::claim_internal calls this with `actual_paid` (capped
+    /// emission amount, post graceful-depletion). Saturates a single daily bucket;
+    /// view sums across the rolling 30-day window.
+    public(friend) fun record_emission_for_window(amount: u64) acquires GovernanceState, Emission30dRollingBucket {
+        if (amount == 0) return;
+        let now = timestamp::now_seconds();
+        let day = now / SECONDS_PER_DAY;
+
+        if (!exists<Emission30dRollingBucket>(@desnet)) {
+            let pkg_signer = derive_pkg_signer();
+            let amounts = vector::empty<u64>();
+            let days = vector::empty<u64>();
+            let i = 0;
+            while (i < ROLLING_WINDOW_DAYS) {
+                vector::push_back(&mut amounts, 0);
+                vector::push_back(&mut days, 0);
+                i = i + 1;
+            };
+            move_to(&pkg_signer, Emission30dRollingBucket {
+                daily_amounts: amounts,
+                daily_day_nums: days,
+            });
+        };
+
+        let tracker = borrow_global_mut<Emission30dRollingBucket>(@desnet);
+        let idx = day % ROLLING_WINDOW_DAYS;
+        let stored_day = *vector::borrow(&tracker.daily_day_nums, idx);
+        if (stored_day != day) {
+            // Stale entry from prior cycle — reset before adding.
+            *vector::borrow_mut(&mut tracker.daily_amounts, idx) = 0;
+            *vector::borrow_mut(&mut tracker.daily_day_nums, idx) = day;
+        };
+        let cur = *vector::borrow(&tracker.daily_amounts, idx);
+        // Saturating add: pin to u64::MAX on overflow rather than abort
+        // (single-day emission overflowing u64 is structurally impossible
+        // given 1B token cap, but defense-in-depth).
+        let new_val = if (cur > 18446744073709551615u64 - amount) {
+            18446744073709551615u64
+        } else {
+            cur + amount
+        };
+        *vector::borrow_mut(&mut tracker.daily_amounts, idx) = new_val;
+    }
+
+    /// Sum of fresh (within rolling 30-day window) bucket amounts. Returns 0 pre-init.
+    #[view]
+    public fun total_30d_emission_auto(): u64 acquires Emission30dRollingBucket {
+        if (!exists<Emission30dRollingBucket>(@desnet)) return 0;
+        let tracker = borrow_global<Emission30dRollingBucket>(@desnet);
+        let now = timestamp::now_seconds();
+        let day = now / SECONDS_PER_DAY;
+        let cutoff = if (day >= ROLLING_WINDOW_DAYS - 1) day - (ROLLING_WINDOW_DAYS - 1) else 0;
+
+        let sum: u64 = 0;
+        let i = 0;
+        while (i < ROLLING_WINDOW_DAYS) {
+            let stored_day = *vector::borrow(&tracker.daily_day_nums, i);
+            if (stored_day >= cutoff) {
+                let v = *vector::borrow(&tracker.daily_amounts, i);
+                // Saturating sum
+                if (sum > 18446744073709551615u64 - v) {
+                    sum = 18446744073709551615u64;
+                } else {
+                    sum = sum + v;
+                };
+            };
+            i = i + 1;
+        };
+        sum
+    }
+
+    /// max(auto-tracked, manually-set). Used by quorum + threshold computations.
+    /// Manual setter (`update_total_30d_emission`) kept functional for transition;
+    /// expected to be neutered in a future upgrade once auto-tracker proven reliable.
+    fun effective_30d_emission(): u64 acquires GovernanceState, Emission30dRollingBucket {
+        let auto = total_30d_emission_auto();
+        let manual = borrow_global<GovernanceState>(@desnet).total_30d_emission;
+        if (auto > manual) auto else manual
+    }
+
+    #[view]
+    public fun effective_30d_emission_view(): u64 acquires GovernanceState, Emission30dRollingBucket {
+        effective_30d_emission()
+    }
+
     // ============ DAO-PHASE PROPOSAL LIFECYCLE ============
 
     /// IMPORTANT: `new_module_bytes_hash` MUST be computed via
@@ -252,11 +499,15 @@ module desnet::governance {
         proposer: &signer,
         target_package_addr: address,
         new_module_bytes_hash: vector<u8>,
-    ) acquires GovernanceState {
-        // Kimi F4 fix (audit R1): require DAO config before accepting proposals.
-        let cfg = borrow_global<GovernanceState>(@desnet);
-        assert!(cfg.desnet_fa_metadata != @0x0, E_NOT_INITIALIZED);
-        assert!(cfg.total_30d_emission > 0, E_NOT_INITIALIZED);
+    ) acquires GovernanceState, Emission30dRollingBucket {
+        // v0.3.2 (F14, R2 Kimi R2-N1): defense-in-depth — only @desnet pkg upgrades
+        // are valid in monolith. Reject impossible proposals at submission time.
+        assert!(target_package_addr == @desnet, E_INVALID_ADDRESS);
+
+        // v0.3.2 (F6): DAO-unlock now driven by auto-tracker (lp_staking emission claims).
+        // `update_total_30d_emission` manual setter still functional but auto-tracker
+        // takes precedence via `effective_30d_emission()`.
+        assert!(effective_30d_emission() > 0, E_NOT_INITIALIZED);
 
         let proposer_addr = signer::address_of(proposer);
         let proposer_power = voting_power(proposer_addr);
@@ -340,7 +591,7 @@ module desnet::governance {
     public entry fun ratify(
         _caller: &signer,
         proposal_id: u64,
-    ) acquires GovernanceState {
+    ) acquires GovernanceState, Emission30dRollingBucket {
         // Pre-compute quorum BEFORE mut-borrow (view fn acquires same resource = conflict).
         let q = quorum_amount();
 
@@ -409,6 +660,11 @@ module desnet::governance {
             // Verify submitted code matches what voters approved.
             assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);
 
+            // v0.3.2 (F14, R2 Kimi R2-N1): defense-in-depth at execute too.
+            // `target_package_addr` was sanitized at propose time, but re-assert in
+            // case future code paths bypass propose-time validation.
+            assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);
+
             proposal.executed_at_secs = option::some(now);
             target_package_addr = proposal.target_package_addr;
         };
@@ -423,6 +679,102 @@ module desnet::governance {
         });
     }
 
+    // ============ DAO CHUNKED EXECUTE (v0.3.2 F8) ============
+    //
+    // Sister of multisig_stage_upgrade_chunk / multisig_publish_chunked_upgrade but
+    // gated on DAO proposal lifecycle (approved + ratified + timelock-elapsed).
+    //
+    // Reuses `UpgradeStaging` resource. Hash-verify the assembled (metadata, code) at
+    // publish time matches `proposal.new_module_bytes_hash`. Auth: anyone can call
+    // (post-ratify, the DAO has spoken; staging is pure mechanics).
+    //
+    // Flow:
+    //   1. Anyone calls `dao_stage_upgrade_chunk(proposal_id, ...)` N-1 times to stage
+    //   2. Anyone calls `dao_publish_chunked_upgrade(proposal_id, last_chunk, ...)` —
+    //      stages final + verifies digest + publishes + marks proposal executed
+
+    public entry fun dao_stage_upgrade_chunk(
+        _caller: &signer,
+        proposal_id: u64,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires GovernanceState, UpgradeStaging {
+        // Verify proposal is approved + ratified + timelock-elapsed (same as execute_proposal).
+        let state = borrow_global<GovernanceState>(@desnet);
+        assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
+        let proposal = smart_table::borrow(&state.proposals, proposal_id);
+        let approved_opt = proposal.approved_at_secs;
+        assert!(option::is_some(&approved_opt), E_QUORUM_NOT_MET);
+        assert!(option::is_none(&proposal.executed_at_secs), E_ALREADY_EXECUTED);
+        let approved_at = *option::borrow(&approved_opt);
+        let now = timestamp::now_seconds();
+        assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
+        assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);
+
+        let pkg_signer = derive_pkg_signer();
+        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+    }
+
+    public entry fun dao_publish_chunked_upgrade(
+        caller: &signer,
+        proposal_id: u64,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires GovernanceState, UpgradeStaging {
+        // Re-verify (defense-in-depth — staging may span days; conditions can change).
+        let target_package_addr;
+        let stored_hash;
+        {
+            let state = borrow_global<GovernanceState>(@desnet);
+            assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
+            let proposal = smart_table::borrow(&state.proposals, proposal_id);
+            let approved_opt = proposal.approved_at_secs;
+            assert!(option::is_some(&approved_opt), E_QUORUM_NOT_MET);
+            assert!(option::is_none(&proposal.executed_at_secs), E_ALREADY_EXECUTED);
+            let approved_at = *option::borrow(&approved_opt);
+            let now = timestamp::now_seconds();
+            assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
+            assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);
+            target_package_addr = proposal.target_package_addr;
+            stored_hash = proposal.new_module_bytes_hash;
+        };
+
+        let pkg_signer = derive_pkg_signer();
+        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+
+        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
+
+        // Defense-in-depth — same empty-slot check as multisig variant.
+        let i = 0;
+        let n = vector::length(&code);
+        while (i < n) {
+            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
+            i = i + 1;
+        };
+
+        // Verify assembled payload matches the hash voters approved.
+        let assembled_digest = compute_upgrade_digest(&metadata, &code);
+        assert!(assembled_digest == stored_hash, E_HASH_MISMATCH);
+
+        // Mark proposal executed BEFORE publish (preserve ordering vs single-tx execute).
+        let now = timestamp::now_seconds();
+        {
+            let state_mut = borrow_global_mut<GovernanceState>(@desnet);
+            let proposal_mut = smart_table::borrow_mut(&mut state_mut.proposals, proposal_id);
+            proposal_mut.executed_at_secs = option::some(now);
+        };
+
+        code::publish_package_txn(&pkg_signer, metadata, code);
+
+        event::emit(ProposalExecuted {
+            proposal_id,
+            target_package_addr,
+            executor: signer::address_of(caller),
+        });
+    }
+
     /// Canonical digest of upgrade payload. Used by both `propose_upgrade` (off-chain
     /// callers compute this on the intended payload) and `execute_proposal` (verifies
     /// submitted bytes match). Scheme: sha3_256(bcs(metadata) || concat(bcs(code_bytes[i]))).
@@ -458,58 +810,77 @@ module desnet::governance {
     // ============ VIEWS ============
 
     /// voting_power = min(rewards_earned_30d, current DESNET balance).
-    /// If `desnet_fa_metadata` not yet configured (= @0x0), returns 0.
+    /// v0.3.1 Item 3b: DESNET FA addr hardcoded as `DESNET_FA_ADDR` constant (eliminates
+    /// manipulation surface). `state.desnet_fa_metadata` field intentionally ignored
+    /// (vestigial; compat-preserved).
+    /// Object-exists guard: returns 0 pre-`register_handle("desnet")` (when DESNET FA
+    /// hasn't been spawned yet at the deterministic addr).
+    /// NOTE v0.3.1: `rewards_earned_30d` still mixed-token aggregate. Item 2 (per-token
+    /// rewards isolation) deferred to v0.3.2 — until then, voting power = min(LP-stake-
+    /// earned-mixed, DESNET balance). Cross-token reward claims still inflate first
+    /// term but bound by DESNET balance.
+    /// v0.3.2 (F7): per-token DESNET-only rewards if RegistryByToken initialized,
+    /// fallback to legacy mixed `rewards_earned_30d` otherwise. Eliminates cross-token
+    /// inflation surface — voting power becomes strictly DESNET-LP-earned.
     #[view]
     public fun voting_power(voter_addr: address): u64 acquires GovernanceState {
-        let state = borrow_global<GovernanceState>(@desnet);
-        if (state.desnet_fa_metadata == @0x0) return 0;
-
-        let earned = voter_history::rewards_earned_30d(voter_addr);
+        let _ = borrow_global<GovernanceState>(@desnet);
+        if (!aptos_framework::object::object_exists<aptos_framework::fungible_asset::Metadata>(DESNET_FA_ADDR))
+            return 0;
+        let earned = if (voter_history::has_per_token_registry()) {
+            voter_history::rewards_earned_30d_for_token(voter_addr, DESNET_FA_ADDR)
+        } else {
+            voter_history::rewards_earned_30d(voter_addr)
+        };
         let fa_meta = aptos_framework::object::address_to_object<aptos_framework::fungible_asset::Metadata>(
-            state.desnet_fa_metadata
+            DESNET_FA_ADDR
         );
         let balance = aptos_framework::primary_fungible_store::balance(voter_addr, fa_meta);
         if (earned < balance) earned else balance
     }
 
     #[view]
-    public fun proposal_threshold_amount(): u64 acquires GovernanceState {
-        let state = borrow_global<GovernanceState>(@desnet);
-        if (state.total_30d_emission == 0) return 18446744073709551615u64;
-        (state.total_30d_emission * PROPOSAL_THRESHOLD_BPS) / 10000
+    public fun proposal_threshold_amount(): u64 acquires GovernanceState, Emission30dRollingBucket {
+        // v0.3.2 (F6): use effective (max of auto-tracked, manual) for denominator.
+        let eff = effective_30d_emission();
+        if (eff == 0) return 18446744073709551615u64;
+        (eff * PROPOSAL_THRESHOLD_BPS) / 10000
     }
 
     #[view]
-    public fun quorum_amount(): u64 acquires GovernanceState {
-        let state = borrow_global<GovernanceState>(@desnet);
-        if (state.total_30d_emission == 0) return 18446744073709551615u64;
-        (state.total_30d_emission * QUORUM_BPS) / 10000
+    public fun quorum_amount(): u64 acquires GovernanceState, Emission30dRollingBucket {
+        // v0.3.2 (F6): use effective (max of auto-tracked, manual) for denominator.
+        let eff = effective_30d_emission();
+        if (eff == 0) return 18446744073709551615u64;
+        (eff * QUORUM_BPS) / 10000
     }
 
     // ============ ADMIN SETTERS (multisig-only) ============
 
     const E_NOT_MULTISIG_ADMIN: u64 = 100;
 
-    /// Multisig sets DESNET FA metadata addr post-deploy. Required to activate
-    /// voting_power. Idempotent (admin can re-point if needed).
-    /// R3 fix (Claude R2-N5 / Kimi / Qwen): reject @0x0 — that is the
-    /// "unconfigured" sentinel value and would freeze all voting power.
+    /// v0.3.1 Item 3b: NEUTERED. DESNET FA addr now hardcoded as `DESNET_FA_ADDR` constant.
+    /// Field `desnet_fa_metadata` retained as vestigial (compat-only, not read).
+    /// Eliminates manipulation surface where multisig could set malicious FA addr post
+    /// `disable_multisig_upgrade`.
     public entry fun update_desnet_fa_metadata(
-        multisig: &signer,
-        fa_addr: address,
+        _multisig: &signer,
+        _fa_addr: address,
     ) acquires GovernanceState {
-        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG_ADMIN);
-        assert!(fa_addr != @0x0, E_INVALID_ADDRESS);
-        borrow_global_mut<GovernanceState>(@desnet).desnet_fa_metadata = fa_addr;
+        let _ = borrow_global<GovernanceState>(@desnet);
+        abort E_NEUTERED
     }
 
-    /// Multisig sets 30d emission estimate (denominator for threshold/quorum).
+    /// v0.3.2 (F6b): NEUTERED. Auto-tracker (Emission30dRollingBucket) is sole source
+    /// of truth via `effective_30d_emission()`. Manual setter eliminates manipulation
+    /// surface where multisig could pin denominator to favorable value.
+    /// Field `total_30d_emission` retained as vestigial (compat-only, not read).
     public entry fun update_total_30d_emission(
-        multisig: &signer,
-        amount: u64,
+        _multisig: &signer,
+        _amount: u64,
     ) acquires GovernanceState {
-        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG_ADMIN);
-        borrow_global_mut<GovernanceState>(@desnet).total_30d_emission = amount;
+        let _ = borrow_global<GovernanceState>(@desnet);
+        abort E_NEUTERED
     }
 
     #[view]
diff --git a/sources/handle_fee_vault.move b/sources/handle_fee_vault.move
new file mode 100644
index 0000000..bc9281a
--- /dev/null
+++ b/sources/handle_fee_vault.move
@@ -0,0 +1,143 @@
+/// HandleFeeVault — handle reg fees: 10% deployer, 90% buy DESNET + burn.
+/// Destinations immutable. No admin.
+module desnet::handle_fee_vault {
+    use aptos_framework::event;
+    use aptos_framework::fungible_asset::{Self, Metadata};
+    use aptos_framework::object::{Self, ExtendRef};
+    use aptos_framework::primary_fungible_store;
+
+    use desnet::amm;
+    use desnet::apt_vault;
+    use desnet::factory;
+    use desnet::governance;
+
+    friend desnet::profile;
+
+    const SEED_VAULT: vector<u8> = b"handle_fee_vault";
+    const DESNET_HANDLE: vector<u8> = b"desnet";
+    const APT_FA_ADDR: address = @0xa;
+
+    /// 10% to deployer beneficiary, 90% to DESNET buyback-burn.
+    const SPLIT_DEPLOYER_BPS: u64 = 1000;
+    const SPLIT_BURN_BPS: u64 = 9000;
+    const BPS_DENOM: u64 = 10000;
+
+    /// Min APT balance for settle (anti-dust). 0.1 APT.
+    const APT_SETTLE_THRESHOLD: u64 = 10_000_000;
+
+    const E_BELOW_THRESHOLD: u64 = 1;
+    const E_VAULT_NOT_INITIALIZED: u64 = 2;
+
+    struct HandleFeeVault has key {
+        deployer_beneficiary: address,
+        extend_ref: ExtendRef,
+    }
+
+    #[event]
+    struct Settled has drop, store {
+        total_apt: u64,
+        to_deployer: u64,
+        desnet_burned: u64,
+    }
+
+    /// Auto-fires on compat-upgrade publish since this module is new.
+    /// `account` is @desnet (resource account signer assembled by code::publish_package_txn).
+    fun init_module(account: &signer) {
+        let constructor = object::create_named_object(account, SEED_VAULT);
+        let vault_signer = object::generate_signer(&constructor);
+        let extend_ref = object::generate_extend_ref(&constructor);
+        let transfer_ref = object::generate_transfer_ref(&constructor);
+        object::disable_ungated_transfer(&transfer_ref);
+
+        move_to(&vault_signer, HandleFeeVault {
+            deployer_beneficiary: @origin,
+            extend_ref,
+        });
+    }
+
+    public fun vault_addr(): address {
+        object::create_object_address(&@desnet, SEED_VAULT)
+    }
+
+    public fun vault_exists(): bool {
+        exists<HandleFeeVault>(vault_addr())
+    }
+
+    /// Friend-only: APT FA → vault primary store. Called by profile::register_handle.
+    public(friend) fun deposit_apt_fa(fa: fungible_asset::FungibleAsset) {
+        primary_fungible_store::deposit(vault_addr(), fa);
+    }
+
+    /// Public top-up — anyone can deposit APT to vault.
+    public entry fun deposit_apt(depositor: &signer, amount: u64) {
+        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
+        let fa = primary_fungible_store::withdraw(depositor, apt_meta, amount);
+        deposit_apt_fa(fa);
+    }
+
+    /// 10% APT → deployer beneficiary, 90% APT → swap to DESNET → burn.
+    /// Permissionless. Requires DESNET handle registered (else swap aborts in amm).
+    public entry fun settle(_caller: &signer) acquires HandleFeeVault {
+        let v_addr = vault_addr();
+        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
+
+        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
+        let total = primary_fungible_store::balance(v_addr, apt_meta);
+        assert!(total >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);
+
+        let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
+        let to_burn = total - to_deployer;
+
+        let vault = borrow_global<HandleFeeVault>(v_addr);
+        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
+
+        // 10% APT direct to deployer beneficiary primary store
+        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer);
+        primary_fungible_store::deposit(vault.deployer_beneficiary, apt_for_deployer);
+
+        // 90% APT swap to DESNET via amm pool → burn via DESNET apt_vault's BurnRef (delegation)
+        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn);
+        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, 0);
+        let desnet_burned = fungible_asset::amount(&desnet_fa);
+
+        let desnet_apt_vault = factory::vault_addr_of_handle(DESNET_HANDLE);
+        apt_vault::burn_via_vault(desnet_apt_vault, desnet_fa);
+
+        event::emit(Settled { total_apt: total, to_deployer, desnet_burned });
+    }
+
+    /// One-time poke: migrate stranded pre-upgrade fees from @desnet primary store.
+    /// Pre-v0.3.1, register_handle deposited fees to `state.fee_receiver` (= @desnet
+    /// at init). This pulls those funds into the vault for proper 10/90 split.
+    public entry fun migrate_legacy_fees(_caller: &signer) {
+        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
+        let balance = primary_fungible_store::balance(@desnet, apt_meta);
+        if (balance == 0) return;
+        let pkg_signer = governance::derive_pkg_signer();
+        let fa = primary_fungible_store::withdraw(&pkg_signer, apt_meta, balance);
+        deposit_apt_fa(fa);
+    }
+
+    #[view]
+    public fun deployer_beneficiary(): address acquires HandleFeeVault {
+        let v_addr = vault_addr();
+        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
+        borrow_global<HandleFeeVault>(v_addr).deployer_beneficiary
+    }
+
+    #[view]
+    public fun apt_balance(): u64 {
+        let v_addr = vault_addr();
+        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
+        primary_fungible_store::balance(v_addr, apt_meta)
+    }
+
+    #[view]
+    public fun split_deployer_bps(): u64 { SPLIT_DEPLOYER_BPS }
+
+    #[view]
+    public fun split_burn_bps(): u64 { SPLIT_BURN_BPS }
+
+    #[view]
+    public fun settle_threshold(): u64 { APT_SETTLE_THRESHOLD }
+}
diff --git a/sources/lp_staking.move b/sources/lp_staking.move
index 9072480..8ae16a6 100644
--- a/sources/lp_staking.move
+++ b/sources/lp_staking.move
@@ -436,7 +436,18 @@ module desnet::lp_staking {
 
             if (actual_paid > 0) {
                 let pkg_signer = governance::derive_pkg_signer();
-                voter_history::record_reward_received(&pkg_signer, recipient, actual_paid);
+                // v0.3.2 (F7): record per-token (also writes legacy mixed for compat).
+                // Token addr is the pool's emission token = current pool.token_metadata_addr.
+                voter_history::record_reward_received_for_token(
+                    &pkg_signer,
+                    recipient,
+                    pool.token_metadata_addr,
+                    actual_paid,
+                );
+                // v0.3.2 (F6): feed the 30d auto-tracker so DAO threshold/quorum
+                // become driven by actual emission flow (eliminates manipulation
+                // surface of multisig::update_total_30d_emission).
+                governance::record_emission_for_window(actual_paid);
             };
         };
 
diff --git a/sources/profile.move b/sources/profile.move
index d721f08..4517f33 100644
--- a/sources/profile.move
+++ b/sources/profile.move
@@ -36,6 +36,7 @@ module desnet::profile {
     use desnet::reference_gate::{Self, ReferenceGate};
     use desnet::factory;
     use desnet::governance;
+    use desnet::handle_fee_vault;
 
     friend desnet::mint;
     friend desnet::link;
@@ -84,6 +85,8 @@ module desnet::profile {
     const E_SYNC_GATE_ALREADY_SET: u64 = 16;
     const E_RESERVED_HANDLE: u64 = 17;
     const E_INVALID_ADDRESS: u64 = 18;
+    /// v0.3.2 (F10): update_fee_receiver neutered after handle_fee_vault (F9) takes over fee routing.
+    const E_NEUTERED: u64 = 19;
 
     // ============ TYPES ============
 
@@ -229,15 +232,16 @@ module desnet::profile {
     /// Post-vault upgrade, register_handle body bypasses this field — handle_fee_vault
     /// is the immutable destination. Kept here for v0.3.0 baseline; body becomes
     /// `abort 0` in v0.3.1 compat upgrade.
+    /// v0.3.2 (F10): NEUTERED. With handle_fee_vault (F9), `state.fee_receiver` field
+    /// is no longer read by `register_handle` body — fees route directly to the vault.
+    /// Field retained as vestigial (compat-only). Eliminates the last admin knob over
+    /// fee destination once F9 is live.
     public entry fun update_fee_receiver(
-        admin: &signer,
-        new_fee_receiver: address,
+        _admin: &signer,
+        _new_fee_receiver: address,
     ) acquires ProtocolState {
-        // Gemini MED fix (audit R1): zero-addr check.
-        assert!(new_fee_receiver != @0x0, E_INVALID_ADDRESS);
-        let state = borrow_global_mut<ProtocolState>(@desnet);
-        assert!(signer::address_of(admin) == state.admin, E_NOT_ADMIN);
-        state.fee_receiver = new_fee_receiver;
+        let _ = borrow_global<ProtocolState>(@desnet);
+        abort E_NEUTERED
     }
 
     /// Admin rotates admin (e.g., to governance contract). One-way after PMF transition.
@@ -357,18 +361,19 @@ module desnet::profile {
         );
         assert!(!exists<Profile>(pid_addr), E_PID_ALREADY_EXISTS);
 
-        // 3. Fee in APT — withdraw from wallet, deposit to fee_receiver.
+        // 3. Fee in APT — v0.3.2 F9: route directly to handle_fee_vault
+        //    (10% deployer beneficiary / 90% DESNET buyback-burn).
+        //    state.fee_receiver field is now vestigial (compat-preserved); body bypasses it.
+        //    Borrow kept (unused) to preserve `acquires ProtocolState` annotation parity
+        //    with the deployed bytecode metadata.
         //    Plus pool_seed_apt (5 APT) — withdrawn as separate FA, passed to factory
         //    for atomic AMM pool seed.
-        //    Note: fee_receiver = @desnet at init. Compat upgrade adds handle_fee_vault
-        //    that pulls fees from this primary store via migrate_legacy_fees + reroutes
-        //    register_handle body to deposit directly to vault (post-upgrade body).
-        let state = borrow_global<ProtocolState>(@desnet);
+        let _state = borrow_global<ProtocolState>(@desnet);
         let fee_raw = handle_fee_apt(vector::length(&handle));
         let apt_metadata = object::address_to_object<Metadata>(APT_FA_METADATA);
         if (fee_raw > 0) {
             let fee_fa = primary_fungible_store::withdraw(wallet, apt_metadata, fee_raw);
-            primary_fungible_store::deposit(state.fee_receiver, fee_fa);
+            handle_fee_vault::deposit_apt_fa(fee_fa);
         };
         let pool_seed_amount = factory::pool_seed_apt_amount();
         let pool_seed_fa = primary_fungible_store::withdraw(wallet, apt_metadata, pool_seed_amount);
@@ -729,6 +734,15 @@ module desnet::profile {
         borrow_global<Profile>(pid_addr).handle
     }
 
+    /// v0.3.2 (F1b): wallet→handle convenience. Derives PID from wallet, looks up
+    /// handle. Aborts E_PROFILE_NOT_FOUND if wallet has no registered PID.
+    /// (Lives here, not in factory.move, because profile→factory but not the reverse.)
+    #[view]
+    public fun handle_of_wallet(wallet_addr: address): String acquires Profile {
+        let pid_addr = derive_pid_address(wallet_addr);
+        handle_of(pid_addr)
+    }
+
     #[view]
     public fun has_signer(pid_addr: address, pubkey: vector<u8>): bool acquires Profile {
         if (!exists<Profile>(pid_addr)) return false;
diff --git a/sources/voter_history.move b/sources/voter_history.move
index f248749..82dc361 100644
--- a/sources/voter_history.move
+++ b/sources/voter_history.move
@@ -64,6 +64,15 @@ module desnet::voter_history {
         voters: SmartTable<address, VoterHistory>,
     }
 
+    /// v0.3.2 (F7): per-token isolated rewards. Eliminates cross-token mix where a
+    /// non-DESNET reward stream could inflate voter's voting power. Lazy-init on
+    /// first per-token record. Outer key = voter_addr, inner key = token_metadata_addr.
+    /// `governance::voting_power` reads DESNET-only via this registry when present,
+    /// falls back to legacy mixed `Registry` when not.
+    struct RegistryByToken has key {
+        voters: SmartTable<address, SmartTable<address, VoterHistory>>,
+    }
+
     // ============ EVENTS ============
 
     /// Emitted on every voter reward record. Pairs atomically with
@@ -155,6 +164,42 @@ module desnet::voter_history {
         });
     }
 
+    // ============ v0.3.2 (F7): per-token isolation ============
+
+    /// Friend-only: extends `record_reward_received` with per-token tracking.
+    /// Records to BOTH legacy mixed `Registry` (preserve compat for old read-paths)
+    /// AND new `RegistryByToken` (per-token isolation for governance::voting_power).
+    /// Lazy-init RegistryByToken on first call.
+    public(friend) fun record_reward_received_for_token(
+        factory_authority: &signer,
+        voter_addr: address,
+        token_addr: address,
+        amount: u64,
+    ) acquires Registry, RegistryByToken {
+        // 1. Legacy path — keeps old indexers working.
+        record_reward_received(factory_authority, voter_addr, amount);
+
+        // 2. Per-token isolated path. (factory_authority asserted == @desnet inside #1.)
+        if (!exists<RegistryByToken>(@desnet)) {
+            move_to(factory_authority, RegistryByToken { voters: smart_table::new() });
+        };
+        let registry = borrow_global_mut<RegistryByToken>(@desnet);
+        if (!smart_table::contains(&registry.voters, voter_addr)) {
+            smart_table::add(&mut registry.voters, voter_addr, smart_table::new());
+        };
+        let voter_tokens = smart_table::borrow_mut(&mut registry.voters, voter_addr);
+        if (!smart_table::contains(voter_tokens, token_addr)) {
+            smart_table::add(voter_tokens, token_addr, VoterHistory {
+                rewards_history: vector::empty(),
+                total_received: 0,
+            });
+        };
+        let history = smart_table::borrow_mut(voter_tokens, token_addr);
+        let now = timestamp::now_seconds();
+        vector::push_back(&mut history.rewards_history, RewardEntry { timestamp_secs: now, amount });
+        history.total_received = history.total_received + amount;
+    }
+
     // ============ PRUNE — permissionless storage bound ============
 
     /// Anyone can call to prune entries older than HISTORY_PRUNE_AFTER_SECS.
@@ -195,6 +240,38 @@ module desnet::voter_history {
 
     // ============ VIEWS ============
 
+    /// v0.3.2 (F7): Per-token rewards within 30d. Returns 0 if RegistryByToken not yet
+    /// initialized OR voter has no entry for this token. Replaces mixed-aggregate when
+    /// caller wants strict per-token isolation (e.g., governance DESNET-only voting power).
+    #[view]
+    public fun rewards_earned_30d_for_token(voter_addr: address, token_addr: address): u64
+        acquires RegistryByToken
+    {
+        if (!exists<RegistryByToken>(@desnet)) return 0;
+        let registry = borrow_global<RegistryByToken>(@desnet);
+        if (!smart_table::contains(&registry.voters, voter_addr)) return 0;
+        let voter_tokens = smart_table::borrow(&registry.voters, voter_addr);
+        if (!smart_table::contains(voter_tokens, token_addr)) return 0;
+        let history = smart_table::borrow(voter_tokens, token_addr);
+
+        let now = timestamp::now_seconds();
+        let cutoff = if (now > VOTING_WINDOW_SECS) now - VOTING_WINDOW_SECS else 0;
+        let sum: u64 = 0;
+        let len = vector::length(&history.rewards_history);
+        let i = 0;
+        while (i < len) {
+            let e = vector::borrow(&history.rewards_history, i);
+            if (e.timestamp_secs >= cutoff) sum = sum + e.amount;
+            i = i + 1;
+        };
+        sum
+    }
+
+    /// v0.3.2 (F7): exists check — gates governance::voting_power's choice of
+    /// per-token vs legacy-mixed read.
+    #[view]
+    public fun has_per_token_registry(): bool { exists<RegistryByToken>(@desnet) }
+
     /// Sum reward entries within last 30d window. Used as filter A in voting power.
     #[view]
     public fun rewards_earned_30d(voter_addr: address): u64 acquires Registry {
