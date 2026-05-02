# DeSNet v0.3.2 — External Audit Report (R5) — Qwen 3 Max

**Verdict:** 🟡 **YELLOW** (Conditional Pass)
**Risk:** **HIGH** finding in F7 (Voting Power Transition Logic).
**Status:** Production stability requires a patch or specific operational awareness for the F7 issue.

---

## 🔴 HIGH FINDINGS

### H1: Governance Voting Power Collapse on Transition (F7)

**Affected Module:** `governance.move`, `voter_history.move`
**Severity:** HIGH

**Description:** The `voting_power` function determines a voter's power based on the existence of the global `RegistryByToken` resource. The `RegistryByToken` is **lazy-initialized** on the first call to `record_reward_received_for_token` (triggered by `lp_staking::claim`).

**Impact:**
1. Before First Claim: registry doesn't exist; all voters use legacy `rewards_earned_30d` (mixed tokens).
2. First Claim by *Any* User: `RegistryByToken` resource created globally.
3. The `if` condition switches to `true` for **all** voters instantly.
4. Any voter with legacy rewards but no claim since upgrade has no entry in the new per-token registry. Their `rewards_earned_30d_for_token` returns `0`.
5. Voting power collapses to `min(0, balance)`. The first claimer (or attacker) can trigger this switch, stripping voting power from inactive but legitimate voters.

**Recommendation:**
- Option A: `if (voter_history::has_per_token_entry(voter_addr)) { use per-token } else { use legacy }` — per-user check
- Option B: Migrate existing rewards to new structure during privileged upgrade step
- Option C: Grace period or manual DAO toggle to switch global state only after sufficient migration time

---

## 🟡 MEDIUM FINDINGS

### M1: DAO Chunked Upgrade Staging Collision/Griefing (F8)

**Affected Module:** `governance.move`
**Severity:** MED

**Description:** `UpgradeStaging` is a singleton stored at `@desnet`. `dao_stage_upgrade_chunk` appends metadata and code chunks. No isolation: doesn't verify staging belongs to current proposal_id. Append logic uses `vector::append` blindly.

**Impact:** If two DAO upgrades stage concurrently (or malicious actor front-runs legitimate staging), chunks interleave. `dao_publish_chunked_upgrade` hash verification fails. Abort & drop: `UpgradeStaging` has `drop` ability, all staged chunks lost. Result: DAO upgrade DoS — proposer must re-stage with new gas.

**Recommendation:** Store `proposal_id` inside `UpgradeStaging` struct + assert match. Alternatively use deterministic object address derived from proposal_id for staging isolation.

### M2: Handle Fee Vault Swap Slippage Risk (F9)

**Affected Module:** `handle_fee_vault.move`
**Severity:** MED

**Description:** `settle` swaps 90% of accumulated APT for DESNET via `amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, 0)`. `min_out` hardcoded to `0`.

**Impact:** Permissionless settle with zero slippage protection — sandwich-attackable. Attacker manipulates pool price before settle tx → 90% portion receives significantly fewer DESNET. 10% deployer cut is fixed in APT, so loss entirely absorbed by burn amount. Reduces deflationary efficiency. Thin liquidity scenarios make this worse.

**Recommendation:** Compute `min_out` based on spot price reserves (e.g., 95-99% of expected output) or allow `min_out` parameter. Document trade-off if accepting permissionless trade-off.

---

## 🟢 LOW / INFO FINDINGS

### L1: Migration of Non-Fee Funds (F9 Wiring)
`migrate_legacy_fees` sweeps **all** APT from `@desnet` primary store. If admins accidentally send operational APT, swept and 90% burned. Low risk if procedures sound, but irreversible.

### L2: UpgradeStaging Singleton Constraint (F8)
Only one `UpgradeStaging` at a time. Prevents concurrent proposal staging. Acceptable — DAOs usually serialize upgrades.

### L3: Error Code Distinctness
`E_NEUTERED=22` in governance, `=19` in profile. No overlaps. `E_INCOMPLETE_CHUNKS=23`. All distinct. Good hygiene.

---

## ✅ POSITIVE OBSERVATIONS

1. **ABI Compatibility:** 0 public fn removals. All additive. upgrade_number increments correctly. Chunked upgrade robust.
2. **Emission Tracker (F6):** Mathematically sound. `day % 30` + parallel `daily_day_nums` efficient. Saturating arithmetic prevents overflow.
3. **Delegate Burn Pattern (F9):** `apt_vault::burn_via_vault` lets fee vault burn without holding BurnRef (least privilege). Direction lock enforced by framework.
4. **Neutered Functions:** Correctly abort `E_NEUTERED`, remove admin manipulation surfaces.

---

## 📝 FINAL RECOMMENDATION

**Do not deploy v0.3.2 as-is without addressing H1.** [Note: already deployed; this is post-mainnet review — patch via v0.3.3]

The voting power collapse on first claim is a critical governance bug. Creates "race to claim" where first actor disenfranchises all other unclaiming stakers.

**Required Action:** Modify `governance::voting_power` to handle transition gracefully, or migration script for existing voters.
