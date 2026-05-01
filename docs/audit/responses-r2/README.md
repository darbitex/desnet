# DeSNet v0.3.0 R2 — Audit Responses

R2 verification of R1 fixes.

**Submission:** `../AUDIT-DESNET-V030-R2-SUBMISSION.md` + `../AUDIT-DESNET-V030-R2-DIFF.md`
**Date:** 2026-05-02
**Panel:** same 6 LLMs as R1 (fresh sessions for unbiased verification)
**Source tag:** `v0.3.0-mainnet-baseline-r2`
**Diff:** R1 → R2, ~486 lines, 21 KB
**Status:** all 6 responses received

## Files

| Auditor | File | R1 Verdict → R2 Verdict | Status |
|---|---|---|---|
| Kimi K2.6 | `kimi-r2.md` | YELLOW → 🟢 **GREEN** | ✓ received |
| Gemini 3 Pro | `gemini-r2.md` | YELLOW → 🟡 **YELLOW** (1 architectural HIGH) | ✓ received |
| Grok 4 | `grok-r2.md` | YELLOW → 🟢 **GREEN** | ✓ received |
| Qwen 3 Max | `qwen-r2.md` | GREEN → 🟢 **GREEN** | ✓ received |
| DeepSeek V3.2 | `deepseek-r2.md` | RED (1 FP) → 🟢 **GREEN** | ✓ received |
| Claude Opus 4.7 (fresh web) | `claude-r2.md` | YELLOW → 🟡 **YELLOW** (1 HIGH on H3 sandwich) | ✓ received |

**Tally:** 4/6 GREEN (Kimi, Grok, Qwen, DeepSeek), 2/6 YELLOW (Gemini, Claude — different HIGH findings).

## R2 HIGH findings (require triage before mainnet)

1. **Claude R2-N1 — `apt_vault::settle` H3 fix is structurally ineffective.**
   - The 3% slippage check is tautological under Move atomicity (both sides of inequality use post-attacker-manipulation reserves).
   - Concrete attack: attacker bundles `swap_apt_for_token` → `settle` → `swap_token_for_apt` in one tx → +2 APT profit on a 100/1000 pool with 10 APT vault.
   - Recommended fix: two-phase commit-reveal settle (`request_settle` → wait 60s → `execute_settle`).

2. **Gemini HIGH — `factory::set_paused` hardcoded `@origin` creates DAO transition deadlock.**
   - After `disable_multisig_upgrade` + DAO transition, @origin may be dissolved → factory pause permanently bricked, OR @origin retains centralized kill-switch bypassing DAO.
   - Recommended fix: align with `profile.move` pattern — use rotatable `FactoryState.admin: address` (initially `@origin`, rotatable to DAO resource account).

## After all responses received

1. Per-auditor file under this dir ✓
2. `../R2-VERIFICATION.md` consolidated table — for each fix, did each auditor verify GREEN? — **TODO**
3. If ≥4/6 GREEN on R2: proceed to mainnet — **4/6 GREEN, but 2 YELLOW with material HIGH findings → recommend R3 to address before mainnet**
4. If <4/6 GREEN: address blocking concerns, tag `v0.3.0-mainnet-baseline-r3`, R3
