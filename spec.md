# Spec: Delegent — Context-Aware Coding-Agent Orchestration

## 1. Overview

Delegent is a user-invoked orchestration skill that composes one explicitly selected engineering workflow with context-aware delegation.

Target UX:

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
- whether to reuse an existing Worker or start fresh;
- when a Worker must escalate;
- what information may cross the context boundary;
- when the selected workflow is ready for Lead acceptance.

Initial environment:

- **Lead:** Codex / GPT-5.6 Sol high or xhigh
- **Workflow skills:** Matt Pocock skills such as `implement`, `code-review`, `diagnosing-bugs`, and `research`
- **Worker harness:** OpenCode
- **Worker model:** NVIDIA Nemotron 3 Super 120B
- **Delegation inspiration:** Spellbook `dispatching-parallel-agents`
- **Runtime design inspiration:** NVIDIA NeMo Switchyard affinity, subagent routing, escalation, and observability patterns

The core optimization is not:

> easy task → cheap model; hard task → expensive model

It is:

> **decision-heavy work → Lead**  
> **context-heavy / execution-heavy work → Worker**

The central question is:

> **Where should this work live?**

---

## 2. Product Model

```text
User
  │
  │ $delegent $implement
  ▼
Delegent
  │  orchestration + workflow completion
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

`skills/delegent/SKILL.md` is the top-level, user-invoked orchestration entry point.

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

The selected workflow owns **what must happen**. Delegent owns **where each significant unit lives**, Worker continuity, escalation, Context Firewall enforcement, and final workflow completion.

Multi-workflow composition is a future feature.

### 2.2 `delegating-work`

`skills/delegating-work/SKILL.md` is an internal reusable placement policy, not the product entry point.

It owns:

- Lead ownership gates;
- context-value routing;
- dispatch-overhead routing;
- safe-parallelism rules;
- Worker-selection hooks.

It does not own the selected workflow, OpenCode invocation, provider configuration, or model-level routing.

### 2.3 Worker runtime

The current Worker adapter is:

```text
Delegent / delegating-work
        ↓
nemotron-worker.ps1
        ↓
OpenCode
        ↓
NVIDIA NIM
        ↓
Nemotron 3 Super
```

Provider- and harness-specific behavior stays below the policy layer.

---

## 3. Problem and Context Firewall

Repository-scale engineering produces large amounts of low-reuse intermediate context:

- source-file exploration;
- repository searches;
- dependency tracing;
- test output;
- logs;
- debugging attempts;
- repetitive implementation details.

The Lead should instead preserve high-value strategic context:

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

Workers may consume large intermediate context, but only compact results and evidence should cross back to the Lead. This boundary is the **Context Firewall**.

---

## 4. Goals

1. **Preserve Lead context.** Lead context growth should track important decisions, not total repository work.
2. **Preserve workflow semantics.** Delegation must not weaken the selected workflow's testing, review, or completion requirements.
3. **Delegate context-heavy execution.** Exploration, approved implementation, routine refactoring, tests, debugging, logs, and verification should usually live with Workers.
4. **Keep consequential judgment with Lead.** Intent, architecture, public APIs, schema semantics, security, irreversible choices, and final acceptance stay with Lead.
5. **Reuse expensive Worker understanding.** Same-subsystem follow-up should reuse a trustworthy Worker when continuity is valuable.
6. **Preserve independent judgment.** Review, security analysis, second opinion, and root-cause verification should prefer fresh context when prior assumptions are harmful.
7. **Escalate safely.** Hard Lead-owned boundaries escalate immediately; trajectory-based failure escalation is a later runtime feature.

---

## 5. Non-Goals for V0.1

V0.1 does not build:

- a generic multi-provider model router;
- a large Worker pool;
- a complex task DAG scheduler;
- automatic worktree/merge orchestration;
- distributed Workers;
- autonomous long-running project management;
- per-turn strong/weak model switching in one shared conversation.

Switchyard may later be evaluated below the Worker layer for model-level routing, but it does not replace Delegent's work-unit/context routing.

---

## 6. Workflow Composition

Delegent preserves the companion workflow and assigns ownership inside it.

Example:

```text
$delegent $implement
        │
        ▼
understand task / fixed decisions
        │
        ├─ architecture ambiguity ─────────→ Lead
        ├─ repository exploration ────────→ Worker
        ├─ approved implementation ───────→ same Worker
        ├─ test/debug loop ───────────────→ same Worker
        ├─ Lead-owned blocker ────────────→ Lead decision
        │                                  └→ same Worker resumes
        ├─ independent review ─────────────→ fresh Worker when useful
        └─ final acceptance ───────────────→ Lead
```

The target UX does not require the user to say "send implementation to Nemotron". The user selects the workflow; Delegent performs placement.

---

## 7. Placement Policy

Every significant work unit follows these gates in order.

### 7.1 Lead Ownership Gate

Keep with Lead when the work determines:

- user intent or ambiguous requirements;
- architecture;
- public contracts;
- schema semantics;
- security posture;
- irreversible/high-blast-radius behavior;
- conflicting requirements;
- final acceptance.

### 7.2 Context Value Gate

Ask:

> Does the Lead need the intermediate context, or only the verified result?

Delegate when searches, broad reading, logs, test output, implementation attempts, or debugging history are disposable to future Lead decisions.

### 7.3 Dispatch Overhead Gate

Do not delegate trivial known local work when dispatch overhead exceeds the context savings.

### 7.4 Parallelism Gate

Delegation does not imply parallelism. Parallelize only independent tasks that do not edit the same files, share mutable state, or depend on each other's findings. Unknown-scope exploration begins with one Worker.

---

## 8. Worker Selection and Affinity

Lead-vs-Worker placement and Worker-memory affinity are separate decisions.

### Reuse an existing Worker when

- the same subsystem or feature remains in scope;
- implementation continues into testing/debugging;
- follow-up work benefits from prior exploration;
- prior context remains relevant and trustworthy.

### Start a fresh Worker when

- the subsystem is unrelated;
- independent judgment is required;
- old context is confused or too stale;
- the context is near a practical quality/size limit;
- task scope changed substantially.

### V0.1 deterministic affinity

Automatic registry-driven affinity is not yet implemented. Reusable OpenCode sessions use a stable title:

```text
delegent:<project>:<scope>:<role>
```

Example:

```text
delegent:personal-assistant-backend:scheduler:build
```

Session discovery must go through the Worker wrapper so it uses the same OpenCode storage roots:

```powershell
nemotron-worker.ps1 sessions --format json
```

A title match is only a candidate. Reuse still requires scope/role fit and a staleness check.

This design follows the Switchyard pattern that assignment policy and affinity lifetime are separate concerns. See `migration-spec.md` for provenance.

---

## 9. Worker Identity and Future Registry

A future automatic Worker registry should track at least:

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

Lifecycle states:

```text
active | stale | retired | invalid
```

V0.1 uses title-based session discovery. V0.2 should replace this with registry-driven lookup and automatic `last_sync_commit` tracking.

---

## 10. Memory Model

### Lead memory

Contains intent, requirements, plans, architectural decisions, compressed Worker results, unresolved decisions, risks, and acceptance state.

### Worker working memory

Lives in the OpenCode/Nemotron session and contains detailed repository understanding, file relationships, implementation context, test/debug history, logs, and temporary hypotheses.

### Persistent project memory

Persist only stable, expensive-to-rediscover facts such as invariants and durable architecture decisions. Do not persist raw logs, failed hypotheses, or easy-to-recover source summaries.

---

## 11. Staleness and Resynchronization

Before reusing a Worker:

```text
last_sync_commit
        ↓
compare with current HEAD
        ↓
inspect the complete changed-path set
        ↓
refresh affected mental model
        ↓
continue
```

The `plan` Worker is read-only but may use narrowly allowed Git commands:

```text
git status
git log
git diff
git show
git rev-parse
```

Exact staleness detection requires the Worker's actual `last_sync_commit`. Arbitrary heuristics such as `HEAD~N` are not equivalent because they do not prove what changed since that Worker last synchronized. Evidence scope must also match conclusion scope: inspecting only one changed file is not enough to make a repository-wide staleness claim.

The runtime does not yet persist `last_sync_commit`; this is now a validated V0.2 functional requirement rather than only an optimization. When an exact baseline is unavailable in V0.1, resynchronize conservatively rather than inventing one.

---

## 12. Worker Dispatch Contract

Delegent sends a compact task contract rather than the Lead's full conversation:

```text
TASK:
What must be accomplished.

SCOPE:
Relevant subsystem and mutation boundaries.

DECISIONS:
Already-fixed architectural/product/workflow decisions.

CONSTRAINTS:
Behavior and invariants that must be preserved.

FORBIDDEN:
Decisions, files, or changes the Worker may not make.

SUCCESS:
Observable verification criteria.
```

Do not pre-read a repository broadly merely to prepare this contract. If broad exploration belongs to the Worker, let the Worker perform it in its own context.

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

Every field is required exactly once. Use `none` only when a field genuinely does not apply.

Workers must not return entire source files, giant logs, hidden reasoning, complete repository maps, or irrelevant failed attempts.

The Lead may inspect specific `REVIEW_TARGETS` and evidence as needed, but should not repeat broad Worker exploration just to reconstruct the Worker's intermediate context.

---

## 14. Escalation

### Hard escalation — V0.1

A Worker immediately stops and escalates when it encounters:

- architecture ambiguity;
- public API behavior change;
- schema semantics;
- security-sensitive behavior;
- conflicting requirements;
- destructive or irreversible choices.

Return:

```text
DECISION_NEEDED
Question:
Evidence:
Options:
Recommendation:
Confidence:
```

Lead resolves the decision. Reuse the existing Worker afterward when continuity remains useful.

### Trajectory escalation — future

Repeated same errors, failed fix/test loops, prolonged unproductive activity, contradictory conclusions, context-quality degradation, or explicit low confidence may later trigger escalation. Exact thresholds must be calibrated on Delegent workloads rather than copied from Switchyard.

---

## 15. Switchyard-Derived Rules

`migration-spec.md` is the provenance/reference document. This `spec.md` remains authoritative for product behavior.

Adopted/adapted rules:

1. separate placement from affinity;
2. distinguish delegated work from Worker maintenance;
3. use stable Worker identity;
4. dispatch compact delegated prompts rather than full Lead context;
5. use hard deterministic boundaries before fuzzy judgment;
6. escalate from observed trajectory rather than task size alone;
7. compress escalation/handoff context;
8. record decision provenance in later telemetry;
9. give runtime memory a lifecycle.

Explicit non-migrations:

- Switchyard per-turn strong/weak stage mapping;
- proxy/protocol translation as a Delegent concern;
- the assumption that exploration should route to the stronger tier;
- Switchyard's exact thresholds or TTLs.

---

## 16. Repository Structure

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
   │  └─ worker-agent.md
   └─ scripts/
      └─ nemotron-worker.ps1

evals/
└─ v0.1-smoke.md

README.md
spec.md
migration-spec.md
```

Responsibilities:

```text
Delegent
→ orchestration entry point + workflow completion

delegating-work
→ work-unit placement + Worker-selection policy

worker-agent / scripts / opencode.json
→ configured Worker execution

evals
→ repeatable routing/orchestration validation

migration-spec.md
→ external design provenance + adopt/adapt/reject rationale
```

---

## 17. Current Implementation Status

### Implemented

- `skills/delegent/SKILL.md` orchestration entry point
- `$delegent $<one-workflow>` composition contract
- `delegating-work` Lead-vs-Worker placement policy
- context-value and dispatch-overhead gates
- safe-parallelism guidance
- Worker reuse vs fresh policy
- compact Worker dispatch contract
- compressed handoff contract
- hard Lead-owned decision escalation
- OpenCode/Nemotron configuration
- read-only `plan` and mutating `build` Worker roles
- PowerShell Worker wrapper
- wrapper-scoped OpenCode session discovery
- manual/deterministic session reuse via stable titles
- narrowly allowed read-only Git resynchronization commands
- V0.1 smoke-evaluation matrix
- development installation/usage README

### Validated by direct-Worker smoke tests

- OpenCode -> NVIDIA NIM -> Nemotron `plan` Worker execution
- plan permission enforcement and recovery from a denied general-shell attempt
- compact Worker handoff / Context Firewall output behavior
- same-session follow-up continuity and reuse-policy behavior
- read-only Git resynchronization primitives
- targeted refresh without broad repository rereading

### Fixes applied from smoke findings; re-test required

- Worker prompts now explicitly require every handoff field exactly once after one follow-up omitted `CHANGES`, `TESTS`, and `RISKS`
- the `plan` prompt now explicitly prefers native read/search tools and avoids general shell listing attempts such as `ls -la`

### Partial / policy-only

- Worker staleness resynchronization: Git primitives work, but exact baseline detection is incomplete because `last_sync_commit` is not persisted
- persistent Worker lifecycle
- persistent project-memory conventions

### Not yet implemented / not yet validated

- full Codex Lead -> `$delegent $workflow` -> Worker -> compact handoff -> Lead acceptance loop has not yet been validated end to end
- automatic Worker registry / affinity
- automatic `last_sync_commit` tracking
- trajectory-based escalation
- routing telemetry/evaluation logging
- multi-Worker parallel runtime
- automated evaluation runner

---

## 18. V0.1 Acceptance

V0.1 should be considered usable when representative tasks in `evals/v0.1-smoke.md` demonstrate:

- `$delegent $<workflow>` has predictable semantics;
- workflow completion requirements are preserved;
- high-impact decisions stay with Lead;
- context-heavy execution moves to Workers;
- related follow-up can deliberately reuse a Worker;
- independent review can deliberately start fresh;
- hard decision escalation works;
- Worker trajectory/log noise stays behind the Context Firewall;
- final acceptance remains with Lead.

Current direct-Worker status:

```text
OpenCode/NIM/Nemotron execution        PASS
plan permission enforcement           PASS
compact handoff / Context Firewall    PASS
same-session continuity               PASS
reuse-policy behavior                 PASS
read-only Git resync primitives       PASS
targeted refresh                      PASS
handoff completeness fix              APPLIED; RE-TEST NEEDED
exact staleness baseline              PARTIAL; V0.2 REGISTRY REQUIRED
full Delegent orchestration           NOT YET VALIDATED
```

Useful evaluation quadrants adapted from Switchyard:

```text
DELEGATE_SAFE
Worker succeeds; Lead intervention is unnecessary.

DELEGATE_LOSS
Worker fails where Lead ownership would likely have succeeded.

CONTEXT_RESCUE
Worker succeeds while avoiding substantial disposable Lead context.

HARD
Neither ownership strategy succeeds cleanly.
```

---

## 19. Next Milestones

### Immediate V0.1 validation

- re-test complete handoff after prompt tightening
- validate the actual Codex Lead -> `$delegent $implement` -> Worker -> handoff -> Lead acceptance path
- validate a fresh independent review Worker
- validate hard decision escalation through the top-level orchestration loop

### V0.2

- automatic Worker registry and stable Worker identities
- automatic session lookup/reuse
- Git-based resynchronization with persisted `last_sync_commit`
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

## 20. Design Principle

```text
Lead     = strategic memory + high-impact judgment
Worker   = repository context + execution memory
Repo     = durable project knowledge
Delegent = orchestration across those boundaries
```

The user chooses **what workflow to run**. Delegent decides **where each significant unit should live** while preserving workflow semantics, Worker continuity, the Context Firewall, and Lead ownership of consequential decisions.
