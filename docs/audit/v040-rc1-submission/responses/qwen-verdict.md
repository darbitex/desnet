# Qwen Audit Verdict — v0.4.0-rc1 Opinion Module

**Reviewer:** Qwen
**Received:** 2026-05-03
**Verdict:** **GREEN** (0 HIGH, 1 MED, 3 LOW, 4 INFO)
**Recommendation:** APPROVE for v0.4.0-rc2 → Mainnet contingent on E2E integration test scaffold
**Notable:** Identifies NEW solo MED on synchronous history coupling. Comprehensive validation of self-audit findings and design soundness.

---

## Verbatim Response

# 🛡️ DeSNet `opinion` Module (v0.4.0-rc1) — Independent Audit Report
**Commit:** `6ace5a4` | **Branch:** `opinion-pool-design` | **Date:** 2026-05-03
**Auditor Role:** External Smart Contract & Move-Security Reviewer
**Scope:** `sources/opinion.move` + touchpoint integration safety (`apt_vault`, `factory`, `history`, `profile`)

---

## 📊 Executive Summary
The `desnet::opinion` module implements a perpetual, no-settle CPMM prediction substrate using a symmetric pool seed, creator-token collateral, and strict conservation invariants (`vault == total_yay == total_nay`).

**Overall Verdict: 🟢 GREEN (Ready for Mainnet Post-E2E Test Scaffold)**
The codebase is structurally sound, mathematically correct, and adheres tightly to the locked design doc (`02-design-doc.md`). The self-audit (`04-tests-and-self-audit.md`) correctly identified and patched all critical logical gaps (H1, M1–M5). No new **HIGH** severity issues were found. Remaining findings are **LOW/INFO** or process-oriented, focusing on integration test coverage, gas-bound history appending, and UI/UX precision handling.

---

## ✅ Validation of Self-Audit Findings
| ID | Self-Audit Finding | Auditor Verification |
|:---|:---|:---|
| **H1** | PID vs Wallet mismatch in `create_opinion` | ✅ **Fixed Correctly.** `factory::owner_has_token(author_pid)` now aligns with `factory.move` indexing. Blocking deploy issue resolved. |
| **M1** | Missing conservation assert in swaps | ✅ **Fixed.** `assert_conservation(mkt)` added. Zero runtime cost, strong regression guard. |
| **M2** | Missing pool-active check in deposit | ✅ **Fixed.** Explicit `>0` balance assert prevents silent CPMM breakage. |
| **M3** | Tax dust evasion via truncation | ✅ **Fixed.** `compute_tax` ceiling formula guarantees `tax ≥ 1` for any `amount>0, bps>0`. Mathematically sound. |
| **M4** | Missing UX balance requirements in docs | ✅ **Fixed.** Doc-comments explicitly state atomic `amount + tax` requirement. Framework `withdraw` aborts safely if insufficient. |
| **M5** | No per-PID opinion limit (storage grief) | ✅ **Fixed.** `MAX_OPINIONS_PER_PID = 10_000` enforced before seq increment. Binds state bloat predictably. |
| **L3/L4** | Guest history skip & vault floor lock | ✅ **Accepted by Design.** Aligns with `02-design-doc.md` §4.7 & §10. No code change needed. |

---

## 🔍 Independent Audit Findings

### 🟡 MEDIUM (1)
| ID | Finding | Severity | Recommendation |
|:---|:---|:---|:---|
| **Q-I-01** | **History Append Blocking Financial Tx**<br>`history::append` is called synchronously inside `emit_action`. If `history.move` hits chunk rotation limits, gas caps, or internal assertions, the entire financial transaction (deposit/swap/redeem) will revert. While acceptable for audit purity, this couples core AMM liquidity to a non-critical social ledger. | MED | Consider wrapping `history::append` in a `try!` or deferring to an async indexer/event-driven sidecar if mainnet gas volatility spikes. If kept sync, document as "social-feed dependency" in SLA. |

### 🟢 LOW (3)
| ID | Finding | Severity | Recommendation |
|:---|:---|:---|:---|
| **Q-I-02** | **CPMM Integer Truncation Precision Loss**<br>`compute_amount_out` uses standard integer division: `(amount_in * reserve_out) / (reserve_in + amount_in)`. Truncation favors the pool slightly over time. At extreme reserve ratios (`>1:1000`), micro-slippage accumulates. This is standard UniV2 behavior, not a bug, but UI slippage tolerances must account for it. | LOW | Frontend should apply `min_out = expected_out - slippage_bps` and display "exact vs minimum" clearly. No on-chain change required. |
| **Q-I-03** | **Tax Burn Gas Inefficiency at Micro-Amounts**<br>Burning `tax_amount = 1` raw unit costs ~5–10k gas. For trades where `tax < 50` raw units, gas cost exceeds economic value burned. M3 ceiling fix intentionally prevents `tax=0`, but creates negative gas-efficiency at sub-dust sizes. | LOW | Accept as anti-sybil cost. If UX friction reported, consider `if (tax_amount < MIN_BURN_THRESHOLD) tax_amount = 0;` (requires design waiver). Current implementation is safer against dust-splitting attacks. |
| **Q-I-04** | **`OpinionAction` Event Redundant Sentinel**<br>`is_opinion: bool = true` is embedded in every event payload. While useful for cross-module indexer filtering, it adds 1 byte per event. Given Aptos event storage costs are trivial, this is purely cosmetic. | LOW | Keep as-is. Provides explicit type-discrimination for off-chain parsers. |

### ℹ️ INFO / DESIGN CONFIRMATIONS
| ID | Observation | Status |
|:---|:---|:---|
| **Q-I-05** | **FA Metadata Immutability Assumption** | ✅ `creator_token` address is cached at create. Relies on `factory.move` token immutability. Verified: factory tokens cannot change metadata post-mint. Safe. |
| **Q-I-06** | **Reentrancy Safety** | ✅ Aptos `fungible_asset` standard has no callback hooks. `primary_fungible_store` ops are stateful but non-reentrant. Confirmed safe. |
| **Q-I-07** | **Borrow-Checker & Resource Sealing** | ✅ `MintRef`/`BurnRef`/`ExtendRef` stored inside `OpinionMarket has key`. Move access rules guarantee only `opinion.move` can borrow. No capability leakage. Safe. |
| **Q-I-08** | **Conservation Invariant Mathematical Proof** | ✅ `vault == total_yay == total_nay` holds by construction. Deposit/Redeem are atomic pair-mint/burn. Swaps redistribute pool reserves only. Tax is burned from external user balance, never touching vault or minted totals. Invariant is mathematically airtight. |

---

## 🧪 Critical Pre-Mainnet Checklist
1. **[BLOCKER] End-to-End Integration Test Scaffold**
   The self-audit correctly flags the absence of a full `create → deposit → swap → redeem` flow test. Before mainnet promotion, deploy a temporary test harness on `testnet` or `devnet` that:
   - Registers a factory token & profile
   - Creates an opinion with `initial_mc = MIN`
   - Executes deposit, swap, redeem from distinct signers
   - Verifies conservation invariant & tax burn receipts via indexer
   *(Unit tests cover math; integration tests verify FA framework + cross-module atomicity.)*

2. **[RECOMMENDED] Slippage & Gas Benchmarking**
   Simulate worst-case CPMM paths (`reserve_in = 1e17, reserve_out = 1e6, amount_in = 1e12`) to confirm `compute_amount_out` + `burn_tax` gas stays under Aptos `max_gas_units` (currently `50,000`). Expected: ✅ Well within limits.

3. **[RECOMMENDED] Indexer Compatibility Check**
   Verify off-chain indexers correctly parse `OpinionMintCreated` and `OpinionAction` BCS payloads. The `is_opinion: bool` sentinel must be checked first to avoid collision with future modules.

---

## 🏁 Final Verdict
| Dimension | Status | Notes |
|:---|:---|:---|
| **Conservation & Solvency** | 🟢 Sound | Invariant mathematically proven & runtime-enforced |
| **Access Control & Auth** | 🟢 Sound | H1 fixed, refs sealed, friend boundaries correct |
| **CPMM Math & Precision** | 🟢 Sound | Standard UniV2 integer math, truncation documented |
| **Tax & Anti-Dust** | 🟢 Sound | Ceiling rounding enforced, atomic rollback verified |
| **State Machine & Griefing** | 🟢 Sound | PID caps, pool-active checks, transfer locks in place |
| **Integration Safety** | 🟢 Sound | FA metadata matching, profile/history delegation correct |
| **Test Coverage** | 🟡 Gap | Unit tests 93/93 ✅. E2E scaffold required pre-mainnet |

**Recommendation:** **APPROVE for v0.4.0-rc2 → Mainnet Promotion**, contingent on adding the E2E integration test scaffold. The module is production-ready, economically aligned with the closed-loop design, and free of critical vulnerabilities.

---

## Triage Notes (auditor-side review)

### Q-I-01 — NEW solo MED (history coupling)
Qwen-only finding. Real concern: synchronous `history::append` couples financial tx atomicity to history module state. If chunk rotation hits Aptos resource limits or any inner assert fires, the deposit/swap/redeem reverts entirely.

**Counter-arguments**:
- History module is in the same package, audited at v0.3.3 R6 — known reliable
- Chunk rotation is well-tested (unit tests include rotation at 30KB threshold)
- Aptos doesn't have hard chunk-size limits at the FA framework level
- "Try!" pattern would silently lose history entries — bad for indexers

**Verdict**: solo finding, real but mitigated. Could defer with "social-feed dependency" doc note. Or implement try! pattern if mainnet gas issues emerge. NOT a blocker.

### Q-I-02 — CPMM truncation
Confirmed standard CPMM behavior. No on-chain action; frontend handles.

### Q-I-03 — Tax burn gas inefficiency at micro-amounts
Real observation: 5-10k gas to burn 1 raw unit. Trade-off acceptable per anti-sybil intent (M3). No action.

### Q-I-04 — OpinionAction sentinel redundancy
Keep as-is per Qwen's own recommendation (provides type-discrimination for parsers). 1-byte cost trivial.

### Integration test scaffold
Qwen flags as **BLOCKER** for mainnet. Convergent with Grok + Kimi + Claude (4-way convergence) → strong consensus to address in rc2.

### Notably: Qwen does NOT flag swap tax base (G-H1 / D-M1)
Silent on the issue. Like Claude. So G-H1/D-M1 is now: 2 confirm (Gemini HIGH, DeepSeek MED) + 1 counter (Kimi reject) + 3 silent (Grok, Claude, Qwen). 

Per R6 protocol convergence (≥2 same-finding), G-H1/D-M1 IS convergent and should be addressed. But severity is MED not HIGH (DeepSeek's lower assessment + 3-reviewer silence on severity).
