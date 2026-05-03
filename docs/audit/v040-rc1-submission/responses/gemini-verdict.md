# Gemini Audit Verdict — v0.4.0-rc1 Opinion Module

**Reviewer:** Gemini
**Received:** 2026-05-03
**Verdict:** **YELLOW — 1 HIGH, 1 MED, 1 LOW, 1 INFO**
**Recommendation:** Address HIGH finding before mainnet promotion

---

## Verbatim Response

This is a very thorough and well-documented submission. The mathematical spine of the pure constant-product curve ($x \cdot y = k$) combined with the Mirror-Mint Bootstrap is an elegant solution for a perpetual, no-settle opinion market.

I have reviewed the provided scope, focusing deeply on `opinion.move` and the specific cross-module touchpoints. Overall, the conservation invariants are incredibly tight, and the symmetric pool seed safely bypasses the typical phase-1 lockup risks of bonding curves.

However, during the deep dive into the integration of the tax burn mechanics, I identified a critical flaw in how the swap tax is calculated, alongside a few architectural optimizations.

Here is the verdict and the detailed audit report.

---

### **Audit Verdict**
**Status:** **1 HIGH**, **1 MED**, **1 LOW**, **1 INFO**.
**Recommendation:** Address the HIGH finding regarding the swap tax base calculation before proceeding to the v0.4.0-rc2 mainnet deploy. The mathematical invariants hold, but the economic application of the tax rate during swaps is currently broken.

---

### **Detailed Findings**

#### **[HIGH] Incorrect Nominal Base for Swap Tax Calculation**
* **Location:** `opinion.move`, functions `swap_yay_for_nay` and `swap_nay_for_yay`
* **Description:** The swap functions currently pass `amount_in` (which is denominated in YAY or NAY tokens) directly into the `burn_tax` function. The inline developer comment justifies this by stating: *"YAY is 1:1 with creator_token redemption"*. This assumption is mathematically false. As established by your conservation invariant, it requires a complete set to redeem:
$$1 \text{ YAY} + 1 \text{ NAY} = 1 \text{ \$creator\_token}$$
Because a single YAY or NAY token represents only a fractional value of the underlying collateral, applying the tax rate to the raw YAY/NAY amount effectively overcharges the trader. Furthermore, this contradicts your locked design document, which explicitly requires the swap tax to be proportional to the `amount_in` converted to its `$creator_token` equivalent via an AMM quote.
* **Impact:** Users are severely over-taxed on swaps. For example, if the pool is heavily skewed and 100 NAY is only worth 10 `$creator_token`, a user swapping 100 NAY is taxed as if they just traded 100 `$creator_token`.
* **Suggested Fix:** Before calling `burn_tax`, calculate the spot value of the `amount_in` in terms of the underlying collateral. Since the spot price of YAY in `$creator_token` is $\frac{\text{NAY}_{\text{reserve}}}{\text{YAY}_{\text{reserve}} + \text{NAY}_{\text{reserve}}}$, you can derive the underlying collateral value of the trade. Alternatively, implement the factory AMM quote lookup as originally specified in the v1 $\rightarrow$ v2 refactor checklist.

#### **[MED] 100% Tax on Dust Redemptions**
* **Location:** `opinion.move`, function `redeem_complete_set`
* **Description:** The `redeem_complete_set` function requires the user to burn `amount` of YAY and NAY, releases `amount` of `$creator_token` to the user, and then withdraws `compute_tax(amount, tax_bps)` from the user to burn it. Because `compute_tax` enforces a strict ceiling to act as an anti-dust protection, any fraction of a tax resolves to at least `1`. If a user attempts to redeem exactly `1` unit of YAY/NAY (dust), the tax will consume the entire `1` unit returned from the vault.
* **Impact:** While mathematically safe and highly effective at preventing zero-tax dust spam, this effectively acts as a 100% tax rate on micro-redemptions.
* **Suggested Fix:** This is acceptable by design based on your anti-dust requirements, but the frontend clients must be made explicitly aware of this. Ensure the UI warns users or prevents them from redeeming sub-tax-threshold dust amounts to avoid unexpected total loss of their redeemed collateral.

#### **[LOW] Double-Withdrawal Inefficiency in Deposit Flow**
* **Location:** `opinion.move`, function `deposit_pick_side`
* **Description:** In the deposit flow, the contract performs a `primary_fungible_store::withdraw` for the main `amount_token` collateral, and then subsequently triggers a second identical `withdraw` internally when calling `burn_tax`.
* **Impact:** While functionally correct (the transaction will atomically revert if the user lacks the combined sum), performing two sequential withdrawals from the exact same store is slightly gas-inefficient and clutters the on-chain event logs with redundant framework-level withdrawal events.
* **Suggested Fix:** Compute the tax upfront in the main function body. Perform a single withdrawal of `amount_token + tax_amount`. Deposit `amount_token` into the market vault, and pass the remaining `tax_amount` FA directly to `apt_vault::burn_via_vault`.

#### **[INFO] History Append Fall-Through Validation**
* **Location:** `history.move`, function `append`
* **Description:** You noted that the addition of `VERB_OPINION = 7` relies on a compat-safe fall-through in the `history::append` logic to avoid breaking the `HistoryLog` struct layout.
* **Validation:** This is a sound and pragmatic approach to smart contract upgradability. As long as the upstream `history::append` logic safely ignores unmapped verbs without causing a runtime abort, this additive change is perfectly safe.

---

### **Design Evaluation Validation**

To close the loop on your specific requests for evaluation on the key design decisions:

1. **Vault collateral = creator's $token:** This successfully closes the economic loop. By preventing the need to dump the token to bootstrap liquidity, you have secured a self-reinforcing reputation mechanism.
2. **Symmetric pool seed at create:** The math holds flawlessly. Because the pool receives `initial_mc` of both YAY and NAY, $k$ is active from block 0, entirely mitigating the vulnerability of early single-sided curve manipulation.
3. **Conservation invariant:** The core invariant (`vault == total_yay == total_nay`) is maintained rigorously across all four operational paths (create, deposit, swap, redeem). The separation of the tax burn from the pool's internal reserves ensures the CPMM logic is never polluted by the deflationary mechanic.

Let me know if you need to workshop the math for the swap tax fix!

---

## Triage Notes (auditor-side review)

### HIGH — VALIDATED + CRITICAL
Gemini's HIGH finding is **mathematically correct**. Verification:
- Code at `opinion.move` line 571 (swap_yay_for_nay): `burn_tax(user, mkt.creator_token, mkt.author_pid, amount_in, mkt.tax_bps)` passes raw YAY amount.
- Code comment line 570: `"YAY is 1:1 with creator_token redemption"` — false claim. Only PAIR is 1:1; standalone YAY = `nay_r / (yay_r + nay_r)` $creator_token spot.
- Design doc `02-design-doc.md` §4 line 156 explicitly says: `"Swap tax: Proportional to amount_in converted to $token via factory AMM quote"`. Code contradicts own design.
- Concrete overcharge: at pool (10, 100), swapping 100 NAY taxed at `100 * 10/10000 = 0.1` token but actual value `9.09 $creator_token` → correct tax `0.009`. **~11× overcharge** at this skew. Worst case ~100× at extreme skew.
- Bug isolated to swap functions — deposit/redeem use 1:1 correctly (deposit creates fresh pair from $token, redeem burns balanced pair for $token).

**Fix path** (clean CPMM math, no factory AMM hop needed):
```move
// In swap_yay_for_nay, after capturing pool_yay_r + pool_nay_r:
let amount_in_token_equiv = ((amount_in as u128) * (pool_nay_r as u128)
    / ((pool_yay_r as u128) + (pool_nay_r as u128))) as u64;
let tax_burned = burn_tax(user, mkt.creator_token, mkt.author_pid,
                          amount_in_token_equiv, mkt.tax_bps);

// In swap_nay_for_yay, swap pool_yay_r ↔ pool_nay_r in numerator.
```

Math safety: `amount_in × pool_reserve` ≤ 1e17 × 1e17 = 1e34, well under u128 max ~3.4e38. ✓

### MED — VALID, design-acceptance documentation gap
Dust redemption 100% tax effect is mathematically real (per M3 ceiling rounding) but acceptable per anti-dust design intent. Gemini's recommendation: frontend warn / prevent sub-threshold redeems. Consider adding to design doc + frontend integration checklist.

### LOW — VALID optimization
Double-withdraw in deposit/swap/redeem flows. Genuine gas saving + cleaner event logs. ~3 line refactor per entry function. No behavior change. Worth bundling with HIGH fix in v0.4.0-rc2.

### INFO — non-blocking
History fall-through validation confirms additive design soundness. No action needed.
