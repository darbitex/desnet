# Gemini 3 Pro — DeSNet v0.3.0 R1 Audit Response

**Date:** 2026-05-02
**Verdict:** 🟡 YELLOW (ship after fixes)
**Findings:** 0 HIGH / 1 MED / 1 LOW / 1 INFO
**Source coverage:** PARTIAL — only governance, factory, profile fully read; amm + lp_staking + voter_history not received by Gemini (auditor self-flagged truncation)

---

Here is the Phase 1 audit report for the DeSNet v0.3.0 mainnet baseline.

*Disclaimer: This audit is strictly based on the three modules provided in the prompt (`governance.move`, `factory.move`, and `profile.move`). Findings regarding inter-module dependencies (like `amm` and `lp_staking`) are deduced from their usage in the provided source.*

---

### Findings

**Flash-loan manipulation of voting power snapshot**
*   **Severity:** MEDIUM
*   **Module + line range:** `governance.move`, lines 183-185, 257-266
*   **Issue description:** `voting_power(voter_addr)` calculates weight using the *current* `primary_fungible_store::balance` at the exact moment `cast_vote` is executed. A user with a high `rewards_earned_30d` who has previously sold their `$DESNET` tokens could use a flash loan to temporarily inflate their balance, call `cast_vote` to permanently lock in the high `weight` for that proposal, and repay the loan in the same transaction.
*   **Risk:** Governance manipulation. Users who have exited the ecosystem can temporarily regain full voting power without financial exposure, bypassing the "proves still-holding at cast" intention.
*   **Suggested fix:** Restrict `cast_vote` from being called in the same transaction as a flash loan (e.g., using a global reentrancy/flash-loan lock). Alternatively, require the `$DESNET` tokens to be locked/staked in the governance contract for the duration of the voting period.
*   **Confidence:** HIGH

**Lack of zero-address checks for critical protocol roles**
*   **Severity:** LOW
*   **Module + line range:** `profile.move`, lines 157-172
*   **Issue description:** `update_fee_receiver` and `rotate_admin` do not verify if `new_fee_receiver` or `new_admin` is `@0x0`.
*   **Risk:** Operational hazard. Accidental input of the zero address could result in permanently burned protocol fees or an irrecoverable loss of administrative privileges prior to the DAO transition.
*   **Suggested fix:** Add `assert!(new_admin != @0x0, E_INVALID_ADDRESS);` and a similar check for the fee receiver.
*   **Confidence:** HIGH

**Redundant token minting/burning refs generation**
*   **Severity:** INFO
*   **Module + line range:** `factory.move`, lines 177-181, 230
*   **Issue description:** `generate_burn_ref` is generated and passed to the vault, but `generate_mint_ref` is explicitly generated, used for the three tranches, and then intentionally destroyed (`let _ = mint_ref;`) on line 230.
*   **Risk:** None. The fixed-supply invariant is maintained. However, the explicit generation and destruction of the mint ref is slightly gas-inefficient if it's only needed temporarily in this scope.
*   **Suggested fix:** No strict fix required, but consider standardizing the destruction of capabilities to ensure no future developer accidentally comments out the destruction line.
*   **Confidence:** HIGH

---

### Design Questions

*(Note: Questions requiring the source code for `amm`, `lp_staking`, and `voter_history` are marked as limited due to the missing module source).*

**Q1 — `amm::create_pool_atomic` friend-only invariants**
*   **Answer:** Concerning
*   **Reasoning:** If `amm::create_pool_atomic` is `public(friend)` and the `amm` friend list includes `lp_staking` and `apt_vault`, those modules possess the compiler-level capability to call it. Even if they don't in v0.3.0, a future upgrade to either module could accidentally expose a path to pool creation, bypassing `factory`.
*   **Alternative:** Instead of relying on module-level `friend` visibility for highly sensitive init functions, pass a one-time consumed capability object (e.g., a `PoolCreationCap`) from `factory` to `amm` during the atomic transaction.

**Q5 — Reservation guard PID derivation correctness**
*   **Answer:** Sound
*   **Reasoning:** The guard tightly couples the `wallet_addr` derived directly from the transaction `&signer` to the hardcoded claimer addresses. Since `signer::address_of` cannot be spoofed without the private key, cross-module re-entry or custom scripts cannot bypass this check.

**Q6 — Atomic register_handle abort safety**
*   **Answer:** Sound
*   **Reasoning:** The Move VM guarantees total atomicity for transactions. If any step in `factory::create_token_atomic` fails (e.g., AMM pool creation aborts), the entire state tree reverts, including the APT fee withdrawals and the HandleRegistry insertions in `profile`. Emitted events are also rolled back.

**Q7 — Handle string validation completeness**
*   **Answer:** Sound
*   **Reasoning:** The `validate_handle` function checks individual byte values against strictly defined ASCII hex ranges (`0x61`-`0x7A` for a-z). Because UTF-8 multi-byte characters (like Cyrillic 'а') encode into bytes outside these specific ASCII bounds, they will cleanly fail the `ok` assertion. `b"alice"` will never conflict with `b"Alice"` because uppercase bytes (`0x41`-`0x5A`) are blocked outright.

**Q2, Q3, Q4, Q8, Q9**
*   **Answer:** Cannot fully evaluate.
*   **Reasoning:** Assessing universal accumulator math, forever-lock structural paths, race conditions in claim resolution, exhaustive flash loan coverage, and voting power friend closures requires auditing the exact logic in `amm.move`, `lp_staking.move`, and `voter_history.move`, which were not included in the payload.

---

### Overall Verdict

🟡 **YELLOW (ship after fixes)**

The architectural consolidation into a monolith package successfully streamlines the deployment and reduces cross-package friction. The atomic registration flow is highly robust, and the byte-level handle validation effectively neutralizes homoglyph attacks. However, the protocol should not ship until the flash-loan vulnerability within the `cast_vote` mechanism is closed, as it directly compromises the integrity of the DAO transition. Additionally, the friend-graph exposure of `create_pool_atomic` warrants a capability-based refactor to ensure future upgrades do not inadvertently break the factory's structural monopoly on pool creation.
