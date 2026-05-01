# Gemini 3 Pro — DeSNet v0.3.0 R2 Verification

**Date:** 2026-05-02
**Verdict:** 🟡 YELLOW (1 architectural HIGH on factory pause auth post-DAO transition)
**R1 → R2:** YELLOW → YELLOW (different reason — R2 introduces this architectural concern)

Overall, the architecture presents a cohesive, tightly coupled monolith design. The Opsi 1 ExtendRef patterns, the deterministic address derivation, and the DAO upgrade mechanics reflect a high level of Aptos-specific maturity. The fixes implemented from Round 1 (e.g., the `compute_upgrade_digest` and the Uniswap V2-style refund pattern in `amm.move`) are sound.

However, there is one major architectural inconsistency regarding the DAO transition, alongside a few medium-level observations.

---

## High Severity / Architectural Findings

### 1. Deadlock/Centralization Risk in `factory::set_paused` Post-DAO Transition

- **Location:** `factory.move` (Lines 294-297)
- **Description:** You implemented an irreversible `disable_multisig_upgrade` in `governance.move` to allow the protocol to formally transition power from the deployer multisig (`@origin`) to the DAO. However, in `factory.move`, the `set_paused` function hardcodes the access control to `@origin` (`assert!(signer::address_of(admin) == @origin, E_NOT_ADMIN);`).
- **Impact:** If the protocol fully transitions to the DAO and the `@origin` multisig is dissolved or its keys are rotated/lost, the ability to pause or unpause the factory is permanently bricked. Conversely, if `@origin` remains active, they retain a centralized kill-switch over token creation forever, bypassing the DAO entirely.
- **Recommendation:** Align the factory's admin logic with `profile.move`. Instead of hardcoding `@origin`, read a centralized `admin` state that can be rotated to the DAO's resource account, or allow the governance package signer to execute the pause.

---

## Medium Severity / Logic Findings

### 1. `amm.move` is Truncated

- **Location:** `amm.move` (Line 249)
- **Description:** The provided source code for `amm.move` cuts off abruptly at the signature for `remove_liquidity_internal`.
- **Impact:** The flash loan mechanics (`flash_borrow`, `flash_repay`), swap logic, and the full implementation of the LP burning math cannot be verified in this pass.

### 2. Rigid APT FA Metadata Assumption

- **Location:** `profile.move` (Line 131 & 339) and `amm.move` (Line 38)
- **Description:** The protocol hardcodes the `APT_FA_METADATA` as `@0xa`. While standard native AptosCoin (0x1::aptos_coin::AptosCoin) is indeed mapped to a paired Fungible Asset at `0xa` in modern Aptos framework versions, hardcoding this limits testability on custom localnets if the framework deployment differs, and it assumes the user is paying with the FA representation rather than the native `Coin<AptosCoin>`.
- **Recommendation:** Ensure your frontend and routing layers strictly wrap native APT to the `0xa` FA before hitting these endpoints, or include a fallback/wrapper utility within the contract.

---

## Informational Observations & Commendations

### 1. `derive_pkg_signer` Centralized Trust (Governance)

The use of `derive_pkg_signer()` as a `public(friend)` function is clean and prevents `SignerCapability` sprawl. However, it means every `friend` module (`factory`, `profile`, `amm`, `lp_staking`) has absolute, unfettered god-mode access to the `@desnet` resource account. If any of these modules suffer an arbitrary execution bug, the entire protocol state is compromised. Ensure strict boundaries in future upgrades for these sibling modules.

### 2. AMM Donation Attack Mitigated (R1 Fix)

The update to `add_liquidity_internal` that calculates the optimal LP pair and refunds the surplus directly to the caller is excellent. This effectively patches the classic AMM vulnerability where naive callers over-fund one side of a pair, unintentionally gifting value to existing LPs.

### 3. Execution Hash Verification (R1 Fix)

The `compute_upgrade_digest` implementation in `governance.move` correctly forces the executor to submit the exact byte payload that the DAO voted on. The manual loop hashing `bcs(metadata)` and `code_bytes` chunks is secure and deterministic.

### 4. Opsi 1 Capability Hierarchy

The segregation of the `TransferVault` from the standard `Profile` struct is a great design choice. Allowing the hot wallet (controller) to manage application signers while strictly isolating the NFT transfer capability to the cold wallet (owner) creates a robust security layer for users.
