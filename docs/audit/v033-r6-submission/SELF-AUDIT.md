# DeSNet v0.3.3 — Self-Audit (post-fix bundle)

**Subject:** Tag `v0.3.3-pre-deploy` (= commit `a369fa3` on branch `v0.3.3-fix-bundle`).
**Scope:** Independent re-review of G1-G7 fixes I authored.
**Method:** 8-dim audit per SOP, plus targeted edge-case scenarios.
**Result:** **1 HIGH found (S1 — re-fix required before deploy), 2 MED/LOW design caveats documented (S2-S3), 2 INFO observations (S4-S5).**

---

## 🔴 S1 [HIGH] — G3 execute_settle uses stale min_out anchored to old to_burn (bug introduced by my fix)

**Module:** `handle_fee_vault.move`

**Description:** In `request_settle`, `min_out` is computed from the **request-time** `to_burn`:
```move
let total = primary_fungible_store::balance(v_addr, apt_meta);
let to_burn = total - (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
let quoted_out = amm::quote_swap_exact_in(DESNET_HANDLE, to_burn, true);
let min_out = (quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL;
```

In `execute_settle`, `to_burn` is **recomputed from current balance** (which may have grown — more handle fees during 60s+ window):
```move
let total = primary_fungible_store::balance(v_addr, apt_meta);  // CURRENT, may > request-time
let to_burn = total - (total * SPLIT_DEPLOYER_BPS) / BPS_DENOM;
...
let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, min_out);  // OLD min_out
```

**Concrete attack scenario:**
1. Vault holds 1 APT. Honest user calls `request_settle` → snapshots min_out for `to_burn = 0.9 APT`. Quoted ~3.69M DESNET out, min_out = 3.51M (95%).
2. During 60s+ window, 5 new handle registrations land → vault now holds 6 APT.
3. Honest user calls `execute_settle` → swap is `to_burn = 5.4 APT`, expected out at fair price ~22M DESNET, but min_out check is against 3.51M (TRIVIALLY satisfied even at horrendous slippage).
4. MEV attacker front-runs execute_settle, skews pool 50%, then settle swaps 5.4 APT for ~11M DESNET (vs fair 22M), attacker back-runs and extracts ~10M DESNET worth of value.
5. min_out=3.51M passes (11M ≥ 3.51M). Sandwich succeeds.

**Severity:** HIGH — directly defeats the purpose of G3. Two-phase mechanic gives FALSE security if balance grows between request and execute.

**Required fix (before deploy):**

Store `to_burn_at_request` in PendingSettle and use IT (not current balance) for the swap:
```move
struct PendingSettle has key, drop {
    requested_at_secs: u64,
    to_burn_at_request: u64,    // NEW — locks the amount being swapped
    to_deployer_at_request: u64, // NEW — locks the deployer cut
    min_desnet_out: u64,
}
```

In `execute_settle`:
- Use `pending.to_burn_at_request` (not recomputed from current balance)
- Use `pending.to_deployer_at_request` for deployer transfer
- Excess balance (current - request_total) stays for NEXT settle cycle

This guarantees: (swap amount, min_out) are PAIRED from same snapshot → slippage protection holds for the actual swap size.

---

## 🟡 S2 [MED] — G2 dao_cleanup_upgrade_staging permits wipe-grief of in-progress staging

**Module:** `governance.move`

**Description:** `dao_cleanup_upgrade_staging` is unconditionally permissionless:
```move
public entry fun dao_cleanup_upgrade_staging(_caller: &signer) acquires DaoUpgradeStaging {
    if (exists<DaoUpgradeStaging>(@desnet)) {
        let _ = move_from<DaoUpgradeStaging>(@desnet);
    };
}
```

**Attack scenario:**
1. Publisher P stages chunks 1..N-1 for proposal Q over multiple txs
2. Attacker calls `dao_cleanup_upgrade_staging` → wipes P's accumulated staging
3. P must restart from chunk 1
4. Attacker repeats indefinitely → asymmetric grief (1 attacker tx = N publisher txs lost)

**Severity rationale:** MED. Pure DoS, no asset loss. But for large pkg (e.g., 10 chunks), the asymmetry is significant.

**Mitigation candidates (NOT applied to v0.3.3):**
- (A) Gate cleanup on staging being for STALE proposal (not eligible for current execute lifecycle)
- (B) Require cleanup caller == staging.stager (but defeats grief recovery if attacker is the stager)
- (C) Add minimum cleanup-cooldown (cleanup only if last_stage > X seconds ago)
- (D) Move to `SmartTable<proposal_id, staging>` per-proposal isolation (struct change, not compat-safe in v0.3.3)

**Recommendation:** Document as known DoS surface for v0.3.3. Use single-tx publish for small pkg. v0.3.4 should adopt (D) via new struct addition.

---

## 🟡 S3 [LOW-MED] — G2 auto-reset enables proposal-switching grief

**Module:** `governance.move`

**Description:** `dao_stage_chunks_into_staging` auto-resets when called with a different `proposal_id`:
```move
if (staging_ref.proposal_id != proposal_id) {
    let _ = move_from<DaoUpgradeStaging>(@desnet);  // wipe stale
}
```

**Attack scenario:** If multiple proposals P and Q are concurrently in approved+ratified+timelock-elapsed state:
1. Publisher stages for P
2. Attacker stages for Q → auto-reset wipes P's staging
3. Same wipe-grief as S2 but using legit proposal_id

**Severity rationale:** LOW-MED. Requires multiple eligible proposals (less common). Mitigations same as S2.

**Recommendation:** Document. If DAO governance frequently has multiple eligible proposals, consider per-proposal staging in v0.3.4.

---

## ℹ️ S4 [INFO] — G3 attacker can cycle request/cancel to delay legitimate settle

**Module:** `handle_fee_vault.move`

**Description:** `request_settle` requires `!exists<PendingSettle>`. `cancel_pending_settle` is permissionless. So:
1. Attacker request_settle → locks pending state
2. Honest user can't request → must cancel attacker's first
3. Honest user cancel + new request → starts fresh 60s clock
4. Attacker can race-cancel honest user's request via same flow

**Net:** attacker can delay legitimate settle indefinitely with cycle of (request, cancel). No asset loss. Cost = gas.

**Mitigation:** Could add cooldown per-caller, but adds state complexity. Current design accepts this as bounded grief.

**Severity:** INFO — bounded gas-only grief.

---

## ℹ️ S5 [INFO] — `apt_balance_at_request` field stored but unused in v0.3.3 G3

The PendingSettle struct stores `apt_balance_at_request` but only `min_desnet_out` and `requested_at_secs` are read. Currently unused.

**Status:** If S1 is fixed via `to_burn_at_request` field addition, this field also becomes meaningful (caller can verify execute uses request-time amounts).

---

## Other dimensions — clean

| Dim | G1 | G2 | G3 | G4 | G5 | G6 | G7 |
|---|---|---|---|---|---|---|---|
| ABI compat | ✓ +1 fn | ✓ +3 fn, +1 struct | ✓ +6 fn, +1 struct | ✓ body | ✓ +1 fn | ✓ #[view] | ✓ const |
| Args validation | ✓ | ✓ E_NOT_STAGER + auto-reset | ⚠️ S1 | ✓ | ✓ digest enforce | ✓ N/A | ✓ N/A |
| Math | ✓ N/A | ✓ N/A | ⚠️ S1 (size mismatch) | ✓ | ✓ N/A | ✓ N/A | ✓ N/A |
| Reentrancy | ✓ | ✓ Move atomicity | ✓ PendingSettle consumed pre-swap | ✓ | ✓ | ✓ | ✓ |
| Edges | ✓ per-user fallback | ⚠️ S2/S3 | ⚠️ S1 + S4 | ✓ | ✓ | ✓ | ✓ |
| X-module | ✓ | ✓ no new friend | ✓ uses amm + apt_vault + factory friends (existing) | ✓ | ✓ | ✓ | ✓ |
| Errors | ✓ | ✓ E_NOT_STAGER=24 | ✓ E_USE_TWO_PHASE=3, E_PENDING_*=4-7 | ✓ | ✓ | ✓ | ✓ |
| Events | ✓ | ✓ ProposalExecuted preserved | ✓ Settled fires from execute_settle | ✓ | ✓ MultisigUpgrade | ✓ | ✓ |

---

## Recommendation

**S1 MUST be fixed before chunked deploy.** It's a real bug introduced by my G3 implementation. Without fix, G3 provides false security against the very attack it's designed to prevent.

**S2-S3** are design tradeoffs documented for user awareness. Acceptable for v0.3.3 with clear caveats. Real fix needs per-proposal staging in v0.3.4 (struct change required, not compat-safe in v0.3.3).

**S4-S5** are INFO-level — accept as-is.

**Suggested action:**
1. Fix S1 in v0.3.3-fix-bundle branch (tag bumped to `v0.3.3-pre-deploy-r2`)
2. Optionally apply partial S2 mitigation (gate cleanup on stale staging)
3. Re-run ABI compat-check, re-self-audit, then deploy
