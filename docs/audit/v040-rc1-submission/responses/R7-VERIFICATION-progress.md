# R7 Audit Panel Verification — v0.4.0-rc1 Opinion Module (PROGRESS)

**Status:** WORK IN PROGRESS — 2/6 reviewers in
**Last updated:** 2026-05-03
**Acceptance bar:** ≥4 GREEN out of 6 reviewers + zero unfixed HIGH

---

## Reviewer Panel Status

| Reviewer | Verdict | HIGH | MED | LOW | INFO | Notes |
|---|---|---|---|---|---|---|
| **Grok** | ✅ GREEN | 0 | 0 | 2 | 4 | 1 LOW false positive (claimed truncation that doesn't exist) |
| **Gemini** | 🟡 YELLOW | 1 | 1 | 1 | 1 | HIGH valid: swap tax overcharge bug |
| Claude | ⏳ pending | — | — | — | — | — |
| DeepSeek | ⏳ pending | — | — | — | — | — |
| Kimi | ⏳ pending | — | — | — | — | — |
| Qwen | ⏳ optional | — | — | — | — | — |

**Acceptance bar progress:**
- GREEN count: **1/4 required** (need 3 more)
- Unfixed HIGH count: **1** (Gemini swap tax bug — must fix before mainnet)
- Currently NOT meeting bar; awaiting more reviewers + fix bundle

---

## Findings Tracker

### HIGH (1 unfixed)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **G-H1** | Gemini | Swap tax computed on raw YAY/NAY units instead of $creator_token-equivalent. Contradicts design doc §4.156. Overcharges ~11× to ~100× depending on pool skew. Bug isolated to swap fns; deposit/redeem use 1:1 correctly. | **UNFIXED — DEFERRED** | Compute spot-price equivalent before burn_tax. ~5 lines per swap fn. See `gemini-verdict.md` triage notes for code. |

### MED (1)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **G-M1** | Gemini | Dust redemption (1 raw YAY+NAY pair) → 100% effective tax via M3 ceiling. By design but UX-confusing. | **UNFIXED — DEFERRED** | Frontend guard: warn / block sub-threshold redeems. Optionally document in design doc as accepted-by-design. |

### LOW (3)

| ID | Reviewer | Description | Status | Fix path |
|---|---|---|---|---|
| **R-L1** | Grok | No end-to-end integration test (create→deposit→swap→redeem) | **ACKNOWLEDGED GAP** | Add factory token + profile setup scaffold; defer to rc2 if convergent |
| **R-L2** | Grok | "Missing redeem_complete_set source" — **FALSE POSITIVE** | **DISMISSED** | Source is present at 03-source-code.md lines ~549-607 |
| **G-L1** | Gemini | Double-withdraw in deposit/swap/redeem flow — gas inefficiency + redundant events | **UNFIXED — DEFERRED** | Compute tax upfront, single withdraw `amount + tax`, split FA. ~3 lines per entry fn |

### INFO (5)

| ID | Reviewer | Description | Status |
|---|---|---|---|
| R-I1 | Grok | Consider `#[view]` on more helpers | NOTED — most already covered |
| R-I2 | Grok | Document guest trading clearly | NOTED — exists in design doc |
| R-I3 | Grok | Add input validation on swap amounts (UX) | NOTED — framework handles, optional pre-check |
| R-I4 | Grok | Long-term: formal specs for invariant | NOTED — v2+ work |
| G-I1 | Gemini | History append fall-through compat validation | CONFIRMED sound |

---

## Convergence Analysis

**No convergent findings yet** between Grok and Gemini. Different focus areas:
- Grok focused on overall security model + invariant correctness → GREEN
- Gemini focused on tax mechanics + economic correctness → caught swap tax bug Grok missed

**Why Grok missed G-H1**: The bug is in a 1-line code path (`burn_tax` argument). Grok evaluated the higher-level flow ("tax burn flow correct") without checking unit-conversion correctness. Gemini did deep dive on the comment claim "1:1 with redemption" and identified the false assumption.

**Implication for next reviewers**: Different reviewers will catch different things. Convergent issues = confirmed must-fix; divergent issues need careful judgment (sometimes HIGH from one reviewer is acceptable trade-off per another).

---

## Decision: NO FIXES APPLIED YET

Per user direction: **consolidate + document only at this stage**. No code changes. Awaiting:
- Claude verdict
- DeepSeek verdict
- Kimi verdict
- (Optionally Qwen)

Once all 4-6 reviewer responses are in, this document will be finalized as `R7-VERIFICATION.md` with:
1. Final convergence triage (which findings appear in ≥2 reviews)
2. Severity reclassification based on reviewer consensus (e.g., one HIGH may downgrade to MED if other reviewers explicitly disagree with severity)
3. Fix bundle scope (which findings to address in v0.4.0-rc2)
4. Accept-by-design rejections with rationale (e.g., L4 vault floor stranded — rejected as already-explicit design intent)
5. Recompute acceptance bar status

---

## Critical Open Question for Final Triage

**G-H1 (swap tax bug) is currently 1/2 reviewer findings.** It IS mathematically valid and contradicts design doc — strong evidence even without convergence. But typical R6 protocol requires ≥2 reviewer convergence for HIGH escalation.

Possible resolutions:
- **(a)** Accept G-H1 as HIGH on its own merits (mathematical proof + doc inconsistency = sufficient evidence). Fix in rc2.
- **(b)** Wait for confirmation from another reviewer (Claude/DeepSeek/Kimi). If they ALSO catch it → confirmed convergent HIGH. If they DON'T mention it → re-evaluate (maybe Gemini's interpretation is too strict).
- **(c)** Submit clarification question to remaining reviewers: "Is the current tax base for swaps (raw YAY/NAY) or should it be $token-equivalent?" — get explicit position from each.

**Defer this decision until at least 4 reviewers in.**

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
    └── R7-VERIFICATION-progress.md  ← this file (will be finalized as R7-VERIFICATION.md)
```

Source under audit: commit `6ace5a4` (opinion-pool-design branch tip).
