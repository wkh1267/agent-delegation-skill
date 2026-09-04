# CONTEXT.md

The shared vocabulary of this project. Glossary only — no mechanisms, no
decisions. Decisions live in `docs/decisions/`, gate status in
`evals/next-test-plan.md`.

## Roles

**Lead** — the agent that owns user intent, decomposition, architecture and
public contracts, security-sensitive choices, and final acceptance. Placement is
a Lead decision. Final acceptance is never delegated.

**Worker** — the delegated agent that performs context-heavy work and reports
back. It never decides whether its own output is acceptable.

## The boundary

**Handoff** — the compact, structured report that crosses from Worker to Lead.
Carries the outcome and the evidence for it, never the intermediate reasoning or
the transcript.

**Machine boundary** — the point where a handoff is enforced rather than
requested. A boundary holds because a contract is checked; a model complying
with a prompt is not a boundary, however reliably it complies.

**Context Firewall** — the filtering applied to everything crossing to the Lead,
so a Worker cannot put secrets or bulk detail into the Lead's context.

**Escalation** — a Worker surfacing a choice it must not make alone: one that
touches architecture, security, a public contract, or anything irreversible.

## Continuity

**Affinity** — the identity under which a Worker's accumulated context persists,
so a later turn can build on an earlier one. Written
`delegent:<project>:<scope>:<role>`.

**Reuse** vs **fresh** — whether a task inherits a Worker's prior context.
Implementation continuity wants reuse; independent judgement wants a fresh
Worker, because inherited context biases a review. Always a Lead decision, never
inferred from the task.

## Mutation

**Recoverable capability** — one whose worst outcome can be undone from
information the project already keeps. Writing a file inside a version-controlled
repository is recoverable.

**Unrecoverable capability** — one whose worst outcome cannot be undone.
Executing an arbitrary command is unrecoverable: it runs with the user's
privileges and leaves no record to restore from.

This distinction, not the Worker's trustworthiness, decides what needs
isolating. Two capabilities can carry identical intent and warrant completely
different containment.

**Mutation scope** — the set of paths a Lead declares a Worker may change.
Declared before the work, not inferred from what the Worker did.

**Staging tree** — the isolated copy of the repository a mutating Worker works
in. Named for its role: everything in it is awaiting acceptance. The user's own
working tree is never what a Worker changes, so "nothing outside the scope
moved" holds structurally rather than needing to be proven after the fact.

**Reported changes** — what a Worker says it changed. A claim, not an
observation.

**Observed diff** — what actually changed. Agreement between the mutation
scope, the reported changes, and the observed diff is decidable; any
disagreement names a specific failure rather than needing human judgement.
