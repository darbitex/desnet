# Qwen 3 Max — DeSNet v0.3.0 R1 Audit Response

**Date:** 2026-05-02
**Verdict:** 🟢 GREEN (Ship-ready)
**Findings:** 0 HIGH / 0 MED / 1 LOW / 2 INFO
**Source:** raw response pasted by Rera 2026-05-02

---

Here is the external audit report for DeSNet v0.3.0 mainnet baseline.

# DeSNet v0.3.0 External Audit Report (Round 1)
**Date:** 2026-05-02
**Scope:** 17 modules, ~7434 LoC Move (monolith package `@desnet`)
**Verdict:** 🟢 **GREEN** (Ship-ready after minor clarifications)

## 1. Findings

### Finding 1: Info — `MintRef` Destruction Assumption
**Module:** `factory.move`
**Line:** `let _ = mint_ref;` (Step 9 of `create_token_atomic`)
**Issue:** The code relies on the `MintRef` resource having the `drop` ability to finalize the fixed supply of 1B tokens. If `MintRef` lacked `drop`, this would fail to compile. Since the source compiles cleanly, this assumption holds, but it couples supply immutability to the Aptos framework's definition of `MintRef`.
**Risk:** Low. Standard practice for fixed-supply FAs in Aptos.
**Suggested Fix:** None required.
**Confidence:** HIGH

### Finding 2: Info — Fee Bucket Truncation Dust
**Module:** `amm.move`, `lp_staking.move`
**Line:** Fee accumulator math in `swap_exact_apt_in` vs `claim_internal`.
**Issue:** The V3-style fee accumulator uses truncating division `(fee * SCALE) / lp_supply`. When multiple positions claim, the sum of truncated claims per position will be ≤ the actual fee bucket balance. The pool retains small amounts of dust (unclaimable by LPs).
**Risk:** Low. This is standard V3 behavior and pool-favorable (no over-claim risk). The `extract_fees_for_claim` assertion `balance >= amount` will never fail due to rounding errors.
**Confidence:** HIGH

### Finding 3: Low — Governance Signer Exposure in Monolith
**Module:** `governance.move`, `factory.move`, `lp_staking.move`
**Issue:** `governance::derive_pkg_signer` grants the package signer to all friend modules. In the monolith, `factory` and `lp_staking` are friends and thus could theoretically derive the `@desnet` signer and call `voter_history::record_reward_received` directly (bypassing `claim_internal`).
**Risk:** Low. Since this is a monolith package, `factory` and `lp_staking` are trusted internal code. There is no external threat vector here, and the current logic paths do not abuse this.
**Confidence:** HIGH

---

## 2. Design Questions

### Q1 — `amm::create_pool_atomic` friend-only invariants
**Answer:** Sound
**Reasoning:** The friend list for `amm` includes `factory`, `lp_staking`, and `apt_vault`. Only `factory` calls `create_pool_atomic`. `lp_staking` and `apt_vault` are friends for other functions (`add_liquidity`, `swap`, etc.) and do not invoke pool creation. The monolith structure ensures no unauthorized internal module creates pools.
**Alternative:** None needed.

### Q2 — Universal fee accumulator denominator semantics
**Answer:** Sound
**Reasoning:** The truncation in `(fee * SCALE) / lp_supply` and `(acc_delta * shares) / SCALE` ensures that `sum(claims) ≤ bucket_balance`. The pool retains the rounding dust. There is no risk of over-pay or underflow in `extract_fees_for_claim`. The invariant holds even when `lp_supply` changes.
**Alternative:** None needed.

### Q3 — Locked-creator forever-lock structural enforcement
**Answer:** Sound
**Reasoning:** The lock is enforced in `lp_staking::remove_liquidity` via `unlock_at != UNLOCK_FOREVER`. The AMM reserves are held in `amm`, and `amm::remove_liquidity_internal` is `public(friend)`. No friend module (`factory`, `apt_vault`) calls this function for the creator's pool. The structural lock holds as long as the monolith code is not modified.
**Alternative:** None needed.

### Q4 — Recipient auto-resolution at claim time
**Answer:** Acceptable trade-off
**Reasoning:** The recipient is resolved at execution time via `object::owner(pid_obj)`. If a PID is transferred before a claim is processed in the block, the new owner receives the yield. This is atomic within Aptos's execution model; there is no "in-flight" claim state that can be frontrun by a validator in a way that breaks atomicity. The yield follows the NFT.
**Alternative:** To lock yield to a specific address, the protocol would need a non-transferable position, but this contradicts the V3 NFT LP design.

### Q5 — Reservation guard PID derivation correctness
**Answer:** Sound
**Reasoning:** The guard checks `wallet_addr == required_claimer` for reserved handles. PID derivation is deterministic from `wallet_addr`. An attacker cannot spoof `signer::address_of`. The only risk is if a reserved claimer (e.g., `@origin`) registers a non-reserved handle first, occupying the PID slot, but this is a governance/trust assumption, not a bypass.
**Alternative:** None needed.

### Q6 — Atomic register_handle abort safety
**Answer:** Sound
**Reasoning:** All operations (fee withdraw, object creation, resource moves, factory calls) are within a single transaction. Aptos runtime reverts all state changes and events on abort. No non-revertible operations exist.
**Alternative:** None needed.

### Q7 — Handle string validation completeness
**Answer:** Sound
**Reasoning:** Validation iterates over bytes, allowing only ASCII `a-z`, `0-9`, and `-`. Multi-byte UTF-8 characters (e.g., Cyrillic homoglyphs) contain bytes outside this range and are rejected. Normalization is not required as the charset is strictly ASCII.
**Alternative:** None needed.

### Q8 — Flash loan reentrancy comprehensive coverage
**Answer:** Sound
**Reasoning:** `Pool.locked` is set in `flash_borrow` and cleared in `flash_repay`. All mutable entry points (`add/remove_liquidity`, `swap`, `extract_fees`, `flash_borrow`) check `!pool.locked`. Nested flash loans are blocked. Coverage is exhaustive.
**Alternative:** None needed.

### Q9 — Voting power source authentication
**Answer:** Sound
**Reasoning:** `voter_history::record_reward_received` asserts `signer.addr == @desnet`. The `@desnet` signer can only be derived via `governance::derive_pkg_signer`, which is restricted to friends. Only `lp_staking::claim_internal` calls this path. The friend graph isolates the authority.
**Alternative:** None needed.

### Q10 — Anything else
**Answer:** Observation
**Reasoning:** The monolith design simplifies the trust model significantly. The friend graph is clean and cycle-free. The `claim_internal` auto-claim before liquidity removal is a smart pattern to prevent lost yield. The codebase demonstrates strong invariant enforcement (e.g., forever-lock, atomic register).
**Alternative:** None.

---

## 3. Overall Verdict

🟢 **GREEN** (Ship-ready)

**Rationale:**
DeSNet v0.3.0 presents a robust, well-architected monolith. The consolidation into a single package eliminates cross-package trust risks and simplifies the friend graph. Key invariants—atomic registration, structural forever-lock, universal fee accrual, and secure voting power authentication—are correctly implemented and guarded. The self-audit identified and fixed the `extract_fees_for_claim` flash lock gap. No high or medium severity issues were found. The code is production-ready for mainnet deployment.
