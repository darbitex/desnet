# DeSNet v0.3.2 Chain Bytecode Bundle Audit — Kimi K2.6

**Verdict (raw):** 🔴 (Multiple "Critical" findings, but several are false-positive vs submission doc)
**Date:** 2026-05-02
**Method:** ABI summaries + MASM disassembly across all 18 modules

---

## Executive Summary

After reviewing all 18 modules (~72KB of bytecode), I've identified several critical and high-severity issues spanning governance manipulation, access control bypasses, economic attacks, and denial-of-service vectors.

[NOTE: Several of Kimi's "Critical" findings flag intentionally neutered setters — Kimi did not cross-reference submission doc explaining F6b/F10 design. See R5-VERIFICATION.md triage for FP analysis.]

## 🔴 Critical Severity (per Kimi's classification)

### 1. Governance: Unimplemented Admin Functions with Hardcoded Abort
`update_desnet_fa_metadata` and `update_total_30d_emission` unconditionally abort with code 22. Kimi reads this as "intentionally disabled backdoors or incomplete implementations".

### 2. AMM: Pool Locking Logic Inconsistency in Flash Loans
Claim: if `flash_repay` aborts on invalid receipt/wrong pool, pool stays locked → permanent DoS.

### 3. Profile: Missing Authorization in `update_fee_receiver`
Same pattern as #1 — pops signer, loads state, aborts 19.

## 🟠 High Severity

### 4. Governance: Single Address Multisig with No Rotation
@origin hardcoded; no enable/rotate after disable_multisig_upgrade.

### 5. Factory: Token Minting Authority Centralization
1B supply hardcoded (5M+5M+90M); no programmatic verification.

### 6. LP Staking: Reward Calculation Overflow Risk
`(time_delta * rate_per_sec * 1e18) / lp_supply` — u128 intermediate may overflow at extreme parameters.

### 7. Reaction Emission: Unbounded Emission with No Supply Cap Check
`emission = press_order * 1e8` per reaction; no per-day/per-user caps; sybil could drain.

## 🟡 Medium

### 8. Handle Fee Vault: Settlement Uses Hardcoded "desnet" Handle
Low liquidity pools cause unfavorable swaps. (overlaps F9 sandwich)

### 9. Assets: No Chunk Size Enforcement During Finalization
`finalize` doesn't verify chunks sum to claimed `total_size`.

### 10. Profile: Reserved Handle Claimer Hardcoded Privileged Addresses
5 reserved handles bound to fixed addresses → namespace oligopoly.

## 🟢 Low / Code Quality

### 11. AMM: `read_warning` Contains Unprofessional Message
"AI-audited only" — misleading.

### 12. Multiple Modules: Inconsistent Error Codes
No central registry.

### 13. Voter History: Pruning is Permissionless
Anyone can prune anyone's history (low impact since bounded change).

## Architectural

### 14. Circular Dependencies and Tight Coupling
Factory is central hub for amm/apt_vault/reaction/lp_emission/lp_staking — malicious factory upgrade compromises ecosystem.

### 15. No Emergency Pause on Core AMM
Factory has `set_paused`, AMM doesn't.

## Recommendations

| Priority | Action |
|---|---|
| P0 | Implement or remove stub functions in governance (30-31) and profile (28) |
| P0 | Add pool unlock guarantee in amm::flash_repay |
| P1 | Add overflow checks in lp_staking::update_pool |
| P1 | Implement daily emission caps in reaction_emission |
| P1 | Add total size verification in assets::finalize |
| P2 | Create proper error code registry |
| P2 | Add emergency pause to amm |
| P2 | Document hardcoded privileged addresses and custody procedures |

## Verification Notes

The bytecode hashes match the on-chain deployment at @desnet upgrade_number 4. The most concerning finding is the pattern of functions that load state, pop the signer without authorization, then unconditionally abort.
