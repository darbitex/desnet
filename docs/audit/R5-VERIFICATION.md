# DeSNet v0.3.2 R5 — Verification & Triage (FINAL)

**Status:** 6/6 received. Triage FINAL. **NO FIXES APPLIED YET.**

| Auditor | Verdict (raw) | HIGH | MED | LOW | INFO | Status |
|---|---|---:|---:|---:|---:|---|
| Gemini 3 Pro | 🔴 RED | 3 | 0 | 0 | 0 | ✓ |
| Claude Opus 4.7 | 🟡 YELLOW | 0 | 3 | 4 | 3 | ✓ |
| DeepSeek V3.2 | 🟡 YELLOW | 1 | 0 | 1 | 2 | ✓ |
| Grok 4 (xAI) | 🟡 YELLOW (implicit) | 0 | 4 | 3 | 1 | ✓ |
| Qwen 3 Max | 🟡 YELLOW | 1 | 2 | 3 | 0 | ✓ |
| Kimi K2.6 | 🔴 RED (raw) → 🟡 YELLOW (post-FP-correction) | 3→0 | 4→2 | 3 | 0 | ✓ |

**Final tally**: 0 GREEN / **5 YELLOW** / 1 RED (Gemini). Two RAW REDs (Gemini + Kimi), but Kimi's RED is driven by 3 false-positives explained below.

---

## Kimi false-positive analysis (corrects raw RED → YELLOW)

Kimi flagged 3 "Critical" findings that are intentional design per the submission doc Kimi did not cross-reference:

| Kimi finding | Reality | Why FP |
|---|---|---|
| #1 governance::update_desnet_fa_metadata + update_total_30d_emission abort | F6b + Item 3b NEUTERED setters by design | Kimi missed submission §F6b/F10 explanation |
| #3 profile::update_fee_receiver missing auth | F10 NEUTERED setter by design (post-handle_fee_vault) | Same — submission §F10 |
| #2 AMM flash_repay locking inconsistency (DoS via wrong-pool repay) | **Move tx atomicity** ensures lock state reverts on abort; the lock toggle in flash_borrow is in same tx as the repay; abort = full revert = lock reset | Misread of Move semantics. Lock can ONLY become permanent if a successful flash_borrow tx is followed by a SEPARATE never-repaid tx, which is impossible (FlashReceipt has no `drop` ability — must be consumed in same tx) |

Other Kimi findings (4-15) are documented design choices or valid LOW concerns also noted by other reviewers.

---

## CONVERGENCE MATRIX (deduped across 6 reviewers)

| ID | Finding | Gemini | Claude | DSeek | Grok | Qwen | Kimi | Tally | Mode-of-finding |
|---|---|---|---|---|---|---|---|---|---|
| **C1** | F9 settle MEV (zero min_out sandwich) | 🔴 H | 🟡 M | 🟢 L | (indirect) | 🟡 M | 🟡 M (#8) | **6/6** | **MED-HIGH** |
| **C2** | F8 DAO chunked staging grief (singleton + cleanup gated) | 🔴 H | 🟡 M | ⚪ I (calls "constraint") | 🟡 M | 🟡 M | (not directly) | **5/6** | **MED** |
| **C3** | F7 voting_power discontinuity (lazy-flip global) | 🔴 H | 🟡 M | ⚪ I (calls "safe") | (general) | 🔴 H | (not directly) | **4/6** | **HIGH** (2H + 1M weighted toward precaution) |
| **C4** | F6 vestigial overflow (manual field can brick) | — | — | 🔴 H | — | — | — | **1/6** | **LOW** (latent on this mainnet, easy fix) |
| **C5** | LP staking reward overflow (rate × time × scale / lp_supply) | — | — | — | (low int conv) | — | 🟠 H (#6) | **1/6** | **LOW** (extreme params required, defense-in-depth) |
| **C6** | Reaction emission daily cap missing | — | — | — | — | — | 🟠 H (#7) | **1/6** | **MED** (worth caps, but bounded by Press constraints — needs deeper review) |
| **C7** | Multisig publish missing hash-verify | — | 🟡 L | — | — | — | — | **1/6** | **LOW** (DAO has it; multisig path is off-chain trust) |
| **C8** | vault_addr / vault_exists missing #[view] | — | 🟡 L | — | — | — | — | **1/6** | **LOW** (annotation-only) |
| **C9** | quorum step-change at auto>manual transition | — | 🟡 L | — | — | — | — | **1/6** | **LOW** (document) |
| **C10** | Vault bricks if AMM pool unusable (no admin escape) | — | 🟡 L | — | — | — | — | **1/6** | **LOW** (design tradeoff) |
| **C11** | migrate_legacy_fees permanent permissionless sweep | — | ⚪ I | — | — | 🟡 L | — | **2/6** | **INFO/LOW** (by design) |
| **C12** | swap_*_actor field caller-attested (not protocol-verified) | — | ⚪ I | — | — | — | — | **1/6** | **INFO** (entry fns bind correctly) |
| **C13** | extend_ref in HandleFeeVault is latent power | — | ⚪ I | — | — | — | — | **1/6** | **INFO** (trust assumption) |
| **C14** | Assets finalize doesn't verify chunk total size | — | — | — | — | — | 🟡 M (#9) | **1/6** | **LOW** (uploader pays own bloat — no protocol grief, creator_addr enforced) |
| **C15** | Reserved handle hardcoded addresses | — | — | — | — | — | 🟡 M (#10) | **1/6** | **BY DESIGN** (documented locked decision) |
| **C16** | Single multisig with no rotation | — | — | — | — | — | 🟠 H (#4) | **1/6** | **DOCUMENTED tradeoff** (disable_multisig_upgrade is intentional one-way) |
| **C17** | AMM no emergency pause | — | — | — | — | — | (#15 arch) | **1/6** | **DOCUMENTED tradeoff** (immutable trading is design intent) |
| **C18** | read_warning unprofessional ("AI-audited only") | — | — | — | — | — | 🟢 (#11) | **1/6** | **LOW** (cosmetic) |

---

## Cleared by ALL or majority

- F6 auto-tracker math + saturating arithmetic + staleness check ✓
- ABI compat (additive only, 0 removals) ✓
- Vestigial fields neutered correctly (E_NEUTERED) ✓ (Kimi misread as bug)
- Delegate burn pattern (F9 burn_via_vault direction-lock) ✓
- F8 hash verification at dao_publish_chunked_upgrade ✓
- Tx-level atomicity protections (flash_borrow/repay) ✓ (Kimi misread)

---

## v0.3.3 fix bundle scope (FINAL recommendation — pending user approval)

| ID | Source | Severity (consensus) | Convergence | Mitigation choice |
|---|---|---|---|---|
| **G1** | C3 F7 disenfranchise | **HIGH** | 4/6 | Per-user fallback in `voting_power` (gradual migration) |
| **G2** | C2 F8 grief | **MED** | 5/6 | Per-proposal staging (`SmartTable<u64,UpgradeStaging>`) + auto-clean on hash-fail |
| **G3** | C1 F9 sandwich | **MED-HIGH** | 6/6 | Two-phase commit-reveal (`request_settle` → 60s → `execute_settle`), mirror R3 H3 fix |
| **G4** | C4 F6 vestigial | **LOW** (currently dormant) | 1/6 | Drop manual read in `effective_30d_emission` — 1-line |
| **G5** | C7 multisig publish hash-verify | **LOW** | 1/6 | NEW companion fn `multisig_publish_chunked_upgrade_with_digest(...)` |
| **G6** | C8 vault_addr/vault_exists | **LOW** | 1/6 | Add `#[view]` annotation |
| **G7** | C18 read_warning text | **LOW** | 1/6 | Soften "AI-audited only" wording |

**OPEN QUESTION items** (require user direction):
| ID | Issue | Decision needed |
|---|---|---|
| **D1** | C10 vault bricks if pool unusable | Add emergency_drain (compromises immutability) OR document tradeoff? |
| **D2** | C5 LP staking overflow at extreme rate | Add hard cap on rate_per_sec? Currently anyone-can-call `seed_lp_staking_pool` could abuse, but already limited |
| **D3** | C6 reaction_emission daily cap | Add per-author/per-day cap? Or rely on Press constraints (window + supply_cap)? |
| **D4** | C9 quorum step-change docs | No code change — just document trajectory for proposers? |
| **D5** | C11 migrate_legacy_fees scope | Restrict to historical fee amounts only, or accept "any APT to @desnet = forced burn" semantic? |

**Total v0.3.3 scope**: 7 mandatory fixes (G1-G7) + 5 open design decisions (D1-D5). Estimate 250-400 LoC depending on D-decisions, single chunked deploy.

---

## ACCEPTANCE CHECK — verdict

**Acceptance criteria from submission doc:** ≥4/6 GREEN with no unfixed HIGH for production stability sign-off.

**Result:** 0 GREEN, 5 YELLOW, 1 RED. **DOES NOT MEET acceptance bar.**

**Recommendation:** v0.3.3 fix bundle MUST address G1-G3 (the convergent finds) before claiming production stability. G4-G7 should bundle in same upgrade for efficiency.

---

## Pending

- 6/6 LLM responses received. **Awaiting user decision on**:
  1. Approval of G1-G7 mandatory fix scope
  2. D1-D5 design decisions
  3. Specific mitigation choice per fix (defaults shown above)
  4. Whether to do another R6 review pass after v0.3.3 deploy
