# DeSNet v0.3.2 — External Audit Submission (R5, post-mainnet)

**Submission date:** 2026-05-02
**Mainnet status:** LIVE at upgrade_number 4 (deployed 2026-05-02 via chunked upgrade)
**Source tag:** `v0.3.2-mainnet-live` (= commit `31765c2` on branch `v0.3.2-fix-bundle`)
**Prior audited baseline:** `v0.3.0-mainnet-baseline-r3` (R1+R2+R3 audited, see `responses/` and `responses-r2/`)
**Diff scope:** R3 → v0.3.2 = ~1188 lines across 8 module files + 1 NEW module (`handle_fee_vault.move`, 143 LoC)

---

## What changed since R3 (the last externally audited state)

R3 was the last external multi-LLM panel review (5 LLMs: kimi, gemini, grok, qwen, deepseek + claude). 4/6 GREEN, 2 YELLOW with HIGH findings — both addressed in R3 commit `f9b5af9`.

Between R3 and v0.3.2, three production iterations happened:

### v0.3.0.5 (deployed mainnet 2026-05-02 09:03)
- **giveaway::settle_bounty_bps view added** (1-line public fn `: u64 { 5 }`) — needed for compat (without it, future giveaway un-neuter would have failed publish with VMError 1096 BACKWARD_INCOMPATIBLE_MODULE_UPDATE)

### v0.3.0.6 (deployed mainnet 2026-05-02 09:08)
- **Chunked-upgrade infra in `governance.move`** — added `UpgradeStaging` struct + `multisig_stage_upgrade_chunk` + `multisig_publish_chunked_upgrade` + `cleanup_upgrade_staging` + `upgrade_staging_exists` view. Required because future package upgrades exceed Aptos 64KB single-tx publish limit. Self-contained (uses only `0x1::code::publish_package_txn`, no aptos-experimental dep).

### v0.3.1 (deployed mainnet 2026-05-02 11:41 via chunked upgrade)
- **Bootstrap publisher pattern** — replaced `resource_account::retrieve_resource_account_cap` with `origin::publisher::take_cap_for_desnet` (chunked publish requires this indirection through bootstrap pkg)
- **`DESNET_FA_ADDR` const hardcoded** in governance — eliminates manipulation surface where multisig could re-point to malicious FA addr post `disable_multisig_upgrade`. `voting_power` reads const directly with `object_exists` guard.
- **`update_desnet_fa_metadata` neutered** — body changed to `abort E_NEUTERED`. Field `desnet_fa_metadata` retained as vestigial (compat-only).
- **`propose_upgrade` body**: dropped vestigial `desnet_fa_metadata != @0x0` check.
- **Reserved-handle guard** (5 handles bound to specific claimer addrs).

### v0.3.2 (deployed mainnet 2026-05-02 ~16:50 via chunked upgrade) ← **THIS SUBMISSION**

14 fixes — see [§ Fix bundle](#fix-bundle) below.

---

## Fix bundle (v0.3.2)

| ID | Module | Severity | Description |
|---|---|---|---|
| **F1** | factory | LOW | 5 view fns: `assert!(...)` error code `E_HANDLE_TAKEN(=3)` → `E_TOKEN_NOT_FOUND(=19)`. Misleading code semantically — fns are "lookup" not "register". |
| **F1b** | profile | LOW | NEW `handle_of_wallet(wallet_addr): String` — derives PID from wallet, looks up handle. Lives in profile (not factory) to avoid factory→profile dependency cycle. |
| **F2** | governance | LOW | `multisig_publish_chunked_upgrade` defense-in-depth: assert each module slot in `code: vector<vector<u8>>` is non-empty before `code::publish_package_txn`. New error `E_INCOMPLETE_CHUNKS=23`. Without this, missed chunks produce framework-level error instead of clear ours-error. |
| **F3** | governance | LOW | `cleanup_upgrade_staging` now emits `UpgradeStagingCleanup { multisig, timestamp_secs }` event (was silent — observability gap). |
| **F4b** | amm | LOW | `compute_amount_out` adds `#[view]` annotation — was `public fun` only, unreachable via `/v1/view`. Frontend forced to make tx for ad-hoc CPMM quotes. Pure fn, no `acquires`. |
| **F4c** | amm | INFO | Added 5 view companions for handle/pool_addr split (some views took handle, others pool_addr — confusing for integrators): `lp_fee_per_share_by_handle`, `pool_locked_by_handle`, `creator_pid_at`, `fee_buckets_at`, `quote_swap_exact_in_at`. |
| **F5** | amm | LOW | `Swapped` event `actor` field was hardcoded `@0x0` because `swap_exact_*` were `public fun` (no `&signer` param) — couldn't recover actor. Added `swap_exact_apt_in_actor` + `swap_exact_token_in_actor` taking explicit actor param. Entry fns `swap_apt_for_token` + `swap_token_for_apt` route through `*_actor` variants with `signer::address_of(caller)`. Old fns kept as compat wrappers passing `@0x0`. |
| **F6** | governance + lp_staking | MED | **30d emission auto-tracker.** New struct `Emission30dRollingBucket { daily_amounts: vector<u64>, daily_day_nums: vector<u64> }` — per-day buckets indexed by `day_number % 30`, parallel `daily_day_nums` for staleness check on read. New friend fn `record_emission_for_window(amount)` called from `lp_staking::claim_internal` per `actual_paid` (the post-graceful-depletion amount, mirroring H2 pattern). View `total_30d_emission_auto()` aggregates fresh buckets. New view `effective_30d_emission_view()` returns `max(auto, manual)`. Modified `proposal_threshold_amount` + `quorum_amount` to use `effective_30d_emission()`. **Eliminates manipulation surface** where multisig could pin denominator to favorable value via `update_total_30d_emission`. Lazy-init bucket on first record (init_module skipped for upgrades). |
| **F6b** | governance | MED | `update_total_30d_emission` NEUTERED — body now `abort E_NEUTERED`. Auto-tracker is sole source of truth. Field `total_30d_emission` retained as vestigial (compat). |
| **F7** | voter_history + governance | MED | **Per-token rewards isolation.** New resource `RegistryByToken has key { voters: SmartTable<address, SmartTable<address, VoterHistory>> }` — outer key = voter, inner key = token_metadata_addr. New friend fn `record_reward_received_for_token(authority, voter, token_addr, amount)` — writes to BOTH legacy mixed `Registry` (compat preserved) AND per-token. View `rewards_earned_30d_for_token(voter, token_addr)`. View `has_per_token_registry()`. `governance::voting_power` reads per-token DESNET-only when `RegistryByToken` initialized, falls back to legacy mixed when not. **Eliminates cross-token mix** where non-DESNET reward streams could inflate voting power. Lazy-init on first call. |
| **F8** | governance | MED | **DAO chunked-upgrade variant.** New entries `dao_stage_upgrade_chunk(caller, proposal_id, ...)` + `dao_publish_chunked_upgrade(caller, proposal_id, ...)` mirror multisig variants but gated on DAO proposal lifecycle (approved + ratified + timelock-elapsed). Hash-verifies assembled `(metadata, code)` matches `proposal.new_module_bytes_hash` at publish. Reuses `UpgradeStaging` resource. Auth: anyone post-ratify (DAO has spoken). |
| **F9** | NEW handle_fee_vault | MED | **Buyback-burn vault for handle registration fees.** New module ~143 LoC. `init_module` auto-fires on publish — creates singleton vault Object at deterministic addr `object::create_object_address(&@desnet, b"handle_fee_vault")`. Immutable destinations: 10% APT → deployer beneficiary primary store (= `@origin`), 90% APT → swap to DESNET via `amm::swap_exact_apt_in(b"desnet")` → burn via `apt_vault::burn_via_vault(desnet_apt_vault, fa)` (DELEGATE BURN PATTERN). Permissionless `settle()` poke, threshold 0.1 APT (anti-dust). `migrate_legacy_fees` (permissionless) pulls stranded pre-upgrade fees from `@desnet` primary store. Public `deposit_apt(depositor, amount)` for top-ups. |
| **F9 wiring** | apt_vault, factory, profile, governance | — | `friend desnet::handle_fee_vault` in apt_vault + governance. `apt_vault::burn_via_vault(vault_addr, fa)` friend fn — direction-locked (FA metadata must match vault.token_metadata_addr; framework `fungible_asset::burn` enforces). `factory::vault_addr_of_handle` view. `profile::register_handle` body change: routes APT fee directly to `handle_fee_vault::deposit_apt_fa(fee_fa)` (was `state.fee_receiver` primary store). |
| **F10** | profile | MED | `update_fee_receiver` NEUTERED — body now `abort E_NEUTERED=19`. Field `fee_receiver` retained as vestigial (compat); fee path = handle_fee_vault per F9. |
| **F14** | governance | LOW | R2 Kimi unfixed finding (R2-N1): `propose_upgrade` + `execute_proposal` now assert `target_package_addr == @desnet` (defense-in-depth — monolith only target). |

---

## ABI compat summary

**0 public/friend fn removed across 17 existing modules.**
**29 NEW public/friend fns added** (additive).
**1 NEW module** (`handle_fee_vault`, 11 public/friend fns).

| Module | chain v0.3.1 | v0.3.2 | Δ |
|---|---|---|---|
| voter_history | 7 | 10 | +3 (record_reward_received_for_token, rewards_earned_30d_for_token, has_per_token_registry) |
| governance | 26 | 31 | +5 (record_emission_for_window, total_30d_emission_auto, effective_30d_emission_view, dao_stage_upgrade_chunk, dao_publish_chunked_upgrade) |
| amm | 32 | 39 | +7 (swap_exact_apt_in_actor, swap_exact_token_in_actor, lp_fee_per_share_by_handle, pool_locked_by_handle, creator_pid_at, fee_buckets_at, quote_swap_exact_in_at) |
| apt_vault | 11 | 12 | +1 (burn_via_vault) |
| factory | 21 | 22 | +1 (vault_addr_of_handle) |
| profile | 22 | 23 | +1 (handle_of_wallet) |
| handle_fee_vault | NEW | 11 | NEW (vault_addr, vault_exists, deposit_apt_fa, deposit_apt, settle, migrate_legacy_fees, deployer_beneficiary, apt_balance, split_deployer_bps, split_burn_bps, settle_threshold) |

Pkg size: 67,782 bytes → 73,671 bytes (+5,889b).

ABI compat-check method documented in `docs/v0.3.1-post-mainnet-audit.md` §6 (disassemble + diff vs on-chain). Used as pre-deploy gate for v0.3.2.

---

## Self-audit summary (all GREEN before deploy)

| Dim | Status |
|---|---|
| ABI surface | ✓ 0 removals, 29 additions, 1 new module |
| Argument validation | ✓ F1+F2+F14 strengthen |
| Math | ✓ F6 saturating u64 arithmetic, no overflow possible (1B token cap × 30 days bounded) |
| Reentrancy | ✓ no new external-callback surface |
| Edge cases | ✓ F2 empty-slot, F6 stale-bucket reset, settle 0.1 APT threshold |
| Cross-module | ✓ lp_staking → governance friend (preserved); handle_fee_vault → amm + apt_vault + factory + governance friends declared |
| Errors | ✓ E_INCOMPLETE_CHUNKS=23, E_NEUTERED=19/22 (no overlap) |
| Events | ✓ UpgradeStagingCleanup added, Settled added, Swapped.actor populated |

---

## Mainnet state (post-deploy verification)

**On-chain confirmations:**
- `upgrade_number` = 4
- `source_digest` = `404D8C42C1DFCFDD4FBB522936146642CCC0734618380B4B34...`
- 18 modules registered (incl handle_fee_vault)
- `upgrade_staging_exists()` = false (consumed cleanly)

**Live verification of fixes (post-deploy):**

| Fix | Verification |
|---|---|
| F1 | `factory::handle_of_token(0x0)` aborts `E_TOKEN_NOT_FOUND(0x13)` (was `E_HANDLE_TAKEN(0x3)`) ✓ |
| F1b | `profile::handle_of_wallet(@origin) = "desnet"` ✓; `handle_of_wallet(0x0047)` aborts `E_PROFILE_NOT_FOUND` ✓ |
| F4b | `compute_amount_out(1e8, 5e15, 1e7)` callable via `/v1/view` ✓ (returned 454,132,193,835,803) |
| F4c | All 5 companion views return values ✓ |
| F5 | `Swapped.actor = 0x47a3e13465...` (= sender) on tx `0xdde64774105f...` ✓; was `@0x0` in v0.3.1 |
| F6 | Post-claim: `total_30d_emission_auto = 8,613,243,402,396 raw = 86,132 DESNET` ✓; `proposal_threshold_amount = 5%× = 4,306 DESNET`; `quorum_amount = 35%× = 30,146 DESNET` |
| F6b | `update_total_30d_emission(_,_)` aborts `E_NEUTERED(0x16)` ✓ |
| F7 | Post-claim: `has_per_token_registry = true` ✓; `voting_power(@origin) = 8,613,243,402,396` reads per-token DESNET-only |
| F9 | **Settle 1 APT → 0.1 APT to @origin + 0.9 APT swap → 3,685,451 DESNET BURNED** (supply 1,000,000,000 → 996,314,549 = -0.37% deflationary). Tx `0x64a6de8b71a3...` ✓ |
| F10 | `update_fee_receiver(_,_)` aborts `E_NEUTERED(0x13)` ✓ |
| F14 | (require DAO setup — defer test) |

---

## Areas of focus for R5 reviewers

1. **F6 auto-tracker correctness** — bucket index by `day % 30`; staleness via parallel `daily_day_nums` vector; saturating u64 add. Consider edge cases: long emission gaps (>30 days), simultaneous claims across day boundary, view-time staleness when no record fired today.

2. **F7 dual-write pattern** — `record_reward_received_for_token` writes to BOTH legacy `Registry` (mixed) AND new `RegistryByToken` (per-token). Verify no double-count surface; verify legacy fallback in `voting_power` is correct (only triggers when `has_per_token_registry()=false`).

3. **F8 DAO chunked variant** — verify hash-verify against `proposal.new_module_bytes_hash` is sound; verify any-caller auth (post-ratify) doesn't enable griefing (e.g., partial staging by malicious actor blocking legitimate publish).

4. **F9 handle_fee_vault** — DELEGATE BURN PATTERN is novel: `handle_fee_vault::settle` swaps APT→DESNET via amm, then hands DESNET FA to `apt_vault::burn_via_vault` which holds the BurnRef. Verify direction-lock (wrong-token FA → `fungible_asset::burn` aborts). Verify settle is replay-safe (vault drained per call). Verify init_module idempotency (won't fire on subsequent upgrades since module already published).

5. **Compat-violation detection method** (`docs/v0.3.1-post-mainnet-audit.md` §6) — was used as pre-deploy gate for v0.3.2. Verify the method catches all compat-relevant changes (struct layout, public/friend fn removal/sig change, ability changes).

6. **Vestigial fields** — `state.desnet_fa_metadata`, `state.fee_receiver`, `state.total_30d_emission` all kept compat-only after their setters were neutered. Confirm no read paths still exist that would surface stale values.

---

## Submission package

**🔍 GROUND TRUTH = ON-CHAIN BYTECODE.** Source files are provided for cross-reference, but auditors should primarily verify what's actually deployed.

| File | Path | Contents |
|---|---|---|
| **Chain bytecode bundle (ground truth)** | `docs/audit/v032-chain-bytecode/` | Fetched directly from mainnet `@desnet`: 18 `bytecode/{name}.mv` (binary) + `bytecode/{name}.hex` (textual) + `abi/{name}.json` (REST `/v1/accounts/.../module/{name}.abi`) + `masm/{name}.masm` (disassembled via `aptos move disassemble`) + `MANIFEST.json` (per-module sha3_256 + pkg metadata) |
| Source bundle (cross-reference) | `sources/*.move` (18 files, 8591 LoC) | Full v0.3.2 source — for reading intent. **Not authoritative.** |
| Diff vs R3 (cross-reference) | `docs/audit/AUDIT-DESNET-V032-DIFF.md` | git diff `v0.3.0-mainnet-baseline-r3..HEAD` -- sources/ |
| This submission doc | `docs/audit/AUDIT-DESNET-V032-SUBMISSION.md` | What changed + areas of focus |
| Prior audit context | `docs/audit/AUDIT-DESNET-V030-R2-SUBMISSION.md` + `responses-r2/` | R2 review context |
| Self-audit (v0.3.1) | `docs/v0.3.1-post-mainnet-audit.md` | R4 self-audit + compat-check method |
| v0.3.2 roadmap | `docs/v0.3.2-upgrade-roadmap.md` | Original 14-fix planning doc |

### Bytecode integrity (verifiable by auditor)

```json
{
  "desnet_addr": "0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724",
  "pkg_name": "Desnet",
  "upgrade_number": 4,
  "source_digest": "404D8C42C1DFCFDD4FBB522936146642CCC0734618380B4B34DA582C368C...",
  "total_module_bytes": 71968,
  "pkg_concat_sha3_256": "6b5326ff446d35323332a879e152654dee2e7fbcc836be97a49516ffe1f73472",
  "modules": 18
}
```

Auditor verification recipe:
```bash
# 1. Fetch each module fresh from mainnet REST
for m in voter_history governance amm apt_vault assets reaction_emission \
         lp_emission lp_staking factory reference_gate handle_fee_vault \
         profile history link mint giveaway press pulse; do
    curl -sS "https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x7ba7ee5a.../module/$m" \
        | jq -r .bytecode | xxd -r -p > /tmp/v032/$m.mv
done

# 2. Compute sha3_256 of each, compare to MANIFEST.json
sha3sum /tmp/v032/*.mv

# 3. Compare to bundled bytecode/*.mv (should be byte-identical)
diff -r docs/audit/v032-chain-bytecode/bytecode/ /tmp/v032/
```

### Per-module sha3_256 (from chain, 2026-05-02)

| # | module | bytes | sha3_256 |
|---|---|---:|---|
| 0 | voter_history | 2,785 | `b69051e8...8bf2bc50` |
| 1 | governance | 7,972 | `2e5057dd...39d31092` |
| 2 | amm | 8,165 | `e0a984d0...cd302618` |
| 3 | apt_vault | 3,004 | `764df544...ae6fb04f` |
| 4 | assets | 2,950 | `8de46f4e...41472e55` |
| 5 | reaction_emission | 2,195 | `f6c103a8...4bab79f0` |
| 6 | lp_emission | 1,929 | `015edb50...39026745` |
| 7 | lp_staking | 6,047 | `754a12aa...ede01c27` |
| 8 | factory | 5,721 | `b477bdfe...95cdddca` |
| 9 | reference_gate | 1,363 | `cd27eaf0...162c6c67` |
| 10 | handle_fee_vault (NEW) | 2,115 | `c6caf6b4...ecf15430` |
| 11 | profile | 6,403 | `b61420ac...e6332d60` |
| 12 | history | 2,934 | `19bf456b...bf5eaee0` |
| 13 | link | 1,981 | `ab14968a...b1df9133` |
| 14 | mint | 4,704 | `2c4f9f3e...c74b609a` |
| 15 | giveaway | 4,753 | `946ef6e5...2075c570` |
| 16 | press | 4,457 | `c3259a61...a56c43893` |
| 17 | pulse | 2,490 | `42e1ceef...015b11327` |

---

## Mainnet addresses (for reviewer cross-reference)

```
@desnet (resource account, pkg home):
    0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724

@origin (1/5 → now 3/5 multisig, vanity 0x0000 prefix):
    0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9

DESNET FA (deterministic, hardcoded as DESNET_FA_ADDR const):
    0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7

desnet PID NFT (handle owner: @origin, controller: 0x0047a3e1...):
    0xfa4dd0513a60afe94e9dcafda75e50072ef9718b14b8a91a731f2d04d9fc3adf

AMM pool (DESNET/APT):
    0x5ba92cb1c4eb871b36eb4475b85763c390f8aa604946eb1ea26c10ee46c822a8

handle_fee_vault (deterministic):
    object::create_object_address(@desnet, b"handle_fee_vault")
```

---

## Key tx hashes (post-deploy verification trail)

| Action | Tx hash |
|---|---|
| chunk_00 propose (stage 11 modules) | `0x66839a4dc856f05b12d378090236571e4c059eaf7357d2c1c3829a31290d2de6` |
| chunk_01 execute (publish) | `0x45ac61756d6e3a2982004b23271196dd704a0aeeec6143148b80ef685c46eb5a` |
| migrate_legacy_fees | `0xb2eb14bde2879cea48c898468f2df52490be098ec8fa0a839a2d22462d1a0cb3` |
| settle (10/90 split + 3.69M DESNET burned) | `0x64a6de8b71a32ee0874c14a10b5c0d341b2eb9c0a551fe4bd00c8f6a8a7041d8` |
| F5 swap (actor populated) | `0xdde64774105f51679536021fd3240b63fbc1e28a3bae33873105a35d900da5f5` |
| F7 claim (per-token registry init) | `0xc2d683448eb3a0f411e9e5dbfd77ecc9d9d56a920fd28aac36b120deb27857ff` |
| Multisig threshold raise 1→3 | `0xec8f2bd50d08de4a7c429f11c5fd9b663c3c56100d1468808a08d48f5048233d` |

---

## Reviewer panel

Same 6 LLMs as R1/R2/R3 (target):
- Kimi K2.6
- Gemini 3 Pro
- Grok 4 (xAI)
- Qwen 3 Max
- DeepSeek V3.2
- Claude Opus 4.7

Responses to be saved under `responses-v032/`.

**Verdict scale:** GREEN / YELLOW / RED with HIGH/MED/LOW finding tally.

**Acceptance criteria:** ≥4/6 GREEN with no unfixed HIGH for production stability sign-off.
