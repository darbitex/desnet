# Gemini 3 Pro — DeSNet v0.3.2 R5 Verification

**Verdict:** 🔴 **RED** (3 HIGH findings, 0 MED, 0 LOW)

The F7, F8, and F9 implementations introduce critical vulnerabilities ranging from DAO disenfranchisement to MEV value extraction. It is highly recommended to address these before considering the v0.3.2 upgrade stable.

---

## Detailed Findings

### 1. [HIGH] F9: Zero-Slippage Delegate Burn Allows MEV Extraction

**Module:** `handle_fee_vault.move`

**Vulnerability:** The `settle()` function converts the vault's accumulated APT (90% of the balance) into DESNET using the AMM, but hardcodes `min_out` to `0`.
```move
let desnet_fa = amm::swap_exact_apt_in(DESNET_HANDLE, apt_for_burn_fa, 0);
```

**Impact:** Because `settle()` is permissionless, an MEV searcher or malicious actor can front-run the transaction, heavily skewing the DESNET/APT AMM pool. They can then execute `settle()` (causing the protocol to buy DESNET at an extraordinarily inflated price) and back-run the transaction to extract the protocol's APT. The vault will burn a negligible amount of DESNET, effectively leaking 90% of the protocol's handle fee revenue to arbitrageurs.

**Recommendation:** Implement a slippage parameter in `settle()`, or rely on a time-weighted average price (TWAP) oracle to enforce a minimum expected output.

### 2. [HIGH] F8: Permissionless DAO Staging Enables Complete DoS / Griefing

**Module:** `governance.move`

**Vulnerability:** `dao_stage_upgrade_chunk` allows *any* caller (`_caller: &signer`) to stage code chunks once a proposal is ratified. The internal function `stage_chunks_into_staging` appends the provided bytes to the `UpgradeStaging` resource.

**Impact:** A malicious user can call `dao_stage_upgrade_chunk` with garbage data. Because the data is appended, this permanently corrupts the staged payload for that proposal. Furthermore, the `cleanup_upgrade_staging` function is strictly gated to the multisig admin (`@origin`). Consequently, the decentralized DAO is completely paralyzed and cannot execute its own successful proposals without relying on the multisig admin to manually clean the staging area.

**Recommendation:**
* Allow `cleanup_upgrade_staging` to be called permissionlessly for DAO proposals if the staging area is corrupted.
* Alternatively, tie the staging resource strictly to the user staging it, or clear the staging state automatically if `dao_publish_chunked_upgrade` fails the hash check.

### 3. [HIGH] F7: Lazy-Init of Per-Token Registry Disenfranchises the Entire DAO

**Module:** `governance.move` / `voter_history.move`

**Vulnerability:** In `governance::voting_power`, the logic checks `if (voter_history::has_per_token_registry())`. If true, it exclusively reads from the new `RegistryByToken`.

**Impact:** `RegistryByToken` is lazily initialized the very first time *any* user receives a reward post-upgrade. The moment this happens, `has_per_token_registry()` becomes true for the entire protocol. Because the new registry starts empty, every single user's rolling 30-day voting power (which is currently stored in the legacy mixed `Registry`) will instantly drop to 0. Only the user who just claimed the reward will have voting power.

**Recommendation:** You must implement a migration path. `rewards_earned_30d_for_token` should ideally fall back to the legacy `Registry` on a per-user basis if their specific `RegistryByToken` entry is empty, or you need a discrete migration script to copy the 30-day rolling data over before fully cutting over the `voting_power` logic.

---

## Review of Focus Areas

* **F6 Auto-Tracker Correctness:** This implementation is mathematically and logically sound. The use of modulo arithmetic (`day % 30`), parallel `daily_day_nums` tracking for staleness, and saturating addition prevents both array out-of-bounds and overflow vulnerabilities.
* **Compat-Violation Detection:** The purely additive approach to the ABI has been maintained perfectly. No existing public or friend functions were altered in a way that breaks backwards compatibility.
* **Vestigial Fields:** The neutering of `update_fee_receiver`, `update_total_30d_emission`, and `update_desnet_fa_metadata` effectively nullifies admin manipulation while preserving struct layouts.

---

Given the severity of the MEV slippage and DAO execution griefing vectors, how would you prefer to redesign the F8 staging cleanup and the F9 AMM interaction to securely close these loopholes?
