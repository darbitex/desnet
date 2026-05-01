# DeSNet v0.3.0 mainnet baseline — External Audit Submission (Round 2)

**Version:** v0.3.0-r2 (post-R1 fix patch)
**Date:** 2026-05-02
**Chain:** Aptos mainnet (publish pending R2 clearance)
**Audit scope:** R1 fix verification — focused review of patch (~486 diff lines, 21 KB)
**Tests:** 68/68 unit + integration passing on `aptos move test`
**Companion files:**
- `AUDIT-DESNET-V030-R2-DIFF.md` — git diff R1→R2 (THIS IS THE PRIMARY AUDIT TARGET)
- `AUDIT-DESNET-V030-SOURCE.md` — full v0.3.0-r2 source (~285 KB, post-patch state)
- `AUDIT-DESNET-V030-SUBMISSION.md` — original R1 audit prompt (architecture context)

**R1 panel responses:** 6/6 received. Verdict spread:
- 🟢 GREEN: Qwen 3 Max
- 🟡 YELLOW: Gemini 3 Pro, Grok 4, Kimi K2.6, Claude Opus 4.7
- 🔴 RED: DeepSeek V3.2 (1 false-positive)

---

## ⚡ R2 SCOPE — verify fixes, do NOT re-audit unchanged code

This round is **NARROW and FOCUSED**. Re-auditing the entire codebase wastes your context — please prioritize:

1. Did each R1 fix correctly address the original finding?
2. Do the fixes introduce any new issues (regressions, edge cases, unintended interactions)?
3. Are there OTHER critical issues you'd flag now that weren't visible in R1?

The full v0.3.0-r2 source is provided as appendix in case you want to re-trace specific call paths. The DIFF file is the recommended primary read.

---

## 1. R1 Findings → R2 Fix Map

### HIGH (4 fixes)

#### H1 — `execute_proposal` hash verification
**R1 finding (Claude H1, Kimi F1, DeepSeek implicit):** `execute_proposal` accepted arbitrary `metadata` + `code_bytes` without comparing to `proposal.new_module_bytes_hash`. Voters approved code A, executor publishes code B. Full DAO bypass.

**R2 fix (`governance.move`):**
```move
// Added pure helper:
public fun compute_upgrade_digest(
    metadata: &vector<u8>,
    code_bytes: &vector<vector<u8>>,
): vector<u8> {
    let buf = bcs::to_bytes(metadata);
    let i = 0;
    let n = vector::length(code_bytes);
    while (i < n) {
        let chunk_bcs = bcs::to_bytes(vector::borrow(code_bytes, i));
        vector::append(&mut buf, chunk_bcs);
        i = i + 1;
    };
    hash::sha3_256(buf)
}

// In execute_proposal, before publish_package_txn:
let submitted_digest = compute_upgrade_digest(&metadata, &code_bytes);
// ... after timelock checks ...
assert!(submitted_digest == proposal.new_module_bytes_hash, E_HASH_MISMATCH);
```

**Verification questions:**
- Q1.1: Is the digest scheme (`sha3_256(bcs(metadata) || concat(bcs(code_bytes[i])))`) collision-resistant for this use case?
- Q1.2: Is the BCS-of-individual-chunks-then-concat ambiguous in any way (length-prefix included? canonical encoding?)
- Q1.3: Does `propose_upgrade` documentation make it clear that off-chain callers MUST use this exact scheme to compute their hash before submitting?
- Q1.4: Should the fix also restrict `caller: &signer` of execute_proposal (currently anyone can execute approved proposal — by design, but worth confirming)?

---

#### H2 — Voting power records actual paid amount
**R1 finding (Claude H2, DeepSeek F1):** `claim_internal` recorded `pending_emission` (requested) instead of actual paid amount. After lp_emission depletes, `pull_for_claim` returns 0 but `record_reward_received(pending_emission)` keeps inflating voting power for free.

**R2 fix (`lp_staking.move::claim_internal`):**
```move
// Was:
voter_history::record_reward_received(&pkg_signer, recipient, pending_emission);

// Now:
let actual_paid = fungible_asset::amount(&emission_fa);
primary_fungible_store::deposit(recipient, emission_fa);
if (actual_paid > 0) {
    let pkg_signer = governance::derive_pkg_signer();
    voter_history::record_reward_received(&pkg_signer, recipient, actual_paid);
};
```

**Verification questions:**
- Q2.1: Does this fully close the post-depletion inflation vector?
- Q2.2: Edge case: what if `actual_paid` < `pending_emission` (partial fill due to rounding)? Voter gets less voting power than emission accumulator suggests they earned. Is this acceptable (yes — voter only gets credit for what they actually received)?
- Q2.3: Should `position.last_acc_per_share` be reset to a value that reflects "I claimed only actual_paid not pending"? Currently it's set to `acc` regardless. This means the unpaid portion is FORGOTTEN (won't be claimable later if reserve is topped up). Acceptable trade-off?

---

#### H3 — apt_vault::settle slippage tolerance
**R1 finding (Claude H3):** `swap_exact_apt_in(handle, apt, 0)` with zero slippage in permissionless `settle` entry. Attacker bundles 3-leg swap+settle+swap in one tx → sandwich exploit.

**R2 fix (`apt_vault.move::settle`):**
```move
const SETTLE_SLIPPAGE_BPS: u64 = 300;  // 3% tolerance
const BPS_DENOM: u64 = 10000;

// In settle:
let (apt_reserve, token_reserve) = amm::reserves(vault.handle);
let expected_out = amm::compute_amount_out(apt_reserve, token_reserve, buyback_amount);
let min_out = (expected_out * (BPS_DENOM - SETTLE_SLIPPAGE_BPS)) / BPS_DENOM;
// Pass min_out (not 0) to amm::swap_exact_apt_in
```

**Verification questions:**
- Q3.1: Is 3% the right tolerance? Too tight = settle aborts on legitimate volatility. Too loose = sandwich still profitable. Trade-off rationale?
- Q3.2: The expected_out is computed AT `settle` start. If a swap (legit or attack) happens between expected_out computation and the actual swap, slippage check still uses pre-attack expected. Does this leave a window? (My understanding: no, because both are in the same tx — Move sequencing means no interleaved state change.)
- Q3.3: Bonus M5 fix: assert `pool_address_of_handle(vault.handle) == vault.amm_pool_addr` — protects against future pool migration drift. Is this assert correctly placed (BEFORE swap, after vault load)?

---

#### H4 — voter_history visibility friend-restricted
**R1 finding (Claude H4, DeepSeek F5):** `record_reward_received` was `public`, sole-call-site invariant grep-enforced not type-enforced. Future code with @desnet pkg_signer could mint voting power.

**R2 fix (`voter_history.move`):**
```move
friend desnet::lp_staking;  // added

public(friend) fun record_reward_received(  // was public
    factory_authority: &signer,
    voter_addr: address,
    amount: u64,
) acquires Registry { /* keep @desnet assertion as belt-and-braces */ }
```

Plus updated stale doc comments to reflect monolith architecture (no more `factory_signer` / `lp_emission obtains factory_signer` references).

**Verification questions:**
- Q4.1: Is the friend list now exclusively `desnet::lp_staking` for this fn? (Confirmed via grep — but please re-verify.)
- Q4.2: Does the @desnet signer addr assertion stay relevant as belt-and-braces, or is it now redundant given friend restriction?
- Q4.3: Are there other functions in voter_history that should be friend-restricted but aren't? (`prune_voter_history` is permissionless by design.)

---

### MEDIUM (3 fixes)

#### M1 — add_liquidity_internal returns surplus refunds
**R1 finding (Claude M1):** Mismatched ratio caused surplus to be gifted to existing LPs. User pays both sides full, gets LP for the constraining side only.

**R2 fix (`amm.move::add_liquidity_internal` + `lp_staking.move::add_liquidity_with_lock_internal`):**
- Signature change: `: u128` → `: (u128, FungibleAsset, FungibleAsset)` (return triple)
- amm computes optimal pair, extracts surplus from over-funded side
- lp_staking deposits refunds to caller's primary store

**Verification questions:**
- Q5.1: Is the optimal_apt / optimal_token computation arithmetically correct? `optimal_apt = lp_minted * apt_reserve / lp_supply`
- Q5.2: Edge: when one side has zero surplus, `fungible_asset::extract(_, 0)` is called — is that safe? (Move framework typically handles zero-extract OK, but worth confirming.)
- Q5.3: Test wrapper `add_liquidity_internal_for_test` deposits leftover refunds to `@desnet` — clean for test, but should it instead destroy_zero or assert_zero?

---

#### M2 — disable_multisig_upgrade one-way switch
**R1 finding (Claude M2):** `multisig_upgrade(@origin, ...)` is a permanent backdoor. Even if DAO is well-established, @origin key compromise = full upgrade rights.

**R2 fix (`governance.move`):**
- Added `multisig_upgrade_disabled: bool` field to GovernanceState (init=false)
- `multisig_upgrade` asserts `!disabled` (E_MULTISIG_DISABLED)
- New entry `disable_multisig_upgrade(multisig: &signer)` — @origin only, irreversible
- Emits `MultisigUpgradeDisabled` event

**Verification questions:**
- Q6.1: Adding new field to existing struct breaks `compatible` upgrade policy. For mainnet baseline (fresh deploy) this is fine. For testnet (already has v0.3.1 deployed) this would break — but testnet is throwaway. Confirm understanding.
- Q6.2: Should `disable_multisig_upgrade` also have an event-only public confirmation (e.g., a 24h timelock) to prevent accidental disable? Or keep as is (irreversible-on-call, deliberate)?

---

#### M5 — apt_vault cache consistency
**R1 finding (Claude M5):** Vault stores both `amm_pool_addr` (cached at deploy) and `handle`. settle uses handle but views return cached addr. Future pool migration could cause divergence.

**R2 fix (`apt_vault.move::settle`):**
```move
assert!(
    amm::pool_address_of_handle(vault.handle) == vault.amm_pool_addr,
    E_POOL_ADDR_DRIFT
);
```

**Verification questions:**
- Q7.1: Is the assert correctly placed BEFORE swap (not after)?
- Q7.2: Should this assert also be applied to other places that use vault.amm_pool_addr (views? other entries?)?

---

### LOW (3 fixes)

#### Kimi F2 — factory pause/unpause
**R1 finding (Kimi F2):** `paused` flag was nuclear one-way (no unpause).

**R2 fix (`factory.move`):**
```move
public entry fun set_paused(admin: &signer, new_paused: bool) acquires FactoryState {
    assert!(signer::address_of(admin) == @origin, E_NOT_ADMIN);
    borrow_global_mut<FactoryState>(@desnet).paused = new_paused;
}
```

**Verification questions:**
- Q8.1: Is @origin the right authority? (Bootstrap multisig, raised to 3/5 post-smoke.) Should this transition to DAO control eventually?

---

#### Kimi F4 — governance bootstrap state validation
**R1 finding (Kimi F4):** `propose_upgrade` could be called even with `desnet_fa_metadata = @0x0` and `total_30d_emission = 0` (sentinel = unconfigured). Threshold returned u64::MAX so proposals would always fail E_INSUFFICIENT_VOTING_POWER, but the abort path was confusing.

**R2 fix (`governance.move::propose_upgrade`):**
```move
let cfg = borrow_global<GovernanceState>(@desnet);
assert!(cfg.desnet_fa_metadata != @0x0, E_NOT_INITIALIZED);
assert!(cfg.total_30d_emission > 0, E_NOT_INITIALIZED);
```

**Verification questions:**
- Q9.1: Better error than the silent u64::MAX threshold path. Confirm UX improvement is real (less confusing for proposer who'd otherwise see E_INSUFFICIENT_VOTING_POWER).

---

#### Gemini MED — zero-addr checks
**R1 finding (Gemini MED-2):** `update_fee_receiver` and `rotate_admin` accepted `@0x0` → permanently burned fee receiver / orphaned admin.

**R2 fix (`profile.move`):**
```move
assert!(new_fee_receiver != @0x0, E_INVALID_ADDRESS);
// in rotate_admin:
assert!(new_admin != @0x0, E_INVALID_ADDRESS);
```

**Verification questions:**
- Q10.1: Are there other admin entries in any module that should also reject @0x0?

---

### DEFERRED to v0.3.2 (acknowledged but not in R2)

- **Claude M3** (`derive_pid_signer` over-permissioned to 6 friend modules): bigger refactor, deferred. Current code traces all clean (no exploit), but defense-in-depth gap remains.
- **DeepSeek F2** (MintRef compile error): FALSE POSITIVE per Aptos Framework `MintRef has store, drop`. No action.

---

## 2. New issues to flag (free-form)

If you spot anything new in the R2 patch — issues introduced by the fixes, or things you missed in R1 that you'd flag now — please surface them as `R2-N1`, `R2-N2`, etc.

Particularly interested in:
- Did any fix introduce a regression in another module?
- Did the diff change any API signature in a way that breaks downstream callers we missed?
- Are there test gaps the patch should add?

---

## 3. Verdict format

For each verification question (Q1.1 through Q10.1), answer:
- **Verified** / **Concerned** / **Insufficient context**
- 1-2 sentence reasoning

Plus overall R2 verdict:
- 🟢 GREEN (fixes correctly address R1 findings, ready to ship)
- 🟡 YELLOW (some fixes need iteration — list which)
- 🔴 RED (fixes introduce new HIGH issues — list)

---

## 4. Next steps after R2

If GREEN from ≥4 of 6 auditors:
1. Tag final mainnet baseline `v0.3.0-mainnet`
2. Publish via 1/5 multisig per `feedback_mainnet_deploy_sop.md`
3. Reserved handle claims (4 controllable)
4. Compat upgrade to v0.3.1 (handle_fee_vault) — separate audit Round 3 if material

Thank you for the focused review.

— Rera (DeSNet protocol author + Claude Opus 4.7 (1M context) co-author)
