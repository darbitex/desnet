# DeSNet v0.3.3 — External Audit Report (R6) — Qwen 3 Max

**Verdict:** 🟡 **YELLOW** (Conditional Pass)
**Risk:** **HIGH** finding in G1 (Voting Power Disenfranchisement for Multi-Pool Stakers).
**Status:** Requires patch to G1 logic before deployment. Other fixes (G2-G7, S1) are correctly implemented.

---

## 🔴 HIGH FINDINGS

### H1: G1 Logic Flaw — Voting Power Collapse for Voters Claiming Non-DESNET Tokens

**Affected Module:** `voter_history.move`, `governance.move`
**Severity:** HIGH

**Description:**
The G1 fix introduces `voter_history::has_per_token_entry(voter_addr)` to solve the lazy-flip mass disenfranchisement from v0.3.2. The function checks if the voter has *any* entry in the outer `RegistryByToken` smart table, and `governance::voting_power` uses this boolean to switch from legacy reads to per-token reads:
```move
let earned = if (voter_history::has_per_token_entry(voter_addr)) {
    voter_history::rewards_earned_30d_for_token(voter_addr, DESNET_FA_ADDR)
} else {
    voter_history::rewards_earned_30d(voter_addr)
};
```
However, `lp_staking::claim_internal` calls `record_reward_received_for_token` for **every pool's specific token**:
```move
voter_history::record_reward_received_for_token(&pkg_signer, recipient, pool.token_metadata_addr, actual_paid);
```
This dual-write creates an outer `RegistryByToken` entry for the voter as soon as they claim rewards from *any* token (e.g., an `alice` token pool).

**Impact:**
1. A voter with significant legacy `Registry` rewards but who has only ever claimed rewards from a *non-DESNET* pool will have `has_per_token_entry == true`.
2. `voting_power` forces them into the per-token branch and queries `rewards_earned_30d_for_token(voter, DESNET_FA_ADDR)`.
3. No DESNET-specific inner entry → returns `0`.
4. Their legacy rewards (still being correctly written!) are completely ignored, instantly zeroing their governance voting power.
5. **This disenfranchises active LP stakers of any ecosystem token other than DESNET, defeating the intent of the G1 fix.**

**Recommendation:**
Change the check to be DESNET-specific rather than generic "has any entry":
- **Option A (Preferred):** Add new view `has_per_token_entry_for_token(voter_addr, token_addr): bool` and use `DESNET_FA_ADDR` in `voting_power`.
- **Option B (Fallback):** Keep current check, but if `rewards_earned_30d_for_token` returns 0, gracefully fall back to `rewards_earned_30d(voter_addr)`.

A voter should only lose legacy voting power once they actually have a DESNET reward entry.

---

## 🟡 MEDIUM FINDINGS

### M1: Semantic Error Code Reuse in `handle_fee_vault`

**Affected:** `handle_fee_vault.move`
**Severity:** MED

In `execute_settle`, the assertion `assert!(current_total >= apt_balance_at_request, E_BELOW_THRESHOLD);` reuses `E_BELOW_THRESHOLD` (defined as "Min APT balance for settle (anti-dust). 0.1 APT"). In context it actually means `E_VAULT_SHRUNK_BELOW_SNAPSHOT`. Functionally safe but misleads off-chain monitors.

**Recommendation:** Distinct error code (e.g., `E_VAULT_SHRUNK = 8`).

### M2: `dao_stage_chunks_into_staging` Proposal-Switch Griefing (S3 Confirmation)

**Affected:** `governance.move`
**Severity:** MED

Confirms self-audit S3. Pure DoS, asymmetric grief.

**Recommendation:** Accepted as known tradeoff for v0.3.3. v0.3.4 should implement per-proposal isolated storage.

---

## 🟢 LOW / INFO FINDINGS

### L1: `effective_30d_emission` Retains Unused `acquires`

**Severity:** INFO. Intentional for ABI annotation parity. Zero security impact.

---

## ✅ POSITIVE OBSERVATIONS

1. **S1 Fix (G3 + Handle Fee Vault):** Self-audit bug correctly fixed. PendingSettle locks all amounts. Sandwich attack prevented.
2. **G2 DAO Chunked Isolation:** New DaoUpgradeStaging cleanly separates DAO from multisig. Stager-lock + auto-reset effective.
3. **G4 Vestigial Overflow Neutralization:** Manual field permanently ignored. Latent overflow closed.
4. **AMM Slippage Enforcement:** `swap_exact_apt_in_actor` correctly asserts `amount_out >= min_out` before fund movements. Atomic + strict.
5. **No Regressions:** v0.3.2 functionality intact. ABI strictly additive.

---

## 📝 FINAL RECOMMENDATION

**Do not merge/deploy v0.3.3 as-is.**

The **H1** finding is a critical logic error that will silently disenfranchise active LP stakers of non-DESNET pools. Must be patched to use DESNET-specific existence check.

**Required Action:**
1. Implement Option A from H1 recommendations (per-token DESNET-specific check)
2. Optionally apply M1 (new error code) for monitoring clarity
3. Re-verify `voting_power` with test case: user with legacy DESNET rewards + newly claimed non-DESNET rewards
