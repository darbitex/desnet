# Qwen 3 Max — DeSNet v0.3.0 R2 Verification

**Date:** 2026-05-02
**Verdict:** 🟢 GREEN (ship-ready)
**R1 → R2:** GREEN → GREEN
**All 19 verification questions: Verified**
**New issues (R2-N): 2 (both Info, non-blocking)**

---

### Verification Questions (Q1.1 – Q10.1)

**Q1.1:** Verified. SHA3-256 is cryptographically collision-resistant, and the concatenation of BCS-encoded chunks guarantees a deterministic, unambiguous byte stream resistant to length-extension or prefix-collision attacks.

**Q1.2:** Verified. BCS serialization of `vector<u8>` always prepends a length field, ensuring canonical encoding. Concatenating length-prefixed chunks prevents structural ambiguity between different code/metadata combinations.

**Q1.3:** Verified. The doc comment on `execute_proposal` explicitly defines the exact hashing scheme and mandates its use by off-chain `propose_upgrade` callers. It is clear and directly actionable for tooling/frontend developers.

**Q1.4:** Verified. Permissionless execution is intentional and aligns with standard DAO timelock designs (e.g., OpenZeppelin Governor) to guarantee liveness. The hash verification and timelock prevent mismatched or malicious execution, making caller restriction unnecessary.

**Q2.1:** Verified. Recording `actual_paid` instead of `pending_emission` strictly ties voting power to tokens that actually left the reserve. The `actual_paid > 0` guard prevents zero-amount or partial-fill claims from artificially inflating the voter registry.

**Q2.2:** Verified. Acceptable trade-off. Voting power must represent actual economic stake received; crediting unfulfilled accumulator claims would enable Sybil/inflation vectors. The protocol correctly prioritizes verifiable token transfers over theoretical accrual.

**Q2.3:** Verified. Acceptable v1 trade-off. Tracking "unclaimed debt" across reserve depletion/top-ups introduces complex accounting and potential griefing vectors. Advancing the snapshot aligns with standard MasterChef/V3 yield-farming practices where post-depletion top-ups serve future claims only.

**Q3.1:** Verified. 300 bps (3%) is a standard industry bound for permissionless vault settlements. It effectively caps single-tx MEV extraction while providing enough tolerance for normal pool volatility and dust accumulation to prevent constant aborts.

**Q3.2:** Verified. Move's atomic transaction execution guarantees zero interleaved state changes. `expected_out` and the subsequent `swap_exact_apt_in` occur within the same execution context, so the pre-computed `min_out` safely applies to the actual state.

**Q3.3:** Verified. Correctly positioned immediately after loading the vault resource and before any AMM interactions. This ensures fast-fail validation and prevents accidental execution against a stale or mismatched pool address during settlement.

**Q4.1:** Verified. The `public(friend)` visibility modifier combined with the explicit `friend desnet::lp_staking;` declaration restricts invocation solely to `lp_staking`. No other module in the monolith holds friend access for this function.

**Q4.2:** Verified. Retains strong value as defense-in-depth. While `public(friend)` enforces compile-time boundaries, the runtime `signer.addr == @desnet` assertion protects against future refactors, accidental visibility changes, or hypothetical compiler edge cases at negligible gas cost.

**Q4.3:** Verified. Function visibility is correctly scoped. `init_registry` remains friend-only, `prune_voter_history` is intentionally permissionless for storage management, and view functions are public read-only. No additional restrictions are required.

**Q5.1:** Verified. The formula correctly implements standard constant-product optimal liquidity math. It reverses the LP minting equation to derive the exact reserve contribution required for the minted shares, ensuring surplus extraction is mathematically precise.

**Q5.2:** Verified. The fix explicitly guards against zero-extraction by using a conditional branch that calls `fungible_asset::zero()` when surplus is `0`, avoiding any potential framework panic or unnecessary gas consumption on zero-amount extracts.

**Q5.3:** Verified. Test-only helpers are exempt from production economic strictness. Depositing test refunds to `@desnet` or destroying zero amounts is standard practice for Aptos test scaffolds and poses zero production risk.

**Q6.1:** Verified. Adding a trailing `bool` field to `GovernanceState` is permissible under Aptos `compatible` upgrade policy for a fresh mainnet deployment. Testnet layout divergence is acceptable as stated, given its throwaway nature.

**Q6.2:** Verified. Irreversible-on-call is deliberate and appropriate for bootstrap backdoor renouncement. The multisig (`@origin`) is already trusted at this stage, and the emitted `MultisigUpgradeDisabled` event provides sufficient on-chain transparency without adding unnecessary timelock friction.

**Q7.1:** Verified. Correctly positioned immediately after loading the vault resource and before any AMM interactions, ensuring deterministic routing and fast-fail safety before economic state mutation occurs.

**Q7.2:** Verified. Correctly scoped to the sole state-mutating path (`settle`) that interacts with the AMM. Applying it to views would unnecessarily break UI rendering, and other entry points do not require pool address validation.

**Q8.1:** Verified. `@origin` aligns with the documented bootstrap governance phase. Transitioning this control to the DAO is already outlined in the roadmap for post-PMF, making the current implementation appropriate for the v0.3.0 baseline.

**Q9.1:** Verified. Substantially improves proposer UX by replacing a misleading `E_INSUFFICIENT_VOTING_POWER` (caused by the `u64::MAX` sentinel) with a clear `E_NOT_INITIALIZED` abort, accurately signaling unconfigured DAO parameters.

**Q10.1:** Verified. Critical admin setters (`update_fee_receiver`, `rotate_admin`) are now properly guarded. `governance::update_desnet_fa_metadata` could also benefit from a `@0x0` guard for consistency, but it is non-critical since `voting_power` already handles the unconfigured sentinel safely by returning `0`.

---

### New Issues Flagged (R2)

**R2-N1 — Info: `LiquidityAdded` Event Semantics Shift**
**Module:** `amm.move`
**Issue:** The `LiquidityAdded` event now emits `apt_in` and `token_in` net of refunded surplus (`apt_amount - apt_surplus`). While this accurately reflects pool economics, indexers/frontend parsers relying on the previous gross-deposit semantics will need updating to avoid double-counting user outflows.
**Risk:** None on-chain. Purely an off-chain indexing alignment requirement.
**Confidence:** HIGH

**R2-N2 — Info: Test Wrapper Gas Leak to `@desnet`**
**Module:** `amm.move` (test-only)
**Issue:** `add_liquidity_internal_for_test` deposits positive refunds to `@desnet` instead of returning them to the test caller or burning them. This is safe in a sandbox but technically leaks test FA balance to the protocol address.
**Risk:** None. Test-only behavior. Suggest changing to `fungible_asset::destroy()` for cleaner test isolation.
**Confidence:** HIGH

---

### Overall R2 Verdict

🟢 **GREEN** (Ship-ready)

**Rationale:**
All R1 findings have been accurately and comprehensively addressed. The fixes introduce no functional regressions, preserve atomic invariants, and align with industry-standard patterns for DAO timelocks, AMM liquidity math, and yield-farming accounting. The added defense-in-depth measures (hash verification, slippage tolerance, friend-restricted voting power, zero-address guards) strengthen the protocol's security posture without compromising usability or liveness. Minor indexer alignment (R2-N1) and test-sandbox cleanup (R2-N2) are non-blocking. The v0.3.0-r2 baseline is production-ready for mainnet deployment.
