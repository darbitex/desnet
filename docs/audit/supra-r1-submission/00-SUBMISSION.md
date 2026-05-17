# DeSNet Supra Port — External Audit Submission (Supra-R1, PRE-DEPLOY)

**Submission date:** 2026-05-17
**Status:** PRE-DEPLOY (local source only — no chain bytecode yet on Supra).
**Source branch:** `port/v0.4-supra` at https://github.com/darbitex/desnet/tree/port/v0.4-supra
**Tip commit:** `3a30ba2` (self-audit Y-4 fix)
**Parent lineage:** branched from canonical Aptos `v0.3.3-mainnet-live` (= `bf6d230`); all R1-R6 audit hardening (F7/F9/G2/G3/G6) carried over verbatim, then forked to Supra surfaces.

---

## Why Supra-R1

This is the **first external review** of the Supra port. The Aptos branch reached 5/6 GREEN on R6 (Claude / Gemini / DeepSeek / Grok / Kimi accept; Qwen YELLOW on a disputed G1 design, rejected with explicit 5/6 panel consensus). The Supra fork preserves every accepted v0.3.3 fix and adds Supra-specific divergences listed in `01-DELTAS.md`.

The port is not a refactor — it is a deliberate **second mode** running on a different chain (Supra mainnet) parallel to Aptos. Both modes coexist; the market chooses. So this submission is scoped to the new surfaces, not to re-litigate the Aptos design.

---

## Acceptance bar

Same as R6: ≥ 4 of 6 reviewers GREEN, no unfixed HIGH. If RED/HIGH findings land, they will be addressed in a follow-up Supra-R2 round before chunked deploy.

## Reviewer panel (intended)

Claude (Opus 4.7), DeepSeek (V3), Gemini (2.0), Grok-2, Kimi (k2), Qwen (Coder 32B). Each reviewer reads independently. Convergent findings carry more weight; minority findings get rebuttal.

---

## What changed vs Aptos v0.3.3 (delta summary)

| Surface | Aptos mode | Supra mode (this) |
|---|---|---|
| Token distribution | 5% AMM seed / 5% reactions / 90% LP emission, sealed at registration | **100% to IPO pool**, depositor-driven |
| Creator allocation | Locked LP NFT forever | **0 token at register** — handle = identity; creator can self-participate via IPO for ≤ 10% cap |
| Launch mechanic | Atomic spawn + immediate LP staking emission | **IPO with refund-during-launch** — burn position before target_tvl → 100% refund |
| LP reward source | Sealed `$TOKEN` reserve, depleting | **Permissionless multi-FA topup gauge** (MasterChef-style) |
| Reaction reward source | Sealed `$TOKEN` reserve, linear-by-press-order curve | **BPS-of-pool per press** from multi-FA gauge (25 bps/press), keyed by **author PID address** (not handle string) |
| Identity | Main handle only | Main handle **+ unbounded subdomains `alice@bob`** via IPO deposit |
| Profile entry path | Must register own handle (pay handle fee) | **Also enter as backer** — IPO deposit creates subdomain Profile NFT |
| Verb auth | Verb entries derive PID from caller wallet | 13 verb entries gained explicit `pid_addr` arg + `profile::assert_authorized` (controller OR `object::owner(pid)`); **subdomain PIDs are full citizens** |
| Native FA | APT (Aptos coin v1) | SUPRA (FA v2 native) via `supra_fee_vault` (replaces `handle_fee_vault`) |
| Opinion module | Live in v0.4 | Ported with `apt_vault`→`supra_vault`, `MIN_INITIAL_MC` lowered from 1e15 to 1e13 (100K whole token) per user override |
| Assets Tier-2/Tier-3 | Live in v0.4 | Ported (no logical change) |

See `01-DELTAS.md` for detailed code-level walk-through of each surface.

---

## Self-audit findings (pre-flagged for reviewers)

| ID | Severity | Status | Module |
|---|---|---|---|
| **Y-1** | MED | FIXED in `e357fdd` | ipo |
| **Y-2** | MED | FIXED in `e357fdd` | ipo |
| **Y-3** | LOW (documented) | ACCEPTED — DNS-style first-come | ipo |
| **Y-4** | HIGH | FIXED in `3a30ba2` | reaction_emission + lp_emission |
| **Y-5** | LOW | ACCEPTED — bounded griefing | reaction_emission |

Full discussion in `02-SELF-AUDIT.md`.

---

## Test results

`supra move tool test --dev --ignore-compile-warnings`:

```
Test result: OK. Total tests: 117; passed: 117; failed: 0
```

Test toolchain: `supra` v0.5.0 (build commit `657ff163`, 2025-04-04) at https://pub-aa772efaa01a41deb1679acfca2d28b3.r2.dev/releases/supra_node_v9.0.3-stripped.zip. Sourced from `Entropy-Foundation/homebrew-supra`.

Coverage map:

| Module | Tests | Notes |
|---|---|---|
| amm | 7 | AMM math, swap, slippage, flash borrow |
| assets | ~12 | MIME validators, Tier-1/2/3 lifecycle |
| factory | indirect | Covered via integration tests |
| giveaway | unit | Format helpers |
| governance | ~5 | Treasury ops |
| history | ~6 | Append + chunk rotation |
| ipo | 0 direct — see `02-SELF-AUDIT.md` for known gap | TODO `setup_test_ipo` scaffold |
| lp_emission | unit | ACC_SCALE constant |
| lp_staking | unit + integration | Free + time-locked + forever positions |
| mint | unit + integration | Verb constants |
| opinion | ~15 | Pure math + integration |
| press | indirect | Covered via per-PID test |
| profile | ~10 | Handle validation, PID derivation |
| pulse | unit | Spark/echo verbs |
| reaction_emission | 5 | Per-PID isolation, lazy init, multi-FA, zero-amount, views |
| reference_gate | ~4 | Sync + LP-stake gate paths |
| registration | indirect | Covered via test flow |
| supra_fee_vault | unit | Two-phase settle |
| supra_vault | unit | Vault deploy |
| voter_history | ~3 | Per-token entries |

---

## Package contents (this folder)

```
docs/audit/supra-r1-submission/
├── 00-SUBMISSION.md          (this file — overview + scope)
├── 01-DELTAS.md              (what's new vs Aptos v0.3.3, surface-by-surface)
├── 02-SELF-AUDIT.md          (Y-1 through Y-5 with status + rationale)
├── 03-REVIEWER-CHECKLIST.md  (focused scrutiny questions for the panel)
└── SOURCE-BUNDLE.md          (all 21 module sources, concatenated)
```

Reviewers reading via the LLM panel can either consume `SOURCE-BUNDLE.md` directly (~10K LoC, fits comfortably in modern LLM contexts) or pull files individually from the branch URL above.

---

## Build / verify locally

```bash
git clone https://github.com/darbitex/desnet.git
cd desnet
git checkout port/v0.4-supra

# install supra CLI (Linux)
mkdir -p ~/.local/share/supra && cd ~/.local/share/supra
curl -L -o supra.zip 'https://pub-aa772efaa01a41deb1679acfca2d28b3.r2.dev/releases/supra_node_v9.0.3-stripped.zip'
unzip supra.zip
ln -sf ~/.local/share/supra/build_output/stripped/supra ~/.local/bin/supra
cd -

# compile + test
supra move tool compile --dev
supra move tool test --dev --ignore-compile-warnings
```

Expected: 117/117 PASS, 0 errors. Warnings include dependency-side unused aliases (framework dep noise) and 1 substantive warning on `reference_gate::check` parameter `actor_stake_position_addr` which is a reserved API surface for LP-stake gating (no caller wires it yet).

---

## Out of scope for this round

- Aptos-side v0.3.3 review (already done, R1-R6 closed).
- Frontend integration (separate repo, not yet wired).
- Indexer-satellite (parked workstream).
- Deploy procedure / chunked-publish ceremony (post-audit).
- Token economics modeling / market mechanism design — focus is on code-correctness, not whether the design will work commercially.

---

## Submission instructions for the panel

For each reviewer:

1. Read `00-SUBMISSION.md` (this file) + `01-DELTAS.md` for orientation.
2. Read `SOURCE-BUNDLE.md` or pull source from the branch URL.
3. Read `02-SELF-AUDIT.md` to see what's pre-flagged.
4. Read `03-REVIEWER-CHECKLIST.md` for focused questions.
5. Produce findings in the standard format: `[HIGH|MED|LOW|INFO] (Conv if multi-reviewer convergent expected) — Title. Module. Description + suggested fix.`
6. Provide overall verdict: `GREEN` / `YELLOW` (concerns but no HIGH) / `RED` (HIGH unfixed).

Responses go into `docs/audit/supra-r1-submission/responses/<reviewer-id>/<filename>.md`.
