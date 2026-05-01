# DeepSeek V3.2 — DeSNet v0.3.0 R1 Audit Response

**Date:** 2026-05-02
**Verdict:** 🔴 RED (do not ship)
**Findings:** 1 HIGH actual + 1 HIGH false-positive / 0 MED / 1 LOW / 2 INFO

---

**Overall Verdict:** 🔴 RED (do not ship)

**Rationale:** The codebase contains a critical economic vulnerability (HIGH severity) that allows governance voting power to be inflated when emission reserves are depleted, and a potential compilation blocker in the factory module due to illegal discard of a non-drop resource. These issues must be resolved before mainnet deployment. Additionally, several lower-risk observations should be addressed for robustness. The architecture is otherwise well-designed, with careful use of Move's object model and friend graph, but the vote-power bug strikes at the heart of DAO integrity.

---

## Findings

### Finding 1: Voting Power Inflation via Depleted Emission Reserve
**Severity:** HIGH
**Module + line range:** `lp_staking::claim_internal` (approx. lines 204–225 after `pending_emission` calculation)
**Issue description:**
When `lp_emission::pull_for_claim` returns fewer tokens than `pending_emission` (or zero, if the reserve is empty), `claim_internal` still records the **original** `pending_emission` amount in `voter_history::record_reward_received`. The code:
```move
let emission_fa = lp_emission::pull_for_claim(..., pending_emission);
primary_fungible_store::deposit(recipient, emission_fa);
voter_history::record_reward_received(&pkg_signer, recipient, pending_emission);
```
`pending_emission` is not the actual distributed amount; it is the computed pending amount based on the accumulator. Thus, an attacker can claim repeatedly from a depleted reserve, resetting the pending amount each time but accruing voting power as if they had received the full amount. This decouples voting weight from real economic stake, enabling low-cost governance manipulation.

**Risk:** Attackers can inflate their voting power without holding or receiving tokens, potentially passing malicious proposals (e.g., upgrading the protocol to drain funds).
**Suggested fix:** Record the actual distributed amount (`fungible_asset::amount(&emission_fa)`) instead of `pending_emission`. If the reserve is fully depleted, record zero.
**Confidence:** HIGH – clear code path and deterministic scenario.

### Finding 2: Unsafe Discard of `MintRef` (Compilation Error)
**Severity:** HIGH
**Module + line range:** `factory::create_token_atomic`, line `let _ = mint_ref;`
**Issue description:**
The `MintRef` resource does not have the `drop` ability. Binding it to `_` is not allowed; it must be explicitly destroyed with `fungible_asset::destroy_mint_ref`. The provided source contradicts the claim that all modules compile clean.
**Risk:** If this is the code intended for deployment, it will not compile. If the actual code differs, the audit is based on an inaccurate source.
**Suggested fix:** Replace with `fungible_asset::destroy_mint_ref(mint_ref);` and ensure the deployed binary matches.
**Confidence:** HIGH – Move type system compilation rule.

> **Author cross-check:** FALSE POSITIVE — current Aptos Framework `MintRef has store, drop` ability set. Compile + 68/68 tests pass on testnet. DeepSeek's framework knowledge is stale.

### Finding 3: Potential u128 Overflow in `update_pool` (extreme elapsed time)
**Severity:** LOW
**Module + line range:** `lp_staking::update_pool`
**Issue description:**
The calculation `(elapsed as u128) * (rate_per_sec as u128) * ACC_SCALE` can theoretically overflow a `u128` if `elapsed` exceeds ~3.4e11 seconds (≈10,000 years). While unlikely, the protocol should handle extreme dormancy gracefully.
**Risk:** Overflow would corrupt the emission accumulator, possibly breaking all future claims for that pool.
**Suggested fix:** Either cap `elapsed` at a safe maximum or use `math128` multiplied with overflow checks (or simply document and accept the negligible risk).
**Confidence:** LOW – practical likelihood is virtually zero.

### Finding 4: Race Condition between Position Claim and PID Transfer
**Severity:** INFO
**Module + line range:** `lp_staking::resolve_recipient` (locked position path)
**Issue description:**
Locked creator positions send rewards to `object::owner(pid_obj)` at claim time. A separate transaction can transfer the PID NFT before the claim executes, redirecting rewards to the new owner. This is an inherent blockchain race condition; the protocol cannot enforce atomicity across transactions.
**Risk:** A block builder could front-run a claim by inserting a PID transfer, stealing pending rewards. Users relying on exact timing may be surprised.
**Suggested fix:** Document prominently; consider a future snapshot mechanism if deemed necessary.
**Confidence:** MEDIUM – the race exists but is unavoidable without design changes.

### Finding 5: Overly Broad Authorization for Voting Power Recording
**Severity:** LOW
**Module + line range:** `voter_history::record_reward_received` (signer check)
**Issue description:**
The function only requires `signer::address_of(authority) == @desnet`, which can be obtained by **any** friend module of `governance` that has access to `derive_pkg_signer` (`factory`, `profile`, `amm`, `lp_staking`). Currently, only `lp_staking::claim_internal` calls it, but a bug in another friend module could allow unauthorized voting power inflation.
**Risk:** Defense-in-depth gap; if any trusted module is compromised, the governance tokenomics could be attacked.
**Suggested fix:** Restrict the caller by requiring an additional capability (e.g., a unique `VotePowerCap` stored only in `lp_staking`) or use `aptos_framework::account::create_signer_with_capability` with a tighter scope. For the monolith package, the risk remains low but worth noting.
**Confidence:** LOW – requires a bug in a trusted module.

---

## Design Questions

### Q1 — Accidental Pool Creation by Friends
**Answer:** Sound.
**Reasoning:** `create_pool_atomic` is `public(friend)` to `factory`, `lp_staking`, `apt_vault`. Only `factory` calls it during registration. The other friends do not contain any call to this function, and the friend-graph forbids external calls. No unauthorized pool creation is possible.

### Q2 — Universal Fee Accumulator Denomininator & Truncation
**Answer:** Sound (acceptable trade-off).
**Reasoning:** The accumulator uses scaled integer math where truncation always rounds down both at accumulation (`fee_per_lp` update) and at per-position claim (`pending = (acc_diff * shares) / SCALE`). The sum of all position claims will never exceed the fee bucket balance; a small dust amount may remain locked in the fee store. This is standard V3 behaviour and does not lead to insolvency or over‑payment.

### Q3 — Locked‑Creator Forever‑Lock Structural Enforcement
**Answer:** Sound.
**Reasoning:** The locked `Position` is stored using the PID Object signer (`pid_signer`). Only `lp_staking::remove_liquidity` can destroy the position and recover LP, but it aborts with `E_LOCKED_FOREVER` before touching the AMM. No other code path can move the `Position` resource away or extract its shares, because `profile::derive_pid_signer` is restricted to trusted modules that do not implement any such logic. The LP shares are structurally locked forever.

### Q4 — Recipient Auto‑Resolution and PID Transfer Race
**Answer:** Acceptable trade-off.
**Reasoning:** Claim and transfer are separate transactions. In Aptos, block builders can order them arbitrarily, creating a race condition. This is a fundamental limitation of the "current owner" model. Users should be advised to claim rewards before transferring the PID NFT. A snapshot-based solution could be added later if needed.

### Q5 — Reservation Guard PID Derivation Correctness
**Answer:** Sound.
**Reasoning:** Each reserved handle is mapped to a **different** authorized claimer address. The PID is derived solely from the wallet (`derive_pid_address(wallet_addr)`), so the five reserved handles produce five distinct PIDs. The check `assert!(wallet_addr == required_claimer, E_RESERVED_HANDLE)` is enforced before any state mutation, preventing squatting. No custom script can alter the signer's address.

### Q6 — Atomic `register_handle` Abort Safety
**Answer:** Sound.
**Reasoning:** The entire registration process runs in a single Move transaction. Any `assert` or `abort` reverts all state changes (resource creation, token minting, pool creation, etc.). No external dispatchable hook (e.g., FA transfer hook) is used, and standard Aptos framework functions are atomic. The transaction is all‑or‑nothing.

### Q7 — Handle String Validation Completeness
**Answer:** Sound.
**Reasoning:** Validation checks each byte to be in `a-z` (0x61–0x7A), `0-9` (0x30–0x39) or `-` (0x2D). Multi-byte UTF‑8 characters (e.g., Cyrillic 'а') have leading bytes outside this range and are rejected. Uppercase letters also fail. Homoglyph attacks are prevented at the protocol level.

### Q8 — Flash Loan Reentrancy Comprehensive Coverage
**Answer:** Sound.
**Reasoning:** All state‑mutating AMM functions (`add_liquidity_internal`, `remove_liquidity_internal`, `swap_exact_apt_in`, `swap_exact_token_in`, `flash_borrow`, `extract_fees_for_claim`) are gated by `pool.locked == false`. The lock is set in `flash_borrow` and released in `flash_repay`. No mutable entry point is missed. The `create_pool_atomic` function operates on a new pool, not an existing one, so it needs no gate.

### Q9 — Voting Power Source Authentication
**Answer:** Acceptable trade-off (with minor concern).
**Reasoning:** `voter_history::record_reward_received` is called solely from `lp_staking::claim_internal`, authenticated by the package signer. The `derive_pkg_signer` function is accessible to three other modules (`factory`, `profile`, `amm`) that do not call it. While a bug in any of those could theoretically inflate voting power, the current implementation restricts the call path correctly. See Finding 5 for a suggestion to tighten this further.

### Q10 — Anything Else
Beyond the findings above, the overall architecture appears well-considered. One additional observation: the emission accumulator in `update_pool` (as noted in Finding 3) could overflow after extreme elapsed time; recommend a sanity cap. The rest of the code adheres to best practices for Move resource management and access control.

**Final Recommendation:** Fix the HIGH severity issues (Finding 1 and 2) and re-verify compilation. After remediation, the protocol will be ready for mainnet deployment with a 🟢 GREEN status.
