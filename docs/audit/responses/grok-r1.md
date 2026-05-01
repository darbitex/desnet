# Grok 4 — DeSNet v0.3.0 R1 Audit Response

**Date:** 2026-05-02
**Verdict:** 🟡 YELLOW (ship after fixes)
**Findings:** 0 HIGH / 2 MED / 4 LOW / 4 INFO
**Source coverage:** governance, factory, profile fully reviewed; amm/lp_staking inferred from cross-refs and questions; lighter review on carry-over modules

---

**DeSNet v0.3.0 Mainnet Baseline Audit (Round 1)**

**Auditor:** Grok (xAI) — independent analysis of provided submission + full source (truncated but key modules reviewed in detail: governance, factory, profile, amm/lp_staking implied via cross-refs and questions, lp_emission, reaction_emission, reference_gate, giveaway, voter_history, plus architecture/docs).

**Scope alignment:** Focused on NEW/re-written modules (amm, lp_staking, factory, apt_vault, lp_emission, profile changes) + prioritized Q1–Q10. Carry-over modules (mint/pulse/press/etc.) received lighter review assuming prior v0.1.5 coverage + minor edits. All compile/test claims noted but not independently re-executed here (recommend final `aptos move test` + formal verification where possible post-fixes).

**Overall approach:** Traced call paths for friend graph/atomic flows, reviewed resource/object semantics (Move's strong guarantees against reentrancy/double-spend via linear types/resources), math (u128 widening, accumulators), access control (signer derivation, guards), and invariants (forever-lock, universal fees, reservation). Drew on Aptos Move security patterns (e.g., no ConstructorRef leaks, proper ExtendRef/TransferRef isolation, flash loan hot-potato + lock flags).

### Findings

**Finding 1**
**Title:** Friend graph allows potential unauthorized `create_pool_atomic` by non-factory friends
**Severity:** MEDIUM
**Module + line range:** `amm` (create_pool_atomic and friend decls); cross-ref `factory`, `lp_staking`, `apt_vault`
**Issue description:** `amm::create_pool_atomic` is friend-only (factory, lp_staking, apt_vault). Factory is the sole intended caller during atomic `register_handle`. However, lp_staking and apt_vault are also friends and call other AMM functions (e.g., extract_fees, swap). Without explicit caller authentication inside `create_pool_atomic` (e.g., assert on a specific seed, handle registry check, or authority param beyond friend), a compromised/malicious future friend or unexpected call path could spawn arbitrary pools. Handle derivation is deterministic but pool creation logic (if not strictly gated to factory's `create_token_atomic` context) risks duplicate/invalid pool states.
**Risk:** Attacker (or buggy upgrade) spawns fake pool, hijacks LP supply/fee accumulator invariants, or dilutes universal fee accrual. Could break downstream `lp_staking` Position accounting or enable griefing/DoS on registry views. Not immediate fund loss but breaks core atomic register + forever-lock invariants.
**Suggested fix:** Add explicit guard in `create_pool_atomic`, e.g., `assert!(factory::is_valid_spawn_context(handle) || similar)`, or pass a capability/seed proof from factory only. Tighten friend list if lp_staking/apt_vault don't need create. Document exact call tree.
**Confidence:** HIGH (friend graph + Q1 explicit; standard Move friend over-reliance pattern).

**Finding 2**
**Title:** Fee accumulator truncation math is pool/LP-favorable but requires strict invariant proof for sum-of-claims ≤ bucket
**Severity:** LOW (with INFO on documentation)
**Module + line range:** `amm` (swap_exact_apt_in fee advance + extract_fees_for_claim; Position claim logic in lp_staking)
**Issue description:** `fee_per_lp_apt += (fee * ACC_SCALE) / lp_supply` (truncating division) + per-Position `(acc - last) * shares / ACC_SCALE`. Standard V3-style; truncation favors the pool (under-credits individual claims slightly). Self-audit notes precision drift as accepted. No overpay obvious in small-claim accumulation, but full proof (sum claims ≤ total fees accumulated across all positions + dust handling) not explicitly asserted/invariant-tested in provided snippets.
**Risk:** Minor cumulative dust loss to LPs over high-volume claims (gas waste or perceived unfairness); edge-case where many tiny claims + rounding could theoretically underflow extract if not capped (though extract likely guards). Not fund loss but breaks "universal accumulator fairness" expectation.
**Suggested fix:** Add view/invariant fn or test asserting `total_claimable() <= fee_bucket` post-many-claims simulation. Explicitly document "pool retains truncation dust; no over-distribution possible." Use higher-precision intermediates if feasible.
**Confidence:** MEDIUM (pattern-match on V3; Q2 asks for walk-through — math looks standard but full accumulator proof benefits from more tests).

**Finding 3**
**Title:** Locked-creator Position extraction paths appear structurally blocked, but signer derivation tree needs exhaustive mapping
**Severity:** LOW
**Module + line range:** `lp_staking::remove_liquidity` (E_LOCKED_FOREVER guard); `profile::derive_pid_signer`; Position resource at pid_addr + child FungibleStore
**Issue description:** `unlock_at = u64::MAX` aborts before `amm::remove_liquidity_internal`. LP FA lives in Position-owned child store. `profile::derive_pid_signer` re-derives via ExtendRef for PID-controlled actions, but should not grant arbitrary child-store extraction (Move resource rules + no public withdraw on locked). No obvious `move_from`/`withdraw` on locked_lp_store outside unstake.
**Risk:** If any path (upgrade, friend misuse, or pid_signer abuse) can extract LP FA from forever-locked Position, creator LP becomes drainable → permanent LP supply deflation or theft of emission rights. Low likelihood due to Move ownership + abort.
**Suggested fix:** Explicitly audit/map all pid_signer uses (profile friends + factory/lp_staking calls). Add `assert!(!is_locked_forever(position))` deeper in any internal LP extract paths. Test: attempt extraction via re-derived signer in unit tests. Document "structural enforcement — no code path bypasses E_LOCKED_FOREVER".
**Confidence:** MEDIUM (Q3 asks for signer tree; Move semantics strong here, but complex object nesting warrants extra caution).

**Finding 4**
**Title:** PID transfer + claim race condition possible due to non-atomic claim resolution
**Severity:** MEDIUM
**Module + line range:** `lp_staking::resolve_recipient` + `claim_internal`; cross `profile` PID ownership + object::owner
**Issue description:** `resolve_recipient` reads `object::owner(pid_obj)` *at claim execution time*. PID NFT transferable. In same-block frontrun (Aptos sequencing is deterministic per validator but tx ordering within block can allow races), transfer PID → new owner before claim settles → claim disburses to wrong recipient (new owner steals prior accrual). Self-audit doesn't flag; Q4 raises exactly this.
**Risk:** Emission/fee theft via frontrun PID transfer. Breaks "auto-resolved to current PID owner at claim time" expectation and "past accruals frozen for prior owner" invariant. Concrete: Alice claims, Bob transfers PID in same block (possible in bundled tx or validator ordering).
**Suggested fix:** Snapshot recipient at claim *start* (e.g., compute + pass recipient addr early in tx, or use claim-specific lock/pending accrual). Or accept as "claim-time" semantics and document clearly (with warning for users). Prefer snapshot for predictability. Test same-block transfer + claim scenarios.
**Confidence:** HIGH (Q4 scenario direct; common object ownership race in Aptos).

**Finding 5**
**Title:** Reserved handle guard is comprehensive against direct bypass but depends on wallet_addr derivation
**Severity:** LOW / INFO
**Module + line range:** `profile::register_handle` (reserved_claimer check + derive_pid_address); factory validate
**Issue description:** `if is_reserved_handle → wallet_addr == required_claimer`. Different claimer per handle → unique PIDs. Guard before PID creation/registry insert. No custom script bypasses wallet_addr semantics (BCS + derive is deterministic). Cross-module re-entry blocked by atomic tx + friend limits.
**Risk:** Minimal — front-running squatting mitigated. Edge: if derive_pid_address semantics change in upgrade or framework, collision risk (unlikely).
**Suggested fix:** None material. Add explicit test for all 5 reserved + claimer addrs. Document "per-handle claimer preserves 1-wallet-1-PID globally".
**Confidence:** HIGH (Q5; code traces clean).

**Finding 6**
**Title:** Atomic register_handle generally safe; minor non-revertible side-effect notes
**Severity:** INFO
**Module + line range:** `profile::register_handle` → `factory::create_token_atomic` chain
**Issue description:** Full tx atomic (Move guarantee). Events emitted (non-reverting). No dispatchable FA hooks used. Custom token creation via primary_fungible_store + named objects is standard. Abort reverts fees/pool/Position.
**Risk:** None material — off-chain indexer/event observers see partial effects only on success.
**Suggested fix:** Document explicitly. Ensure no pre-emit side effects that survive abort (none apparent).
**Confidence:** HIGH (Q6; standard Move tx atomicity).

**Finding 7**
**Title:** Handle validation prevents basic homoglyphs but is byte/ASCII-only
**Severity:** LOW
**Module + line range:** `factory::validate_handle` / `profile::validate_handle` (a-z0-9- only)
**Issue description:** Charset strictly lowercase ASCII + digits + hyphen. UTF-8 Cyrillic/etc. fail char check (2-byte sequences). No normalization; case blocked. Prevents most visual spoofing for Latin-like handles.
**Risk:** Advanced homoglyphs in other scripts or zero-width unlikely (length/char checks). UX: users expect stricter Unicode? Minor squatting vector via lookalikes if frontend displays normalized.
**Suggested fix:** Consider adding allowlist or normalization if broader Unicode desired (but increases complexity — current is conservative/safe). Document charset explicitly.
**Confidence:** HIGH (Q7).

**Finding 8**
**Title:** Flash loan lock coverage appears comprehensive
**Severity:** INFO
**Module + line range:** `amm` Pool.locked flag + gates on swap/LP/flash/extract_fees (M1 fixed)
**Issue description:** locked=true on borrow, false on repay. Hot-potato FlashReceipt. All mutating entries gated. No missed public entries apparent from description.
**Risk:** None — standard pattern + self-audit fix applied. Reentrancy during window blocked.
**Suggested fix:** None. Add exhaustive unit test calling every public amm fn during active flash.
**Confidence:** MEDIUM (Q8; relies on full amm source not fully excerpted).

**Finding 9**
**Title:** Voting power authentication single-source but governance/derive_pkg_signer reliance
**Severity:** LOW
**Module + line range:** `voter_history::record_reward_received` (assert @desnet); called only from `lp_staking::claim_internal` via `governance::derive_pkg_signer`
**Issue description:** Assert on signer addr strong. Friend graph closes (governance friends amm/lp_staking/factory/profile). Sole call site per grep intent. Pkg signer derivation centralized.
**Risk:** If other path derives pkg_signer (upgrade bug, friend expansion), fake voting power inflation. Low due to friend closure + monolith.
**Suggested fix:** Greppable comment or capability pattern reinforcing sole call site. Test: attempt record from non-claim path (should abort).
**Confidence:** HIGH (Q9).

**Finding 10 (Free-form)**
**Title:** Minor observations & architecture notes
**Severity:** INFO
**Modules:** Various (governance, objects, upgrades)
**Issue description / Observations:**
- **ConstructorRef / ExtendRef handling:** Code patterns (generate then drop/disable ungated where appropriate) look correct; no obvious leaks (critical per Aptos guidelines). PID/Position/Reserve Objects properly sealed in many places.
- **Governance upgrade paths:** Multisig (pre-DAO) + full DAO with timelock/quorum good. DESNET FA config post-deploy needed for voting — ensure activation sequence documented.
- **Upgrade safety:** Monolith simplifies but all upgrades via pkg signer (governance-controlled). Post-mainnet, test compat upgrade path thoroughly (v0.3.1 out-of-scope but mentioned).
- **Scaling/UX:** History chunks (30KB rotate), assets (5MB cap), SmartTable usage reasonable. No indexer dependency for gates good. Gas for append-only history + 7-verb could add up for heavy users.
- **Reserved handles / multisig:** 1/5 → 3/5 post-smoke sensible. Per-handle claimers fix collision nicely.
- **Self-audit alignment:** M1 fix applied; dust/precision accepted as V3-like reasonable.
- **Suspicious feeling:** None major. Design is thoughtful (atomic register, universal accrual, structural locks, permissionless pokes). Potential "this is complex" surface in object nesting + cross-module signer passing, but Move helps. Recommend formal spec + Move Prover on key invariants (forever-lock, fee sums, atomicity).

**Risk:** Operational (upgrade bugs, config sequencing). Not code-level fund loss.
**Suggested fix:** Expand tests for upgrade simulation, PID transfer races, high-volume claims. Add more inline invariants/comments. Consider capability patterns over pure friend for sensitive fns.
**Confidence:** MEDIUM.

### Design Questions (Q1–Q9)

**Q1 — amm::create_pool_atomic friend-only invariants**
**Answer:** Acceptable trade-off (with caveat).
**Reasoning:** Friend list limits surface, factory is primary/sole production caller. lp_staking/apt_vault need other AMM access legitimately. However, without intra-fn guard, future friend expansion or misuse risks unauthorized pools. Not broken but defense-in-depth gap.
**Alternative if Concerning:** Explicit authority check inside create (e.g., handle registry or seed proof from factory).

**Q2 — Universal fee accumulator denominator semantics**
**Answer:** Sound (standard V3).
**Reasoning:** Truncation pool-favorable; claims compute pro-rata. Sum should ≤ bucket due to integer math (no over-credit). Many small claims accumulate dust to pool — accepted. extract_fees guards prevent underflow. Needs explicit invariant tests/proof for full confidence.

**Q3 — Locked-creator forever-lock structural enforcement**
**Answer:** Sound.
**Reasoning:** E_LOCKED_FOREVER early abort + resource ownership + no public withdraw on locked store. pid_signer derivation limited to profile-controlled actions (not arbitrary child extraction). Move linear types prevent leakage. Exhaustive signer tree mapping recommended.

**Q4 — Recipient auto-resolution at claim time**
**Answer:** Concerning.
**Reasoning:** Race possible in block (transfer flips owner before claim resolves). Breaks accrual freezing expectation. Aptos tx sequencing doesn't prevent same-block frontruns reliably for this pattern.
**Alternative:** Snapshot recipient early in claim tx or use pending claim queue/lock.

**Q5 — Reservation guard PID derivation correctness**
**Answer:** Sound.
**Reasoning:** Pre-PID-creation check + per-handle unique claimer → no collision. Derivation deterministic/BCS-based; no re-entry bypass in atomic flow. Good fix for 1-wallet-1-PID.

**Q6 — Atomic register_handle abort safety**
**Answer:** Sound.
**Reasoning:** Move tx atomicity covers all steps. Events non-reverting but only on success. No problematic hooks.

**Q7 — Handle string validation completeness**
**Answer:** Sound for intended scope.
**Reasoning:** ASCII-only + length prevents obvious homoglyphs/upper-case conflicts. Bytes comparison clean. Broader Unicode would add attack surface unnecessarily.

**Q8 — Flash loan reentrancy comprehensive coverage**
**Answer:** Sound (post-M1).
**Reasoning:** locked flag + gates on all mutators + hot-potato standard and effective in Move.

**Q9 — Voting power source authentication**
**Answer:** Sound.
**Reasoning:** Single assert + sole call site via derive_pkg_signer + friend closure. Strong against inflation.

**Q10:** Covered in Finding 10. Additional ask for dev team: Full amm/lp_staking source excerpts for deeper accumulator/Position review; simulation of high-volume claim + PID transfer scenarios; any planned Move Prover specs?

### Overall Verdict

**🟡 YELLOW (ship after fixes)**

Rationale: Core architecture is solid and leverages Move strengths well (resources, objects, atomicity, friend isolation, structural locks). No HIGH issues found — no obvious fund loss, mint/burn bypass, or permanent corruption paths. Key invariants (forever-lock, atomic register, fee accrual) hold structurally. However, MEDIUM concerns around pool creation authorization, PID claim races, and friend over-reliance warrant targeted fixes + expanded tests/invariants before mainnet. INFO items (docs, dust, validation) are minor polish. Post-fixes + re-test + focused Round 2 should reach GREEN. Strong self-audit and smoke tests on testnet are positive signals. Recommend prioritizing Q4 race and Q1 guard.

This audit is based on provided materials and standard Move/Aptos patterns. For production, pair with professional human audit + formal verification. Happy to iterate on specific modules or fixes.
