# DeSNet v0.3.3 — R6 Audit Response (Claude Opus 4.7)

**Reviewer:** Claude Opus 4.7
**Subject:** Tag `v0.3.3-pre-deploy-r2` (commit `93a05a2`)
**Scope:** Diff vs `v0.3.2-mainnet-live` (~508 lines, 8 fix items + S1)
**Date:** 2026-05-02

---

## TL;DR — Verdict: 🟢 **GREEN — safe to deploy v0.3.3**

All four R5 convergent + minority HIGH items (C1-C3 + Deepseek F6) are **correctly addressed**. The self-audit S1 (HIGH) introduced by the original G3 implementation was identified honestly and fixed correctly in the re-spin. My own re-review surfaced **6 new findings, all LOW/INFO** — none rise to HIGH or MED. Acceptance bar (≥4/6 GREEN, no unfixed HIGH) is met from this seat.

**Recommendation:** Proceed with chunked deploy. Track C1-C6 below for v0.3.4.

[Full Claude R6 response saved per submitted markdown.]

---

## Per-fix verifications (summary)

- **G1** ✓ CORRECT. Per-USER fallback eliminates lazy-flip. Edge case "voter with per-token entry but ZERO DESNET amount": **current behavior is correct by F7 design intent**. Falling back to legacy mixed for this voter would re-open the cross-token inflation bug. The "exists entry" check is right.
- **G2** ✓ CORRECT WITH DOCUMENTED CAVEATS. DaoUpgradeStaging cleanly decoupled, stager-lock works, hash-fail-preserves-staging atomic per Move semantics.
- **G3 + S1** ✓ CORRECT. Sandwich-safe within documented 5% bound. All withdraw paths checked, vault balance monotonicity verified, reentrancy impossible via Move borrow checker.
- **G4** ✓ CORRECT. Vestigial overflow eliminated for current code path.
- **G5/G6/G7** ✓ TRIVIAL/CORRECT.

## ABI compatibility regression

0 public/friend fn removed, 0 existing fn signature changed. Only intentional `settle()` deprecation is caller-visible.

---

## NEW R6 findings (LOW/INFO only)

### C1 [LOW] — Theoretical u64 overflow in request_settle slippage math
`(quoted_out * SETTLE_SLIPPAGE_BPS) / BPS_FULL` overflows u64 if pool's DESNET reserve >2×10^15. Realistic exposure: zero. Recommend u128 intermediate cast in v0.3.4.

### C2 [INFO] — View coverage gap on PendingSettle
`pending_settle_min_out()` exposed but `to_burn_at_request`, `to_deployer_at_request`, `apt_balance_at_request` are not. Add views in v0.3.4.

### C3 [INFO] — `cancel_pending_settle` emits no event
Add `PendingSettleCancelled` event in v0.3.4 for monitor distinction.

### C4 [INFO] — Off-chain chunk ordering not contract-enforced
`vector::append`s per-module chunks in submission order. If tooling stages out-of-order, hash mismatch reverts publish (fails closed). Operational discipline mitigates.

### C5 [INFO] — Same-block validator MEV envelope on settle
5% slippage = design-permitted attacker bound. Same-block validator can extract up to 5% per settle. Acknowledged design. v0.3.4 could explore TWAP min_out.

### C6 [INFO] — Storage rebate makes DAO cleanup griefing economically attractive
`move_from` triggers storage rebate. Cycling cleanup-and-replay may be slightly profitable for griefer. Compounds S2. Per-proposal SmartTable in v0.3.4 closes naturally.

---

## Self-audit assessment

The team's `SELF-AUDIT.md` is unusually high-quality. S1 (HIGH) was a real, correctly-identified, correctly-described bug — easy to miss because the structure of the fix (storing min_out, two-phase) appears to address the original vulnerability while the parameter-anchor mismatch silently undermines it. Catching it pre-deploy demonstrates good audit discipline. The fix is correct.

S2-S5 documented at the right severity with clear rationales for not-fixing-in-v0.3.3. No disagreement.

---

## Acceptance verdict

**🟢 GREEN — safe to deploy v0.3.3.**

All four R5 HIGH/MED items addressed. S1 self-audit fix verified. New R6 findings are LOW/INFO only. ABI compat preserved (modulo intentional `settle()` deprecation). Dependency graph clean. Self-audit is honest and thorough.

**Recommended v0.3.4 backlog (none blocking):**
1. C1 — u128 cast on slippage/split math
2. C6 + S2 — per-proposal SmartTable<u64, DaoUpgradeStaging> (closes both)
3. C2 — extra PendingSettle views
4. C3 — PendingSettleCancelled event
5. C5 — TWAP min_out exploration

Proceed with chunked deploy. Suggest using `multisig_publish_chunked_upgrade_with_digest` (G5) for the v0.3.3 deploy itself — pin the digest off-chain from this commit's MANIFEST.json `source_concat_sha3_256`.
