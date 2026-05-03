# R7 Audit Panel Verification — v0.4.0-rc1 Opinion Module (PROGRESS)

**Status:** WORK IN PROGRESS — 3/6 reviewers in
**Last updated:** 2026-05-03
**Acceptance bar:** ≥4 GREEN out of 6 reviewers + zero unfixed HIGH

---

## Reviewer Panel Status

| Reviewer | Verdict | HIGH | MED | LOW | INFO | Notes |
|---|---|---|---|---|---|---|
| **Grok** | ✅ GREEN | 0 | 0 | 2 | 4 | 1 LOW false positive (claimed truncation that doesn't exist) |
| **Gemini** | 🟡 YELLOW | 1 | 1 | 1 | 1 | HIGH (G-H1) on swap tax overcharge — DISPUTED by Kimi |
| **Kimi** | ✅ GREEN | 0 | 0 | 0 | 4 | Explicitly REJECTS Gemini G-H1 (counter-analysis: face-value tax is internally consistent design choice, not a bug) |
| Claude | ⏳ pending | — | — | — | — | — |
| DeepSeek | ⏳ pending | — | — | — | — | — |
| Qwen | ⏳ optional | — | — | — | — | — |

**Acceptance bar progress:**
- GREEN count: **2/4 required** (need 2 more)
- Unfixed HIGH count: **1 DISPUTED** (Gemini G-H1 vs Kimi explicit counter; needs ≥2 counter-analyses per R6 precedent to definitively reject)
- Currently approaching bar; awaiting Claude + DeepSeek for tie-break

---

## Findings Tracker

### HIGH (1 — DISPUTED, awaiting resolution)

| ID | Reviewer | Description | Status | Counter-analyses | Resolution path |
|---|---|---|---|---|---|
| **G-H1** | Gemini | Swap tax computed on raw YAY/NAY units instead of $creator_token-equivalent. Argues this overcharges traders ~11×–100× depending on pool skew. Cites design doc §4 #9 which mentions "via factory AMM quote". | **DISPUTED** | Kimi (INFO-1): explicit reject — argues face-value tax is internally consistent (1 YAY minted 1:1 with $token), gas-cheaper, predictable, and §4 locked decisions don't mandate AMM-quote taxation. §10 is process docs not spec. | Need ≥2 counter-analyses per R6 precedent (Qwen Q-H1 reject pattern). Currently 1/2. Await Claude + DeepSeek. |

### MED (1)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **G-M1** | Gemini | Dust redemption (1 raw YAY+NAY pair) → 100% effective tax via M3 ceiling. By design but UX-confusing. | **DEFERRED** | Frontend guard: warn / block sub-threshold redeems. Optionally document in design doc as accepted-by-design. |

### LOW (3)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **R-L1 / K-INFO-2** | Grok + Kimi | No end-to-end integration test (create→deposit→swap→redeem) — **CONVERGENT** | **ACKNOWLEDGED GAP** | Add factory token + profile setup scaffold; defer to rc2 |
| **R-L2** | Grok | "Missing redeem_complete_set source" — FALSE POSITIVE | **DISMISSED** | Source IS present at 03-source-code.md lines ~549-607 |
| **G-L1** | Gemini | Double-withdraw in deposit/swap/redeem flow — gas inefficiency + redundant events | **DEFERRED** | Compute tax upfront, single withdraw `amount + tax`, split FA. ~3 lines per entry fn |

### INFO (8)

| ID | Reviewer | Description | Status |
|---|---|---|---|
| R-I1 | Grok | Consider `#[view]` on more helpers | NOTED — most already covered |
| R-I2 | Grok | Document guest trading clearly | NOTED — exists in design doc |
| R-I3 | Grok | Add input validation on swap amounts (UX) | NOTED — framework handles, optional pre-check |
| R-I4 | Grok | Long-term: formal specs for invariant | NOTED — v2+ work |
| G-I1 | Gemini | History append fall-through compat validation | CONFIRMED sound |
| K-INFO-1 | Kimi | Design doc §10 stale AMM-quote reference | RECOMMEND — update doc §10 to remove stale reference (no code change) |
| K-INFO-3 | Kimi | `ensure_opinion_storage` double signer derivation | CONSIDER — cosmetic optimization, ~3 line refactor |
| K-INFO-4 | Kimi | CPMM rounding donation to pool | CONFIRMED — standard CPMM behavior, not a bug |

---

## Convergence Analysis

**Convergent findings (≥2 reviewers same finding):**
- ✅ **Integration test gap** (R-L1 + K-INFO-2): both Grok and Kimi flag absence of end-to-end test. Confirmed gap. Action: add scaffold in rc2.

**Divergent findings:**
- 🔥 **G-H1 (swap tax base)**: Gemini = HIGH bug; Kimi = INFO/non-issue. Direct disagreement on whether face-value taxation is a design flaw or a design choice. Awaiting Claude + DeepSeek to break tie.

**Solo findings (1 reviewer only, no convergence yet):**
- G-M1 (dust redeem 100% tax): Gemini-only MED. Acceptable per anti-dust design intent.
- G-L1 (double-withdraw inefficiency): Gemini-only LOW. Genuine optimization.
- K-INFO-1, K-INFO-3, K-INFO-4: Kimi-only suggestions.
- R-I1..4: Grok-only INFO suggestions.

---

## R6 Precedent Application

The v0.3.3 R6 audit had a similar dispute: **Qwen flagged Q-H1 (per-token voting power flip), but Claude + Kimi explicitly counter-analyzed and rejected it**. Final outcome: 5/6 consensus REJECTED Q-H1, preserved current design. Memory entry quote:
> "R6 panel 6/6 received, 5 GREEN + 1 YELLOW (Qwen Q-H1 disputed → REJECTED on Claude+Kimi explicit counter-analysis preserving F7 cross-token-inflation defense, 5/6 reviewer consensus accept current G1 design)"

**Application to G-H1:**
- Currently: 1 HIGH (Gemini) vs 1 explicit counter (Kimi) = 1-1 tie
- Need ≥2 explicit counter-analyses to definitively reject (matching R6 protocol)
- If Claude + DeepSeek both counter Gemini → G-H1 REJECTED, panel converges 4-5 GREEN
- If Claude + DeepSeek both confirm Gemini → G-H1 ESCALATED, must fix in rc2
- If split (1 confirm, 1 counter) → user judgment call

---

## Decision Matrix (when 5-6 reviewers in)

### Scenario A: Final 4+ GREEN with G-H1 REJECTED via consensus
→ Module passes acceptance bar. Promote to mainnet. Bundle minor LOW + INFO items as v0.4.0 polish (post-mainnet).

### Scenario B: Final 4+ GREEN with G-H1 ESCALATED (≥3 confirm)
→ Apply G-H1 fix (swap tax = spot-equivalent computation, ~5 lines per swap fn). Plus optional G-L1 (double-withdraw). Re-submit as v0.4.0-rc2 to remaining reviewers for final pass. Tag rc2-mainnet-ready.

### Scenario C: Final < 4 GREEN
→ Address all valid HIGH/MED findings + iterate. Multi-cycle audit until threshold met.

---

## Decision: NO FIXES APPLIED YET

Per user direction: **consolidate + document only at this stage**. No code changes. Awaiting:
- Claude verdict
- DeepSeek verdict
- (Optionally Qwen)

Once all reviewer responses are in, this document will be finalized as `R7-VERIFICATION.md` with:
1. Final convergence triage
2. G-H1 resolution (ACCEPTED or REJECTED with explicit reviewer count)
3. Fix bundle scope for v0.4.0-rc2 (if needed)
4. Accept-by-design rejections with rationale
5. Final acceptance bar status

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
    └── R7-VERIFICATION-progress.md  ← this file (will be finalized as R7-VERIFICATION.md)
```

Source under audit: commit `6ace5a4` (opinion-pool-design branch tip).
