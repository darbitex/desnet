# DeSNet v0.3.3 — R6 Audit (Grok 4 — xAI)

**Verdict: 🟢 GREEN — v0.3.3-pre-deploy-r2 (commit 93a05a2) is ready for chunked deployment.**

No HIGH or MED issues found. All R5 convergent findings (C1–C3) + self-audit S1 are soundly fixed. S2/S3 documented design tradeoffs are acceptable for v0.3.3 (pure DoS vectors, gas-only, low real-world impact given chunk size and permission model). ABI compat holds perfectly.

---

## Executive Summary (R6)

| Category | Verdict | Notes |
|---|---|---|
| **G3 + S1 (MEV settle)** | **GREEN** | Sandwich protection now robust. Snapshot pairing fixed. |
| **G1 (voting power)** | **GREEN** | Lazy-flip fully eliminated. |
| **G2 (DAO staging)** | **GREEN** | Grief surfaces documented + mitigated where compat-safe. |
| **G4–G7 + regressions** | **GREEN** | Clean. |
| **Overall** | **GREEN** | Meets acceptance (≥4/6 GREEN, zero unfixed HIGH). Safe to deploy. |

---

## Priority 1: G3 + S1 — Settle MEV Fix

**Status: FIXED and VERIFIED.**

- `request_settle` snapshots `to_burn_at_request` / `to_deployer_at_request` + `min_desnet_out` (5% slippage) against exact amount
- `execute_settle` consumes via `move_from` and uses LOCKED snapshot amounts — never recomputes
- Excess fees during 60s window stay for next cycle (correct economics)
- Sanity assert `current_total >= apt_balance_at_request` (vault monotonic growth only)
- Timing: 60s mandatory + 600s grace; permissionless cancel for grief recovery
- Old `settle()` aborts E_USE_TWO_PHASE for ABI parity

**S1 attack scenario impossible.** Paired (swap_amount, min_out) defeats stale-anchor sandwich. Pool shift >5% causes execute_settle revert.

Minor (INFO): apt_balance_at_request now used (S5 closed); no reentrancy (PendingSettle consumed pre-AMM call); request_settle blocked by existing pending (correct).

**Recommendation: Ship as-is. Excellent fix.**

---

## Priority 2: G1 — Per-User Voting Power Fallback

**Status: FIXED and VERIFIED.**

- `voter_history::has_per_token_entry(voter_addr)` checks per-USER
- `governance::voting_power` routes per voter's own entry existence
- Pre-v0.3.2 voters retain full power until *they* claim (no global flip)
- Zero-amount edge: existence-only check matches legacy behavior, acceptable

Lazy-flip disenfranchisement (R5 CONV-3) **fully resolved**. Clean, minimal change.

---

## Priority 3: G2 — DAO Chunked Staging Anti-Grief

**Status: VERIFIED + documented caveats accepted.**

- `DaoUpgradeStaging` (new struct) isolates DAO from multisig path
- `dao_stage_chunks_into_staging`: auto-reset on different proposal_id; same-proposal enforces stager==caller (anti-append grief)
- `dao_cleanup_upgrade_staging` permissionless (S2 documented)
- Hash-mismatch in `dao_publish_chunked_upgrade`: atomic move_from + abort leaves staging untouched (good UX retry)

**S2/S3 grief surfaces low-impact:**
- Permissionless cleanup = asymmetric DoS (1 tx wipes N chunks)
- Multi-proposal auto-reset same
- Mitigation (per-proposal SmartTable) needs struct change → v0.3.4

Acceptable for v0.3.3. Real-world grief bounded by gas + opportunity cost.

---

## Priority 4: G4 — Vestigial Overflow

**Status: FIXED.**

`effective_30d_emission` now returns `total_30d_emission_auto()` only; manual field permanently ignored. Vestigial borrow kept for acquires parity. Dormant risk eliminated.

---

## ABI Compat & Regression Check

- **0 public/friend functions removed.** Purely additive (+11 fns, +2 structs)
- `settle()` body change = intentional deprecation, ABI-compatible via abort
- No existing struct field changes
- New resources at expected addrs (@desnet for DAO staging, vault_addr() for PendingSettle)
- Pkg size delta within 2-chunk limit
- MANIFEST.json + source_concat_sha3_256 verifiable

No regressions in PART-1/2/3 review.

---

## Other Observations

- **S4 (request/cancel grief):** bounded gas grief. Permissionless cancel net positive for liveness.
- **G5 hash-verify multisig:** strong defense-in-depth
- **G6/G7:** trivial annotations + cosmetic — good
- **Code quality:** High. Clear comments, consistent error codes, friend visibility correct, events comprehensive.

---

## Final Recommendation

**Deploy v0.3.3.**

High-quality, targeted fix release that closes major R5 findings while preserving (and improving) mainnet stability. S2/S3 known and acceptable.

Post-deploy:
- Monitor first few DAO chunked publishes and settle flows
- Plan v0.3.4 for per-proposal staging + minor polish

**Grok 4 (xAI) verdict: GREEN — production ready.**
