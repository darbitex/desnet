# DeSNet v0.3.2 — External Audit Response (Claude Opus 4.7)

**Reviewer:** Claude Opus 4.7
**Date:** 2026-05-02
**Method:** Bytecode-first review of all 18 modules in `CHAIN-BYTECODE-BUNDLE.md`, cross-referenced against `AUDIT-DESNET-V032-DIFF.md`. Verified MANIFEST.json sha3_256 fingerprints align.
**Scope:** R3→v0.3.2 diff (14 fixes + 1 new module) per submission.

---

## Verdict

**🟡 YELLOW** — 0 HIGH · 3 MED · 4 LOW · 3 INFO

The fix bundle is well-engineered and the bytecode faithfully implements the source diff. The v0.3.1→v0.3.2 hardening trajectory (neutering admin knobs, adding auto-tracker, isolating per-token rewards) genuinely reduces attack surface. However, three MED-severity issues exist that should be tracked even if not blocking:

- **F9 settle() is sandwich-attackable** (`min_out=0` slippage parameter)
- **F8 DAO chunked upgrade has a griefing path** (singleton staging + multisig-only cleanup)
- **F7 voting-power discontinuity** at first post-upgrade claim (pre-existing voters lose voting power until they re-claim)

None of these block the v0.3.2 deploy (already live). All have straightforward fixes for v0.3.3.

---

## Bytecode integrity

Cross-checked all 18 module sha3_256 hashes in the bundle against `MANIFEST.json` — all match. Hardcoded constants in MASM verified:

- `@desnet` constant `55931188893109713473377936165989862777849437759270464167622070126626736957220` = `0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724` ✓
- `DESNET_FA_ADDR` constant `31098278133965860165911002478625071607922378364132260533573856085805326542055` = `0x44c1006d4d8dae79195fa396c71408514343a5c4b4627b6e7595f64d65b224e7` ✓
- `@origin` constant `799008279626092026266606374476533705615973526478392622784892721766771113` = `0x000073c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9` ✓
- `APT FA` `@0xa` ✓

All claimed neutered functions (`update_desnet_fa_metadata`, `update_total_30d_emission`, `update_fee_receiver`) are confirmed `abort 22` / `abort 19` after the (no-op) borrow_global pop pattern that preserves the `acquires` annotation parity. Vestigial fields (`desnet_fa_metadata`, `total_30d_emission`, `fee_receiver`) — verified no remaining read paths in any function body.

---

## Findings

### 🔴 MED-1 — F9 `handle_fee_vault::settle()` is sandwichable (min_out=0)

[full text per submitted response]

### 🔴 MED-2 — F8 DAO chunked upgrade griefing via singleton staging

[full text per submitted response]

### 🔴 MED-3 — F7 voting-power discontinuity at first post-upgrade claim

[full text per submitted response]

### 🟡 LOW-1 — F9 vault is bricked if AMM pool becomes unusable

`settle()` calls `amm::swap_exact_apt_in(b"desnet", ...)`. If the DESNET/APT pool is locked, removed, or migrated, settle aborts. There is no admin escape function — APT in the vault is unrecoverable. `migrate_legacy_fees` only flows TO the vault. This is an "immutable, no-admin" design choice but worth documenting as a tail-risk.

**Recommendation:** Consider a permissionless `emergency_drain_apt_to_deployer()` that fires only when `amm::pool_locked_by_handle(b"desnet") = true` or pool doesn't exist. Routes 100% APT to `@origin` (who can then re-distribute via DAO). Trade-off vs. immutability claim.

### 🟡 LOW-2 — Multisig chunked publish lacks hash verification

`multisig_publish_chunked_upgrade` does not hash-verify the assembled `(metadata, code)` against any expected digest. If chunks are accidentally staged out of order, or one multisig signer manipulates a chunk, no on-chain check catches it before `code::publish_package_txn`. The DAO variant `dao_publish_chunked_upgrade` does verify against `proposal.new_module_bytes_hash` ✓, but the multisig path is purely off-chain trust.

**Recommendation:** Add an optional `expected_digest: vector<u8>` parameter; assert match if non-empty. Off-chain tooling can then pin the hash, and a single rogue chunk can't slip past visual review.

### 🟡 LOW-3 — `handle_fee_vault::vault_addr` and `vault_exists` missing `#[view]`

Same class of issue as F4b. Both are pure read fns but lack `#[view]` annotation in the deployed bytecode. Frontend can't query them via `/v1/view` — would need to call via tx/simulation. Trivial fix in next compat upgrade.

### 🟡 LOW-4 — Quorum/threshold step-change at auto > manual transition

`effective_30d_emission()` returns `max(auto, manual)`. As auto-tracker accumulates (over the first 30 days post-deploy), there's a moment when `auto` first exceeds the (now-frozen-at-neuter-time) manual value. At that point `proposal_threshold_amount` and `quorum_amount` jump up. Active proposals not yet ratified can suddenly fail quorum at ratify time (since `ratify` recomputes quorum at call time).

**Severity rationale:** LOW because (a) the inflation is monotonic and visible via `effective_30d_emission_view`, (b) proposers can monitor trajectory, and (c) it's an inherent property of rolling-window denominators. But document for proposers.

### ℹ️ INFO-1 — `migrate_legacy_fees` is a permanent permissionless sweep

`migrate_legacy_fees` is permissionless and remains callable indefinitely. Any APT accidentally sent to `@desnet` primary store can be swept into the vault by anyone, then settled via 10/90 split. This is design intent but worth flagging: any APT donation to `@desnet` becomes a forced buy-and-burn with 10% to `@origin`.

### ℹ️ INFO-2 — `swap_exact_*_actor` actor field is caller-attestation only

The new `actor: address` parameter is freely settable by callers. Indexers consuming `Swapped.actor` should treat it as caller-asserted, not protocol-verified. The entry fns `swap_apt_for_token` / `swap_token_for_apt` correctly bind `actor = signer::address_of(caller)`, but the public `swap_exact_*_actor` variants take an arbitrary address.

### ℹ️ INFO-3 — `extend_ref` in HandleFeeVault is latent power

The vault stores `extend_ref`. This grants the ability to mint a vault-signer at any time. Currently used only for primary-store withdraws in settle(). A future upgrade adding a function that uses `vault_signer` for arbitrary purposes would expand the vault's power scope. Not a bug, but a trust assumption: the vault is only as constrained as the module's full set of functions permits.

---

## Reviewer focus area responses

[per submission §6 — F6 auto-tracker, F7 dual-write, F8 DAO chunked, F9 handle_fee_vault, compat-violation detection, vestigial fields — all addressed in submitted text]

---

## Summary table

| # | Severity | Module | Issue | Suggested fix |
|---|---|---|---|---|
| MED-1 | MED | handle_fee_vault | settle() sandwichable (min_out=0) | Compute slippage cap from current reserves; or restrict to keeper |
| MED-2 | MED | governance | DAO chunked upgrade grief via singleton staging | Per-proposal staging; or proposer-can-cleanup |
| MED-3 | MED | governance + voter_history | Voting-power discontinuity at first post-upgrade claim | Eager backfill OR documented re-claim requirement |
| LOW-1 | LOW | handle_fee_vault | Vault bricks if AMM pool unusable | Conditional emergency drain when pool locked |
| LOW-2 | LOW | governance | Multisig chunked publish lacks hash verification | Optional `expected_digest` param |
| LOW-3 | LOW | handle_fee_vault | `vault_addr` / `vault_exists` missing `#[view]` | Add annotations next upgrade |
| LOW-4 | LOW | governance | Quorum step-change at auto>manual transition | Document for proposers |
| INFO-1 | INFO | handle_fee_vault | `migrate_legacy_fees` permanent perm-less sweep | Document — by design |
| INFO-2 | INFO | amm | `actor` field caller-attested in `*_actor` variants | Document for indexers |
| INFO-3 | INFO | handle_fee_vault | `extend_ref` is latent power | Document trust model |

**Acceptance check:** No HIGH findings. 3 MED findings exist but none are immediate exploits — all are tail-risk or design-trade-off. Per the acceptance criteria ("≥4/6 GREEN with no unfixed HIGH"), my YELLOW vote doesn't block production stability sign-off if the panel reaches the threshold, but I would track MED-1 (sandwich) as the highest-priority follow-up since it directly affects the protocol's deflationary value-flow promise.
