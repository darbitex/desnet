# DeSNet v0.3.2 — R5 audit responses (post-mainnet)

R5 verification of v0.3.2 deploy state (mainnet upgrade_number 4).

**Submission:** `../AUDIT-DESNET-V032-SUBMISSION.md` + `../AUDIT-DESNET-V032-DIFF.md`
**Date:** 2026-05-02
**Source tag:** `v0.3.2-mainnet-live` (= commit `31765c2`)
**Diff:** R3 → v0.3.2 = ~1188 lines, 14 fixes (F1/F1b/F2/F3/F4b/F4c/F5/F6/F6b/F7/F8/F9/F14/+F10)

## Files (to be populated)

| Auditor | File | Verdict | Status |
|---|---|---|---|
| Kimi K2.6 | `kimi-v032.md` | TBD | pending |
| Gemini 3 Pro | `gemini-v032.md` | TBD | pending |
| Grok 4 | `grok-v032.md` | TBD | pending |
| Qwen 3 Max | `qwen-v032.md` | TBD | pending |
| DeepSeek V3.2 | `deepseek-v032.md` | TBD | pending |
| Claude Opus 4.7 (fresh web) | `claude-v032.md` | TBD | pending |

## Acceptance criteria

≥4/6 GREEN with no unfixed HIGH for production stability sign-off.

If <4/6 GREEN OR ≥1 unfixed HIGH: address findings, prepare R6 patch, resubmit.

## Areas of focus (per submission doc §6)

1. F6 auto-tracker correctness (rolling bucket edge cases)
2. F7 dual-write pattern (no double-count, legacy fallback)
3. F8 DAO chunked variant (hash-verify, any-caller auth griefing)
4. F9 handle_fee_vault DELEGATE BURN PATTERN (direction-lock, init_module idempotency, replay-safety)
5. Compat-violation detection method (catch struct/sig changes)
6. Vestigial fields (no surviving read paths)
