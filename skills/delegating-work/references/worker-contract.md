# Worker Contract

Workers receive a compact task contract, not the Lead's full conversation or a
dump of broad repository context.

Use this dispatch shape:

```text
TASK:
What must be accomplished.

SCOPE:
Relevant subsystem and allowed mutation boundaries.

DECISIONS:
Architectural, product, or workflow decisions that are already fixed.

CONSTRAINTS:
Behavior and invariants that must be preserved.

FORBIDDEN:
Decisions, files, or changes the Worker may not make.

SUCCESS:
Observable verification and completion criteria.
```

Include relevant known evidence only when it saves rediscovery without leaking
large intermediate context. Do not pre-read the repository broadly just to fill
this contract; repository exploration is Worker work when the routing policy
assigns it there.

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
source files, giant logs, hidden reasoning, complete repository maps, or
irrelevant failed attempts.
