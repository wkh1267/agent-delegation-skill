---
name: delegent
description: Orchestrate one explicitly selected engineering workflow across a lead agent and delegated workers while preserving lead context, worker continuity, escalation boundaries, and final acceptance.
disable-model-invocation: true
---

# Delegent

Delegent is the orchestration layer around one explicitly selected engineering workflow.

Use it like:

```text
$delegent $implement

<task, constraints, and acceptance criteria>
```

V0.1 expects exactly one companion workflow skill. The workflow owns **what must happen**; Delegent owns **where each significant work unit lives** and how work crosses the Lead/Worker boundary.

Delegent is workflow-agnostic. It does not depend on Matt Pocock's `implement` skill or any other particular external workflow. Matt's `implement` is a primary real-world integration target because it matches common ticket/spec-driven development usage, but it is not a Delegent runtime dependency. Controlled evaluation may instead use the repository-local `delegent-eval-workflow` to isolate Delegent orchestration from external workflow behavior.

## Preserve the selected workflow

Follow the companion workflow's instructions and completion gates in full. Do not weaken, skip, replace, or reconstruct its required testing, review, or completion steps merely because work is delegated.

Before assigning significant work:

1. verify that the explicitly selected companion workflow is actually available and load its instructions;
2. load and follow the `delegating-work` skill.

If the companion workflow is unavailable, stop with a setup error. Do **not** invent, approximate, or fall back to guessed workflow semantics. If `delegating-work` is unavailable, stop rather than inventing a replacement routing policy.

## Orchestration loop

1. Identify the selected workflow, user outcome, fixed decisions, mutation scope, and success criteria.
2. Keep user intent, architecture, public contracts, schema semantics, security-sensitive choices, irreversible decisions, and final acceptance with the Lead.
3. For each other significant work unit, apply `delegating-work` before acting.
4. When work is delegated, follow its Worker-memory policy to reuse a trustworthy existing Worker or choose a fresh Worker.
5. Dispatch only the compact task contract required by `worker-contract.md`; do not forward the Lead's whole conversation or broad repository context.
6. If the Worker returns `DECISION_NEEDED`, the Lead resolves the decision from the supplied evidence and sends only the decision and necessary constraints back to the same Worker when continuity remains useful.
7. When a Worker completes, consume its compact handoff. Inspect the reported evidence and `REVIEW_TARGETS` as needed; do not repeat broad Worker exploration merely to reconstruct its intermediate context.
8. Continue until the selected workflow's own completion gates are satisfied.
9. The Lead performs final acceptance. Final acceptance cannot be delegated away.

## Context firewall

The Lead should retain strategic context: intent, requirements, decisions, risks, Worker summaries, and acceptance state.

Workers should retain execution context: repository exploration, source relationships, test/debug history, logs, and implementation attempts.

A Worker may use large intermediate context, but its handoff must stay concise and evidence-oriented.

The Context Firewall is not only a prompt convention. The Worker adapter must eventually provide a structured transport boundary that separates Worker trajectory from the terminal handoff and rejects malformed protocol output before it reaches Lead context.

## Worker runtime

`delegating-work` owns placement and Worker-selection policy. Provider- and harness-specific execution belongs to the configured Worker adapter. In this repository, that adapter is documented under `../delegating-work/references/worker-agent.md` and currently uses OpenCode with Nemotron.

Treat Worker-adapter code that loads credentials, constructs provider process state, parses Worker protocol output, or controls session storage as **security-sensitive runtime code**. A Worker may perform read-only diagnosis of that code, but mutation requires explicit Lead ownership and Lead review. Do not allow a general build Worker to rewrite credential-loading or protocol-boundary code autonomously.

Do not hardcode provider/model behavior into workflow reasoning when the abstract Worker contract is sufficient.

## Independence

Reuse implementation Workers when continuity is valuable. Prefer a fresh Worker when independent judgment is the point of the work, such as independent code review, security review, spec-compliance review, second opinion, or root-cause verification.

Delegation does not imply parallelism. Parallelize only after `delegating-work` establishes that work units are independent.
