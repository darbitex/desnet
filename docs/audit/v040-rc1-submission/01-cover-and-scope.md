# DeSNet v0.4.0-rc1 Audit Submission — Opinion Module

**Project:** DeSNet — Decentralized Social Network on Aptos
**Submission scope:** New module `desnet::opinion` (perpetual no-settle prediction substrate, "opinion pool")
**Branch:** `opinion-pool-design`
**Source commit:** `6ace5a4` (paranoid audit fixes applied)
**Date:** 2026-05-03
**Self-audit status:** 4-agent paranoid audit complete; 1 HIGH + 5 MED + 2 LOW findings all applied

---

## What this submission is

A NEW module `desnet::opinion` (~1136 LoC including tests) that adds perpetual opinion-market functionality to the live DeSNet protocol. Users post claims (e.g. "Make Aptos Great Again"), and the protocol auto-creates a CPMM where YAY (yes-belief) and NAY (no-belief) tokens trade against the creator's $token forever. No oracle, no expiry, no settlement.

Mathematical spine: pure `x*y=k` (UniV2-style CPMM) with creator-funded symmetric pool seed at create time. See `02-design-doc.md` for full economic model and `04-tests-and-self-audit.md` for security analysis.

## What changed (full list)

| File | Change | Lines |
|---|---|---|
| `sources/opinion.move` | NEW module | +1136 |
| `sources/apt_vault.move` | `+friend desnet::opinion;` (1 line, for tax burn delegation) | +1 |
| `sources/history.move` | `+friend desnet::opinion;` + `VERB_OPINION = 7` constant + `verb_opinion()` view + `new_entry` cap bump | +12 |
| `sources/profile.move` | `+friend desnet::opinion;` (1 line, for `derive_pid_signer`) | +1 |

**Everything else (factory, mint, press, governance, amm, lp_*, etc.) is UNCHANGED.** Last full audit of those modules: v0.3.3 R6 panel (commit `bf6d230`, 2026-05-02, accepted with 5 GREEN + 1 YELLOW).

## Audit scope (please focus on)

### Primary scope (deep review)
1. **`sources/opinion.move`** — entire module, especially:
   - `create_opinion` — symmetric pool seed mechanic, conservation establishment
   - `deposit_pick_side` — Mirror-Mint pair-mint semantics, tax burn flow
   - `swap_yay_for_nay` / `swap_nay_for_yay` — pure CPMM, slippage protection
   - `redeem_complete_set` — pair-burn + vault release
   - `compute_amount_out` — CPMM math (no fee version)
   - `compute_tax` — ceiling rounding for anti-dust tax
   - `assert_conservation` — `vault == total_yay == total_nay` invariant
   - `burn_tax` — friend delegation to `apt_vault::burn_via_vault`

### Touchpoint scope (verify integration only — full source provided in `03-source-code.md`)
2. `apt_vault::burn_via_vault(vault_addr, fa)` is called by opinion's `burn_tax`. Verify the friend grant is the only addition and burn delegation is type-safe (FA metadata must match BurnRef).
3. `factory::owner_has_token(pid)`, `factory::token_metadata_of_owner(pid)`, `factory::vault_addr_of_pid(pid)` — verify these public views are stable interfaces (already audited in v0.3.3, no changes here).
4. `history::append`, `history::new_entry`, `history::verb_opinion()` — verify VERB_OPINION = 7 addition and friend grant are compat-safe additive only.
5. `profile::derive_pid_signer`, `profile::derive_pid_address`, `profile::assert_pid_exists`, `profile::profile_exists` — verify integration uses these correctly.

### Out of scope (provided as context only)
- All other modules (factory internals, mint, press, governance, amm, lp_*, etc.) — last audited at v0.3.3 R6, no changes since.
- The v1 opinion scaffold (commit `63f9d88`, used APT collateral + 3-option creator_position) — superseded by rev4 source refactor at commit `707e732`. Historical reference only.

## Key design decisions to evaluate

1. **Vault collateral = creator's $token** (NOT APT, NOT DESNET). Lookup via `factory::token_metadata_of_owner(author_pid)` at create time. Closes economic loop with factory's lp_emission; creator uses own accumulated $token to bootstrap own opinions. Volatility = reputation signal.

2. **Symmetric pool seed at create**: Creator pays `initial_mc` $token → vault. Mints `initial_mc` YAY + `initial_mc` NAY → BOTH go to pool. Creator wallet receives 0 position. Vault locks `initial_mc` forever (no creator-redeem path; "alias di-burn" from POV creator). Pool `k = initial_mc²` active from block 0.

3. **Tax = same $creator_token, BURNED** via `apt_vault::burn_via_vault`. Default 10 bps (0.1%), max 1000 bps (10%). Creator-set per-opinion at create, immutable. Applied to every trader op (deposit/swap/redeem) on top of operation amount.

4. **NO LP shares, NO LP fee, NO add_liquidity**. Pool is coordination state, not ownable claim. Creator's only liquidity contribution is at create-time symmetric seed. Subsequent participation = normal trader path (deposit_pick_side or swap).

5. **Creator NOT hard-banned post-create**: creator can `deposit_pick_side` / swap / redeem like any trader. "Berhak beropini" (creator has right to opine via own market). They just lack a privileged liquidity-injection path.

6. **Conservation invariant**: `vault_$creator_token == total_yay_supply == total_nay_supply` at all times. Maintained by atomic pair-mint (deposit/create) and pair-burn (redeem); swaps don't touch vault or supplies.

7. **Bounds**: `initial_mc ∈ [1M, 100M] WHOLE $creator_token` (= 0.1%-10% of 1B factory supply). Per-PID cap `MAX_OPINIONS_PER_PID = 10_000` (anti-storage-rent grief).

## What NOT to flag

These are accepted-by-design (NOT bugs):
- **Vault floor at `initial_mc` forever** — creator's seed is intentionally permanently locked; only retrievable by traders who burn balanced pairs they earned through trading. Documented in `02-design-doc.md` §4.7.
- **Phase-1 lockup absent** — pool always active from create due to symmetric seed; this is a feature.
- **Guest restriction on create** — only registered handles (with factory token) can create opinions. Required because vault denomination needs $token to exist.
- **No press × opinion coupling** — orthogonal verbs by design (CLOSED PERMANENTLY per §5 knob B).
- **Multi-outcome (>2 sides)** — deferred to v2 as sibling module, NOT in v1.
- **Total consensus = pool dies** — if all traders only pick one side, market self-segregates. Acceptable.

## Integration test gap (acknowledged)

Current test suite: 14 opinion-specific tests + 93/93 total project suite GREEN. All tests are pure helpers (compute_amount_out, compute_tax, constants, deterministic seeds). **NO end-to-end integration test exercising full create → deposit → swap → redeem flow** — would require non-trivial test scaffold (factory token registration in test env, profile setup, etc.). Pure helper tests cover all numeric edge cases extracted into `compute_*` functions.

This is a known gap, NOT a security concern — the math is testable in isolation. Auditors are encouraged to construct adversarial integration scenarios mentally and report any conservation/safety violations they find.

## Submission package contents

| File | Purpose |
|---|---|
| `01-cover-and-scope.md` (this file) | Project context + scope statement |
| `02-design-doc.md` | Full economic model + locked decisions + worked examples |
| `03-source-code.md` | Full source (opinion.move + touchpoint excerpts) |
| `04-tests-and-self-audit.md` | Test results + paranoid 4-agent self-audit findings + applied fixes |

## Reviewer instructions

- Skim `01` (this file) and `02` to align on scope + design intent
- Read `03` deeply for `opinion.move`; reference touchpoint excerpts for integration
- Verify in `04` that self-audit findings are correctly addressed (or flag if not)
- Submit verdict per dimension: HIGH / MED / LOW / INFO with justification + suggested fix
- Convergent issues across multiple reviewers will be prioritized for v0.4.0-rc2 fix bundle

**Acceptance bar:** ≥4 GREEN out of 6 LLM reviewers + zero unfixed HIGH = ready for mainnet deploy.
