# Claude Opus 4.7 (fresh web) — DeSNet v0.3.0 R1 Audit Response

**Date:** 2026-05-02
**Verdict:** 🟡 YELLOW (ship after fixes)
**Findings:** 4 HIGH / 5 MEDIUM / 5 LOW / 4 INFO
**Source coverage:** all 17 modules read, NEW/rewritten emphasized

---

# DeSNet v0.3.0 — External Audit Response (Round 1)

**Auditor:** Claude (Anthropic), Opus 4.7
**Date:** 2026-05-02
**Submission:** AUDIT-DESNET-V030-SUBMISSION.md
**Source reviewed:** AUDIT-DESNET-V030-SOURCE.md (all 17 modules, ~7434 LoC)
**Method:** Full read of NEW/rewritten modules (`amm`, `lp_staking`, `factory`, `profile`, `apt_vault`, `lp_emission`, `governance`, `voter_history`); spot-check of `reference_gate`, `mint`, and friend-graph closure across all 17 modules.

---

## Executive Summary

| Severity | Count |
|---|---|
| HIGH | 4 |
| MEDIUM | 5 |
| LOW | 5 |
| INFO | 4 |

**Verdict:** 🟡 **YELLOW (ship after fixes)** — see Section "Overall Verdict" at end.

The architecture is well-considered and the friend graph hygiene is generally good. However, **two of the HIGH findings (H1, H2) are blockers for mainnet** because they undermine governance integrity in ways that would not be caught by symptom-level monitoring. H3 and H4 are also straightforward fixes that should land in the same patch.

The self-audit's claim of "0 HIGH" did not catch H1 (governance hash mismatch) because the self-audit dimensions emphasize math/reentrancy/auth-on-current-callsite but do not include "did the executor commit to the same artifact the voters approved." That dimension should be added to the SOP.

---

## Findings

### H1 — `execute_proposal` does NOT verify that published code matches the approved proposal hash 🔴 HIGH

**Module + line:** `governance.move`, lines 355–390 (`execute_proposal`).

**Issue:** The proposal stores `new_module_bytes_hash: vector<u8>` at propose time (line 253). Voters cast votes referring to that hash (resolved off-chain to actual code). After approval and timelock, `execute_proposal` accepts `metadata` and `code_bytes` parameters from the executor and calls `code::publish_package_txn(&pkg_signer, metadata, code_bytes)` directly (line 383) — **without ever computing `hash(metadata || code_bytes)` and comparing it against `proposal.new_module_bytes_hash`**.

**Risk:** Anyone (the executor `caller: &signer` is not even checked against the proposer or any whitelist) can wait for any proposal to clear the 30-day timelock, then call `execute_proposal` with completely arbitrary `code_bytes` — for example, code that gives the attacker a fresh signer cap, drains every vault, or replaces the entire AMM with a malicious passthrough. The voters approved code A; the executor publishes code B. This is a **complete bypass of the DAO vote** and converts the timelock into a thin window between "any proposal passes" and "any code at all gets shipped."

A hostile actor with enough voting power to pass even an obviously-benign proposal (e.g., updating a constant) gets to ship a complete protocol takeover. With 35% quorum × 70% approval, ~24.5% of weighted voting power suffices to push a proposal through. Combined with H2/H4 (voting-power inflation paths), the attack surface widens further.

**Suggested fix:** Before calling `code::publish_package_txn`, compute the digest of the submitted bytes and require equality:

```move
use std::hash;
use std::bcs;
// In execute_proposal, before publish_package_txn:
let submitted_digest = hash::sha3_256(bcs::to_bytes(&(metadata, code_bytes)));
assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);
```

The exact digest scheme should match whatever scheme `propose_upgrade` documents (it is currently undocumented — choose one canonical encoding, e.g., `sha3_256(metadata || concat(code_bytes_with_length_prefix))`, and reject anything else). Add a unit test that proposes hash X, attempts execute with bytes-of-Y, and asserts abort.

**Confidence:** HIGH — traced full call path. There is no hash check anywhere in the file.

---

### H2 — `claim_internal` records voting power for **requested** emission, not **actual paid** amount 🔴 HIGH

**Module + line:** `lp_staking.move` lines 3122–3134 (claim path) ↔ `lp_emission.move` lines 6294–6322 (`pull_for_claim`).

**Issue:** `lp_emission::pull_for_claim` is intentionally graceful: it caps `payout` at `available` so claims do not abort once the 900M reserve depletes (line 6303: `let payout = if (amount < available) amount else available;`). However, `lp_staking::claim_internal` calls:

```move
voter_history::record_reward_received(&pkg_signer, recipient, pending_emission);
```

passing `pending_emission` (the *requested* amount derived from the accumulator) rather than the *actually-paid* amount. The accumulator (`update_pool`) keeps advancing regardless of reserve balance — it is purely time × rate / lp_supply. So once the reserve hits zero, `pending_emission > 0` continues to grow, `payout = 0`, but `voter_history` keeps recording the full requested amount as if it were paid.

**Risk:** This is a **governance bypass via asymmetric accounting**. After ~2.85 years (the documented depletion ETA), or sooner for any pool whose emission outpaces top-ups, an attacker can:

1. Hold a small LP position in any depleted pool.
2. Wait. Accumulator grows.
3. Call `claim` permissionlessly. Receives 0 tokens. `voter_history` records, say, 10⁹ "rewards earned."
4. Repeat across many pools / many claims.
5. Voting power = `min(rewards_earned_30d, DESNET_balance)`. The first leg is now arbitrarily inflatable for free.
6. Combine with `H1` to ship arbitrary code. Or pass any DAO proposal.

Even in the pre-depletion regime, any partial-fill scenario (e.g., a temporarily under-funded reserve recovered by `topup_reserve`) creates a permanent over-credit for whoever claimed during the dip.

**Suggested fix:**

```move
let actual_paid = fungible_asset::amount(&emission_fa);
primary_fungible_store::deposit(recipient, emission_fa);
if (actual_paid > 0) {
    let pkg_signer = governance::derive_pkg_signer();
    voter_history::record_reward_received(&pkg_signer, recipient, actual_paid);
};
```

Two changes: (a) use `actual_paid`, not `pending_emission`; (b) skip the call entirely when `actual_paid == 0` (saves gas + avoids zero-amount events). Add a test that depletes a reserve, calls claim, and asserts `voter_history::rewards_earned_30d` does not change.

**Confidence:** HIGH — both files traced; the gap is direct.

---

### H3 — `apt_vault::settle` swaps with `min_out = 0` (atomic-tx sandwich) 🔴 HIGH

**Module + line:** `apt_vault.move` lines 6118–6122.

**Issue:**

```move
let token_received = amm::swap_exact_apt_in(
    vault.handle,
    apt_fa_buyback,
    0,                    // ← min_out
);
```

The buyback half of `settle` swaps APT for $TOKEN with zero slippage protection, in a `public entry` function callable by anyone.

**Risk:** Aptos has no public mempool, but **`settle` is permissionless and the attack does not need to be a frontrun** — the attacker bundles all three legs in a single tx of their own:

```
1. attacker swap: large APT in → TOKEN out (drains TOKEN reserve, pumps APT/TOKEN price)
2. apt_vault::settle(vault_addr)  // protocol now buys TOKEN at the inflated price
3. attacker swap: TOKEN in → APT out (restores reserves, captures spread)
```

The protocol's `buyback_amount = total_apt / 2` gets exchanged for far less $TOKEN than it should, the `burn` event misreports value (under-burns), and the attacker's APT roundtrip nets profit equal to the pool's "donation." With low pool depth this is dramatic; with a fresh handle (5 APT seed, 50M tokens, k=2.5×10¹⁵ at 8 dec) even modest vault accumulation is fully exploitable.

The `APT_SETTLE_THRESHOLD = 0.1 APT` does not help — it's an anti-dust trigger, not a slippage guard.

**Suggested fix:** Compute an expected output before the swap, and pass a tolerance-bounded `min_out`. Three options ranked by simplicity:

1. **Quick fix:** read `amm::reserves(vault.handle)`, compute expected via `amm::compute_amount_out(...)`, pass `expected * 9700 / 10000` (3% tolerance) as `min_out`. This bounds single-tx loss to 3%.
2. **Better:** require `caller != tx initiator of the previous N AMM ops on this pool` — not really feasible on Aptos.
3. **Best:** chunked settle. If `total_apt` is large, split into N swaps of bounded size and accept up to N% total drift. Pair with an `amm::twap` if added later.

Even option 1 closes the worst of this. Document that settle remains imperfect under thin liquidity (it is structurally exposed because the buyback target IS the price source).

**Confidence:** HIGH — direct read of code + standard CPMM sandwich shape.

---

### H4 — `voter_history::record_reward_received` is `public`, not `public(friend)` 🔴 HIGH

**Module + line:** `voter_history.move` line 7449.

**Issue:** The function declaration is `public fun record_reward_received(...)`, with the only auth being `assert!(signer::address_of(factory_authority) == @desnet)`. The friend list (line 7359) only includes `desnet::governance` (for `init_registry`).

`@desnet` is the resource_account holding the package signer cap. Any module in the friend closure of `governance::derive_pkg_signer` (= `factory`, `profile`, `amm`, `lp_staking`) can derive a `signer` for `@desnet` and pass it to `record_reward_received`. Today only `lp_staking::claim_internal` does so, but the type system does not constrain this — any new code path added in any of those modules (including via DAO upgrade) can mint voting power for any voter address with any amount.

The submission's design comment (line 7339–7349) and Q9 both claim "SOLE pathway." That claim is true *today by code review*, false *as a structural invariant*.

**Risk:** Two attack surfaces:

1. **Future-code risk:** any patch (DAO-approved or multisig-pushed) that adds a function to factory/profile/amm/lp_staking and inadvertently exposes a path that hands the pkg_signer to attacker-influenced code can be used to inflate voting power.
2. **Defense-in-depth gap:** the structural claim that voter_history is a "sole source" should be machine-checkable, not human-checkable. With `public(friend)`, accidentally exposing it requires an explicit friend declaration that reviewers will catch in diff. With `public`, no such tripwire exists.

**Suggested fix:**

```move
// In voter_history.move
friend desnet::lp_staking;       // add this line

public(friend) fun record_reward_received(  // change visibility
    factory_authority: &signer,
    voter_addr: address,
    amount: u64,
) acquires Registry { /* keep the @desnet assertion as belt-and-braces */ }
```

You can keep the `signer.addr == @desnet` assertion as belt-and-braces, but the friend restriction is the load-bearing barrier. Also fix the stale comment at line 7339-7349 that refers to `factory_signer` and `lp_emission obtains factory_signer` — both reference v0.1.5 architecture and are misleading post-monolith.

**Confidence:** HIGH — direct.

---

### M1 — `add_liquidity` does not refund excess on mismatched ratio 🟡 MEDIUM

**Module + line:** `lp_staking.move` lines 2960–3019 (`add_liquidity_with_lock_internal`) → `amm.move` lines 2041–2088 (`add_liquidity_internal`).

**Issue:** User passes `apt_amount` and `token_amount` independently. `amm::add_liquidity_internal` computes `lp_minted = min(lp_from_apt, lp_from_token)` and uses that — but **both** assets are deposited fully into the reserves (lines 2072–2073), regardless of which side bound the LP mint. There is no refund of the surplus side.

**Risk:** A user who supplies even slightly mismatched amounts (very common when the pool moved between quote-fetch and tx land) loses the surplus to existing LPs via dilution. Worst case: a user supplies 100 APT + 1B tokens to a pool whose ratio supports only 50M tokens for 100 APT — they get LP for 100 APT worth, and 950M tokens are gifted to the pool.

This is a footgun for users not going through the official frontend, and even with the frontend, mempool delay between quote and submission can cause non-trivial losses in volatile pools.

**Risk severity:** MEDIUM, not HIGH, because (a) Move atomicity prevents partial deposits — user always gets *some* LP for their funds, just not optimal; (b) most professional integrations compute exact ratios. But it is a real loss-of-funds vector for naive users.

**Suggested fix:** After computing `lp_minted` in `amm::add_liquidity_internal`, reverse-compute the optimal pair and `extract` the surplus from one side, returning it as a third `FungibleAsset`. lp_staking forwards it back to caller's primary store. Pattern:

```move
// in amm::add_liquidity_internal, after determining lp_minted
let optimal_apt = (lp_minted * apt_reserve_amt) / pool.lp_supply;
let optimal_token = (lp_minted * token_reserve_amt) / pool.lp_supply;
let apt_refund = fungible_asset::extract(&mut apt_in, apt_amount - (optimal_apt as u64));
let token_refund = fungible_asset::extract(&mut token_in, token_amount - (optimal_token as u64));
// deposit remaining into reserves; return refunds via signature change
```

This is a small ABI break (`add_liquidity_internal` returns more values) but worth it. Uniswap V2's `addLiquidity` handles this same way.

**Confidence:** HIGH.

---

### M2 — `multisig_upgrade` has no on-chain off switch 🟡 MEDIUM

**Module + line:** `governance.move` lines 215–229.

**Issue:** `multisig_upgrade(@origin signer, ...)` permanently bypasses the DAO. The doc comment says "Off-chain: simply stop calling this once DAO is trusted" — but on-chain, `@origin` retains unilateral upgrade rights forever. Combined with H1, this is a permanent backdoor regardless of DAO maturity.

**Risk:** Trust-assumption inflation. The protocol's nominal "DAO-controlled" status is misleading until this function is removed. If `@origin` keys leak — even years later, even after DAO is well-established — the attacker bypasses the entire governance machinery.

**Suggested fix:** Add a one-way flag:

```move
struct GovernanceState has key {
    // ...existing fields...
    multisig_upgrade_disabled: bool,
}

public entry fun disable_multisig_upgrade(multisig: &signer) acquires GovernanceState {
    assert!(signer::address_of(multisig) == @origin, E_NOT_MULTISIG);
    borrow_global_mut<GovernanceState>(@desnet).multisig_upgrade_disabled = true;
}

// in multisig_upgrade:
assert!(!borrow_global<GovernanceState>(@desnet).multisig_upgrade_disabled, E_MULTISIG_DISABLED);
```

Then commit publicly to calling `disable_multisig_upgrade` after the second mainnet smoke pass / after DESNET launch / on a published date. Once called, the only path to upgrade is the full DAO flow (post-H1-fix).

**Confidence:** HIGH.

---

### M3 — `derive_pid_signer` returns full-permission signer to 6 friend modules 🟡 MEDIUM

**Module + line:** `profile.move` lines 1649–1653; friends declared at lines 1014–1019 (`mint, link, pulse, press, giveaway, history`).

**Issue:** `derive_pid_signer(pid_addr)` returns an `ExtendRef`-derived signer for an arbitrary user's PID. There is no auth check — any of the six friend modules can construct a signer for any PID. The intended use is `move_to(pid_signer, SomeStorage)` (lazy-init siblings), which is benign. But the returned signer is fully-permissioned: it can also `primary_fungible_store::withdraw` from the PID's primary store, transfer Objects owned by `pid_addr`, etc.

I traced all six current callers (mint, link, pulse, press, giveaway, history): all current uses are benign (collection creation, lazy-init `move_to`). So **no current vulnerability**, but the trust surface is broad: any future bug in these modules that exposes the signer to attacker-controlled call sites can drain user PID treasuries (creator's 50M allocation, donations, future treasury inflows).

**Risk:** Defense-in-depth gap. Hard to exploit today; easy to exploit accidentally tomorrow.

**Suggested fix:** Two options, in order of preference:

1. Split `derive_pid_signer` into a per-purpose API: e.g., `derive_pid_signer_for_lazy_init(pid_addr, type_witness)` that returns a wrapped signer + only allows `move_to` of a specific type. Move's type system can enforce this if you accept a phantom type parameter and gate behavior.
2. Failing that, add a runtime "purpose" enum + assertion: each friend caller declares what it intends to do, and `profile` records/limits that. Less ergonomic, less safe.

If neither is feasible without major refactor, at minimum: add a self-audit dimension that re-reviews every `derive_pid_signer` call site whenever any of the six modules is touched.

**Confidence:** HIGH for the gap; MEDIUM for the recommended remediation (alt fixes possible).

---

### M4 — Stale documentation in `voter_history.move` 🟡 MEDIUM

**Module + line:** `voter_history.move` lines 7339–7349, 7441–7448.

**Issue:** Comments reference `factory_signer`, `factory::derive_factory_signer`, `factory::lp_emission` — all stale references to the v0.1.5 three-package architecture. In v0.3.0 monolith, the actual mechanism is `lp_staking::claim_internal` calling `governance::derive_pkg_signer()`. A future maintainer reading these comments will be misled about where to add a new caller, the trust model, and the audit surface.

**Risk:** Indirect — accelerates the H4 risk because a future contributor may "follow the docs" and add a new caller without realizing the structural implications.

**Suggested fix:** Rewrite to reflect v0.3.0:

```
/// `record_reward_received` is the SOLE pathway for voting power generation. Called
/// EXCLUSIVELY by `desnet::lp_staking::claim_internal` after pulling emission from
/// the LP emission reserve via `desnet::lp_emission::pull_for_claim`.
///
/// Cross-module authentication: function is `public(friend)` to `desnet::lp_staking`
/// only. The `signer` arg is the package signer at @desnet, obtained via
/// `desnet::governance::derive_pkg_signer()`. The signer.addr assertion is belt-
/// and-braces; the friend restriction is the load-bearing barrier.
```

(Pair with the H4 visibility fix.)

**Confidence:** HIGH.

---

### M5 — `apt_vault::settle` reads `vault.amm_pool_addr` cached at deploy but uses `vault.handle` for swap — no consistency check 🟡 MEDIUM

**Module + line:** `apt_vault.move` lines 6011–6013, 6118–6122.

**Issue:** Vault stores both `amm_pool_addr` (cached at deploy, line 6062) and `handle` (line 6061). At settle, the swap uses `vault.handle` (resolved by AMM via deterministic seed), not `vault.amm_pool_addr`. If the on-chain pool addr ever diverged from `pool_address_of_handle(vault.handle)` — e.g., due to a future migration that re-seeds — the swap would target the new pool while the cached `amm_pool_addr` would point at the old one. Views (`apt_vault::pool_addr`) would lie about what `settle` actually does.

**Risk:** Today: zero (deterministic addr derivation guarantees match). Future: if any upgrade ever introduces pool-addr migration, this becomes a source of surprising behavior. Low likelihood, but worth flagging.

**Suggested fix:** Either drop the `amm_pool_addr` cache (compute on demand from handle) or assert at `settle` that `pool_address_of_handle(vault.handle) == vault.amm_pool_addr`. The latter is one cheap line.

**Confidence:** MEDIUM (it's a forward-looking concern, not a current bug).

---

### L1 — `Swapped` event hardcodes `actor: @0x0` 🟢 LOW

**Module + line:** `amm.move` lines 2262, 2315.

**Issue:** The `Swapped` event has an `actor: address` field that is always set to `@0x0`. The `swap` public function takes a `_swapper: address` param but ignores it; the `swap_exact_*` family doesn't take a caller addr at all (and probably can't, since they receive a pre-extracted `FungibleAsset`).

**Risk:** Indexers cannot determine who actually swapped. This contradicts the self-audit's "indexer-grade events" claim and breaks downstream analytics, MEV detection, attribution for points programs, etc.

**Suggested fix:** Two paths:

1. Remove the `actor` field entirely and let indexers derive from tx sender (cleaner; honest signal that on-chain doesn't know).
2. Add `caller: &signer` to the `swap_exact_*` family and propagate `signer::address_of(caller)` into the event. Modest ABI change.

I'd lean (1) — Move's tx context is already indexable.

**Confidence:** HIGH.

---

### L2 — `add_signer` records `added_at_secs: 0` and `last_used_secs: 0` 🟢 LOW

**Module + line:** `profile.move` lines 1453–1454.

**Issue:** Both timestamp fields are hardcoded to zero instead of `timestamp::now_seconds()`. The event correctly emits a real timestamp, but the on-chain state is wrong.

**Risk:** Any feature that ever reads `SignerEntry.added_at_secs` or `last_used_secs` (e.g., for stale-key pruning, key-rotation policies) will see zero. No security impact today since nothing reads those fields; it becomes a footgun the moment anything does.

**Suggested fix:** One-line fix.

```move
let now = timestamp::now_seconds();
let entry = SignerEntry {
    app_label: string::utf8(app_label),
    added_at_secs: now,
    last_used_secs: now,
};
```

Note: there's no code anywhere that updates `last_used_secs` on use either — that update would belong to whichever module verifies signatures from these keys. Currently nothing does.

**Confidence:** HIGH.

---

### L3 — Handle validation allows degenerate forms 🟢 LOW

**Module + line:** `factory.move` 810–824, `profile.move` 1241–1256.

**Issue:** Validation checks per-byte allowed set but no structural rules. Examples that pass:
- `-` (single hyphen, 1 char) → costs 100 APT, weird squat target
- `--` / `---` / `------`
- `a-` / `-a`
- All-digit handles like `0`, `1`, `00`
- `a-b-c-d-e-f-g` (heavy hyphen)

None of these are security bugs. They are UX hazards (some look like CLI flags or addresses) and may complicate anti-spam later.

**Suggested fix (optional):** Reject leading/trailing hyphens, reject consecutive hyphens, reject all-hyphen strings:

```move
// in validate_handle, after the per-byte loop:
let first = *vector::borrow(handle, 0);
let last = *vector::borrow(handle, len - 1);
assert!(first != 0x2D && last != 0x2D, E_HANDLE_INVALID_CHAR);
// optional: scan for "--"
```

If reserved handles or future business logic ever needs this, retrofitting is a breaking change.

**Confidence:** HIGH for the observation; LOW for whether it matters.

---

### L4 — Pre-v0.3.1 fees accumulate at `@desnet` primary store with no on-chain extractor 🟢 LOW

**Module + line:** `profile.move` lines 1334–1337 (deposit to `state.fee_receiver = @desnet`); no withdrawal entry exists in the v0.3.0 baseline.

**Issue:** During v0.3.0 (between mainnet deploy and v0.3.1 compat upgrade), all handle fees land at `@desnet` primary store. The `@desnet` resource_account's signer cap lives in `governance::GovernanceState` and is reachable only via `derive_pkg_signer` to friend modules. None of the friend modules currently expose a path to withdraw FA from `@desnet`'s primary store.

**Risk:** Fees are effectively **stuck** until the v0.3.1 migration runs `migrate_legacy_fees` (per the comment at profile.move line 1329). If something prevents that migration (e.g., bug, proposal rejection), funds remain locked. Low probability but worth flagging — and the v0.3.1 upgrade is out of scope of *this* audit, so it cannot be assumed correct from here.

**Suggested fix:** Either:

1. Add a `multisig_extract_legacy_fees(multisig: &signer, recipient: address, amount: u64)` entry in profile, gated by `@origin`, just for the v0.3.0 baseline. Removed by v0.3.1.
2. Or: ensure the v0.3.1 audit explicitly reviews `migrate_legacy_fees` and the migration guarantees no stuck funds.

The reserved-handle admin doc says "47 APT total" of pre-DESNET fees expected during this window — small enough that loss is bounded. Still, eyes-open is better than eyes-closed.

**Confidence:** HIGH.

---

### L5 — Fee accumulator dust drift (already in self-audit as L2) 🟢 LOW

**Module + line:** `amm.move` lines 2250, 2303, 2407 (accumulator updates); `lp_staking.move` lines 3109–3110 (per-position settlement).

**Issue:** Already documented in self-audit. Re-confirming: V3-style truncation is pool-favorable (both delta and per-position settle round down). Sum of per-position claims ≤ accumulated fee bucket — verified by inspection. Dust accumulates in `apt_fees` / `token_fees` stores indefinitely. Acceptable.

One thing the self-audit didn't quantify: with `FEE_ACC_SCALE = 1e18` and lp_supply ~1.58e12 (initial creator pool), each fee delta unit is 1e18 / 1.58e12 ≈ 6.3e5 per LP unit. So precision is ~6.3 ppb of LP. Excellent. With realistic LP top-ups bringing supply to 1e15+, precision degrades to ~1 ppb. Still excellent.

**Confidence:** HIGH that there's no overflow / underflow within plausible lifecycle.

---

### I1 — `TransferVault.transfer_ref` is stored but never used 🔵 INFO

**Module + line:** `profile.move` lines 1087–1089, 1349, 1367.

`TransferRef` is generated, stored in `TransferVault`, but no code path reads it. The doc says "controller cannot transfer NFT" — true, but only because controller isn't owner; the TransferRef is unrelated to that protection. Today this is dead storage, which is fine for forward-compat; the comment overstates its current role.

---

### I2 — Redundant lookup in `amm::swap` aggregator entry 🔵 INFO

**Module + line:** `amm.move` lines 2173–2189.

The `swap` function takes `pool_addr`, immediately reads `pool.handle`, then calls `swap_exact_apt_in(handle, ...)` which re-derives `pool_addr` from `handle`. Two `borrow_global` of the same Pool. Not a bug; just gas waste (~2× pool fetch). For darbitex aggregator parity. INFO-only.

---

### I3 — `Position` Object orphaned (resource removed, ObjectCore remains) after `remove_liquidity` 🔵 INFO

**Module + line:** `lp_staking.move` line 3060.

`remove_liquidity` does `move_from<Position>(position_addr)` to extract the Position resource, but the underlying ObjectCore stays at that address. The Object becomes inert (the `Position` key resource is gone, so `lp_staking::has_position` returns false), but the address remains occupied — re-staking would generate a NEW Object at a fresh GUID-derived addr.

If a `DeleteRef` were generated at constructor time, the Object could be properly deleted via `object::delete`. Standard Aptos cleanliness pattern. INFO; no functional impact.

---

### I4 — Theoretical `compute_amount_out` overflow at extreme reserves 🔵 INFO

**Module + line:** `amm.move` lines 2427–2436.

For `numerator = amount_in_after_fee × (reserve_out as u128)`, with `amount_in` and `reserve_out` both ≤ ~1e17 (token supply), `numerator ≤ 1.84e21 × 1e17 = 1.84e38`, just under u128 max (3.4e38). Headroom is tight but adequate given supply caps. If supply caps were ever raised (e.g., for a bigger token), this becomes a concern. Not actionable today; flag for awareness.

---

## Design Questions

### Q1 — `amm::create_pool_atomic` friend-only invariants

**Answer:** Sound.

**Reasoning:** Friend list is `factory, lp_staking, apt_vault`. Searched both `lp_staking.move` and `apt_vault.move` for any call to `amm::create_pool_atomic` — none. Both modules only call other amm functions (`add_liquidity_internal`, `remove_liquidity_internal`, `extract_fees_for_claim`, `swap_exact_apt_in`, `fee_per_lp`, etc.). Move's `public(friend)` gives compiler-enforced single-call-site guarantees here. The friend graph is intentionally over-broad for the OTHER amm functions but `create_pool_atomic` is uniquely callable only from `factory::create_token_atomic`.

**Alternative if Concerning/Wrong:** N/A.

---

### Q2 — Universal fee accumulator denominator + truncation semantics

**Answer:** Sound.

**Reasoning:** Both directions of arithmetic round down: (a) `fee_per_lp_delta = (fee × 1e18) / lp_supply` (Move integer div truncates), (b) per-position settle `(acc_now - last_acc) × shares / 1e18` also truncates. So sum of per-position pending is always ≤ total fees deposited. `extract_fees_for_claim` asserts `fee_bucket >= requested` so even if pending sum minus dust happened to drift, no underflow possible. Worst case: dust accumulates in `apt_fees`/`token_fees` indefinitely; this is the documented L2 behavior.

One observation: the accumulator update `if (pool.lp_supply > 0)` (lines 2249, 2302, 2406) handles the empty-pool case correctly. The fee FAs are still deposited to the bucket, but the accumulator doesn't advance until lp_supply > 0 — so first-LP after a zero-pool window would NOT inherit those fees. Given the protocol's structure (locked-creator LP at register_handle is always > 0), this case is unreachable. INFO-only.

**Alternative if Concerning/Wrong:** N/A.

---

### Q3 — Locked-creator forever-lock structural enforcement

**Answer:** Sound.

**Reasoning:** Position struct holds `shares: u128` only — no FA store inside. The "locked LP" is shares accounted in `amm::Pool.lp_supply`; reserves can only leave via `amm::remove_liquidity_internal`, which has friend list (factory, lp_staking, apt_vault). I traced all callers:
- `factory`: never calls `remove_liquidity_internal`.
- `apt_vault`: never calls `remove_liquidity_internal` (only `swap_exact_apt_in`).
- `lp_staking`: calls it from exactly one site (`remove_liquidity` line 3062), gated by `unlock_at != UNLOCK_FOREVER` (line 3043).

The only `move_from<Position>` site in lp_staking is line 3060, also inside `remove_liquidity` after the same gate. `Position` has key only (no `store`), so it cannot be extracted by external generic Object-mover code.

`profile::derive_pid_signer` returning a signer for pid_addr does NOT enable Position extraction, because `move_from<Position>` is restricted by Move's module-locality rule (only the `desnet::lp_staking` module can `move_from<Position>`, period). So even if all six friends of `derive_pid_signer` are compromised, the locked Position cannot be touched.

This is a strong invariant and well-designed.

**Alternative if Concerning/Wrong:** N/A.

---

### Q4 — Recipient auto-resolution at claim time / race conditions

**Answer:** Sound (per stated design).

**Reasoning:** Aptos has sequenced execution and no public mempool. There is no "frontrun" via mempool ordering. Within a single block, transactions execute serially. The "race" scenario in Q4 (alice pokes claim, bob frontruns by transferring PID) doesn't apply because:

1. If alice and bob submit independent txs, validators sequence them; whichever lands first executes its full effects atomically.
2. If a single tx bundles both (e.g., a marketplace settlement), the transfer must complete before the new owner can claim — which means the new owner sees only post-transfer accruals as their right.

The "buyer of a PID inherits unclaimed accruals" is by design, documented in §4 of submission ("frozen for prior owner"). Sellers must call `claim` before transferring to capture rewards earned during their ownership. This is standard NFT-with-rewards UX (Velodrome, Convex, etc).

**One LOW observation worth surfacing to the dev team / frontend:** marketplace listings should auto-include "expected unclaimed yield" in pricing UI. Otherwise sellers will get rugged by buyers who immediately claim post-purchase. Not a contract bug; a UX consideration.

**Alternative if Concerning/Wrong:** N/A.

---

### Q5 — Reservation guard PID derivation correctness

**Answer:** Sound.

**Reasoning:** `wallet_addr = signer::address_of(wallet)` — Move signers are unforgeable; `wallet_addr` is the genuine tx authority's address. `reserved_handle_claimer(handle)` returns `Option<address>` for the 5 reserved handles. The check `assert!(wallet_addr == required_claimer, E_RESERVED_HANDLE)` runs BEFORE any state mutation. There is no cross-module re-entry path: register_handle is `public entry`, atomically validates → fees → mints → calls factory. No friend module exposes a way to bypass this guard for reserved handles.

PID-per-wallet uniqueness is preserved because each reserved handle has a different `required_claimer` → 5 different wallet_addrs → 5 different `derive_pid_address` outputs → 5 different PIDs. The `d` reservation pointing at a sealed resource_account is intentionally unclaimable (effective burn).

One belt-and-braces observation: there is no test in `profile.move`'s test block that exercises the reserved-handle guard. Recommended to add:
```move
#[test, expected_failure(abort_code = E_RESERVED_HANDLE, location = Self)]
fun test_reserved_handle_rejected_for_wrong_wallet() { ... }
#[test]
fun test_reserved_handle_accepts_authorized_wallet() { ... }
```
These would also serve as documentation of the guard semantics.

**Alternative if Concerning/Wrong:** N/A.

---

### Q6 — Atomic register_handle abort safety

**Answer:** Sound (with one footnote).

**Reasoning:** Move atomicity reverts all state on abort. `register_handle` does fee withdrawal + deposit, PID create + ref generation, profile move_to, transfer_vault move_to, registry insert, factory call (which itself does mint + reserve deploys + amm pool create + lp_staking lock). Any abort anywhere in this chain reverts everything except event emissions (events are advisory only on Aptos).

I checked specifically:
- No dispatchable FA hooks are used. `primary_fungible_store::withdraw/deposit` for APT goes through paired-coin standard but doesn't trigger arbitrary code.
- Custom Metadata is configured in factory step 1 with empty icon_uri / project_uri (line 704–705), so no off-chain side effects.
- `code::publish_package_txn` is not called during register_handle path (only governance paths call it).

**Footnote:** Events emitted by partial execution (e.g., FactoryInitialized, ProtocolInitialized — only fire at module init, not register_handle) are not a concern. Within register_handle, all events are emitted at the end (line 1385) so abort-mid-fn means no events. Good.

**Alternative if Concerning/Wrong:** N/A.

---

### Q7 — Handle string validation completeness

**Answer:** Sound for security; LOW gaps documented as L3.

**Reasoning:** Per-byte check excludes everything outside `[0x30-0x39] | [0x61-0x7A] | 0x2D`. Cyrillic 'а' (U+0430) is UTF-8-encoded as `0xD0 0xB0` — both bytes outside allowed ranges → rejected. All non-ASCII Unicode is rejected since UTF-8 multi-byte sequences start with bytes ≥ 0xC0 and continuation bytes are 0x80-0xBF, both outside the allowed set. Latin homoglyph attacks (capital I vs lowercase l) are partially mitigated because uppercase is rejected; lowercase l vs digit 1 vs digit 0 vs lowercase o ARE confusable but that's a font/UX problem, not a contract problem.

Bytes-only comparison: `b"alice"` and `b"Alice"` cannot collide because `Alice` is rejected. `b"ALICE"` rejected. No normalization issues since only ASCII is allowed.

L3 gaps are UX (degenerate hyphen forms), not security.

**Alternative if Concerning/Wrong:** Optional L3 fix for hyphen edge cases.

---

### Q8 — Flash loan reentrancy comprehensive coverage

**Answer:** Sound for state-mutating functions. Acceptable trade-off for views (with one watch-out).

**Reasoning:** `pool.locked` flag set at flash_borrow (line 2342), cleared at flash_repay (line 2415). Gates checked:

| Function | `assert!(!pool.locked)` | Line |
|---|---|---|
| `add_liquidity_internal` | ✅ | 2058 |
| `remove_liquidity_internal` | ✅ | 2104 |
| `swap_exact_apt_in` | ✅ | 2236 |
| `swap_exact_token_in` | ✅ | 2286 |
| `flash_borrow` (re-entry block) | ✅ | 2341 |
| `extract_fees_for_claim` (M1 self-audit fix) | ✅ | 2151 |
| `create_pool_atomic` | N/A (per-pool flag) | — |
| All views | ❌ (intentional) | — |

`create_pool_atomic` doesn't need the gate because `locked` is per-pool and a brand-new pool has its own flag. Can't borrow from pool A and create-as-attacker pool B and exfiltrate — different resources, different flags.

**Watch-out for views:** Views (`reserves`, `lp_supply`, `quote_swap_exact_in`, etc.) are NOT gated. During a flash window, reserves are temporarily drained on the borrowed side. If any external protocol uses DeSNet pool views as a price oracle, they get manipulable readings. The submission's threat model says "no external oracle, pool reserves are the sole price source" — which is correct for DeSNet's *own* internal use (DeSNet doesn't use its own pools as oracle for any decision). External protocols using DeSNet as oracle do so at their own risk.

However: I found one DeSNet-internal place where reserve readings are weaponizable, and it's H3 (`apt_vault::settle` with `min_out=0`). That's a same-tx exploit, not technically a flash loan, but the underlying issue is the same: trusting AMM mid-execution is dangerous.

**Alternative if Concerning/Wrong:** Fix H3. Optionally add a `pool_locked` view-side warning flag indexed by external integrators.

---

### Q9 — Voting power source authentication

**Answer:** **Concerning.** See H2 + H4 for full detail.

**Reasoning:** Three layered weaknesses combine:

1. **H4 — `record_reward_received` is `public`, not `public(friend)`.** The "sole call site" claim is enforced by `grep`, not by Move's type system. Any future code added to factory/profile/amm/lp_staking/governance with access to pkg_signer can call it. This is a structural hardening gap, not a current exploit.

2. **H2 — The `amount` argument is the requested `pending_emission`, not the actual paid amount.** Once lp_emission depletes (or under any partial-fill scenario), voting power inflates without bound at zero token cost. This IS a current exploit.

3. **`pkg_signer` is the master capability.** Its derivation is friend-restricted (good) but it's a single uber-cap — once you have it, you can call any module's friend functions claiming to be the package authority.

H2 alone is enough to undermine governance. H1 (execute_proposal hash mismatch) makes any successful governance proposal arbitrarily-payloadable. The compound of H1+H2 means: with enough patience post-depletion, an attacker can pass any proposal and ship any code. This is the central reason for the 🟡 YELLOW verdict rather than 🟢 GREEN.

**Alternative:** All three fixes (H1, H2, H4) are small. Land them together. After fixes, this becomes Sound.

---

### Q10 — Free-form

A few additional observations the structured questions didn't cover:

**Q10a — `governance::propose_upgrade` allows any address with > 5% voting power to propose:**
There's no rate limit on proposals from a single proposer, and proposals are stored indefinitely in a SmartTable (no cleanup). A single whale could spam thousands of proposals to bloat storage / make `proposal_count` UI noisy. Not security; storage UX.

**Q10b — `code::publish_package_txn` package compatibility check:**
Aptos's `publish_package_txn` enforces compatibility rules (e.g., compat-policy = upgrade only if struct layouts unchanged). v0.3.0 → v0.3.1 (handle_fee_vault) needs careful struct layout review. Out of scope here, but worth a self-audit checkpoint at v0.3.1: does adding `handle_fee_vault: address` to `ProtocolState` count as compatible? Depends on which compat policy the .move package toml declares.

**Q10c — The `emit_press_to_presser` cross-module API in factory:**
`factory::emit_press_to_presser(pid_signer, recipient, ...)` is `public` (line 944). Auth is "caller passes pid_signer (ExtendRef-derived). Only desnet::profile friends can construct such a signer." This is correct, BUT: the same M3 concern applies. Six profile friends can construct any pid_signer. So six modules can call `emit_press_to_presser` for any PID. Currently only `press` calls it (presumably). Same defense-in-depth gap as M3. Not a separate finding; M3 captures the structural issue.

**Q10d — Reaction emission supply_cap:**
`emit_press_to_presser` accepts `supply_cap: u64` from caller (press module). Need to verify press doesn't allow user-supplied supply_cap to bypass the 50M reserve cap. Didn't trace — recommend the press audit explicitly check that `supply_cap` is computed from `record.reaction_reserve` state, not from user input.

**Q10e — Governance signer cap for the entire monolith is held by ONE module (`governance`):**
This is good (single auditable site for the master cap). But it means `governance.move` is the most security-critical module in the entire codebase. An RCE-equivalent in governance = total compromise. The H1 finding is exactly that. Recommended: pin `governance.move` as a "no-touch without 2 reviewer sign-offs" file in your repo policy.

**Q10f — Mainnet deploy ordering:**
Current plan in §10 is: apply HIGH/MED fixes → re-test → publish via 1/5 multisig → smoke → 3/5. This is fine, but: between "publish via 1/5" and "raise to 3/5", a single signer compromise can ship arbitrary upgrade via `multisig_upgrade`. Window should be MINUTES, not days, and ideally the smoke txs and multisig threshold raise should be bundled into the same short ops session. Document the time budget (e.g., "≤2 hours from publish to 3/5") in the runbook.

**Q10g — On the "AI-audited only" disclosure in `amm::WARNING`:**
`b"DESNET AMM x*y=k. AI-audited only. Use at own risk."` — honest and appreciated. After human audit (if/when), update to reflect.

---

## Overall Verdict

🟡 **YELLOW** — ship after fixes.

**Rationale:** The architecture is well-thought-out: clean monolith + friend graph hygiene, atomic register_handle, structural forever-lock invariant, V3-style position NFTs with universal accrual, well-designed reservation guards. The core engineering is solid and the self-audit caught what self-audits typically can. However, four HIGH findings cluster around the governance pathway in a way that, in compound, would let any patient attacker take over the protocol after timelock — H1 (executor doesn't verify code matches proposal), H2 (voting power inflates after emission depletes), H3 (sandwich-able settle), H4 (`record_reward_received` not friend-restricted). H1 and H2 are the load-bearing concerns; H3 is straightforward; H4 is a one-line visibility change. M1 (no add_liquidity refund) is also a real loss-of-funds vector for non-frontend users.

All HIGH findings have small, well-bounded fixes (under ~30 LoC total across all four). With those fixes + Round-2 verification focused on the same governance path, this codebase should be GREEN. Hold mainnet baseline publish until at least H1 and H2 are landed; H3, H4, M1 ideally in the same patch. M2 (`disable_multisig_upgrade`) is a strategic rather than tactical fix and can land in v0.3.1 with the other compat upgrades.

Specifically for H1: this is the kind of bug that makes me strongly recommend you add a self-audit dimension called "executor-time invariants vs. proposal-time commitments" — i.e., for every state change that's deferred between approval and execution, what is the executor permitted to vary, and is that documented? That dimension would have caught the missing hash check.

Good luck with mainnet. I'm happy to do Round 2 verification on the patch.

— Claude (Anthropic)
