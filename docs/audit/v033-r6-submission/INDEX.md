# DeSNet v0.3.3 R6 Submission — Quick Index

**ALL files in this folder.** Path: `/home/rera/desnet/docs/audit/v033-r6-submission/`

## Paste order per LLM webchat session

| Step | File | Size | Purpose |
|---|---|---|---|
| 1 (always) | `00-SUBMISSION.md` | 12KB | Initial context — what changed v0.3.2→v0.3.3, fix bundle, areas of focus |
| 2 (pick one) | `01-DIFF.md` | 26KB | Just-the-changes review (508-line git diff) |
| 2 alt | `PART-1-governance-auth.md` | 118KB | Full source: voter_history, governance, factory, profile |
| 2 alt | `PART-2-financial.md` | 108KB | Full source: amm, apt_vault, lp_staking, lp_emission, reaction_emission, handle_fee_vault |
| 2 alt | `PART-3-social-verbs.md` | 129KB | Full source: assets, reference_gate, history, link, mint, giveaway, press, pulse |
| 3 (optional) | `SELF-AUDIT.md` | 8KB | What I (the author) found in self-audit (S1 fixed, S2-S5 documented) |

## Workflow

**Most LLMs accept ~150-200KB direct paste OR ~500KB+ file upload.**

- **Diff-focused review** (small): paste 00 + 01 (= 38KB). Cheap, fast, focused.
- **Full module review** (medium): paste 00 + one PART (= 120-141KB). Per-domain deep audit.
- **Comprehensive review** (full): upload all 6 files as attachment OR paste 00 + 01 + 03 + all PARTs across multiple turns.

## Reviewer drops responses to

`responses/{name}-v033.md` — see `responses/README.md` for naming convention.

## Verify source integrity

```json
{
  "tag": "v0.3.3-pre-deploy-r2",
  "commit": "93a05a2",
  "total_lines": 8869,
  "total_bytes": 351447,
  "source_concat_sha3_256": "77f1831c265acbfac8712aeebe56aecd4548b82694a0866c5e29555e6cd7beb0"
}
```

Per-module sha3_256 in `MANIFEST.json`.

## Acceptance

≥4/6 GREEN + no unfixed HIGH = safe-to-deploy.
