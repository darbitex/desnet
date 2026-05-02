# DeSNet v0.3.2 — External Audit Report

**Auditor:** DeepSeek V3.2
**Date:** 2026-05-02
**Scope:** Full diff from R3 baseline to v0.3.2, plus ground-truth on-chain bytecode (MASM) for cross-verification
**Verdict:** **YELLOW** – One HIGH finding must be addressed before full production-signoff; all other changes are sound.

---

## Executive Summary

DeSNet v0.3.2 introduces 14 targeted fixes and a new buyback-burn vault. The upgrade is already live on Aptos mainnet at upgrade_number 4. The changes are largely well-engineered and address previously identified issues (F1–F14). However, a critical design flaw was discovered in the **emission auto-tracker's fallback logic** (F6/F6b) that could permanently brick DAO governance if the vestigial manual emission field was set to an extreme value before neutering. This issue is currently latent but must be corrected in a subsequent upgrade. All other changes are correctly implemented and match their descriptions.

---

## Detailed Findings

### 1. F6 – 30-Day Emission Auto-Tracker & Vestigial Field Dependency (HIGH)

**Location:** `governance::effective_30d_emission()`, `governance::total_30d_emission_auto()`, `governance::GovernanceState.total_30d_emission`

**Description:**
The auto-tracker correctly records daily lp_staking emissions into a rolling 30-day bucket. However, the function `effective_30d_emission()` computes `max(auto_tracked, manual)`, where `manual` is the value stored in `GovernanceState.total_30d_emission`. The manual setter (`update_total_30d_emission`) was neutered in this same upgrade, but its **pre-existing value persists**. If that value is large enough to cause an overflow in the threshold/quorum calculations (`proposal_threshold_amount` = `(eff * 500) / 10000`), any call to `propose_upgrade` or `ratify` will abort due to runtime overflow. A malicious multisig could have set `total_30d_emission` to `u64::MAX` immediately before deploying v0.3.2, then disabled itself, permanently freezing DAO governance with no recovery path.

**Current State:**
The deployed mainnet state shows `total_30d_emission` was not maliciously manipulated (threshold calculations succeeded post-deploy). However, the vulnerability remains latent; any future re-deployment or fork that carries the same design could be exploited.

**Recommendation:**
Effective immediately (via next upgrade), replace `effective_30d_emission()` with a sole reliance on `total_30d_emission_auto()`. The vestigial `total_30d_emission` field must be completely ignored. If a transition period is desired, cap the manual component at a safe maximum (e.g., `1_000_000_000 * 10^8` to avoid overflow in multiplication).

**Severity: HIGH**
*Exploitation potential: permanent DoS of DAO governance.*

### 2. F9 – handle_fee_vault: Slippage Risk on Permissionless Settle (LOW)

**Location:** `handle_fee_vault::settle`

**Description:**
The `settle` function swaps 90% of accumulated APT to DESNET via `amm::swap_exact_apt_in` with **`min_out = 0`**. While the function is permissionless and intended to be called frequently, a front-running attacker could manipulate the AMM pool to extract value before the swap, reducing the amount of DESNET burned. The risk is partially mitigated by the pool's depth and the ability for anyone to call settle at any time, but no slippage protection exists.

**Recommendation:**
Consider adding a configurable `min_out` parameter or a time-weighted average price oracle to bound the acceptable price. Alternatively, accept the risk as a known de-minimis loss that does not justify gas overhead for MEV protection.

**Severity: LOW**

### 3. F7 – Dual-Write Pattern & Legacy Fallback (INFO / MED)

**Location:** `voter_history::record_reward_received_for_token`, `governance::voting_power`

**Observation:**
The dual-write pattern correctly records rewards to both the legacy mixed `Registry` and the new per-token `RegistryByToken`. The voting power function switches to the per-token source once `RegistryByToken` is initialized (lazy-init on first claim).
This design is safe; there is no double-counting because voting power uses only one source. The legacy Registry remains for backward-compatible queries only. The transition is seamless — after the first post-upgrade claim, voting power becomes strictly DESNET-based. No HIGH finding.

**Severity: INFO**

### 4. F8 – DAO Chunked Upgrade Atomicity (INFO)

**Location:** `governance::dao_publish_chunked_upgrade`

**Observation:**
The hash verification against `proposal.new_module_bytes_hash` is sound, and the `executed_at_secs` is set **before** `code::publish_package_txn`. This is atomic: if the publish aborts, the whole transaction reverts, so there is no risk of marking a proposal executed without a successful upgrade.
The limitation that only one chunked upgrade can be staged at a time (single `UpgradeStaging` resource) is a known design constraint and not a security issue.

**Severity: INFO**

### 5. Other Fixes (F1–F5, F10, F14) – VERIFIED

All remaining fixes have been cross-verified against the on-chain bytecode (MASM) and are implemented exactly as described in the submission:

- **F1/F1b:** View-function error codes corrected; `handle_of_wallet` added correctly in profile.
- **F2:** Empty-chunk guard added with `E_INCOMPLETE_CHUNKS`.
- **F3:** `UpgradeStagingCleanup` event emitted.
- **F4b/c:** `#[view]` annotation and companion views added.
- **F5:** Actor-aware swap variants added; entry functions route through them.
- **F10:** `update_fee_receiver` correctly neutered; fee routing uses `handle_fee_vault`.
- **F14:** Target address asserts at propose and execute.

No discrepancies between source diff and deployed bytecode were detected for these items.

---

## Verdict Summary

| Finding | Severity | Status |
|---------|----------|--------|
| Vestigial emission field can brick governance | **HIGH** | Must fix in next upgrade |
| handle_fee_vault zero `min_out` | LOW | Acceptable risk, but improved |
| All other changes | — | Verified correct |

**Overall Verdict:** **YELLOW** – The upgrade is safe for current state, but the HIGH finding poses a latent systemic risk that must be mitigated before a full production-stability signoff.

**Acceptance criteria alignment:** With one unfixed HIGH, the deployment does not yet meet the ≥4/6 GREEN + no unfixed HIGH bar. A follow-up patch upgrade that unconditionally ignores the vestigial emission field would resolve the sole blocking issue.
