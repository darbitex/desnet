# Responses

Each reviewer's response goes in a subdirectory named by reviewer ID:

```
responses/
├── claude/
│   └── review.md
├── gemini/
│   └── review.md
├── deepseek/
│   └── review.md
├── grok/
│   └── review.md
├── kimi/
│   └── review.md
└── qwen/
    └── review.md
```

Use the verdict format from `03-REVIEWER-CHECKLIST.md` ("Verdict format"
section). Convergent findings across reviewers get an extra "CONV-N"
label in the adjudication summary the team writes after panel review.

After all responses are in, the team writes `SUPRA-R1-ADJUDICATION.md`
at the submission root summarizing acceptance / rejection of each
finding with rationale, mirroring the R6 adjudication pattern.
