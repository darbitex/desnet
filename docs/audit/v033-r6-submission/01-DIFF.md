diff --git a/sources/amm.move b/sources/amm.move
index 9a5809c..9530b97 100644
--- a/sources/amm.move
+++ b/sources/amm.move
@@ -43,7 +43,7 @@ module desnet::amm {
     const SEED_POOL: vector<u8> = b"desnet::amm::pool::";
 
     /// On-chain user-facing risk disclosure (concise; off-chain docs hold full text).
-    const WARNING: vector<u8> = b"DESNET AMM x*y=k. AI-audited only. Use at own risk.";
+    const WARNING: vector<u8> = b"DESNET AMM x*y=k. Multi-LLM audited (R1-R5, mainnet live). Use at own risk.";
 
     // ============ ERROR CODES ============
 
diff --git a/sources/governance.move b/sources/governance.move
index a9e543c..e78b53b 100644
--- a/sources/governance.move
+++ b/sources/governance.move
@@ -85,6 +85,8 @@ module desnet::governance {
     const E_NEUTERED: u64 = 22;
     /// v0.3.2 (F2): chunked-publish defense-in-depth — at least one module slot empty.
     const E_INCOMPLETE_CHUNKS: u64 = 23;
+    /// v0.3.3 (G2): caller is not the original DAO stager for this proposal.
+    const E_NOT_STAGER: u64 = 24;
     /// v0.3.2 (F6): 30-day rolling emission tracker constants.
     const SECONDS_PER_DAY: u64 = 86400;
     const ROLLING_WINDOW_DAYS: u64 = 30;
@@ -142,6 +144,20 @@ module desnet::governance {
         code: vector<vector<u8>>,
     }
 
+    /// v0.3.3 (G2, R5 CONV-2 MED fix): isolated DAO chunked staging. Separate from
+    /// multisig `UpgradeStaging` — DAO + multisig paths can no longer collide.
+    /// `proposal_id` field binds staging to one proposal (stale staging for a
+    /// different proposal auto-clears on next stage call). `stager` field locks
+    /// further appends to original staging address (anti-grief).
+    /// Permissionless `dao_cleanup_upgrade_staging` allows recovery if stage
+    /// becomes corrupted or stale.
+    struct DaoUpgradeStaging has key, drop {
+        proposal_id: u64,
+        stager: address,
+        metadata: vector<u8>,
+        code: vector<vector<u8>>,
+    }
+
     /// v0.3.2 (F6): Auto-tracker for 30-day rolling emission. Eliminates manipulation
     /// surface where multisig sets `total_30d_emission` to arbitrary value.
     /// Per-day buckets indexed by (day_number % 30); parallel vector tracks the
@@ -374,6 +390,43 @@ module desnet::governance {
         });
     }
 
+    /// v0.3.3 (G5, R5 Claude C7 LOW defense-in-depth): hash-verifying multisig publish.
+    /// Same as `multisig_publish_chunked_upgrade` but asserts assembled `(metadata, code)`
+    /// digest equals `expected_digest` parameter — pin the hash off-chain (e.g., from a
+    /// signed multisig review summary), preventing a single rogue signer from substituting
+    /// chunk bytes during multisig coordination.
+    public entry fun multisig_publish_chunked_upgrade_with_digest(
+        multisig: &signer,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+        expected_digest: vector<u8>,
+    ) acquires GovernanceState, UpgradeStaging {
+        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        assert!(
+            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
+            E_MULTISIG_DISABLED
+        );
+        let pkg_signer = derive_pkg_signer();
+        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
+        // Empty-slot defense (mirror multisig_publish_chunked_upgrade).
+        let i = 0;
+        let n = vector::length(&code);
+        while (i < n) {
+            assert!(!vector::is_empty(vector::borrow(&code, i)), E_INCOMPLETE_CHUNKS);
+            i = i + 1;
+        };
+        // v0.3.3 hash-verify: assembled payload must match pinned digest.
+        let assembled_digest = compute_upgrade_digest(&metadata, &code);
+        assert!(assembled_digest == expected_digest, E_HASH_MISMATCH);
+        code::publish_package_txn(&pkg_signer, metadata, code);
+        event::emit(MultisigUpgrade {
+            multisig: signer::address_of(multisig),
+            timestamp_secs: timestamp::now_seconds(),
+        });
+    }
+
     /// Discard a half-staged UpgradeStaging (e.g., aborted upgrade, restart).
     public entry fun cleanup_upgrade_staging(multisig: &signer) acquires UpgradeStaging {
         assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
@@ -473,13 +526,15 @@ module desnet::governance {
         sum
     }
 
-    /// max(auto-tracked, manually-set). Used by quorum + threshold computations.
-    /// Manual setter (`update_total_30d_emission`) kept functional for transition;
-    /// expected to be neutered in a future upgrade once auto-tracker proven reliable.
+    /// v0.3.3 (G4, R5 Deepseek HIGH): now reads ONLY auto-tracker. Manual field
+    /// `state.total_30d_emission` permanently ignored — eliminates latent overflow
+    /// vector where `(eff * BPS) / 10000` could abort if vestigial value was extreme.
+    /// `update_total_30d_emission` already neutered (E_NEUTERED) in v0.3.2 F6b, so
+    /// vestigial value is frozen at deploy-time state. Defense-in-depth for forks.
+    /// Borrow kept (unused) to preserve `acquires GovernanceState` annotation parity.
     fun effective_30d_emission(): u64 acquires GovernanceState, Emission30dRollingBucket {
-        let auto = total_30d_emission_auto();
-        let manual = borrow_global<GovernanceState>(@desnet).total_30d_emission;
-        if (auto > manual) auto else manual
+        let _ = borrow_global<GovernanceState>(@desnet);
+        total_30d_emission_auto()
     }
 
     #[view]
@@ -693,13 +748,62 @@ module desnet::governance {
     //   2. Anyone calls `dao_publish_chunked_upgrade(proposal_id, last_chunk, ...)` —
     //      stages final + verifies digest + publishes + marks proposal executed
 
+    /// v0.3.3 (G2): per-proposal staging via DaoUpgradeStaging. Auto-resets if
+    /// existing staging is for a different proposal. Locks appends to original
+    /// stager addr to prevent grief from concurrent callers on same proposal.
+    fun dao_stage_chunks_into_staging(
+        pkg_signer: &signer,
+        caller_addr: address,
+        proposal_id: u64,
+        metadata_chunk: vector<u8>,
+        code_indices: vector<u16>,
+        code_chunks: vector<vector<u8>>,
+    ) acquires DaoUpgradeStaging {
+        assert!(
+            vector::length(&code_indices) == vector::length(&code_chunks),
+            E_ARGS_LEN_MISMATCH
+        );
+        // Auto-reset if existing staging is for a different proposal (stale).
+        if (exists<DaoUpgradeStaging>(@desnet)) {
+            let staging_ref = borrow_global<DaoUpgradeStaging>(@desnet);
+            if (staging_ref.proposal_id != proposal_id) {
+                let _ = move_from<DaoUpgradeStaging>(@desnet);
+            } else {
+                // Same proposal — must be original stager (anti-grief append).
+                assert!(staging_ref.stager == caller_addr, E_NOT_STAGER);
+            };
+        };
+        if (!exists<DaoUpgradeStaging>(@desnet)) {
+            move_to(pkg_signer, DaoUpgradeStaging {
+                proposal_id,
+                stager: caller_addr,
+                metadata: vector::empty(),
+                code: vector::empty(),
+            });
+        };
+        let staging = borrow_global_mut<DaoUpgradeStaging>(@desnet);
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
     public entry fun dao_stage_upgrade_chunk(
-        _caller: &signer,
+        caller: &signer,
         proposal_id: u64,
         metadata_chunk: vector<u8>,
         code_indices: vector<u16>,
         code_chunks: vector<vector<u8>>,
-    ) acquires GovernanceState, UpgradeStaging {
+    ) acquires GovernanceState, DaoUpgradeStaging {
         // Verify proposal is approved + ratified + timelock-elapsed (same as execute_proposal).
         let state = borrow_global<GovernanceState>(@desnet);
         assert!(smart_table::contains(&state.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
@@ -712,8 +816,9 @@ module desnet::governance {
         assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
         assert!(proposal.target_package_addr == @desnet, E_INVALID_ADDRESS);
 
+        let caller_addr = signer::address_of(caller);
         let pkg_signer = derive_pkg_signer();
-        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+        dao_stage_chunks_into_staging(&pkg_signer, caller_addr, proposal_id, metadata_chunk, code_indices, code_chunks);
     }
 
     public entry fun dao_publish_chunked_upgrade(
@@ -722,7 +827,7 @@ module desnet::governance {
         metadata_chunk: vector<u8>,
         code_indices: vector<u16>,
         code_chunks: vector<vector<u8>>,
-    ) acquires GovernanceState, UpgradeStaging {
+    ) acquires GovernanceState, DaoUpgradeStaging {
         // Re-verify (defense-in-depth — staging may span days; conditions can change).
         let target_package_addr;
         let stored_hash;
@@ -741,10 +846,11 @@ module desnet::governance {
             stored_hash = proposal.new_module_bytes_hash;
         };
 
+        let caller_addr = signer::address_of(caller);
         let pkg_signer = derive_pkg_signer();
-        stage_chunks_into_staging(&pkg_signer, metadata_chunk, code_indices, code_chunks);
+        dao_stage_chunks_into_staging(&pkg_signer, caller_addr, proposal_id, metadata_chunk, code_indices, code_chunks);
 
-        let UpgradeStaging { metadata, code } = move_from<UpgradeStaging>(@desnet);
+        let DaoUpgradeStaging { proposal_id: _, stager: _, metadata, code } = move_from<DaoUpgradeStaging>(@desnet);
 
         // Defense-in-depth — same empty-slot check as multisig variant.
         let i = 0;
@@ -755,6 +861,9 @@ module desnet::governance {
         };
 
         // Verify assembled payload matches the hash voters approved.
+        // v0.3.3 NOTE: on hash-fail, abort reverts entire tx including the move_from above
+        // → DaoUpgradeStaging stays UNTOUCHED (Move atomicity), so legitimate publisher can
+        // retry without a separate cleanup call.
         let assembled_digest = compute_upgrade_digest(&metadata, &code);
         assert!(assembled_digest == stored_hash, E_HASH_MISMATCH);
 
@@ -771,10 +880,29 @@ module desnet::governance {
         event::emit(ProposalExecuted {
             proposal_id,
             target_package_addr,
-            executor: signer::address_of(caller),
+            executor: caller_addr,
         });
     }
 
+    /// v0.3.3 (G2): permissionless cleanup of DAO chunked staging. Anyone can wipe
+    /// `DaoUpgradeStaging` if it's stale or grief'd. Cost = gas only. Original stager
+    /// (or anyone else) can re-stage cleanly afterward. Multisig path's `cleanup_upgrade_staging`
+    /// remains multisig-only by design (different trust model).
+    public entry fun dao_cleanup_upgrade_staging(_caller: &signer) acquires DaoUpgradeStaging {
+        if (exists<DaoUpgradeStaging>(@desnet)) {
+            let _ = move_from<DaoUpgradeStaging>(@desnet);
+        };
+    }
+
+    #[view]
+    public fun dao_upgrade_staging_exists(): bool { exists<DaoUpgradeStaging>(@desnet) }
+
+    #[view]
+    public fun dao_upgrade_staging_proposal_id(): u64 acquires DaoUpgradeStaging {
+        if (!exists<DaoUpgradeStaging>(@desnet)) return 0;
+        borrow_global<DaoUpgradeStaging>(@desnet).proposal_id
+    }
+
     /// Canonical digest of upgrade payload. Used by both `propose_upgrade` (off-chain
     /// callers compute this on the intended payload) and `execute_proposal` (verifies
     /// submitted bytes match). Scheme: sha3_256(bcs(metadata) || concat(bcs(code_bytes[i]))).
@@ -819,15 +947,19 @@ module desnet::governance {
     /// rewards isolation) deferred to v0.3.2 — until then, voting power = min(LP-stake-
     /// earned-mixed, DESNET balance). Cross-token reward claims still inflate first
     /// term but bound by DESNET balance.
-    /// v0.3.2 (F7): per-token DESNET-only rewards if RegistryByToken initialized,
-    /// fallback to legacy mixed `rewards_earned_30d` otherwise. Eliminates cross-token
-    /// inflation surface — voting power becomes strictly DESNET-LP-earned.
+    /// v0.3.3 (G1, R5 CONV-3 HIGH fix): per-USER fallback eliminates lazy-flip
+    /// disenfranchisement. Previous v0.3.2 logic checked GLOBAL `has_per_token_registry`
+    /// — first claimer post-v0.3.2 flipped the flag for everyone, instantly zeroing
+    /// voting_power for all other pre-existing voters until they claimed themselves.
+    /// New logic: per-user — read per-token if THIS voter has a per-token entry; else
+    /// fall back to legacy mixed for THIS voter. Each voter migrates individually
+    /// when they next claim. No cross-voter flip event.
     #[view]
     public fun voting_power(voter_addr: address): u64 acquires GovernanceState {
         let _ = borrow_global<GovernanceState>(@desnet);
         if (!aptos_framework::object::object_exists<aptos_framework::fungible_asset::Metadata>(DESNET_FA_ADDR))
             return 0;
-        let earned = if (voter_history::has_per_token_registry()) {
+        let earned = if (voter_history::has_per_token_entry(voter_addr)) {
             voter_history::rewards_earned_30d_for_token(voter_addr, DESNET_FA_ADDR)
         } else {
             voter_history::rewards_earned_30d(voter_addr)
diff --git a/sources/handle_fee_vault.move b/sources/handle_fee_vault.move
index bc9281a..9262552 100644
--- a/sources/handle_fee_vault.move
+++ b/sources/handle_fee_vault.move
@@ -27,12 +27,41 @@ module desnet::handle_fee_vault {
 
     const E_BELOW_THRESHOLD: u64 = 1;
     const E_VAULT_NOT_INITIALIZED: u64 = 2;
+    /// v0.3.3 (G3): old single-tx settle deprecated for MEV-safety. Use two-phase.
+    const E_USE_TWO_PHASE: u64 = 3;
+    const E_PENDING_SETTLE_NOT_FOUND: u64 = 4;
+    const E_PENDING_SETTLE_NOT_RIPE: u64 = 5;
+    const E_PENDING_SETTLE_EXPIRED: u64 = 6;
+    const E_PENDING_SETTLE_ALREADY_EXISTS: u64 = 7;
+
+    /// v0.3.3 (G3): commit-reveal delay parameters mirror R3 H3 fix on apt_vault.
+    /// 60s delay defeats single-tx sandwich (atomic same-tx grief impossible);
+    /// cross-tx pre-positioning bounded by 5% slippage tolerance baked at request.
+    /// Grace window: 600s before request expires (prevents stale baseline exploit).
+    const SETTLE_DELAY_SECS: u64 = 60;
+    const SETTLE_REQUEST_GRACE_SECS: u64 = 600;
+    const SETTLE_SLIPPAGE_BPS: u64 = 9500;
+    const BPS_FULL: u64 = 10000;
 
     struct HandleFeeVault has key {
         deployer_beneficiary: address,
         extend_ref: ExtendRef,
     }
 
+    /// v0.3.3 (G3 + S1 fix): two-phase commit-reveal settle state. Lives at `vault_addr()`.
+    /// All amounts LOCKED at request time — execute uses these (NOT current balance) so
+    /// (swap_amount, min_out) stay paired from same snapshot. Without this S1 fix, balance
+    /// growing during the 60s window would let attacker sandwich the larger swap with
+    /// trivially-satisfied stale min_out (anchored to smaller request-time amount).
+    /// Excess balance accrued during window stays in vault for next settle cycle.
+    struct PendingSettle has key, drop {
+        requested_at_secs: u64,
+        apt_balance_at_request: u64,
+        to_deployer_at_request: u64,
+        to_burn_at_request: u64,
+        min_desnet_out: u64,
+    }
+
     #[event]
     struct Settled has drop, store {
         total_apt: u64,
@@ -55,10 +84,14 @@ module desnet::handle_fee_vault {
         });
     }
 
+    /// v0.3.3 (G6, R5 Claude C8): added #[view] so frontend can call gas-free.
+    #[view]
     public fun vault_addr(): address {
         object::create_object_address(&@desnet, SEED_VAULT)
     }
 
+    /// v0.3.3 (G6): added #[view].
+    #[view]
     public fun vault_exists(): bool {
         exists<HandleFeeVault>(vault_addr())
     }
@@ -75,11 +108,30 @@ module desnet::handle_fee_vault {
         deposit_apt_fa(fa);
     }
 
-    /// 10% APT → deployer beneficiary, 90% APT → swap to DESNET → burn.
-    /// Permissionless. Requires DESNET handle registered (else swap aborts in amm).
+    /// v0.3.3 (G3, R5 CONV-1 MED-HIGH fix): old single-tx settle DEPRECATED for
+    /// MEV-safety. The original `min_out=0` swap was atomically sandwich-attackable;
+    /// any caller could front-run by skewing the AMM pool, trigger settle to swap
+    /// at unfavorable rate, then back-run to extract APT and leak protocol revenue.
+    /// Replaced by two-phase commit-reveal: `request_settle()` (records reserves
+    /// snapshot + 5% slippage min_out) → 60s delay → `execute_settle()` (enforces
+    /// pre-recorded min_out). Single-tx sandwich now structurally impossible;
+    /// cross-tx pre-positioning bounded by 5% baked tolerance.
+    /// Body kept (with abort) for compat preservation of `acquires HandleFeeVault`
+    /// annotation parity. Callers MUST switch to two-phase flow.
     public entry fun settle(_caller: &signer) acquires HandleFeeVault {
+        let _ = borrow_global<HandleFeeVault>(vault_addr());
+        abort E_USE_TWO_PHASE
+    }
+
+    /// v0.3.3 (G3): Phase 1 of MEV-safe settle. Records current pool quote +
+    /// 5% slippage tolerance. After SETTLE_DELAY_SECS, anyone can call
+    /// `execute_settle` to consume this snapshot. If cross-tx attacker shifts pool
+    /// >5% during the 60s window, execute_settle aborts (pool moved too far).
+    /// Pending settle expires after grace (cleanable via `cancel_pending_settle`).
+    public entry fun request_settle(_caller: &signer) acquires HandleFeeVault {
         let v_addr = vault_addr();
         assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
+        assert!(!exists<PendingSettle>(v_addr), E_PENDING_SETTLE_ALREADY_EXISTS);
 
         let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
         let total = primary_fungible_store::balance(v_addr, apt_meta);
@@ -88,22 +140,102 @@ module desnet::handle_fee_vault {
         let to_deployer = (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
         let to_burn = total - to_deployer;
 
+        // Quote DESNET-out for to_burn at current reserves; bake 5% slippage tolerance.
+        let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
+        let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;
+
+        let vault = borrow_global<HandleFeeVault>(v_addr);
+        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
+        move_to(&vault_signer, PendingSettle {
+            requested_at_secs: aptos_framework::timestamp::now_seconds(),
+            apt_balance_at_request: total,
+            to_deployer_at_request: to_deployer,
+            to_burn_at_request: to_burn,
+            min_desnet_out: min_out,
+        });
+    }
+
+    /// v0.3.3 (G3): Phase 2 of MEV-safe settle. Requires pending request from
+    /// at least SETTLE_DELAY_SECS ago, within grace window. Enforces baked min_out
+    /// — if pool moved >5% adversely since request, swap aborts (caller must
+    /// `cancel_pending_settle` and `request_settle` again at fresh reserves).
+    public entry fun execute_settle(_caller: &signer) acquires HandleFeeVault, PendingSettle {
+        let v_addr = vault_addr();
+        assert!(exists<HandleFeeVault>(v_addr), E_VAULT_NOT_INITIALIZED);
+        assert!(exists<PendingSettle>(v_addr), E_PENDING_SETTLE_NOT_FOUND);
+
+        let now = aptos_framework::timestamp::now_seconds();
+        let pending_ref = borrow_global<PendingSettle>(v_addr);
+        let requested_at = pending_ref.requested_at_secs;
+        let min_out = pending_ref.min_desnet_out;
+        assert!(now >= requested_at + SETTLE_DELAY_SECS, E_PENDING_SETTLE_NOT_RIPE);
+        assert!(now <= requested_at + SETTLE_DELAY_SECS + SETTLE_REQUEST_GRACE_SECS, E_PENDING_SETTLE_EXPIRED);
+
+        // S1 fix: extract LOCKED amounts from snapshot — do NOT recompute from current balance.
+        // Excess balance (current - apt_balance_at_request) stays in vault for next cycle.
+        let PendingSettle {
+            requested_at_secs: _,
+            apt_balance_at_request,
+            to_deployer_at_request,
+            to_burn_at_request,
+            min_desnet_out,
+        } = move_from<PendingSettle>(v_addr);
+
+        // Sanity check: vault must still have ≥ snapshot amount (vault has no withdraw path
+        // other than this fn, so balance can only grow via deposits — never shrink).
+        let apt_meta = object::address_to_object<Metadata>(APT_FA_ADDR);
+        let current_total = primary_fungible_store::balance(v_addr, apt_meta);
+        assert!(current_total >= apt_balance_at_request, E_BELOW_THRESHOLD);
+
         let vault = borrow_global<HandleFeeVault>(v_addr);
         let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
 
-        // 10% APT direct to deployer beneficiary primary store
-        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer);
+        let apt_for_deployer = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_deployer_at_request);
         primary_fungible_store::deposit(vault.deployer_beneficiary, apt_for_deployer);
 
-        // 90% APT swap to DESNET via amm pool → burn via DESNET apt_vault's BurnRef (delegation)
-        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn);
-        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, 0);
+        // 90% APT swap with min_out enforcement — sandwich-safe per snapshot.
+        // Swap amount AND min_out paired from same request snapshot — slippage check
+        // properly bounds the actual swap size (S1 fix vs anchor-mismatch bug).
+        let apt_for_burn_fa = primary_fungible_store::withdraw(&vault_signer, apt_meta, to_burn_at_request);
+        let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, min_desnet_out);
         let desnet_burned = fungible_asset::amount(&desnet_fa);
 
         let desnet_apt_vault = factory::vault_addr_of_handle(DESNET_HANDLE);
         apt_vault::burn_via_vault(desnet_apt_vault, desnet_fa);
 
-        event::emit(Settled { total_apt: total, to_deployer, desnet_burned });
+        // Settled.total_apt reflects snapshot amount actually settled (not current vault balance).
+        event::emit(Settled {
+            total_apt: apt_balance_at_request,
+            to_deployer: to_deployer_at_request,
+            desnet_burned,
+        });
+    }
+
+    /// v0.3.3 (G3): permissionless cancel of stale/grief'd pending settle. Cost = gas only.
+    /// Anyone can call to clear a stuck PendingSettle (e.g., griefer requested then
+    /// abandoned, blocking honest caller from new request_settle).
+    public entry fun cancel_pending_settle(_caller: &signer) acquires PendingSettle {
+        let v_addr = vault_addr();
+        if (exists<PendingSettle>(v_addr)) {
+            let _ = move_from<PendingSettle>(v_addr);
+        };
+    }
+
+    #[view]
+    public fun pending_settle_exists(): bool { exists<PendingSettle>(vault_addr()) }
+
+    #[view]
+    public fun pending_settle_executable_at_secs(): u64 acquires PendingSettle {
+        let v_addr = vault_addr();
+        if (!exists<PendingSettle>(v_addr)) return 0;
+        borrow_global<PendingSettle>(v_addr).requested_at_secs + SETTLE_DELAY_SECS
+    }
+
+    #[view]
+    public fun pending_settle_min_out(): u64 acquires PendingSettle {
+        let v_addr = vault_addr();
+        if (!exists<PendingSettle>(v_addr)) return 0;
+        borrow_global<PendingSettle>(v_addr).min_desnet_out
     }
 
     /// One-time poke: migrate stranded pre-upgrade fees from @desnet primary store.
diff --git a/sources/voter_history.move b/sources/voter_history.move
index 82dc361..e9425c9 100644
--- a/sources/voter_history.move
+++ b/sources/voter_history.move
@@ -269,9 +269,23 @@ module desnet::voter_history {
 
     /// v0.3.2 (F7): exists check — gates governance::voting_power's choice of
     /// per-token vs legacy-mixed read.
+    /// v0.3.3 (G1) NOTE: superseded for voting-power by per-USER `has_per_token_entry`
+    /// to fix lazy-flip disenfranchisement. Kept for indexer compatibility.
     #[view]
     public fun has_per_token_registry(): bool { exists<RegistryByToken>(@desnet) }
 
+    /// v0.3.3 (G1, R5 CONV-3 HIGH): per-USER existence check. Eliminates lazy-flip
+    /// disenfranchisement where the FIRST claimer post-v0.3.2 instantly zeroed
+    /// voting power for all OTHER pre-existing voters by triggering the global flag.
+    /// Returns true only when THIS voter has at least one per-token entry under any
+    /// token. Governance::voting_power should use this for per-user fallback to legacy.
+    #[view]
+    public fun has_per_token_entry(voter_addr: address): bool acquires RegistryByToken {
+        if (!exists<RegistryByToken>(@desnet)) return false;
+        let registry = borrow_global<RegistryByToken>(@desnet);
+        smart_table::contains(&registry.voters, voter_addr)
+    }
+
     /// Sum reward entries within last 30d window. Used as filter A in voting power.
     #[view]
     public fun rewards_earned_30d(voter_addr: address): u64 acquires Registry {
