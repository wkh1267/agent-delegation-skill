# Spec: Delegent — Context-Aware Coding-Agent Orchestration

## 1. Overview

Delegent is a user-invoked orchestration skill that composes an existing engineering workflow with context-aware delegation.

The intended user experience is:

```text
$delegent $implement

架構已確認，請實作 reminder retry。
- retry 最多 3 次
- 不改 lease semantics
- 補 regression tests
```

The user chooses **what workflow to run** and **what outcome is needed**. Delegent decides:

- which significant work units stay with the Lead;
- which work units move to a Worker;
- whether to reuse an existing Worker or start a fresh one;
- when a Worker must escalate to the Lead;
- what information is allowed to cross the context boundary;
- when the workflow is ready for final Lead acceptance.

Initial target environment:

- **Lead:** Codex / GPT-5.6 Sol high or xhigh
- **Workflow skills:** Matt Pocock skills such as `implement`, `code-review`, `diagnosing-bugs`, and `research`
- **Worker harness:** OpenCode
- **Worker model:** NVIDIA Nemotron 3 Super 120B
- **Worker context:** large-context execution workspace
- **Delegation inspiration:** Spellbook `dispatching-parallel-agents`
- **Runtime design inspiration:** NVIDIA NeMo Switchyard affinity, subagent routing, escalation, and observability patterns

The core optimization is not:

> easy task → cheap model; hard task → expensive model

It is:

> **decision-heavy work → Lead**  
> **context-heavy / execution-heavy work → Worker**

The central question is:

> **Where should this work live?**

Possible answers are:

1. Lead context
2. Existing persistent Worker context
3. Fresh Worker context
4. Persistent project memory

---

## 2. Product Model

Delegent is the top-level orchestrator. `delegating-work` is an internal reusable placement policy. OpenCode/Nemotron is the current Worker runtime.

```text
User
  │
  │ $delegent $implement
  ▼
Delegent
  │  owns orchestration and workflow completion
  ├──────────────────────────────┐
  │                              │
  ▼                              ▼
workflow skill              delegating-work
(e.g. implement)            placement policy
  │                              │
  └──────────────┬───────────────┘
                 ▼
           significant work unit
                 │
          ┌──────┴──────┐
          ▼             ▼
        Lead          Worker
      Codex/Sol        OpenCode
                         │
                         ▼
                      Nemotron
                         │
                         ▼
                 compressed handoff
                         │
                         ▼
                      Delegent
                         │
                         ▼
                  Lead acceptance
```

### 2.1 Delegent

Delegent is a **user-invoked orchestration skill**. When invoked alongside one workflow skill, it preserves that workflow's semantics while controlling ownership, Worker continuity, escalation, handoff, and final acceptance.

V0.1 supports:

```text
$delegent + exactly one workflow skill
```

Examples:

```text
$delegent $implement
$delegent $code-review
$delegent $diagnosing-bugs
$delegent $research
```

Multi-workflow composition is a future feature.

### 2.2 `delegating-work`

`delegating-work` is not the product entry point. It is the policy layer used by Delegent to decide where each significant work unit belongs.

It owns:

- Lead ownership gates
- context-value routing
- dispatch-overhead routing
- safe parallelism rules
- Worker-selection policy hooks

It does **not** own:

- the selected engineering workflow;
- OpenCode-specific invocation details;
- NVIDIA/Nemotron-specific configuration;
- session persistence implementation;
- model-level routing.

### 2.3 Worker runtime

The current Worker adapter is:

```text
Delegent / delegating-work
        ↓
Nemotron worker wrapper
        ↓
OpenCode
        ↓
NVIDIA NIM
        ↓
Nemotron 3 Super
```

The policy layer should continue to refer to an abstract `Worker`; provider- and harness-specific behavior belongs in the Worker adapter/runtime.

---

## 3. Problem

Codex Lead has stronger high-impact reasoning but repository-scale work can fill its context with low-reuse intermediate information:

- source files;
- repository searches;
- dependency tracing;
- test output;
- logs;
- debugging attempts;
- generated files;
- repetitive implementation details.

Those details are often necessary to execute a task but unnecessary for future Lead decisions.

Without delegation:

```text
Lead context
├─ user intent
├─ architecture
├─ source-file exploration
├─ grep/search output
├─ test output
├─ debugging attempts
├─ implementation history
└─ final review
```

Desired Lead context:

```text
Lead context
├─ user intent
├─ requirements
├─ architecture
├─ important decisions
├─ compressed Worker findings
├─ risks
└─ final acceptance
```

The system therefore creates a **Context Firewall**: Workers may consume large intermediate context, while the Lead receives only high-value results and evidence.

---

## 4. Goals

### G1. Preserve Lead context

Lead context growth should be roughly proportional to important decisions, not total codebase work.

### G2. Preserve workflow semantics

Delegent must not silently replace or weaken the selected workflow skill. If `$implement` requires implementation, testing, review, and completion gates, Delegent must preserve them while deciding who performs each unit.

### G3. Delegate context-heavy work

Prefer Workers for:

- repository exploration;
- broad or large-file reading;
- dependency tracing;
- implementation of approved designs;
- routine refactoring;
- test generation and execution;
- debugging and log analysis;
- documentation;
- mechanical migrations;
- independent verification.

### G4. Keep high-impact decisions with the Lead

Lead owns:

- user intent and ambiguous requirements;
- high-level planning;
- architecture;
- public API semantics;
- database/schema semantics;
- security-sensitive decisions;
- irreversible or high-blast-radius decisions;
- conflicting requirements;
- final acceptance.

### G5. Reuse valuable Worker context

A Worker that has already built an expensive mental model of a subsystem should be reused for related follow-up work when that context remains trustworthy.

### G6. Preserve independent judgment

Fresh Workers should be preferred for work where prior assumptions are harmful, including:

- independent code review;
- security review;
- spec-compliance review;
- second opinions;
- root-cause verification;
- challenges to an existing architecture.

### G7. Escalate based on boundaries and trajectory

Workers must immediately escalate Lead-owned decisions. Later versions should also escalate when execution trajectory indicates repeated failure, spinning, or loss of progress.

---

## 5. Non-Goals for V0.1

V0.1 does not attempt to build:

- a generic multi-provider model router;
- a large Worker pool;
- a complex task DAG scheduler;
- automatic worktree/merge orchestration;
- distributed Workers;
- autonomous long-running project management;
- per-turn strong/weak model switching inside one shared conversation.

Model-level routing may later be delegated to a system such as Switchyard, but it is separate from Delegent's work-unit routing.

---

## 6. Workflow Composition

Delegent composes with an existing workflow rather than replacing it.

Example with `implement`:

```text
$delegent $implement
        │
        ▼
understand task / fixed decisions
        │
        ▼
Delegent identifies work units
        │
        ├─ architecture ambiguity ─────────→ Lead
        │
        ├─ repository exploration ────────→ Worker
        │
        ├─ approved implementation ───────→ same Worker
        │
        ├─ test/debug loop ───────────────→ same Worker
        │
        ├─ Lead-owned blocker ────────────→ Lead decision
        │                                  │
        │                                  └→ Worker resumes
        │
        ├─ independent review ─────────────→ fresh Worker when useful
        │
        └─ final acceptance ───────────────→ Lead
```

Delegent should not require the user to manually say "send implementation to Nemotron". That is acceptable for smoke testing but is not the target UX.

---

## 7. Core Placement Policy

Every significant work unit passes through these gates.

### Stage 1 — Lead Ownership Gate

Ask:

> Does the Lead need to own this decision?

Keep with Lead when the work determines:

- user intent;
- ambiguous requirements;
- architecture;
- public contracts;
- schema semantics;
- security posture;
- irreversible/high-blast-radius behavior;
- conflicting requirements;
- final acceptance.

If yes, stop routing and keep the work with Lead.

### Stage 2 — Context Value Gate

Ask:

> Does the Lead need the intermediate context, or only the verified result?

Delegate when intermediate searches, reading, logs, test output, implementation attempts, or debugging history are disposable to the Lead.

### Stage 3 — Dispatch Overhead Gate

Do not delegate trivial known local work when dispatch cost exceeds execution cost.

Examples:

- one targeted small-file lookup;
- one known symbol inspection;
- a trivial local edit whose context is already loaded.

### Stage 4 — Parallelism Gate

Delegation does not imply parallelism. Parallelize only when tasks:

- are independently understandable;
- do not edit the same files;
- do not share mutable state;
- do not depend on each other's result.

Unknown-scope exploration begins with one Worker. Fan out only after independent domains are known.

---

## 8. Worker Selection and Affinity

Once work is delegated, the next decision is:

> Which Worker context should own it?

This decision is separate from Lead-vs-Worker placement.

### 8.1 Reuse an existing Worker

Reuse when:

- the same subsystem or feature remains in scope;
- implementation continues into testing/debugging;
- follow-up work benefits from prior exploration;
- prior context remains relevant and trustworthy.

### 8.2 Start a fresh Worker

Start fresh when:

- the subsystem is unrelated;
- independent judgment is required;
- the old Worker is confused;
- its context is too stale to resynchronize cheaply;
- its context is near a practical quality/size limit;
- the task scope changed substantially.

### 8.3 Assignment pinning

Once a work thread owns a useful Worker context, reuse that Worker until an invalidation condition fires. Do not re-route every turn merely because the generic policy would choose a different fresh Worker.

This separation follows the Switchyard pattern:

```text
placement policy → which execution context should own work
memory/affinity policy → how long that assignment should live
```

See `migration-spec.md` for source-code provenance.

---

## 9. Worker Identity and Registry

Policy is already documented; automatic runtime affinity requires a Worker registry.

Minimum future identity:

```text
WorkerIdentity {
  project
  role
  scope
  worker_id
  session_id
  last_sync_commit
  last_task
  status
  last_used_at
}
```

Example:

```text
project: personal-assistant-backend
role: implementation
scope: scheduler
worker_id: scheduler-primary
session_id: <opencode-session>
last_sync_commit: 92ac371
status: active
```

Lifecycle states should include at least:

```text
active | stale | retired | invalid
```

V0.1 may use manual session selection; automatic registry-driven affinity is the next runtime milestone.

---

## 10. Memory Model

### 10.1 Lead Memory

Lives in Codex context and contains:

- intent;
- requirements;
- plans;
- architectural decisions;
- compressed Worker results;
- unresolved decisions;
- risks;
- acceptance state.

It should normally not contain broad source dumps, raw logs, complete test output, or Worker debugging history.

### 10.2 Worker Working Memory

Lives in the OpenCode/Nemotron session and contains:

- detailed repository understanding;
- file relationships;
- implementation context;
- test/debug history;
- temporary hypotheses.

### 10.3 Persistent Project Memory

Stable, expensive-to-rediscover facts may be persisted in repository artifacts. Persist invariants and durable architecture knowledge, not raw logs or easy-to-recover source summaries.

---

## 11. Worker Staleness and Resynchronization

Before reusing a persistent Worker:

```text
last_sync_commit
      ↓
compare with current HEAD
      ↓
inspect relevant changes
      ↓
refresh affected mental model
      ↓
continue
```

Do not reread the whole repository unless changed code invalidates prior understanding.

The current runtime does not yet persist `last_sync_commit`; this is a planned Worker-registry feature.

Read-only Workers should eventually be allowed narrowly scoped read-only Git operations such as status/log/diff/rev-parse so they can resynchronize safely.

---

## 12. Worker Dispatch Contract

Routing and execution should receive a compact task contract rather than the Lead's entire conversation.

Minimum dispatch information:

```text
TASK
What must be accomplished.

SCOPE
Subsystem and mutation boundaries.

DECISIONS
Already-fixed architectural/product decisions.

CONSTRAINTS
Behavior that must be preserved.

FORBIDDEN
Decisions or files the Worker may not change.

SUCCESS
Observable verification criteria.
```

This prevents accidental context leakage and keeps Worker startup focused.

---

## 13. Worker Handoff Contract

Normal handoff:

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

The Worker must not return:

- entire source files;
- giant logs;
- hidden reasoning;
- complete repository maps;
- irrelevant failed attempts.

Target principle:

> A Worker may consume hundreds of thousands of tokens internally while the Lead receives only the compact evidence needed for decisions and review.

---

## 14. Escalation

### 14.1 Hard escalation — V0.1

A Worker must stop and escalate immediately when it encounters:

- architecture ambiguity;
- public API behavior changes;
- schema semantics;
- security-sensitive behavior;
- conflicting requirements;
- destructive/irreversible choices.

Return:

```text
DECISION_NEEDED
Question:
Evidence:
Options:
Recommendation:
Confidence:
```

Lead decides; the existing Worker should resume when continuity remains useful.

### 14.2 Trajectory escalation — future

Borrowing the pattern from Switchyard, a single recoverable failure should not automatically escalate. Repeated or corroborated failure may trigger escalation based on observable execution signals.

Potential signals:

- repeated same error;
- repeated failed fix/test cycles;
- long periods without productive writes/edits;
- contradictory Worker conclusions;
- context compaction/quality degradation;
- Worker explicitly reporting low confidence.

Exact thresholds must be calibrated on Delegent workloads; Switchyard's numeric thresholds must not be copied blindly.

---

## 15. Observability and Decision Provenance

Every significant routing decision should eventually record:

```text
task_id
workflow
owner: lead | worker
decision_source
reason
worker_id
memory_action: reuse | fresh | none
result: success | blocked | escalated
escalation_reason
```

Suggested stable decision sources:

```text
hard_lead_boundary
context_heavy
dispatch_overhead
worker_affinity
fresh_independence
parallel_independence
worker_escalation
fallback
```

This follows Switchyard's useful pattern of recording not only a decision but **which component produced it**.

---

## 16. Switchyard-Derived Design Rules

`migration-spec.md` is the provenance/reference document. The authoritative product requirements remain in this `spec.md`.

The adopted design rules are:

1. **Separate placement from affinity.** Deciding Lead vs Worker is different from deciding how long a Worker assignment lives.
2. **Distinguish delegated work from Worker maintenance.** Sync, compact, registry maintenance, and shutdown are not new engineering work units.
3. **Use stable Worker identity.** Worker continuity requires project/scope/role/session identity rather than a raw session ID alone.
4. **Classify/dispatch a compact delegated task.** Do not send the entire Lead conversation merely to route or start a Worker.
5. **Use hard deterministic boundaries before fuzzy judgment.** Security/API/schema/architecture boundaries are not probabilistic.
6. **Escalate from observed trajectory, not task size alone.** A Worker gets a chance to recover from ordinary failures.
7. **Compress escalation and handoff context.** The Context Firewall applies during failure as well as success.
8. **Record decision provenance.** Routing must be explainable and later calibratable.
9. **Give runtime memory a lifecycle.** Persistent Workers must support resync, invalidation, retirement, and eventual cleanup.

Explicit non-migrations:

- Switchyard's per-turn strong/weak stage mapping;
- its proxy/protocol translation layer;
- its assumption that exploration should route to a stronger tier;
- its exact thresholds and TTLs.

---

## 17. Repository Structure

Target structure:

```text
skills/
├─ delegent/
│  └─ SKILL.md
│
└─ delegating-work/
   ├─ SKILL.md
   ├─ opencode.json
   ├─ references/
   │  ├─ routing-policy.md
   │  ├─ worker-memory.md
   │  ├─ worker-contract.md
   │  ├─ worker-agent.md
   │  └─ escalation-policy.md        # future / when trajectory policy lands
   └─ scripts/
      └─ nemotron-worker.ps1

spec.md
migration-spec.md
```

Responsibilities:

```text
Delegent
→ orchestration entry point and workflow completion

delegating-work
→ work-unit placement and Worker-selection policy

worker-agent / scripts / opencode.json
→ how the configured Worker is executed

migration-spec.md
→ external design provenance and adopt/adapt/reject rationale
```

---

## 18. Current Implementation Status

As of the current repository state:

### Implemented

- `delegating-work` Lead-vs-Worker policy
- context-value and dispatch-overhead gates
- safe-parallelism guidance
- Worker reuse vs fresh policy
- compressed Worker contract and hard decision escalation
- OpenCode/Nemotron configuration
- PowerShell Worker wrapper
- manual OpenCode session reuse

### Partial / policy-only

- Worker staleness resynchronization
- persistent Worker memory lifecycle
- project memory conventions

### Not yet implemented

- `skills/delegent/SKILL.md` orchestration entry point
- automatic Worker registry / affinity
- automatic `last_sync_commit` tracking
- trajectory-based escalation
- routing telemetry/evaluation logging
- multi-worker parallel runtime
- evaluation suite

---

## 19. V0.1 Scope From This Point

V0.1 should now mean **a usable Delegent orchestration loop**, not merely a routing document.

Required milestones:

1. Add `skills/delegent/SKILL.md`.
2. Support the UX `$delegent $<one-workflow>`.
3. Preserve the selected workflow's semantics.
4. Use `delegating-work` to choose Lead vs Worker per significant work unit.
5. Invoke the existing OpenCode/Nemotron Worker path.
6. Support manual or deterministic session reuse without losing the Context Firewall.
7. Enforce Worker handoff and hard escalation contracts.
8. Keep final acceptance with Lead.
9. Run representative end-to-end smoke/evaluation tasks.

Automatic Worker registry and trajectory escalation may land immediately after this core loop if they are not necessary for the first end-to-end test.

---

## 20. Validation

Collect 10–20 representative engineering tasks, including:

1. broad repository exploration;
2. a high-impact architecture decision;
3. approved implementation;
4. multi-file mechanical refactor;
5. test/debug loop;
6. security-sensitive decision boundary;
7. same-subsystem follow-up that should reuse a Worker;
8. unrelated work that should create a fresh Worker;
9. independent code review;
10. Worker failure requiring escalation.

Record:

```text
workflow
expected owner
actual owner
expected memory action
actual memory action
Lead duplicated Worker exploration?
handoff sufficient?
escalation correct?
task succeeded?
Lead context burden
```

Useful evaluation quadrants adapted from Switchyard:

```text
DELEGATE_SAFE
Worker succeeds and Lead intervention is unnecessary.

DELEGATE_LOSS
Worker fails where Lead ownership would likely have succeeded.

CONTEXT_RESCUE
Worker succeeds while avoiding substantial disposable Lead context.

HARD
Neither ownership strategy succeeds cleanly.
```

---

## 21. Success Criteria

V0.1 succeeds when:

### Workflow

- `$delegent $<workflow>` has a predictable meaning;
- the selected workflow's completion requirements are preserved;
- Lead remains responsible for final acceptance.

### Routing

- context-heavy work is consistently delegated;
- high-impact decisions remain with Lead;
- trivial tasks are not excessively delegated.

### Context Firewall

- Lead avoids broad repository exploration when a Worker can do it;
- Worker trajectory/log/test noise does not flood Lead context;
- handoffs contain enough evidence to review results.

### Memory

- related follow-up work can reuse a Worker;
- independent review can deliberately use a fresh Worker;
- stale context is detected or conservatively invalidated.

### Safety / quality

- Workers escalate Lead-owned decisions;
- Worker mutation scope is respected;
- final acceptance cannot be delegated away.

---

## 22. Future Versions

### V0.2

- Worker registry and stable Worker identities
- automatic session lookup/reuse
- Git-based resynchronization and `last_sync_commit`
- trajectory failure signals and escalation
- decision-source logging

### V0.3

- multiple persistent subsystem Workers
- parallel independent Workers
- worktree isolation
- automatic fresh reviewer Workers
- evaluation dashboards/metrics

### V0.4

- optional model/provider routing below the Worker layer
- Switchyard evaluation as a Worker-side model router
- adaptive routing/escalation thresholds based on observed outcomes

---

## 23. Design Principle

The system optimizes where context and judgment live:

```text
Lead   = strategic memory + high-impact judgment
Worker = repository context + execution memory
Repo   = durable project knowledge
Delegent = orchestration across those boundaries
```

The user chooses **what workflow to run**. Delegent decides **where each unit of work should live** while preserving workflow semantics, Worker continuity, the Context Firewall, and Lead ownership of consequential decisions.