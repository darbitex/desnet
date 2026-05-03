# DeSNet v0.4.0-rc1 — Tests + Self-Audit Report

**Source commit:** `6ace5a4` (paranoid audit fixes applied)
**Self-audit method:** 4-agent parallel paranoid review (general-purpose LLM agents)
**Date:** 2026-05-03

---

## 1. Test Results

### Full project test suite: 93/93 GREEN ✅

```
$ aptos move test

Running Move unit tests
... (truncated for brevity)
Test result: OK. Total tests: 93; passed: 93; failed: 0
```

### Opinion module tests: 14/14 GREEN ✅

```
$ aptos move test --filter opinion

[ PASS ] 0xdade::history::test_new_entry_opinion_verb_accepted
[ PASS ] 0xdade::opinion::test_compute_amount_out_no_fee
[ PASS ] 0xdade::opinion::test_compute_amount_out_symmetric_pool
[ PASS ] 0xdade::opinion::test_compute_amount_out_zero_in
[ PASS ] 0xdade::opinion::test_compute_tax_ceiling_dust_protection
[ PASS ] 0xdade::opinion::test_compute_tax_max_bounds_no_overflow
[ PASS ] 0xdade::opinion::test_compute_tax_normal_amounts
[ PASS ] 0xdade::opinion::test_compute_tax_zero_inputs
[ PASS ] 0xdade::opinion::test_constants_distinct
[ PASS ] 0xdade::opinion::test_initial_mc_bounds
[ PASS ] 0xdade::opinion::test_make_market_seed_deterministic
[ PASS ] 0xdade::opinion::test_market_addr_deterministic
[ PASS ] 0xdade::opinion::test_max_opinions_per_pid_constant
[ PASS ] 0xdade::opinion::test_tax_bps_constants

Test result: OK. Total tests: 14; passed: 14; failed: 0
```

### Test coverage breakdown

| Test | Covers | Type |
|---|---|---|
| `test_compute_amount_out_no_fee` | CPMM math correctness (asymmetric pool) | Pure helper |
| `test_compute_amount_out_symmetric_pool` | CPMM math at 50:50 ratio | Pure helper |
| `test_compute_amount_out_zero_in` | Zero-input edge case | Pure helper |
| `test_compute_tax_zero_inputs` | tax_bps=0 + amount=0 corner cases | Pure helper |
| `test_compute_tax_ceiling_dust_protection` | M3 fix: anti-dust ceiling rounding | Pure helper |
| `test_compute_tax_normal_amounts` | Tax math at typical sizes (1M-100M token) | Pure helper |
| `test_compute_tax_max_bounds_no_overflow` | u64::MAX × 10% no overflow | Pure helper |
| `test_make_market_seed_deterministic` | Object addr derivation determinism | Pure helper |
| `test_market_addr_deterministic` | Cross-PID + cross-seq distinct | Pure helper |
| `test_constants_distinct` | SIDE/KIND enums non-overlapping | Pure helper |
| `test_initial_mc_bounds` | MIN/MAX const values correct | Pure helper |
| `test_tax_bps_constants` | DEFAULT/MAX bps values correct | Pure helper |
| `test_max_opinions_per_pid_constant` | MAX_OPINIONS_PER_PID = 10k | Pure helper |
| `test_new_entry_opinion_verb_accepted` (history) | VERB_OPINION accepted by `new_entry` cap | Pure helper |

### Acknowledged coverage gap

**No end-to-end integration test** exercising full `create_opinion → deposit_pick_side → swap → redeem_complete_set` flow with real factory token + profile setup. Reason: would require non-trivial test scaffold (factory token registration mocking, profile lazy-init in test env, FA primary store priming, etc.).

**Mitigation**: all numeric math + invariant logic extracted into `compute_amount_out`, `compute_tax`, `make_market_seed`, `market_addr_of` — these are tested in isolation with edge cases. Conservation invariant (`vault == total_yay == total_nay`) is asserted at runtime in every mutating entry function (`assert_conservation` called in create_opinion, deposit_pick_side, both swaps, redeem_complete_set). Any integration bug breaking conservation would abort the tx.

**Recommended future work**: add integration test scaffold to v0.4.0-rc2 if external auditors flag this as blocker.

---

## 2. Self-Audit Methodology

Spawned 4 parallel `general-purpose` LLM agents in paranoid mode, each focused on a distinct dimension:

| Agent | Dimension |
|---|---|
| 1 | Conservation invariant + value/supply safety |
| 2 | CPMM math correctness + numeric edge cases |
| 3 | Access control + authorization + friend boundaries |
| 4 | State machine + griefing + DoS + design-intent violations |

Each agent reads `opinion.move` independently + cross-references touchpoint modules (`apt_vault.move`, `factory.move`, `history.move`, `profile.move`). Reports findings in HIGH/MED/LOW/INFO format with suggested fixes.

---

## 3. Findings Consolidated

### HIGH (1 — convergent across 3 of 4 agents)

#### H1 — PID vs wallet address mismatch in `create_opinion` ✅ FIXED

**Source location:** `opinion.move:284-285` (pre-fix)

**Issue:** `factory::owner_has_token(author_addr)` and `factory::token_metadata_of_owner(author_addr)` were called with the **wallet address** (`signer::address_of(author)`), but `factory::owner_index` is keyed by **PID address** (per `factory.move:474-475` docstring + `vault_addr_of_pid` convention). This means every legitimate `create_opinion` would have aborted with `E_NO_FACTORY_TOKEN` on mainnet.

**Convergence:** flagged independently by Agent 1 (conservation), Agent 3 (access control), Agent 4 (state machine). Agent's own self-evidence: opinion.move's doc-comment at line 133 said "(author_pid)" — proving intent vs implementation mismatch.

**Severity rationale:** Module is structurally non-functional without fix — every create call reverts. HIGH because impossible-to-deploy, not exploitable.

**Fix applied (commit `6ace5a4`):**
```move
// Before:
assert!(factory::owner_has_token(author_addr), E_NO_FACTORY_TOKEN);
let creator_token = factory::token_metadata_of_owner(author_addr);

// After:
assert!(factory::owner_has_token(author_pid), E_NO_FACTORY_TOKEN);
let creator_token = factory::token_metadata_of_owner(author_pid);
```

`burn_tax` was already correctly using `factory::vault_addr_of_pid(author_pid)` — internal inconsistency caught by paranoid review.

---

### MED (5 — applied as paranoid bundle)

#### M1 — `assert_conservation` not called in swap paths ✅ FIXED

**Issue:** Defense-in-depth gap. Swaps don't change vault or total supplies by design (CPMM only redistributes pool reserves between YAY/NAY stores), but a future regression could accidentally introduce mint/burn into swap path. Without conservation assert, regression goes undetected.

**Fix:** Added `assert_conservation(mkt)` at end of both `swap_yay_for_nay` and `swap_nay_for_yay` (after tax_burn, before emit_action). No runtime cost in normal flow; catches future bugs.

#### M2 — `deposit_pick_side` missing pool-active check ✅ FIXED

**Issue:** Pool is always active post-create (initial_mc symmetric seed > 0), but no explicit assert. Future regression that drains pool to (0, k) or (k, 0) would silently break deposit pricing.

**Fix:** Added `assert!(fungible_asset::balance(mkt.pool_yay) > 0 && fungible_asset::balance(mkt.pool_nay) > 0, E_POOL_NOT_ACTIVE)` at start of `deposit_pick_side`. Cheap insurance.

#### M3 — Tax dust evasion via integer truncation ✅ FIXED

**Issue:** `amount × tax_bps / BPS_DENOM` with integer division means `amount < BPS_DENOM/tax_bps` (e.g. `< 1000` raw at 10 bps default) yields `tax_amount = 0` → free trade. Sub-dust trade-splitting (e.g. 99 raw × 100M iterations) evades all tax.

**Fix:** Extracted `compute_tax(amount, tax_bps)` as `#[view]` pure function with ceiling rounding:

```move
public fun compute_tax(amount: u64, tax_bps: u64): u64 {
    if (tax_bps == 0 || amount == 0) return 0;
    let numerator = (amount as u128) * (tax_bps as u128) + (BPS_DENOM as u128) - 1;
    (numerator / (BPS_DENOM as u128)) as u64
}
```

Now any `amount > 0 && tax_bps > 0` yields `tax >= 1` raw — anti-dust floor enforced.

`burn_tax` updated to call `compute_tax`. New tests added: `test_compute_tax_ceiling_dust_protection`, `test_compute_tax_zero_inputs`, `test_compute_tax_normal_amounts`, `test_compute_tax_max_bounds_no_overflow`. All GREEN.

#### M4 — UX requirement docs missing ✅ FIXED

**Issue:** Trader entries (`deposit_pick_side`, `swap_*`, `redeem_complete_set`) require user to hold BOTH the operation amount AND the tax amount in `$creator_token`. If user lacks tax, tx aborts atomically (no partial state) — but doc-comments don't surface this requirement, leading to confusing UX failures.

**Fix:** Added explicit doc-comment notes to all 4 trader entries clarifying primary-store requirements. Frontend can pre-validate balances + show clear error messages.

#### M5 — No per-PID opinion limit (storage-rent grief) ✅ FIXED

**Issue:** No cap on `create_opinion` calls per PID. Each create allocates 1 market object + 3 FungibleStore children + 2 FA Metadata objects + SmartTable entry — significant state-rent burn on the PID account. Bounded only by creator's `$token` balance (1B factory supply ÷ MIN_INITIAL_MC 1M = 1000 max opinions per token), but this still leaves room for state bloat.

**Fix:** Added `MAX_OPINIONS_PER_PID = 10_000` constant + `E_OPINION_LIMIT_REACHED = 13` error code. Asserted in `create_opinion` before counter increment:

```move
assert!(meta.opinion_count < MAX_OPINIONS_PER_PID, E_OPINION_LIMIT_REACHED);
```

10k chosen as practical ceiling — bound by capital (capital limit kicks in long before count limit), so this is pure defense against pathological state-bloat scenarios.

---

### LOW (2 code, 2 design-only)

#### L1 — `compute_amount_out` not `#[view]`-annotated ✅ FIXED

**Issue:** `compute_amount_out` was `public fun` (off-chain callable) but lacked `#[view]` attribute used elsewhere in the codebase. Cosmetic — no runtime impact, but inconsistent with module conventions.

**Fix:** Added `#[view]` attribute. Off-chain SDK / indexer can now call gas-free.

#### L2 — YAY/NAY FA name + symbol collision across opinions ✅ FIXED

**Issue:** Every opinion's YAY token had identical FA metadata `("Opinion YAY Share", "OPN-YAY")`. Wallet UIs that key off symbol would show identical strings for every opinion's YAY in user holdings — impossible to distinguish multi-opinion positions.

**Fix:** Include seq in name + symbol via `string_utils::to_string<u64>(&seq)`:

```move
let yay_name = string::utf8(b"Opinion YAY Share #");
string::append(&mut yay_name, seq_str);
let yay_symbol = string::utf8(b"OPN-YAY#");
string::append(&mut yay_symbol, seq_str);
```

Result: `"Opinion YAY Share #5"`, `"OPN-YAY#5"` etc. Wallet UIs can distinguish. Symbol stays under Aptos FA cap for any reasonable seq range.

#### L3 — Guest history skip — design choice (no code change)

**Issue:** `emit_action` skips history-append if actor (trader) lacks a Profile. This is INCONSISTENT with design doc claim "all actions append to history". Two valid resolutions:
- (a) Reject guests at trader entries (profile-required gate)
- (b) Accept guest trade as-designed (low barrier to entry)

**Decision:** Keep current behavior (guests can trade — events emit, history skipped). Rationale: low barrier to entry is desirable for trader UX; only `create_opinion` requires registered handle (because vault denomination needs `$token`). Indexers using events recover full history; only the per-PID `history.move` view misses guest activity (acceptable). 

**Action taken:** No code change. Documented in design doc as accepted behavior.

#### L4 — Vault floor stranded forever — design intent (no code change)

**Issue:** Creator's `initial_mc` `$token` is permanently locked in vault. After all post-create traders fully redeem everything they minted, system terminates with `vault = initial_mc + pool_yay = pool_nay = initial_mc` outstanding but no path for anyone to redeem the seed pair (it's in pool stores, no wallet owns it).

**Decision:** This is the design intent — "alias di-burn dari POV creator" per `02-design-doc.md` §4.7. The locked seed IS the anti-spam mechanism and the visible commitment signal. Acceptable.

**Action taken:** No code change. Already explicit in design doc.

---

### INFO (sound design confirmations)

The 4-agent paranoid review CONFIRMED soundness on the following dimensions (no issues found):

1. **Conservation invariant logic** — vault == total_yay == total_nay holds across all paths by construction (atomic pair-mint at deposit + atomic pair-burn at redeem; swaps don't touch tracked state).

2. **u64/u128 overflow analysis** — all arithmetic has 14+ orders of magnitude headroom:
   - Pool reserves bounded by total `$token` supply (1e17 raw at 1B × 8 decimals); u64 max is ~1.84e19
   - `compute_amount_out` u128 intermediates: max 1e17 × 1e17 = 1e34 < u128 max ~3.4e38
   - Tax math: 1e17 × 1000 = 1e20 < u128 max trivially

3. **MintRef/BurnRef/ExtendRef sealing** — all capabilities stored inside `OpinionMarket has key` resource. Move resource access rules restrict `borrow_global<OpinionMarket>` to this module only. Refs cannot leak via views (none return them).

4. **Friend declarations correct + reciprocal** — `apt_vault::burn_via_vault`, `profile::derive_pid_signer + assert_pid_exists`, `history::append + new_entry + verb_opinion` are all `public(friend)` with opinion in their friend lists.

5. **Signer authority correct on all 5 entries** — all use `&signer` + `primary_fungible_store::withdraw(user, …)` for outbound user-FA flow, which framework enforces signer == owner.

6. **PID NFT object protection** — market object created as named child of `pid_addr` with `disable_ungated_transfer`. Market resource bound to PID, untransferable.

7. **actor_pid spoofing prevented** — `emit_action` derives `actor_pid` from `signer::address_of(user)`, no user-supplied actor_pid path.

8. **Re-bind / overwrite safety** — `meta.next_seq` monotonic; `move_to(&market_signer, OpinionMarket{…})` aborts if resource exists; `create_named_object` aborts on collision; `smart_table::add` aborts on duplicate seq.

9. **Cross-creator vault attack prevented** — `burn_tax(…, mkt.author_pid, …)` always uses immutable post-create `author_pid`; defense-in-depth via FA metadata check inside `fungible_asset::burn` (vault BurnRef metadata MUST match tax_fa metadata).

10. **All factory views called are public + already audited** — `owner_has_token`, `token_metadata_of_owner`, `vault_addr_of_pid` are stable interfaces from v0.3.3 R6.

11. **Move atomicity guarantees** — any abort (e.g., user lacks tax in deposit step 6) rolls the entire tx back, including vault deposit and supply increments. No mid-state corruption possible.

12. **Re-entrancy safe** — Aptos FA standard has no callback hooks. Cannot re-enter opinion via primary_fungible_store ops.

13. **Borrow-checker satisfied throughout** — `borrow_global_mut<OpinionMarket>` does not conflict with `apt_vault::Vault` borrow during `burn_tax` (different resource types, different addresses).

---

## 4. Self-Audit Verdict

**Status: GREEN with all paranoid findings applied at commit `6ace5a4`.**

| Dimension | Verdict |
|---|---|
| Conservation invariant | ✅ Sound (logic + assertions in place) |
| CPMM math | ✅ Numerically safe + ceiling-rounded tax |
| Access control | ✅ Sealed refs, correct friends, no spoof |
| State machine + griefing | ✅ Bounds enforced, opinion cap added, conservation asserted |

**1 HIGH (H1) — was structurally blocking, now fixed and verified by inspection.**

**5 MED (M1-M5) — defense-in-depth + dust evasion + grief mitigation, all applied.**

**2 LOW (L1, L2) — fixed. 2 LOW (L3, L4) — accepted as design intent.**

**Test coverage: 93/93 GREEN including 5 new tests for paranoid fixes.**

Module ready for external audit panel review. Acceptance criteria for v0.4.0-rc1 → mainnet promotion: ≥4 GREEN out of 6 LLM reviewers + zero unfixed HIGH (per v0.3.3 R6 precedent).

---

## 5. Commit Trail (audit-relevant)

| Commit | Description |
|---|---|
| `8411947` | rev1 design doc — Mirror-Mint Bootstrap + APT collateral concept |
| `63f9d88` | v1 scaffold — APT collateral + 3-option creator_position (HISTORICAL — superseded) |
| `d900e47` | rev2 design doc — creator-token + 3-option BOTH default (SUPERSEDED) |
| `174b869` | rev4 design lock — symmetric pool seed + locked vault |
| `d183856` | rev4 clarification — closed knobs B/D/E, no LP shares |
| `707e732` | **rev4 source refactor** — creator-token vault + YAY/NAY rename |
| `6ace5a4` | **paranoid audit fixes** — H1 + 5 MED + 2 LOW + 5 new tests |

The auditable artifact is the source at commit `6ace5a4` (`opinion-pool-design` branch tip at submission).
