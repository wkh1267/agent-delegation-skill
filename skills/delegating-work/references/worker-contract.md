# Worker Contract

Give the worker:

- the task, scope, and desired outcome
- decisions already made and constraints to preserve
- relevant known evidence without duplicating broad exploration
- expected verification and any files it may or may not change

The worker must stop when it encounters a lead-owned decision and return:

```text
DECISION_NEEDED
Question:
Evidence:
Options:
Recommendation:
Confidence:
```

Otherwise, return a concise handoff:

```text
STATUS: completed | blocked
SUMMARY:
EVIDENCE:
CHANGES:
TESTS:
RISKS:
DECISIONS_NEEDED:
REVIEW_TARGETS:
```

Choose exactly one status. Every field must contain a concrete result; write
`none` only when the field genuinely does not apply. A copied or partially
blank template is not a valid handoff. For inspection tasks, cite the files
and commands examined under `EVIDENCE`.

Never inspect, disclose, or persist secret values to verify configuration;
verify only loader logic and whether required secret inputs exist. Return the
handoff in the final response and do not create a handoff file unless asked.

Report conclusions and the evidence needed to verify them. Do not return full
source files, giant logs, hidden reasoning, or irrelevant failed attempts.
