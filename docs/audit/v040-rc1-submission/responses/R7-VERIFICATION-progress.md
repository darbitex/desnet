# R7 Audit Panel Verification — v0.4.0-rc1 Opinion Module (PROGRESS)

**Status:** WORK IN PROGRESS — 4/6 reviewers in
**Last updated:** 2026-05-03
**Acceptance bar:** ≥4 GREEN out of 6 reviewers + zero unfixed HIGH

---

## Reviewer Panel Status

| Reviewer | Verdict | HIGH | MED | LOW | INFO | Notes |
|---|---|---|---|---|---|---|
| **Grok** | ✅ GREEN | 0 | 0 | 2 | 4 | 1 LOW false positive (claimed truncation that doesn't exist) |
| **Gemini** | 🟡 YELLOW | 1 | 1 | 1 | 1 | HIGH (G-H1) on swap tax overcharge — DOWNGRADED to convergent MED via DeepSeek |
| **Kimi** | ✅ GREEN | 0 | 0 | 0 | 4 | Explicitly REJECTS Gemini G-H1 (counter-analysis: face-value tax is internally consistent design choice, not a bug) |
| **DeepSeek** | ✅ GREEN | 0 | 2 | 0 | 1 | Confirms G-H1 at MED severity (D-M1) + new MED on zero-output swap (D-M2) |
| Claude | ⏳ pending | — | — | — | — | — |
| Qwen | ⏳ optional | — | — | — | — | — |

**Acceptance bar progress:**
- GREEN count: **3/4 required** (need 1 more from Claude or Qwen)
- Unfixed HIGH count: **0** (Gemini's HIGH downgraded to convergent MED via DeepSeek panel consensus)
- Convergent MED count: **1** (D-M1 / G-H1 swap tax base — must address per R6 protocol)
- Currently very close to bar; needs 1 more GREEN + addresses convergent MED

---

## Findings Tracker

### HIGH (0 unfixed) — G-H1 downgraded

| ID | Reviewer | Description | Status | Resolution |
|---|---|---|---|---|
| ~~G-H1~~ | ~~Gemini~~ | ~~HIGH on swap tax base~~ | **DOWNGRADED to MED** (= D-M1 convergent) | DeepSeek confirms bug at MED severity. Kimi explicit counter not sufficient (needs ≥2 counters to fully reject). Final severity = MED via 2-reviewer convergence with lower assessment of the 2 confirmers. |

### MED (3 — must address; 1 convergent + 2 solo)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **D-M1 / G-H1** | DeepSeek + Gemini (CONVERGENT) | Swap tax computed on raw YAY/NAY units instead of $creator_token value. Spec violation per §4 #9. Overcharges or undercharges depending on pool skew. | **MUST FIX** (convergent) | Two options: (a) factory AMM quote (per spec); (b) opinion pool spot price (cleaner, no external dep). Deferred to rc2. |
| **D-M2** | DeepSeek (solo) | Zero-output swap possible with naive `min_out=0`. User loses input + tax for 0 output. | **STRONG SUGGEST FIX** (trivial) | Add `assert!(amount_out > 0, E_SLIPPAGE_EXCEEDED)` in both swap functions. ~2 lines per fn. |
| **G-M1** | Gemini (solo) | Dust redemption (1 raw YAY+NAY pair) → 100% effective tax via M3 ceiling. By design but UX-confusing. | **DEFERRED** | Frontend guard: warn / block sub-threshold redeems. Acceptable per anti-dust intent. |

### LOW (3)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **R-L1 / K-INFO-2** | Grok + Kimi (CONVERGENT) | No end-to-end integration test (create→deposit→swap→redeem) | **ACKNOWLEDGED GAP** | Add factory token + profile setup scaffold; defer to rc2 |
| **R-L2** | Grok | "Missing redeem_complete_set source" — FALSE POSITIVE | **DISMISSED** | Source IS present at 03-source-code.md lines ~549-607 |
| **G-L1** | Gemini (solo) | Double-withdraw in deposit/swap/redeem flow — gas inefficiency + redundant events | **DEFERRED** | Compute tax upfront, single withdraw `amount + tax`, split FA. ~3 lines per entry fn |

### INFO (10+)

| ID | Reviewer | Description | Status |
|---|---|---|---|
| R-I1..4 | Grok | View annotations, guest docs, swap input pre-checks, formal specs | NOTED — most addressed, optional |
| G-I1 | Gemini | History append fall-through compat | CONFIRMED sound |
| K-INFO-1 | Kimi | Design doc §10 stale AMM-quote reference | RECOMMEND doc update (BUT: now that D-M1 is being fixed, the AMM-quote requirement is enforced — keep §10 ref accurate) |
| K-INFO-3 | Kimi | `ensure_opinion_storage` double signer derivation | OPTIONAL — cosmetic refactor |
| K-INFO-4 | Kimi | CPMM rounding donation | CONFIRMED — standard, not a bug |
| D-INFO-1 | DeepSeek | compute_tax u64::MAX overflow safety | CONFIRMED via existing test |

---

## Convergence Analysis (UPDATED with DeepSeek)

**Convergent findings (≥2 reviewers same finding):**
- 🔴 **Swap tax base** (D-M1 = G-H1): Gemini + DeepSeek both flag as bug. Severity median = MED (Gemini wanted HIGH, DeepSeek says MED, take lower). Kimi's counter alone not enough to reject (need ≥2 counters per R6).
- ✅ **Integration test gap** (R-L1 + K-INFO-2): Grok + Kimi convergent. Confirmed acknowledged gap.

**Divergent findings:**
- (none — Kimi's counter on G-H1 is now outweighed by 2-reviewer confirmation of bug)

**Solo findings:**
- D-M2 (zero-output swap): DeepSeek only. VALID — trivial fix worth bundling.
- G-M1 (dust redeem 100% tax): Gemini only. Acceptable per design.
- G-L1 (double-withdraw): Gemini only. Optimization, deferrable.
- Various INFO items per reviewer.

---

## R6 Precedent — How G-H1 Resolved

The v0.3.3 R6 audit had Qwen flag Q-H1 (per-token voting power) → REJECTED via Claude+Kimi explicit counter (≥2 counters). This time:

- G-H1 (Gemini HIGH) had ONE explicit counter (Kimi) — not enough to reject per R6 threshold.
- DeepSeek arrived as 2nd confirming reviewer (at MED severity) — escalated to convergent.
- Net: G-H1 status = CONVERGENT MED (downgraded from HIGH via DeepSeek's lower severity rating, but still requires fix).

This is consistent with R6 protocol where panel CONSENSUS determines final severity, not any single reviewer's opinion.

---

## Decision Matrix Update (after Claude + Qwen)

### Scenario A (likely): Claude verdict GREEN with no new HIGH
→ 4/4+ GREEN, 0 unfixed HIGH, 1 convergent MED (D-M1) to address. Apply rc2 fix bundle (D-M1 + D-M2 + optionally G-L1). Re-test, re-submit lite review or proceed direct to mainnet with self-audit on rc2 deltas.

### Scenario B: Claude flags new HIGH or escalates D-M1 to HIGH
→ Address fix bundle, re-submit full panel review for rc3.

### Scenario C: Claude verdict GREEN but advocates Kimi's position (counter-counter on D-M1)
→ Net 2 reviewers reject D-M1, 2 reviewers confirm. Tie. User judgment call: accept design as-is (with doc clarification per Kimi K-INFO-1) OR fix to be safe.

---

## Decision: NO FIXES APPLIED YET

Per user direction: **consolidate + document only**. No code changes. Awaiting:
- Claude verdict
- (Optionally Qwen)

Once all reviewer responses are in, this document will be finalized as `R7-VERIFICATION.md` with:
1. Final convergence triage (lock D-M1 status, severity, fix path)
2. Fix bundle scope for v0.4.0-rc2 (very likely: D-M1 + D-M2 + integration tests; optional: G-L1, K-INFO-3)
3. Accept-by-design rejections with rationale (G-M1 frontend, L4 vault floor)
4. Final acceptance bar status + mainnet promotion gate

---

## Files in this submission

```
docs/audit/v040-rc1-submission/
├── 01-cover-and-scope.md
├── 02-design-doc.md
├── 03-source-code.md
├── 04-tests-and-self-audit.md
└── responses/
    ├── grok-verdict.md
    ├── gemini-verdict.md
    ├── kimi-verdict.md
    ├── deepseek-verdict.md
    └── R7-VERIFICATION-progress.md  ← this file (will be finalized as R7-VERIFICATION.md)
```

Source under audit: commit `6ace5a4` (opinion-pool-design branch tip).
