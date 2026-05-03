# DeepSeek Audit Verdict — v0.4.0-rc1 Opinion Module

**Reviewer:** DeepSeek
**Received:** 2026-05-03
**Verdict:** **GREEN with 2 MED findings**
**Recommendation:** Proceed to mainnet after addressing the two MED fixes
**Notable:** Confirms Gemini's swap tax issue but downgrades severity from HIGH → MED. Identifies new MED on zero-output swap edge case.

---

## Verbatim Response

# Audit Report: DeSNet v0.4.0-rc1 Opinion Module

**Auditor**: Independent security reviewer
**Commit**: `6ace5a4` (paranoid fixes applied)
**Scope**: Primary – `sources/opinion.move`; Touchpoints – `apt_vault.move`, `factory.move`, `history.move`, `profile.move`
**Date**: 2026-05-03

---

## Overall Verdict: GREEN with 2 MED findings

The module is structurally sound. All self-audit fixes (H1, M1-M5, L1-L2) are correctly implemented.
Two new medium-severity issues were identified; neither breaks core conservation or solvency.
The code is **ready for mainnet deployment** after these are addressed (or formally accepted as design trade-offs).

---

## 1. Verification of Self-Audit Fixes

All previously reported findings have been correctly resolved.

- **H1 (PID/wallet mismatch)** – `owner_has_token` and `token_metadata_of_owner` now correctly use `author_pid`.
- **M1 (missing conservation in swaps)** – `assert_conservation(mkt)` added at end of both swap functions.
- **M2 (missing pool-active check in deposit)** – explicit reserve > 0 assertion added.
- **M3 (dust tax evasion)** – `compute_tax` implements ceiling rounding; all new tests pass.
- **M4 (UX docs)** – interface doc-comments now describe tax holding requirements.
- **M5 (opinion limit)** – `MAX_OPINIONS_PER_PID` = 10,000 enforced.
- **L1 (`#[view]` on `compute_amount_out`)** – added.
- **L2 (FA name/symbol collision)** – seq appended; uniqueness guaranteed.

No regressions were introduced. The self-audit's "INFO" confirmations (conservation, overflow safety, ref sealing, friend correctness, etc.) are accurate.

---

## 2. New Findings

### 🔴 MED‑1: Swap tax computed on token amount instead of $creator_token value

**Location:** `swap_yay_for_nay()` / `swap_nay_for_yay()` → `burn_tax(amount_in, …)`

**Issue:**
The design specification (§4, Locked Decision #9) states:
> Swap tax: Proportional to amount_in **converted to $token via factory AMM quote**, with flat floor.

The implementation uses `amount_in` (the number of opinion tokens **YAY or NAY**) as the base for computing the tax in `$creator_token`. However, 1 YAY or 1 NAY is **not** equivalent to 1 $creator_token. The conversion rate depends on the pool's reserves (spot price). For example:

- If YAY price = 0.1 $token, swapping 100 YAY (value ~10 $token) incurs tax on 100 units, **10× higher** than intended.
- If YAY price = 0.9 $token, swapping 100 YAY (value ~90 $token) incurs tax on only 100 units, **under‑taxing** relative to value.

**Impact:**
- **Inconsistent taxation** – traders pay either far more or far less than the proportional tax designed for their economic exposure.
- **Deviation from spec** – the locked design explicitly calls for value‑based taxation using the factory AMM.
- Exploitability: an attacker could structure swaps when the opinion token is extremely cheap (e.g., just after creation or during skewed markets) to avoid taxes almost entirely, or be forced to overpay when the token is expensive, discouraging legitimate trading.

**Recommendation:**
Implement value conversion. The simplest correct approach is to query the **factory AMM** (which trades $creator_token against DESNET/APT) using `amm::compute_amount_out` to obtain the $creator_token value of the swapped amount. Alternatively, use the opinion pool's own spot price (`yay_price_token_1e8` / `nay_price_token_1e8`) as an on‑chain oracle, with awareness of short‑term manipulation. The former is preferred per the design lock.

**Severity:** MEDIUM – undermines the tax model's fairness and spec compliance, though not a funds‑loss or solvency bug.

---

### 🟡 MED‑2: Zero‑output swaps possible without slippage protection

**Location:** `compute_amount_out()` and swap entry functions.

**Issue:**
The CPMM formula `amount_out = reserve_out * amount_in / (reserve_in + amount_in)` performs integer division. If `amount_in` is very small relative to `reserve_in`, `amount_out` can truncate to **zero**. For example, with a pool of (100,000,100,000) and an input of 1 unit, `amount_out = 100,000 * 1 / (200,001) = 0`.

The swap functions **do** check `amount_out >= min_out`, and the caller can set `min_out = 1` to prevent zero‑output swaps. However, the current front‑end or naive users might not specify an appropriate `min_out`, leading to a trade that consumes gas and burns gas + potentially tax (if `tax_bps > 0`) while receiving 0 tokens.

In the degenerate case where `tax_bps > 0` and the user swaps 1 unit, the tax is at least 1 $creator_token (due to ceiling rounding), yet they get 0 output. The function does not abort because `amount_out >= min_out` with `min_out = 0` (default for an uninformed user) succeeds. This is a minor griefing/UX trap.

**Impact:**
- Users can lose input tokens + tax for no output if they fail to specify a reasonable `min_out`.
- Combined with the tax floor, even a very small swap incurs a non‑zero tax, making the zero‑output scenario more painful.

**Recommendation:**
Enforce a **minimum output** ≥ 1 when `amount_in > 0`. In the swap functions, after computing `amount_out`, add:
```move
assert!(amount_out > 0, E_SLIPPAGE_EXCEEDED);  // or a separate error code
```
This prevents zero‑output swaps entirely, regardless of user‑supplied `min_out`.

**Severity:** MEDIUM – leads to verifiable loss in normal operation, but requires user error (not setting slippage) to trigger; tax burn makes it worse. Fix is trivial.

---

### 🟢 LOW‑1: Lack of `min_out` enforcement in `deposit_pick_side` and `redeem_complete_set`

These operations do not take a slippage parameter; they directly use the pool as a storage/redemption mechanism. `deposit_pick_side` deposits the "other" side into the pool without any exchange — it is not a swap, so no slippage applies. `redeem_complete_set` burns exact amounts and withdraws exact vault collateral. Therefore, no slippage parameter is needed. This is by design and not a finding.

---

### 🟢 INFO‑1: Edge case in `compute_tax` for `u64::MAX` input

The test `test_compute_tax_max_bounds_no_overflow` confirms that no overflow occurs. The ceiling rounding adds `BPS_DENOM - 1` (9999) to the numerator; at maximum values the intermediate u128 comfortably accommodates the result. No action required.

---

## 3. Security Dimensions Assessment

| Dimension | Status | Comments |
|-----------|--------|----------|
| Conservation invariant | ✅ Sound | `vault == total_yay == total_nay` enforced at every mutating entry. |
| CPMM math | ✅ Correct | `compute_amount_out` implements standard constant product; no rounding advantage. |
| Access control | ✅ Sealed | MintRef/BurnRef inside OpinionMarket; friend declarations correct; signer authority used correctly. |
| Financial solvency | ✅ Guaranteed | Vault always covers all outstanding pair‑redemptions; pool reserves are not directly redeemable. |
| Griefing / DoS | ✅ Mitigated | Opinion count cap, tax floor, pool‑active checks, and atomic rollbacks prevent abuse. |
| Upgrade safety | ✅ Compatible | Only additive changes to history, vault, profile; market objects non‑transferable. |

---

## 4. Summary of Required Changes

| # | Severity | Description | Fix |
|---|----------|-------------|-----|
| MED‑1 | Medium | Swap tax uses token count, not dollar value | Convert amount to $token via factory AMM |
| MED‑2 | Medium | Zero‑output swaps possible | Assert `amount_out > 0` in swap functions |

All other code meets the stated design and security requirements.

---

## 5. Final Recommendation

**Proceed to mainnet deployment** after implementing the two MED fixes above. The module is well‑engineered, self‑audit findings are fully addressed, and the new issues are correctable with minimal refactoring. With those fixes, the acceptance bar (≥4 GREEN, zero unfixed HIGH) is comfortably met.

---

## Triage Notes (auditor-side review)

### CRITICAL: D-M1 is convergent confirmation of G-H1 (severity downgrade HIGH → MED)

DeepSeek's MED-1 is the SAME finding as Gemini's G-H1 (swap tax computed on raw amount_in instead of $creator_token equivalent). Both reviewers cite the same design doc §4 #9 line "via factory AMM quote" as the spec requirement.

**Severity assessment**:
- Gemini: HIGH ("severely over-taxed", "broken")
- DeepSeek: MED ("not a funds-loss or solvency bug")
- Kimi: NOT-A-BUG (rejects entirely as design choice)

**Convergence**: 2/4 reviewers (Gemini + DeepSeek) flag as bug requiring fix. 1/4 (Kimi) explicit counter. Net: **CONVERGENT MED** (severity median = MED, taking DeepSeek's lower-rated assessment over Gemini's HIGH because they're the 2nd confirmer and the bug is fairness/spec deviation, not solvency).

**Per R6 precedent**: ≥2 reviewer convergence escalates to fix-required. Kimi's solo counter alone insufficient to reject (would need ≥2 explicit counters to dismiss). Recommendation: address as v0.4.0-rc2 fix.

### NEW: D-M2 zero-output swap (solo, valid)

DeepSeek-only finding. Real edge case: with naive `min_out=0`, user can lose input + tax for zero output. Trivial fix: add `assert!(amount_out > 0, E_SLIPPAGE_EXCEEDED)` in swap functions. Solo finding but technically sound.

**Worth considering** for rc2 fix bundle alongside D-M1. Alternative: rely on frontend to enforce sane `min_out` (acceptable for UX-trap class, but on-chain assertion is simple defense-in-depth).

### Other observations

- DeepSeek's INFO-1 (compute_tax overflow safety) confirms self-audit + matches existing test coverage. No action.
- DeepSeek's "LOW-1" is actually a non-finding (clarifies why deposit/redeem don't need slippage). Useful observation, not actionable.
- DeepSeek's SS-Dimensions assessment matches Kimi + Grok on conservation, capability sealing, etc. Strong consensus on core security properties.
