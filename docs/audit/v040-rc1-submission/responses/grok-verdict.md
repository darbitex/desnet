# Grok Audit Verdict — v0.4.0-rc1 Opinion Module

**Reviewer:** Grok
**Received:** 2026-05-03
**Verdict:** **GREEN (with minor INFO notes)**
**Recommendation:** Promote to mainnet after ≥4/6 reviewer GREEN consensus

---

## Verbatim Response

**Audit Verdict: GREEN (with minor INFO notes).** The module is ready for mainnet deployment per the acceptance bar (zero HIGH, all prior self-audit fixes verified). Strong design, solid implementation, excellent invariant enforcement, and good use of Aptos primitives.

I performed a full review of the provided package (`01`–`04`), with deep focus on `opinion.move` (primary scope), touchpoints, invariants, math, and design alignment (rev4 symmetric seed + creator-token collateral).

### Summary of Findings
- **HIGH**: 0
- **MED**: 0 (all self-audit MEDs properly fixed and verified)
- **LOW**: 2 (minor, cosmetic/UX)
- **INFO**: 4 (good practices / future polish)

### 1. Conservation Invariant (Core Security Property)
**Verified: Sound and robustly enforced.**

```
vault_$creator_token == total_yay_supply == total_nay_supply
```

- **create_opinion**: Symmetric seed (`initial_mc` pulled → vault; both sides minted → pool). Post-create `assert_conservation` ✓.
- **deposit_pick_side**: Atomic pair-mint (`+amount` to both supplies + vault). Opposite side to pool. `assert_conservation` ✓.
- **redeem_complete_set** (inferred from symmetry + partial code): Pair-burn + vault release. `assert_conservation` ✓.
- **swaps**: No touch to vault/supplies (pure reserve redistribution). `assert_conservation` added post-tax (M1 fix) ✓.
- **burn_tax**: External burn (via friend delegation) — does *not* affect opinion supplies/vault. Correct.

**Solvency**: Always holds by atomic pair-mint/burn. Swaps are pure CPMM. No mint/burn outside controlled paths. `assert_conservation` on every mutating entry is excellent defense-in-depth. No way for supplies to desync from vault.

**Vault floor (`initial_mc` locked forever)**: As-designed ("alias di-burn" from creator POV). Traders can only redeem *their* balanced pairs earned via activity. Seed pair stays in pool stores. Anti-spam + commitment signal. Correct per design doc §4.7.

### 2. CPMM Math & Numeric Safety
**Verified: Correct.**

- `compute_amount_out`: Standard UniV2 `dy = reserve_out * dx / (reserve_in + dx)` (no fee, as designed). u128 intermediates prevent overflow. Tests cover symmetric/asymmetric/zero cases. Good.
- `compute_tax`: Ceiling rounding (`+ BPS_DENOM - 1`) is the correct fix for M3 dust evasion. Anti-dust floor (`>=1` raw when `amount>0 && tax_bps>0`). u128 safety. Tests excellent (including u64::MAX edge).
- Prices (`yay_price_token_1e8` etc.): Correct marginal pricing based on reserves (1Y + 1N = 1 collateral redeem basis).

No overflow risk (pool sizes bounded by factory supply ~1e17 raw << u128).

### 3. Access Control, Capabilities & Friends
**Verified: Tight and correct.**

- **Mint/Burn/Extend refs**: Sealed inside `OpinionMarket has key` at market object (only this module can `borrow_global_mut`). No leakage.
- **Market object**: Named child of PID (`create_named_object` + `disable_ungated_transfer`). Deterministic, untransferable, bound to author PID. Excellent.
- **Signer authority**: All entries take `&signer` for user ops (`primary_fungible_store::withdraw`). Framework-enforced ownership.
- **Friends**:
  - `apt_vault::burn_via_vault`: Type-safe (FA metadata match enforced by framework `burn`). Correct delegation.
  - `profile::*` + `history::*`: Standard, minimal, reciprocal.
- **Factory views**: Stable public APIs (PID-keyed). H1 PID-vs-wallet fix correctly applied (`author_pid` everywhere).
- **No reentrancy**: FA ops have no callbacks; no external calls before state updates in critical paths.

**Creator rights**: Post-create participation allowed (as trader, pays tax). No privileged post-seed liquidity. Matches design.

### 4. Key Flows & Edge Cases
- **create_opinion**:
  - Content length, `initial_mc` bounds ([1M,100M] whole tokens), tax cap: Enforced.
  - Guest restriction + factory token check: Correct (PID-based).
  - Per-PID cap (`MAX_OPINIONS_PER_PID=10_000`): Good anti-grief (M5).
  - FA names/symbols with seq (L2 fix): Prevents wallet UI collision. Good.
- **deposit_pick_side**: Mirror-mint + pick-side + tax. Pool-active assert (M2). Requires user holds `amount + tax`.
- **Swaps**: Slippage protection (`min_out`), tax burn, CPMM.
- **redeem**: Pair-burn + vault release + tax (symmetric to deposit).
- **History/Events**: `is_opinion: true` sentinel + BCS payloads. Guest skip in history (L3) is acceptable (events cover indexers).
- **Determinism**: `make_market_seed` + `market_addr_of` solid. Tests good.

**Phase 1 (one-sided)**: Trading locked until opposite side arrives. As-designed (skin-in-game). Pool always starts active (`k=initial_mc²`).

**Tax**: Always in `$creator_token`, burned via vault. Creator-controlled per-market, immutable. Deflationary + closed economic loop. Good.

### 5. Integration Touchpoints
- All friend grants minimal/additive.
- `history::new_entry` verb cap bumped safely.
- Factory views unchanged and stable.
- No breakage to prior audited modules (v0.3.3 R6 baseline).

### Minor Issues (LOW/INFO)
**LOW**:
1. **No end-to-end integration tests** (acknowledged gap). Math/helpers are thoroughly unit-tested + invariant asserted at runtime. Not a blocker, but add scaffold for rc2.
2. **Missing explicit `redeem_complete_set` full source** in the truncated `03` (inferred correct by symmetry + conservation calls). Provide full for future audits.

**INFO** (non-blocking):
- Consider `#[view]` on more helpers if not already.
- Guest trading (no profile) is fine for UX but document clearly for indexers.
- Add input validation on `swap` amounts vs. user balance (framework does most, but explicit pre-checks help UX).
- Long-term: Consider formal specs/proofs for invariant if scaling heavily.

### Design Alignment
All locked decisions (rev4 symmetric seed, creator-token collateral/vault/tax, no LP shares/fees, no press coupling, etc.) are faithfully implemented. Economic loop closed. Novel perpetual opinion pool without oracle/settle — mechanically sound.

**No backdoors, no privilege escalation, no conservation breaks, no numeric exploits, no grief vectors beyond bounded caps.**

**Recommendation**: Promote to mainnet after ≥4/6 reviewer GREEN consensus. Excellent work — paranoid self-audit paid off. Ready for v0.4.0.

If you share full `redeem_complete_set` or want me to review a specific function/test scenario in more depth, provide it.

---

## Triage Notes (auditor-side review)

### LOW #2 — FALSE POSITIVE
Grok claims `redeem_complete_set` source was truncated in `03-source-code.md`. **Verified false**: full source IS present at lines ~549-607 of `03-source-code.md`, including the entire entry function body (assert vault balance, withdraw YAY+NAY from user, burn pair, decrement supplies, vault release, tax burn, conservation assert, emit_action). Grok likely skim-read or got confused by file length. **No action needed**.

### LOW #1 — VALID, ACKNOWLEDGED GAP
Integration test gap — already documented in submission `04` §1.3 as known limitation. Not a blocker; defer to v0.4.0-rc2 if convergent.

### INFO — non-blocking
All 4 INFO items are nice-to-haves. Most `#[view]` annotations already in place. Guest trading documentation suggested. Consider for v0.4.0-rc2 polish if other convergent issues bundled.
