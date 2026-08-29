---
name: delegating-work
description: Decide where significant engineering work should live before acting. Use for repository exploration, architecture decisions, approved implementation, debugging, testing, review, or verification to keep high-impact judgment with the lead and move context-heavy work to workers.
---

# Delegating Work

Before each significant unit of engineering work, decide where it should live.

## Keep with the lead

Keep work in the lead context when it owns a high-impact judgment:

- interpreting user intent or ambiguous requirements
- architecture, public API, or schema semantics
- security-sensitive, irreversible, or high-blast-radius choices
- resolving conflicting requirements
- final acceptance

## Delegate

Prefer a worker when the lead needs the result more than the intermediate context:

- broad repository exploration or large-file reading
- dependency tracing, log analysis, or debugging
- implementation of an approved design
- routine refactoring or testing
- independent verification

Keep trivial targeted work with the lead when dispatch would cost more than doing it.

For edge cases, escalation, and safe parallelism, read
[references/routing-policy.md](references/routing-policy.md).

When delegation is chosen, read
[references/worker-memory.md](references/worker-memory.md) to choose an existing
or fresh worker, then follow
[references/worker-contract.md](references/worker-contract.md).

When invoking the configured OpenCode/Nemotron worker, read
[references/worker-agent.md](references/worker-agent.md).
