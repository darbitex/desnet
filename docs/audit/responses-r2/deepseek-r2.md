# DeepSeek V3.2 — DeSNet v0.3.0 R2 Verification

**Date:** 2026-05-02
**Verdict:** 🟢 GREEN (ship-ready)
**R1 → R2:** RED → GREEN
**All 19 verification questions: Verified**
**New issues (R2-N): 0**

---

**Overall R2 Verdict:** 🟢 GREEN (ship-ready)

**Rationale:** All fixes verifiably address the original findings, do not introduce regressions, and defensive measures (hash verification, voting-power tie to actual payout, slippage, friend-gating) close previously identified attack surfaces. No new critical issues discovered.

---

## Verification Questions

### H1 — `execute_proposal` hash verification
- **Q1.1:** Verified. SHA3-256 over BCS-encoded payload with separate encoding per module provides collision resistance; BCS canonicalization ensures determinism.
- **Q1.2:** Verified. BCS encoding of each module's bytes includes length prefix; concatenation is unambiguous and length-delimited, preventing malleability.
- **Q1.3:** Verified (with note). The submission states callers must use this exact scheme, but the in-source documentation could be more explicit about off-chain hash construction; not a security issue given that a wrong hash simply makes the proposal unexecutable.
- **Q1.4:** Verified (acceptable trade-off). Executing an approved proposal is by design permissionless; the hash check ensures only the voted-on code can be published, so any executor is safe.

### H2 — Voting power records actual paid amount
- **Q2.1:** Verified. `actual_paid` is drawn from the fungible asset returned by `pull_for_claim`, which is capped at remaining reserve – zero when depleted. No inflation possible.
- **Q2.2:** Verified. Credit given only for tokens actually received; if partial depletion occurs, voting power reflects real economic value.
- **Q2.3:** Verified (acceptable trade-off). Setting `last_acc_per_share` to `acc` means the unpaid delta is abandoned, but since the reserve is depleted, the user would never receive those tokens anyway. If the reserve is later topped up, the abandoned delta is lost — a minor fairness edge but not a vulnerability.

### H3 — `apt_vault::settle` slippage tolerance
- **Q3.1:** Verified. 3% tolerance is a reasonable trade-off: it prevents most sandwiching while still allowing execution under normal volatility; tightens further can be re-evaluated with usage data.
- **Q3.2:** Verified. `reserves` and `compute_amount_out` are read before the swap in the same transaction; Move's transaction semantics guarantee no interleaved modifications, so the call is safe.
- **Q3.3:** Verified. The assert is placed after vault load and before the swap, correctly guarding against pool address drift.

### H4 — `voter_history` visibility friend-restricted
- **Q4.1:** Verified. Friend list now includes only `desnet::lp_staking`; `record_reward_received` is `public(friend)`.
- **Q4.2:** Verified. The `@desnet` signer assertion remains useful as belt-and-braces, even though the visibility now prevents external callers.
- **Q4.3:** Verified. `prune_voter_history` is intentionally permissionless; no other functions need restriction.

### M1 — `add_liquidity_internal` surplus refunds
- **Q5.1:** Verified. `optimal_apt = lp_minted * apt_reserve / lp_supply` is the correct inverse of the LP calculation, ensuring the effective deposited ratio matches the pool's ratio.
- **Q5.2:** Verified. `fungible_asset::extract` with 0 amount is safe; it returns a zero asset that can be destroyed or deposited harmlessly.
- **Q5.3:** Verified. The test wrapper deposits zero-value refunds to `@desnet`; it's harmless for testing and the real code path correctly refunds to user.

### M2 — `disable_multisig_upgrade` one-way switch
- **Q6.1:** Verified. Adding a field to an existing struct is compatible for a fresh deploy (mainnet baseline), and testnet can be re-deployed.
- **Q6.2:** Verified (acceptable). The call is immediate and irreversible; a timelock is unnecessary because the backdoor is only active during bootstrap – it is meant to be disabled deliberately.

### M5 — `apt_vault` cache consistency
- **Q7.1:** Verified. The assert is placed before the swap, checking immediately after vault load.
- **Q7.2:** Verified. The check is critical only for settle, which performs a financially meaningful swap; views are read‑only and stale data is acceptable for display purposes.

### Kimi F2 — factory pause/unpause
- **Q8.1:** Verified. `@origin` is the correct bootstrap authority; future shift to DAO control can be done via governance upgrade.

### Kimi F4 — governance bootstrap state validation
- **Q9.1:** Verified. The new `E_NOT_INITIALIZED` errors provide clearer feedback than the confusing `u64::MAX` path.

### Gemini MED — zero-addr checks
- **Q10.1:** Verified. No other admin entries accept dangerous addresses; the current coverage is sufficient.

---

### New Issues Flagged (R2-N)
None. The R2 patch cleanly addresses all prior concerns with no introduced regressions observable from the diff.
