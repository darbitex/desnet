# DeSNet v0.3.0 R2 — Patch Diff (R1 → R2)

**Companion to `AUDIT-DESNET-V030-R2-SUBMISSION.md`.**

Diff between `v0.3.0-mainnet-baseline` (R1 audit submission) and `v0.3.0-mainnet-baseline-r2` (post-R1 fix patch). 486 lines changed across 6 source files + Move.toml.

Apply this diff to the R1 source tree to reproduce the R2 state.

```diff
diff --git a/Move.toml b/Move.toml
index 13de6e0..d2ab3da 100644
--- a/Move.toml
+++ b/Move.toml
@@ -1,6 +1,6 @@
 [package]
 name = "Desnet"
-version = "0.3.0"
+version = "0.3.0-r2"
 upgrade_policy = "compatible"
 authors = ["Rera", "Claude (Anthropic)"]
 license = "Unlicense"
diff --git a/sources/amm.move b/sources/amm.move
index e8565f6..1f0cc67 100644
--- a/sources/amm.move
+++ b/sources/amm.move
@@ -258,12 +258,15 @@ module desnet::amm {
 
     // ============ ADD LIQUIDITY (FRIEND, called by lp_staking) ============
 
+    /// M1 fix (audit R1): returns (lp_minted, apt_refund_fa, token_refund_fa).
+    /// Caller (lp_staking) deposits refund FAs back to user. Uniswap V2 pattern —
+    /// prevents naive callers from gifting surplus to existing LPs on ratio mismatch.
     public(friend) fun add_liquidity_internal(
         handle: vector<u8>,
         apt_in: FungibleAsset,
         token_in: FungibleAsset,
         min_lp_out: u64,
-    ): u128 acquires Pool {
+    ): (u128, FungibleAsset, FungibleAsset) acquires Pool {
         let pool_addr = pool_address_of_handle(handle);
         assert!(exists<Pool>(pool_addr), E_POOL_NOT_FOUND);
 
@@ -289,6 +292,23 @@ module desnet::amm {
         assert!(lp_minted > 0, E_INSUFFICIENT_LIQUIDITY);
         assert!(lp_minted >= (min_lp_out as u128), E_SLIPPAGE_EXCEEDED);
 
+        // M1: compute optimal pair from lp_minted; refund surplus from over-funded side.
+        let optimal_apt = (lp_minted * (apt_reserve_amt as u128)) / pool.lp_supply;
+        let optimal_token = (lp_minted * (token_reserve_amt as u128)) / pool.lp_supply;
+        let apt_surplus = (apt_amount as u128) - optimal_apt;
+        let token_surplus = (token_amount as u128) - optimal_token;
+
+        let apt_refund = if (apt_surplus > 0) {
+            fungible_asset::extract(&mut apt_in, (apt_surplus as u64))
+        } else {
+            fungible_asset::zero(apt_meta)
+        };
+        let token_refund = if (token_surplus > 0) {
+            fungible_asset::extract(&mut token_in, (token_surplus as u64))
+        } else {
+            fungible_asset::zero(token_meta)
+        };
+
         fungible_asset::deposit(pool.apt_reserve, apt_in);
         fungible_asset::deposit(pool.token_reserve, token_in);
         pool.lp_supply = pool.lp_supply + lp_minted;
@@ -296,15 +316,15 @@ module desnet::amm {
         event::emit(LiquidityAdded {
             handle: pool.handle,
             pool_addr,
-            apt_in: apt_amount,
-            token_in: token_amount,
+            apt_in: apt_amount - (apt_surplus as u64),
+            token_in: token_amount - (token_surplus as u64),
             lp_minted,
             new_apt_reserve: fungible_asset::balance(pool.apt_reserve),
             new_token_reserve: fungible_asset::balance(pool.token_reserve),
             new_lp_supply: pool.lp_supply,
         });
 
-        lp_minted
+        (lp_minted, apt_refund, token_refund)
     }
 
     // ============ REMOVE LIQUIDITY (FRIEND) ============
@@ -817,7 +837,16 @@ module desnet::amm {
         token_in: FungibleAsset,
         min_lp_out: u64,
     ): u128 acquires Pool {
-        add_liquidity_internal(handle, apt_in, token_in, min_lp_out)
+        let (lp, apt_refund, token_refund) =
+            add_liquidity_internal(handle, apt_in, token_in, min_lp_out);
+        // Tests don't care about refunds; destroy them
+        if (fungible_asset::amount(&apt_refund) > 0) {
+            primary_fungible_store::deposit(@desnet, apt_refund);
+        } else { fungible_asset::destroy_zero(apt_refund) };
+        if (fungible_asset::amount(&token_refund) > 0) {
+            primary_fungible_store::deposit(@desnet, token_refund);
+        } else { fungible_asset::destroy_zero(token_refund) };
+        lp
     }
 
     #[test_only]
diff --git a/sources/apt_vault.move b/sources/apt_vault.move
index 1c968f7..e9a7935 100644
--- a/sources/apt_vault.move
+++ b/sources/apt_vault.move
@@ -33,12 +33,19 @@ module desnet::apt_vault {
 
     const SEED_VAULT: vector<u8> = b"vault::";
 
+    /// H3 fix (audit R1): slippage tolerance for settle buyback.
+    /// 300 bps = 3% — bounds single-tx sandwich loss. Larger drift = abort,
+    /// settle re-callable later when pool recovers.
+    const SETTLE_SLIPPAGE_BPS: u64 = 300;
+    const BPS_DENOM: u64 = 10000;
+
     // ============ ERROR CODES ============
 
     const E_BELOW_THRESHOLD: u64 = 1;
     const E_VAULT_NOT_FOUND: u64 = 2;
     const E_SWAP_FAILED: u64 = 3;
     const E_BURN_FAILED: u64 = 4;
+    const E_POOL_ADDR_DRIFT: u64 = 5;
 
     // ============ TYPES ============
 
@@ -134,11 +141,20 @@ module desnet::apt_vault {
     // ============ SETTLE — permissionless ============
 
     /// Always 50/50 (pool always seeded atomically at register_handle).
+    /// H3 fix (audit R1): swap uses 3% slippage tolerance to bound sandwich attacks.
+    /// M5 fix: assert cached amm_pool_addr matches current handle-derived addr.
     public entry fun settle(
         _caller: &signer,
         vault_addr: address,
     ) acquires Vault {
         let vault = borrow_global_mut<Vault>(vault_addr);
+
+        // M5: cache consistency check
+        assert!(
+            amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
+            E_POOL_ADDR_DRIFT
+        );
+
         let total_apt = coin::value(&vault.apt_balance);
         assert!(total_apt >= APT_SETTLE_THRESHOLD, E_BELOW_THRESHOLD);
 
@@ -148,6 +164,11 @@ module desnet::apt_vault {
         let buyback_amount = total_apt / 2;
         let owner_amount = total_apt - buyback_amount;
 
+        // H3: compute expected output + apply 3% tolerance as min_out.
+        let (apt_reserve, token_reserve) = amm::reserves(vault.handle);
+        let expected_out = amm::compute_amount_out(apt_reserve, token_reserve, buyback_amount);
+        let min_out = (expected_out * (BPS_DENOM - SETTLE_SLIPPAGE_BPS)) / BPS_DENOM;
+
         let apt_for_buyback = coin::extract(&mut vault.apt_balance, buyback_amount);
         let apt_for_owner = coin::extract(&mut vault.apt_balance, owner_amount);
 
@@ -156,7 +177,7 @@ module desnet::apt_vault {
         let token_received = amm::swap_exact_apt_in(
             vault.handle,
             apt_fa_buyback,
-            0,
+            min_out,
         );
         let burned_amount = fungible_asset::amount(&token_received);
         fungible_asset::burn(&vault.burn_ref, token_received);
diff --git a/sources/factory.move b/sources/factory.move
index 16a4f35..f9c824c 100644
--- a/sources/factory.move
+++ b/sources/factory.move
@@ -66,6 +66,7 @@ module desnet::factory {
     const E_FACTORY_PAUSED: u64 = 8;
     const E_PID_NOT_REGISTERED: u64 = 10;
     const E_INVALID_POOL_SEED_APT: u64 = 12;
+    const E_NOT_ADMIN: u64 = 13;
 
     // ============ TYPES ============
 
@@ -402,6 +403,13 @@ module desnet::factory {
         borrow_global<FactoryState>(@desnet).paused
     }
 
+    /// Kimi F2 fix (audit R1): admin pause/unpause control. @origin-only.
+    /// Without this, paused=true was a one-way kill-switch with no recovery.
+    public entry fun set_paused(admin: &signer, new_paused: bool) acquires FactoryState {
+        assert!(signer::address_of(admin) == @origin, E_NOT_ADMIN);
+        borrow_global_mut<FactoryState>(@desnet).paused = new_paused;
+    }
+
     #[view]
     public fun vault_addr_of_pid(pid_addr: address): address acquires FactoryRegistry {
         let registry = borrow_global<FactoryRegistry>(@desnet);
diff --git a/sources/governance.move b/sources/governance.move
index 83257b1..609f2ab 100644
--- a/sources/governance.move
+++ b/sources/governance.move
@@ -28,8 +28,11 @@
 ///   - Voting period: 7 days
 ///   - Timelock post-approval: 30 days
 module desnet::governance {
+    use std::bcs;
+    use std::hash;
     use std::option::{Self, Option};
     use std::signer;
+    use std::vector;
     use aptos_framework::account::{Self, SignerCapability};
     use aptos_framework::code;
     use aptos_framework::event;
@@ -67,6 +70,9 @@ module desnet::governance {
     const E_NOT_MULTISIG: u64 = 15;
     const E_ALREADY_EXECUTED: u64 = 16;
     const E_ALREADY_RATIFIED: u64 = 17;
+    const E_HASH_MISMATCH: u64 = 18;
+    const E_MULTISIG_DISABLED: u64 = 19;
+    const E_INVALID_ADDRESS: u64 = 20;
 
     // ============ TYPES ============
 
@@ -81,6 +87,9 @@ module desnet::governance {
         // 30d emission estimate (denominator for threshold/quorum).
         // 0 = NOT YET CONFIGURED (proposals can't be submitted).
         total_30d_emission: u64,
+        // M2 fix (audit R1): one-way switch to disable multisig_upgrade backdoor.
+        // Set true via `disable_multisig_upgrade` once DAO is trusted; never reversible.
+        multisig_upgrade_disabled: bool,
     }
 
     struct Proposal has store {
@@ -152,6 +161,12 @@ module desnet::governance {
         timestamp_secs: u64,
     }
 
+    #[event]
+    struct MultisigUpgradeDisabled has drop, store {
+        disabled_by: address,
+        timestamp_secs: u64,
+    }
+
     // ============ INIT — called by resource_account at deploy ============
 
     fun init_module(account: &signer) {
@@ -164,6 +179,7 @@ module desnet::governance {
             proposals: smart_table::new(),
             desnet_fa_metadata: @0x0,
             total_30d_emission: 0,
+            multisig_upgrade_disabled: false,
         });
 
         // Initialize centralized voter_history Registry at @desnet.
@@ -191,12 +207,18 @@ module desnet::governance {
     /// Multisig (@origin) directly upgrades the package without a DAO vote.
     /// Used pre-PMF while the team iterates rapidly. Off-chain: simply stop
     /// calling this once DAO is trusted.
+    /// M2 fix (audit R1): callable only while `multisig_upgrade_disabled == false`.
+    /// Use `disable_multisig_upgrade` for irreversible on-chain renouncement.
     public entry fun multisig_upgrade(
         multisig: &signer,
         metadata: vector<u8>,
         code_bytes: vector<vector<u8>>,
     ) acquires GovernanceState {
         assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        assert!(
+            !borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled,
+            E_MULTISIG_DISABLED
+        );
 
         let pkg_signer = derive_pkg_signer();
         code::publish_package_txn(&pkg_signer, metadata, code_bytes);
@@ -207,6 +229,17 @@ module desnet::governance {
         });
     }
 
+    /// One-way switch to permanently renounce the multisig backdoor.
+    /// After this, the only upgrade path is the full DAO flow. NOT REVERSIBLE.
+    public entry fun disable_multisig_upgrade(multisig: &signer) acquires GovernanceState {
+        assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
+        borrow_global_mut<GovernanceState>(@desnet).multisig_upgrade_disabled = true;
+        event::emit(MultisigUpgradeDisabled {
+            disabled_by: signer::address_of(multisig),
+            timestamp_secs: timestamp::now_seconds(),
+        });
+    }
+
     // ============ DAO-PHASE PROPOSAL LIFECYCLE ============
 
     public entry fun propose_upgrade(
@@ -214,6 +247,11 @@ module desnet::governance {
         target_package_addr: address,
         new_module_bytes_hash: vector<u8>,
     ) acquires GovernanceState {
+        // Kimi F4 fix (audit R1): require DAO config before accepting proposals.
+        let cfg = borrow_global<GovernanceState>(@desnet);
+        assert!(cfg.desnet_fa_metadata != @0x0, E_NOT_INITIALIZED);
+        assert!(cfg.total_30d_emission > 0, E_NOT_INITIALIZED);
+
         let proposer_addr = signer::address_of(proposer);
         let proposer_power = voting_power(proposer_addr);
         assert!(proposer_power >= proposal_threshold_amount(), E_INSUFFICIENT_VOTING_POWER);
@@ -329,15 +367,23 @@ module desnet::governance {
     }
 
     /// Execute approved proposal after timelock expires. Calls
-    /// `code::publish_package_txn` directly with the derived package signer —
-    /// monolith means there's only one target (@desnet), no per-package dispatch.
+    /// `code::publish_package_txn` with the derived package signer.
+    ///
+    /// H1 fix (audit R1): the executor MUST submit metadata + code_bytes whose
+    /// digest matches `proposal.new_module_bytes_hash` recorded at propose time.
+    /// Without this check, executor can ship arbitrary code post-timelock — full
+    /// DAO bypass. Digest scheme: sha3_256(bcs(metadata) ++ concat(bcs(code_bytes[i])))
+    /// — `propose_upgrade` callers MUST use the same scheme to compute their hash.
     public entry fun execute_proposal(
         caller: &signer,
         proposal_id: u64,
         metadata: vector<u8>,
         code_bytes: vector<vector<u8>>,
     ) acquires GovernanceState {
-        // Derive pkg signer FIRST (acquires GovernanceState) before mut-borrow below.
+        // Compute digest BEFORE deriving pkg_signer (deterministic on inputs).
+        let submitted_digest = compute_upgrade_digest(&metadata, &code_bytes);
+
+        // Derive pkg signer (acquires GovernanceState) before mut-borrow below.
         let pkg_signer = derive_pkg_signer();
 
         let target_package_addr;
@@ -354,6 +400,9 @@ module desnet::governance {
             let now = timestamp::now_seconds();
             assert!(now >= approved_at + TIMELOCK_SECS, E_TIMELOCK_NOT_EXPIRED);
 
+            // Verify submitted code matches what voters approved.
+            assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);
+
             proposal.executed_at_secs = option::some(now);
             target_package_addr = proposal.target_package_addr;
         };
@@ -368,6 +417,24 @@ module desnet::governance {
         });
     }
 
+    /// Canonical digest of upgrade payload. Used by both `propose_upgrade` (off-chain
+    /// callers compute this on the intended payload) and `execute_proposal` (verifies
+    /// submitted bytes match). Scheme: sha3_256(bcs(metadata) || concat(bcs(code_bytes[i]))).
+    public fun compute_upgrade_digest(
+        metadata: &vector<u8>,
+        code_bytes: &vector<vector<u8>>,
+    ): vector<u8> {
+        let buf = bcs::to_bytes(metadata);
+        let i = 0;
+        let n = vector::length(code_bytes);
+        while (i < n) {
+            let chunk_bcs = bcs::to_bytes(vector::borrow(code_bytes, i));
+            vector::append(&mut buf, chunk_bcs);
+            i = i + 1;
+        };
+        hash::sha3_256(buf)
+    }
+
     // ============ VIEWS ============
 
     /// voting_power = min(rewards_earned_30d, current DESNET balance).
@@ -483,6 +550,7 @@ module desnet::governance {
             proposals: smart_table::new(),
             desnet_fa_metadata: @0x0,
             total_30d_emission: 0,
+            multisig_upgrade_disabled: false,
         });
         voter_history::init_registry(&desnet_signer);
     }
diff --git a/sources/lp_staking.move b/sources/lp_staking.move
index de366ee..9072480 100644
--- a/sources/lp_staking.move
+++ b/sources/lp_staking.move
@@ -269,9 +269,20 @@ module desnet::lp_staking {
         let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
         let token_fa = primary_fungible_store::withdraw(caller, token_meta, token_amount);
 
-        // Mint LP shares via amm
-        let lp_minted = amm::add_liquidity_internal(handle, apt_fa, token_fa, min_lp_out);
+        // Mint LP shares via amm. M1 fix (audit R1): refund surplus on ratio mismatch.
+        let (lp_minted, apt_refund, token_refund) =
+            amm::add_liquidity_internal(handle, apt_fa, token_fa, min_lp_out);
         assert!(lp_minted > 0, E_ZERO_SHARES);
+        if (fungible_asset::amount(&apt_refund) > 0) {
+            primary_fungible_store::deposit(caller_addr, apt_refund);
+        } else {
+            fungible_asset::destroy_zero(apt_refund);
+        };
+        if (fungible_asset::amount(&token_refund) > 0) {
+            primary_fungible_store::deposit(caller_addr, token_refund);
+        } else {
+            fungible_asset::destroy_zero(token_refund);
+        };
 
         // Update emission accumulator BEFORE snapshotting position
         update_pool(pool_addr);
@@ -409,7 +420,10 @@ module desnet::lp_staking {
         // 3. Resolve recipient
         let recipient = resolve_recipient(position.recipient_pid, position_addr);
 
-        // 4. Pull emission ($TOKEN) from lp_emission reserve
+        // 4. Pull emission ($TOKEN) from lp_emission reserve.
+        //    H2 fix (audit R1): record voting power for ACTUAL paid amount, not requested.
+        //    pull_for_claim caps at reserve balance (graceful depletion); recording
+        //    pending_emission would inflate voting power post-depletion at zero cost.
         if (pending_emission > 0) {
             let token_meta = object::address_to_object<Metadata>(pool.token_metadata_addr);
             let emission_fa = lp_emission::pull_for_claim(
@@ -417,11 +431,13 @@ module desnet::lp_staking {
                 token_meta,
                 pending_emission,
             );
+            let actual_paid = fungible_asset::amount(&emission_fa);
             primary_fungible_store::deposit(recipient, emission_fa);
 
-            // Voting power
-            let pkg_signer = governance::derive_pkg_signer();
-            voter_history::record_reward_received(&pkg_signer, recipient, pending_emission);
+            if (actual_paid > 0) {
+                let pkg_signer = governance::derive_pkg_signer();
+                voter_history::record_reward_received(&pkg_signer, recipient, actual_paid);
+            };
         };
 
         // 5. Pull LP fees (APT + TOKEN)
diff --git a/sources/profile.move b/sources/profile.move
index 080f2ce..c7212c9 100644
--- a/sources/profile.move
+++ b/sources/profile.move
@@ -83,6 +83,7 @@ module desnet::profile {
     const E_NOT_CONTROLLER_OR_OWNER: u64 = 15;
     const E_SYNC_GATE_ALREADY_SET: u64 = 16;
     const E_RESERVED_HANDLE: u64 = 17;
+    const E_INVALID_ADDRESS: u64 = 18;
 
     // ============ TYPES ============
 
@@ -232,6 +233,8 @@ module desnet::profile {
         admin: &signer,
         new_fee_receiver: address,
     ) acquires ProtocolState {
+        // Gemini MED fix (audit R1): zero-addr check.
+        assert!(new_fee_receiver != @0x0, E_INVALID_ADDRESS);
         let state = borrow_global_mut<ProtocolState>(@desnet);
         assert!(signer::address_of(admin) == state.admin, E_NOT_ADMIN);
         state.fee_receiver = new_fee_receiver;
@@ -242,6 +245,8 @@ module desnet::profile {
         current_admin: &signer,
         new_admin: address,
     ) acquires ProtocolState {
+        // Gemini MED fix (audit R1): zero-addr check.
+        assert!(new_admin != @0x0, E_INVALID_ADDRESS);
         let state = borrow_global_mut<ProtocolState>(@desnet);
         assert!(signer::address_of(current_admin) == state.admin, E_NOT_ADMIN);
         state.admin = new_admin;
diff --git a/sources/voter_history.move b/sources/voter_history.move
index 3cd1b6c..4677abb 100644
--- a/sources/voter_history.move
+++ b/sources/voter_history.move
@@ -21,6 +21,7 @@ module desnet::voter_history {
     use aptos_std::smart_table::{Self, SmartTable};
 
     friend desnet::governance;
+    friend desnet::lp_staking;
 
     // ============ CONSTANTS ============
 
@@ -102,15 +103,18 @@ module desnet::voter_history {
         });
     }
 
-    // ============ RECORD — called by factory::lp_emission only ============
+    // ============ RECORD — called EXCLUSIVELY by desnet::lp_staking::claim_internal ============
 
-    /// Cross-package callable. Authenticated via signer addr check:
-    /// caller MUST be @desnet (lp_emission obtains factory_signer via
-    /// factory::derive_factory_signer friend helper).
+    /// SOLE pathway for voting power generation. Friend-restricted to lp_staking
+    /// (load-bearing barrier). The signer.addr == @desnet assertion is belt-and-braces.
     ///
-    /// Lazy-creates voter entry in centralized Registry if missing
-    /// (no voter signer required — pkg authority writes to centralized storage).
-    public fun record_reward_received(
+    /// H4 fix (audit R1): visibility tightened from `public` to `public(friend)`.
+    /// Previously, sole-call-site invariant was grep-enforced not type-enforced;
+    /// any future code with @desnet pkg_signer access could mint voting power.
+    /// Now any new caller requires explicit `friend` declaration in this file.
+    ///
+    /// Lazy-creates voter entry in centralized Registry if missing.
+    public(friend) fun record_reward_received(
         factory_authority: &signer,
         voter_addr: address,
         amount: u64,
```
