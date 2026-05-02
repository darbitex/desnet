# DeSNet v0.3.3 — External Audit Submission (R6, PRE-DEPLOY)

**Submission date:** 2026-05-02
**Status:** PRE-DEPLOY (local source only). v0.3.2 is the currently-live mainnet version.
**Source tag:** `v0.3.3-pre-deploy-r2` (= commit `93a05a2` on branch `v0.3.3-fix-bundle`)
**Parent baseline:** `v0.3.2-mainnet-live` (= commit `31765c2`, mainnet upgrade_number 4)
**Diff scope:** v0.3.2 → v0.3.3 = ~508 lines, 8 fix items (G1-G7) + 1 self-audit fix (S1)

---

## Why R6

R5 (post-mainnet audit on v0.3.2) found 6 reviewers' verdicts: 0 GREEN, 5 YELLOW, 1 RED — **does NOT meet acceptance bar (≥4 GREEN + no unfixed HIGH)**. 3 convergent findings (5-6/6 panel):

- C1 [HIGH→MED] F9 settle MEV via zero-slippage swap
- C2 [HIGH→MED] F8 DAO chunked staging griefing via singleton + multisig-only cleanup
- C3 [HIGH→MED] F7 voting_power lazy-flip disenfranchise

Plus 1 minority HIGH (Deepseek): F6 vestigial overflow latent.

v0.3.3 addresses all 4 + 3 LOW defense-in-depth items. THIS submission asks the panel to verify the fixes are sound BEFORE chunked deploy. v0.3.3 is currently 100% local source — nothing on chain yet.

---

## Fix bundle (v0.3.3)

| ID | Severity (R5) | Source | Module | Description |
|---|---|---|---|---|
| **G1** | HIGH | F7 disenfranchise (CONV-3, 4/6 panel) | voter_history + governance | NEW `voter_history::has_per_token_entry(voter_addr): bool`. `governance::voting_power` switches from GLOBAL `has_per_token_registry()` flag to PER-USER lookup. Pre-existing voters retain legacy mixed reads until they themselves claim post-v0.3.2. Eliminates lazy-flip mass disenfranchisement. |
| **G2** | MED | F8 DAO grief (CONV-2, 5/6) | governance | NEW `DaoUpgradeStaging { proposal_id, stager, metadata, code }` — separate from multisig singleton `UpgradeStaging`. Auto-reset if existing staging is for different proposal_id. Stager-lock anti-grief (only original stager can append more chunks). NEW `dao_cleanup_upgrade_staging` (permissionless). NEW views `dao_upgrade_staging_exists` / `dao_upgrade_staging_proposal_id`. Multisig path UNCHANGED. |
| **G3** | MED-HIGH | F9 settle MEV (CONV-1, 6/6) | handle_fee_vault | `settle()` body now ABORTS `E_USE_TWO_PHASE=3` (BREAKING). Two-phase commit-reveal flow: `request_settle()` (snapshots balance + reserves + 5% slippage min_out) → 60s delay → `execute_settle()` (consumes snapshot, swap with baked min_out — sandwich-safe). NEW `cancel_pending_settle()` permissionless. NEW `PendingSettle` struct. NEW views `pending_settle_exists/executable_at_secs/min_out`. NEW errors `E_USE_TWO_PHASE=3`, `E_PENDING_SETTLE_NOT_FOUND=4`, `E_PENDING_SETTLE_NOT_RIPE=5`, `E_PENDING_SETTLE_EXPIRED=6`, `E_PENDING_SETTLE_ALREADY_EXISTS=7`. |
| **S1** | HIGH (self-audit) | (G3 implementation bug) | handle_fee_vault | Self-audit caught: original G3 anchored `min_out` to request-time `to_burn` but execute_settle recomputed `to_burn` from CURRENT balance. If vault grew during 60s window, larger swap with stale-anchored small min_out → sandwich attacker could trivially satisfy check. **Fixed**: PendingSettle now stores `to_deployer_at_request` + `to_burn_at_request`. execute_settle uses snapshot amounts (not current balance). Excess fees stay in vault for next cycle. |
| **G4** | LOW dormant | F6 vestigial overflow (Deepseek 1/6 HIGH) | governance | `effective_30d_emission` body change: drop manual field read; return `total_30d_emission_auto()` directly. Eliminates latent overflow vector at `(eff * BPS) / 10000` if vestigial value was extreme. Currently dormant on this mainnet (`state.total_30d_emission = 0`). |
| **G5** | LOW (defense-in-depth) | Claude C7 hash-verify gap | governance | NEW `multisig_publish_chunked_upgrade_with_digest(multisig, ..., expected_digest)` — pin assembled hash off-chain. Old `multisig_publish_chunked_upgrade` unchanged. |
| **G6** | LOW | Claude C8 missing #[view] | handle_fee_vault | `vault_addr` + `vault_exists` add `#[view]` annotation. Annotation-only change. |
| **G7** | LOW (cosmetic) | Kimi #11 unprofessional warning | amm | `WARNING` const text update: "AI-audited only" → "Multi-LLM audited (R1-R5, mainnet live)". |

**REJECTED with rationale (in commit messages):**
- G8 LP staking rate cap (Kimi #6 HIGH) — `rate_per_sec` hardcoded `DEFAULT_RATE_PER_SEC=1e9` at create, NO setter exists; math doesn't realistically overflow at default × 30yr.
- G9 reaction_emission daily cap (Kimi #7 HIGH) — per-post emission BOUNDED by `cap × (cap+1)/2 × BASE` = 500k tokens at MAX_SUPPLY_CAP=1000; per-actor uniqueness + Aptos gas baseline + ReferenceGate constrain sybil cost.
- G10 assets `finalize` total_size verification (Kimi #9 MED) — would need new resource at `master_addr` but Master.move doesn't capture ExtendRef → can't lazy-init post-create without struct change. Real impact: uploader pays own bloat (no protocol grief).

---

## ABI compat summary (v0.3.2 → v0.3.3)

**0 public/friend fn removed.** Purely additive:

| Module | v0.3.2 chain | v0.3.3 local | Δ |
|---|---|---|---|
| voter_history | 10 | 11 | +1 (`has_per_token_entry`) |
| governance | 31 | 35 | +4 (`dao_cleanup_upgrade_staging`, `dao_upgrade_staging_exists`, `dao_upgrade_staging_proposal_id`, `multisig_publish_chunked_upgrade_with_digest`) |
| amm | 39 | 39 | unchanged (G7 const text only) |
| apt_vault | 12 | 12 | unchanged |
| factory | 22 | 22 | unchanged |
| handle_fee_vault | 11 | 17 | +6 (`request_settle`, `execute_settle`, `cancel_pending_settle`, `pending_settle_exists`, `pending_settle_executable_at_secs`, `pending_settle_min_out`); `vault_addr`/`vault_exists` add #[view] |
| profile | 23 | 23 | unchanged |
| (others 11) | unchanged | unchanged | — |

**+11 NEW fns + 2 NEW structs (DaoUpgradeStaging, PendingSettle).**

Pkg size: 73,671 → 75,847 bytes (+2,176, well within 2-chunk deploy via existing infra).

---

## Self-audit findings (already addressed before this submission)

| ID | Severity | Status |
|---|---|---|
| **S1** | HIGH | FIXED in commit `93a05a2`, tag `v0.3.3-pre-deploy-r2`. G3 swap_amount + min_out now PAIRED from same snapshot. |
| **S2** | MED | DOCUMENTED. `dao_cleanup_upgrade_staging` permissionless wipes in-progress staging — pure DoS, no asset loss. Real fix needs per-proposal SmartTable (struct change, defer to v0.3.4). |
| **S3** | LOW-MED | DOCUMENTED. G2 auto-reset enables proposal-switching wipe-grief if multiple proposals concurrently eligible. Same root cause as S2. |
| **S4** | INFO | Bounded gas-only grief — accept. |
| **S5** | INFO | apt_balance_at_request now used by S1 fix. |

Full self-audit doc: `SELF-AUDIT.md` (this folder).

---

## Submission package (LOCAL SOURCE, no chain bytecode)

**ALL files consolidated in this folder** (`docs/audit/v033-r6-submission/`):

| File | Size | Contents |
|---|---|---|
| `00-SUBMISSION.md` (this) | 12KB | What changed + areas of focus |
| `01-DIFF.md` | 26KB / 508 lines | git diff `v0.3.2-mainnet-live..v0.3.3-pre-deploy-r2 -- sources/` |
| `MANIFEST.json` | 4KB | Per-module sha3_256 + concat hash |
| `PART-1-governance-auth.md` | 118KB | voter_history, governance, factory, profile (4 modules) |
| `PART-2-financial.md` | 108KB | amm, apt_vault, lp_staking, lp_emission, reaction_emission, handle_fee_vault (6 modules) |
| `PART-3-social-verbs.md` | 129KB | assets, reference_gate, history, link, mint, giveaway, press, pulse (8 modules) |
| `SELF-AUDIT.md` | 8KB | S1 found + fixed; S2-S5 documented |
| `responses/` | (empty, for output) | Drop LLM responses here as `{name}-v033.md` |

Outside this folder (background context, not strictly needed for R6):
- `../AUDIT-DESNET-V032-SUBMISSION.md` + `../responses-v032/` — R5 verdicts that drove v0.3.3

### Source integrity (verifiable)

```json
{
  "tag": "v0.3.3-pre-deploy-r2",
  "commit": "93a05a2...",
  "parent_deployed": "v0.3.2-mainnet-live (commit 31765c2, mainnet upgrade_number 4)",
  "total_lines": 8869,
  "total_bytes": 351447,
  "source_concat_sha3_256": "77f1831c265acbfac8712aeebe56aecd4548b82694a0866c5e29555e6cd7beb0"
}
```

Per-module sha3_256 in `v033-source-bundle/MANIFEST.json` (18 entries).

---

## Areas of focus for R6 reviewers

### **PRIORITY 1: Verify G3 + S1 fix is sandwich-safe**
- Read `handle_fee_vault.move` lines 106-225 (settle/request/execute/cancel + PendingSettle)
- Verify: swap_amount and min_out are PAIRED from same request snapshot
- Check edge cases: what if balance grew between request and execute? (S1 was the bug here)
- Check: can attacker force execute to use stale snapshot for larger swap? (should be impossible after S1 fix)
- Check: cancel_pending_settle race conditions
- Check: 60s delay + 600s grace timing windows

### **PRIORITY 2: Verify G1 per-user fallback eliminates lazy-flip**
- Read `voter_history.move::has_per_token_entry` + `governance.move::voting_power`
- Verify: a voter with legacy entry but NO per-token entry retains voting power via legacy path
- Verify: voter who claimed post-v0.3.2 sees per-token reads
- Edge: voter with per-token entry but ZERO DESNET-token amount — should fall back? Currently does NOT (per-user check is "exists entry" not "has DESNET amount > 0")

### **PRIORITY 3: Verify G2 anti-grief**
- Read `governance.move::dao_stage_chunks_into_staging` + `dao_cleanup_upgrade_staging`
- Confirm S2 documented limitation (permissionless cleanup wipes in-progress)
- Confirm S3 documented limitation (auto-reset on different proposal_id)
- Suggest: any compat-safe additional defense for v0.3.3 (e.g., staging-age cooldown for cleanup)?

### **PRIORITY 4: Verify G4 vestigial overflow**
- Read `governance.move::effective_30d_emission` (line ~479)
- Confirm: only `total_30d_emission_auto()` is read; manual field ignored
- Edge: what if upgrade_total_30d_emission was somehow re-enabled in future upgrade? G4 protects current code path; future upgrades retain risk.

### **PRIORITY 5: General regression check**
- Did any v0.3.2 functionality break (other than intentional `settle()` deprecation)?
- ABI compat: 0 public/friend fn removed (verify by checking each module).
- New struct additions only at NEW resources (DaoUpgradeStaging at @desnet, PendingSettle at vault_addr) — no existing struct field changes.

### **PRIORITY 6: Anything else novel**
- Re-look at v0.3.2 areas not focused-on in R5 (e.g., reaction_emission, press, mint, history, link, pulse, assets) — any latent issues we missed?

---

## Reviewer panel (target same 6 as R5)

- Kimi K2.6
- Gemini 3 Pro
- Grok 4 (xAI)
- Qwen 3 Max
- DeepSeek V3.2
- Claude Opus 4.7

Drop responses to `responses/{name}-v033.md` (this folder).

**Acceptance:** ≥4/6 GREEN with no unfixed HIGH for production-stability sign-off + safe-to-deploy.
