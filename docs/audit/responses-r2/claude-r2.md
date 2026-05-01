# Claude (Anthropic) Opus 4.7 — DeSNet v0.3.0 R2 Verification

**Date:** 2026-05-02
**Verdict:** 🟡 YELLOW — H3 needs a second iteration. All other fixes verified GREEN.
**R1 → R2:** YELLOW → YELLOW (different reason)
**Verification questions: 19/19 covered**
**New issues (R2-N): 5 (1 HIGH, 1 LOW, 3 INFO)**

---

## TL;DR

| Fix | Verdict |
|---|---|
| H1 (digest verification) | ✅ Sound. Off-chain reference impl gap is the only nit. |
| H2 (record actual_paid) | ✅ Sound. Closes inflation. Minor INFO on "wait-for-topup" optimal strategy. |
| **H3 (settle slippage)** | ❌ **STRUCTURALLY BROKEN.** The slippage check is tautological under Move atomicity — sandwich still works. **Single new HIGH finding (R2-N1).** |
| H4 (friend-restrict record_reward_received) | ✅ Sound. |
| M1 (add_liquidity refund) | ✅ Sound. Math correct. |
| M2 (disable_multisig_upgrade) | ✅ Sound. INFO on no-confirmation deliberate. |
| M5 (pool addr drift) | ✅ Sound. Correctly placed. |
| Kimi F2 (set_paused) | ✅ Sound. |
| Kimi F4 (governance bootstrap) | ✅ Sound. |
| Gemini MED (zero-addr) | ✅ Sound. |

**Verdict:** 🟡 **YELLOW** — H3 needs a second iteration. All other fixes verified GREEN. No regressions introduced anywhere else.

The R1 verdict was YELLOW because of compound governance-path concerns. R2 closes most of those (H1, H2, H4 all sound). But H3 — sandwich on `apt_vault::settle` — is unfixed because the implementation misreads the threat model. The slippage tolerance is computed against post-attacker-manipulation reserves, which makes the check tautological. Details and recommended re-fix in **R2-N1** below.

---

## R2-N1 (HIGH) — `apt_vault::settle` H3 fix is structurally ineffective

**Module + line:** `apt_vault.move` lines 6248–6262.

**Issue.** The fix as written:

```move
// H3: compute expected output + apply 3% tolerance as min_out.
let (apt_reserve, token_reserve) = amm::reserves(vault.handle);
let expected_out = amm::compute_amount_out(apt_reserve, token_reserve, buyback_amount);
let min_out = (expected_out * (BPS_DENOM - SETTLE_SLIPPAGE_BPS)) / BPS_DENOM;
// ...
let token_received = amm::swap_exact_apt_in(vault.handle, apt_fa_buyback, min_out);
```

`expected_out` is computed against the reserves observed AT settle entry. `min_out = expected_out × 0.97`. The actual `swap_exact_apt_in` will read those same reserves (no state change between read and swap within Move atomicity) and compute the same `amount_out = expected_out`. So `amount_out >= min_out` passes trivially. **The slippage check is a no-op.**

The fix author's reasoning in Q3.2 ("no interleaved state change between read and swap") is correct *as far as it goes*, but it's the wrong threat model. The threat is **not** "state changes between read and swap in settle." The threat is **state is already manipulated BEFORE settle is called**, by a different leg of the same atomic transaction.

**Concrete attack (still works post-fix):**

The attacker submits one transaction containing three calls (via a Move script or their own module's entry function — `swap_apt_for_token` and `settle` are both `public entry` and are also reachable as plain `public` from other code):

```move
// in attacker's module/script
1. desnet::amm::swap_apt_for_token(attacker, b"victim_handle", BIG_APT, 0);
2. desnet::apt_vault::settle(attacker, vault_addr);
3. desnet::amm::swap_token_for_apt(attacker, b"victim_handle", BIG_TOKEN, 0);
```

Walked through with concrete numbers, pool = 100 APT / 1000 TOKEN (k=10⁵), vault has 10 APT, attacker capital 50 APT:

| Step | Reserves before | Op | Reserves after |
|---|---|---|---|
| 1 | 100 / 1000 | attacker swaps 50 APT in → ~333 TOKEN out | 150 / 667 |
| 2a | 150 / 667 | settle reads `(150, 667)`, computes `expected_out = compute_amount_out(150, 667, 5) = 21`, `min_out = 21 × 0.97 = 20` | (unchanged) |
| 2b | 150 / 667 | swap 5 APT (buyback) in → 21 TOKEN out. `21 >= 20` ✓. burn 21 TOKEN. | 155 / 646 |
| 2c | 155 / 646 | owner gets 5 APT direct | (unchanged) |
| 3 | 155 / 646 | attacker swaps 333 TOKEN back → ~52 APT out | 103 / 979 |

- Attacker net: −50 + 52 = **+2 APT profit** (gas/fees ~0.05 APT, net positive).
- Vault: paid 5 APT for 21 TOKEN burn, vs ~47 TOKEN burn without attack — **lost ~26 TOKEN of buyback value** (~2.6 APT-equivalent).

The "3% tolerance" buys nothing because both sides of the inequality use the manipulated reserves.

**Why the misread happened.** "Single-tx sandwich" is somewhat unintuitive on chains without a public mempool. R1's H3 wording emphasized that aspect ("the attacker bundles all three legs in a single tx of their own") — but the fix author reasonably parsed "single-tx" as "atomic, so nothing interleaves" and wrote a slippage check that addresses interleaved-state, not pre-positioned-state. The threat is actually closer to a JIT-liquidity / squeeze-and-release attack than a classic frontrun.

**What an actual fix looks like.** The fundamental property needed is: `min_out` must be derived from a price reference **independent of the current pool state**. Three options ranked by complexity:

**(a) Two-phase (commit-reveal) settle — recommended.**
```move
public entry fun request_settle(_caller: &signer, vault_addr: address) {
    // Set pending_settle_at_secs = now in vault state.
}
public entry fun execute_settle(_caller: &signer, vault_addr: address) {
    // Require now >= pending_settle_at_secs + SETTLE_DELAY_SECS (e.g., 60s).
    // Then read reserves and swap with current price.
}
```
The single-tx sandwich is impossible because the swap legs span at least two blocks. An attacker who manipulates in tx N must hold the manipulated state until tx N+K (when execute_settle lands) — exposing them to other actors and inventory risk. With Aptos block times (~0.3s) and a 60s delay, that's ~200 blocks of exposure. Practical sandwich profitability collapses.

**(b) Cap buyback as % of pool depth.**
```move
const MAX_BUYBACK_BPS_OF_RESERVE: u64 = 100; // 1% of pool APT
let buyback_cap = (apt_reserve * MAX_BUYBACK_BPS_OF_RESERVE) / BPS_DENOM;
let buyback_amount = if (total_apt / 2 > buyback_cap) buyback_cap else total_apt / 2;
```
Doesn't *prevent* sandwich, but bounds the price impact (and thus attacker profitability) to a small fraction. Attacker's manipulation must move price by ≥ buyback_amount × some_factor; with buyback capped at 1% of reserves, the manipulation cost grows as Δ² while the extractable profit grows as Δ — at some point the attack is unprofitable. Pair with (a) for belt-and-braces.

**(c) Snapshot-based reference price.**
Maintain a price snapshot in the AMM that updates at most once per N seconds (a primitive TWAP). Settle uses the snapshot, not the live reserves. More invasive — touches `amm.move`, requires new state, requires update logic on swaps. Probably overkill for v0.3.0.

**Recommendation:** ship (a) as the actual H3 fix. Optionally add (b) as defense-in-depth. The current "3% tolerance" line should be removed — keeping it gives a false sense of security and an LP/maintainer who reads the code may believe they have slippage protection.

**Confidence:** HIGH. Traced the call path, walked through with concrete numbers, and verified `swap_apt_for_token` is `public entry` (so freely composable into an attacker's tx).

---

## Verification Q&A (Q1.1 — Q10.1)

### H1 — execute_proposal hash verification

**Q1.1 — Verified.** SHA3-256 has 2^128 collision resistance. BCS encoding of `vector<u8>` is `ULEB128(len) || bytes` — length-prefixed and self-delimiting. Concatenation gives an injective mapping for fixed schema.

**Q1.2 — Verified, with a doc caveat.** Encoding is unambiguous given knowledge of the schema, but it is **not** the natural BCS encoding of a tuple `(vector<u8>, vector<vector<u8>>)`. Off-chain implementors who reach for `bcs.serialize((metadata, code_bytes))` in TypeScript or Rust will get a different result. Documentation/UX issue; strongly recommend reference TypeScript impl in deploy runbook.

**Q1.3 — Insufficient.** Digest scheme documented in `execute_proposal`'s doc-comment and on `compute_upgrade_digest` itself. **Not** mentioned in `propose_upgrade`'s doc-comment, which is where a proposer authoring the off-chain hash would look first. A miscomputed hash would brick the proposal at execute (timelock-delayed effort wasted). Add `/// IMPORTANT: hash MUST be computed via compute_upgrade_digest(...)` to `propose_upgrade`'s doc.

**Q1.4 — Verified.** Permissionless execute is the right design — it lets community members nudge proposals through if the original proposer goes quiet.

### H2 — record actual_paid amount

**Q2.1 — Verified.** When reserve is depleted, `pull_for_claim` returns zero-amount FA. `actual_paid = 0`. Guard skips `record_reward_received`. Closes H2 completely.

**Q2.2 — Verified, acceptable.** Voter gets credit only for actual receipt.

**Q2.3 — Acceptable trade-off, but flag for documentation.** See R2-N2 below — current behavior creates "wait-for-topup" optimal strategy (asymmetric advantage to sophisticated actors).

### H3 — settle slippage tolerance

**Q3.1 — Concerned (moot).** Tolerance value doesn't matter because the check is tautological. See R2-N1.

**Q3.2 — Concerned — author's threat model is wrong.** Author's understanding ("no interleaved state change") is technically correct but addresses the wrong attack. State is manipulated BEFORE settle is called, by a previous leg of the same atomic tx. See R2-N1.

**Q3.3 — Verified.** M5 pool_addr_drift assert correctly placed (line 6234–6237) — first thing after `borrow_global_mut<Vault>`.

### H4 — voter_history visibility

**Q4.1 — Verified.** `friend desnet::governance` and `friend desnet::lp_staking` declared. Of these, only `lp_staking` calls `record_reward_received` (verified by grep).

**Q4.2 — Verified, useful as belt-and-braces.** Defends against malicious upgrades adding functions in lp_staking that pass non-pkg signers, and future refactors that widen friend scope. Cheap insurance.

**Q4.3 — Verified — current scope is correct.** `prune_voter_history` permissionless by design. `init_registry` friend-only to `governance`. Views read-only. **One INFO** — see R2-N4: file-level doc still says "asserts signer::address_of(authority) == @desnet" without mentioning the now load-bearing friend restriction.

### M1 — add_liquidity surplus refund

**Q5.1 — Verified.** `optimal_apt = floor(lp_minted × apt_reserve / lp_supply) ≤ apt_amount`. Truncation goes the right direction. `apt_surplus = apt_amount - optimal_apt ≥ 0`. Subtraction never underflows.

**Q5.2 — Verified — moot.** Code uses `if (apt_surplus > 0) { extract } else { zero }`, so `extract(_, 0)` never called.

**Q5.3 — Acceptable.** Test wrappers don't model production semantics. Production path correctly returns refunds to caller.

### M2 — disable_multisig_upgrade

**Q6.1 — Verified.** Fresh mainnet publish — no compat constraints. Testnet break acknowledged and acceptable.

**Q6.2 — Acceptable as-is, with INFO call-out.** Irreversible-on-call is the deliberate choice. Ship as-is and document operationally.

### M5 — apt_vault cache consistency

**Q7.1 — Verified.** Lines 6234–6237. First substantive operation after vault borrow. Fails fast.

**Q7.2 — Acceptable scoped to settle.** Other vault entries don't touch the AMM (deposit_apt, views).

### Kimi F2 — factory pause/unpause

**Q8.1 — Acceptable for v0.3.0; transition needed.** @origin matches existing trust model. Long-term should rotate to a DAO-governed addr. Concrete suggestion: instead of hardcoding `@origin` in `set_paused`, read from `FactoryState.admin: address` (initially `@origin`, rotatable via a future entry). Otherwise post-rotation will have split-brain (admin moves, pause control doesn't). LOW priority, not blocking.

### Kimi F4 — governance bootstrap state validation

**Q9.1 — Verified.** `E_NOT_INITIALIZED` much clearer than `E_INSUFFICIENT_VOTING_POWER`. Minor unidiomatic borrow pattern (two separate borrows of same resource) — cosmetic.

### Gemini MED — zero-addr checks

**Q10.1 — Verified, mostly complete.** Found one missed location: `governance::update_desnet_fa_metadata(multisig, fa_addr)` accepts `fa_addr: address` and writes it directly without a zero-check. Setting to @0x0 would freeze ALL voting power until re-set (recoverable but worth defense-in-depth check). See **R2-N5**.

---

## New issues

### R2-N1 (HIGH) — see top of doc.

H3 fix is structurally ineffective. Single-tx sandwich attack still works.

### R2-N2 (LOW/INFO) — H2 fix creates "wait-for-topup" claim incentive

**Module + line:** `lp_staking.move` lines 3217–3218.

When `pull_for_claim` returns less than `pending_emission` (partial fill due to depletion), `position.last_acc_per_share` is still advanced to `acc` — the unpaid portion is forgotten. This creates an asymmetric incentive:
- **Naive user:** claims during depletion, gets partial pay, FORFEITS unpaid.
- **Sophisticated user:** doesn't claim during depletion, waits for community top-up, claims later, gets FULL pending.

Known "stale-claim" problem from MasterChef-style systems. Not exploitable for direct gain. Recommended: (a) document the behavior prominently (event emit when partial-fill occurs; UI banner) or (b) compute unclaimable acc-delta and rewind `last_acc_per_share`. (a) is sufficient.

**Severity:** LOW. UX/fairness issue only.

### R2-N3 (INFO) — `compute_upgrade_digest` is `public` but not `#[view]`

Function is pure and produces a deterministic digest. Marking it `#[view]` would let off-chain SDKs invoke it gas-free for hash verification. One-line change that gives operators a "ground truth" oracle for off-chain implementations.

**Severity:** INFO.

### R2-N4 (INFO) — file-level doc in `voter_history.move` predates H4 fix

File-header doc still describes "Cross-module authentication via signer addr check" without mentioning the friend restriction is now load-bearing. Function-level doc is correct. Recommend harmonizing.

**Severity:** INFO.

### R2-N5 (INFO/LOW) — `update_desnet_fa_metadata` missing zero-addr check

See Q10.1. Bundle into H3 re-fix patch.

```move
public entry fun update_desnet_fa_metadata(multisig: &signer, fa_addr: address) acquires GovernanceState {
    assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG_ADMIN);
    assert!(fa_addr != @0x0, E_INVALID_ADDRESS);  // ADD THIS
    borrow_global_mut<GovernanceState>(@desnet).desnet_fa_metadata = fa_addr;
}
```

---

## Regression check

I traced all signature changes for downstream impact:

- `amm::add_liquidity_internal`: signature changed to `: (u128, FungibleAsset, FungibleAsset)`. Two callers (`lp_staking::add_liquidity_with_lock_internal`, `add_liquidity_internal_for_test`) correctly destructure. **No regression.**
- `amm::create_pool_atomic`: signature unchanged. **No regression.**
- `voter_history::record_reward_received`: visibility `public` → `public(friend)`. Single caller `lp_staking::claim_internal` line 3251. Compiles because `lp_staking` in friend list. **No regression.**
- `governance` struct: `multisig_upgrade_disabled` field added. Init updated. Compat-policy break for testnet (acknowledged). Fresh mainnet: clean. **No regression.**
- `apt_vault::settle` flow: now reads `amm::reserves` and computes `expected_out` before swap. **No regression in happy path; the slippage-protection intent doesn't actually work — see R2-N1.**

No fix introduces a new HIGH issue in any other module. The only HIGH issue is the H3 fix not actually addressing H3.

---

## Test gaps the patch should add

1. **H3 sandwich test (CRITICAL):** integration test that submits one tx with three calls (drain → settle → restore), measures vault token-burn delta vs. unmanipulated baseline, asserts difference within tolerance. Currently no such test exists.
2. **H1 hash-mismatch test:** propose with hash X, attempt execute with bytes whose digest is Y ≠ X, assert `E_HASH_MISMATCH`.
3. **H2 depletion test:** stake LP, advance time large amount, drain reserve to 0, claim, assert `voter_history::rewards_earned_30d` unchanged.
4. **M1 ratio mismatch test:** add_liquidity with deliberate ratio overshoot, assert correct refund amounts on both sides.
5. **M2 disable_multisig_upgrade test:** disable, attempt `multisig_upgrade`, assert `E_MULTISIG_DISABLED`.
6. **Reserved-handle guard test:** reserved handle attempted by wrong wallet → `E_RESERVED_HANDLE`; correct wallet → success.

The H3 sandwich test is the load-bearing addition. Its absence is a self-audit dimension gap — adding "single-tx composability attacks against permissionless economic primitives" to the SOP would have caught the broken fix.

---

## Overall R2 Verdict

🟡 **YELLOW** — H3 needs a second iteration. Everything else is GREEN.

**What changed since R1:** H1, H2, H4, M1, M2, M5, and all three LOW fixes (Kimi F2, Kimi F4, Gemini MED) are correctly addressed and verified. No regressions introduced. The protocol is materially safer than v0.3.0 baseline — three of the four R1 HIGH findings are properly closed.

**What remains:** R2-N1 (the H3 sandwich) is the single blocker. The slippage-tolerance approach was the wrong tool for the threat; a two-phase settle pattern (or equivalent state-independent price reference) is needed. Estimated patch size: ~40 LoC including tests. Plus R2-N5 (missing zero-addr check) and R2-N4 (doc harmonization) bundled in the same iteration.

**Recommendation for R3:** focus exclusively on the H3 re-fix + R2-N5 + R2-N4. Add the sandwich test as a regression guard. Should be GREEN-ready in one more iteration.

Independent observation for the dev team's self-audit SOP: the H3 miss is consistent with how LLM-assisted fixes can pattern-match the surface form of a finding ("add slippage check") without re-deriving the threat model from first principles. For permissionless economic primitives, the dimension worth adding is: **"can a single-tx caller orchestrate state changes around this primitive's read-then-act pattern?"** — which would catch sandwich, JIT-liquidity, and squeeze-and-release attacks alike.

— Claude (Anthropic)
