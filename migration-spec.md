# Migration Spec: Switchyard-Inspired Patterns for Delegent

## 1. Purpose

This document records **which NVIDIA NeMo Switchyard design patterns Delegent borrows, adapts, or explicitly rejects**, and maps each borrowed idea to concrete Switchyard source code.

This is a provenance and migration-design document, not the authoritative product spec.

Authoritative requirements live in:

```text
spec.md
```

The integrated architecture is:

```text
User
  │
  │ $delegent $implement
  ▼
Delegent                         ← orchestration layer
  │
  ├─ selected workflow
  │
  └─ delegating-work             ← work-unit placement policy
          │
          ├─ Lead
          │    Codex / Sol
          │
          └─ Worker
               OpenCode
                 │
               Nemotron
```

Switchyard is not used as a runtime dependency in V0.1. We borrow its **subagent identity, affinity, escalation, signal, lifecycle, and decision-provenance patterns** where they strengthen our architecture.

---

## 2. Upstream Source Snapshot

Repository:

```text
NVIDIA-NeMo/Switchyard
```

Source snapshot reviewed for this document:

```text
commit: 27fc1ce9ff3846760337fe42ab09c28f5b01c807
```

License:

```text
Apache-2.0
```

Switchyard currently describes itself as pre-alpha overall, with different maturity levels across components. We therefore treat it primarily as a design/reference source.

If future implementation copies or derives source code rather than independently implementing the pattern, preserve the required Apache-2.0 attribution/license obligations and re-check the upstream file at the pinned/relevant revision.

---

## 3. Integration Rule

The previous version of this document treated `delegating-work` as the top-level system. That is no longer the product model.

Use this separation:

```text
Delegent
→ owns orchestration and selected workflow completion

delegating-work
→ decides Lead vs Worker placement and safe parallelism

worker-memory / Worker registry
→ decides which Worker context and how long it remains assigned

Worker adapter
→ invokes OpenCode/Nemotron

migration-spec.md
→ records external design provenance
```

A Switchyard idea should migrate only when it supports one of these layers without destroying the Context Firewall.

---

## 4. Migration Summary

| Switchyard concept | Delegent equivalent | Decision | Target layer | Current status |
| --- | --- | --- | --- | --- |
| Parent vs delegated child routing | Lead vs Worker distinction | **ADOPT / ADAPT** | `delegating-work` | policy implemented |
| Subagent work detection | delegated task vs maintenance | **ADOPT** | Worker runtime | planned |
| Affinity | persistent Worker reuse | **ADOPT + EXTEND** | worker memory/registry | policy implemented; runtime pending |
| Session + agent identity | stable Worker identity | **ADAPT** | Worker registry | pending |
| Assignment pinning | reuse work-thread Worker | **ADOPT** | worker memory/registry | policy implemented; runtime pending |
| Prompt-only child classification | compact dispatch contract | **ADOPT** | Worker contract | partly implemented |
| Escalation streak | repeated-failure escalation | **ADAPT** | escalation policy | pending |
| Trajectory condensation | compressed escalation | **ADOPT** | Worker contract | hard escalation implemented; trajectory form pending |
| Deterministic tool signals | Worker-health signals | **ADAPT** | future runtime | pending |
| Decision-source telemetry | delegation provenance | **ADOPT** | observability | pending |
| Session lifecycle/TTL | Worker lifecycle/retirement | **ADAPT** | Worker registry | pending |
| Context-window fallback | Worker rotation/escalation | **ADAPT conceptually** | future runtime | pending |
| Stage strong/weak routing | per-turn model routing | **DO NOT MIGRATE V0.1** | below Worker layer | rejected for core |
| API protocol proxy | model API translation | **DO NOT MIGRATE V0.1** | optional future model-router layer | out of scope |
| Shared-conversation model switching | same trajectory served by different models | **REJECT for core architecture** | n/a | rejected |

---

# 5. Migration 1 — Separate Placement Policy From Affinity Policy

## Switchyard pattern

Switchyard deliberately separates:

```text
SubagentOverride
→ which target delegated work belongs on

AffinityRouter
→ how long a selected target remains associated with an identity
```

### Source code

```text
crates/libsy/src/algorithms/util/subagent.rs

Key symbols:
- SubagentOverride
- SubagentGate
```

```text
crates/libsy/src/algorithms/util/affinity.rs

Key symbols:
- AffinityRouter
- AffinityRouter::for_subagents()
- affinity_key()
- retention_key()
```

Integration behavior is tested in:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs

Notable tests:
- the_override_seeds_a_pin_that_affinity_replays
- the_pin_outlives_the_policy_that_seeded_it
- distinct_children_are_pinned_independently
```

## Delegent migration

Keep these decisions separate:

```text
delegating-work / routing-policy
→ Lead or Worker?

worker-memory / registry
→ Existing Worker or fresh Worker?
→ How long should this assignment survive?
```

Do not merge Worker-reuse rules into Lead-vs-Worker placement logic.

### Target files

Current:

```text
skills/delegating-work/references/routing-policy.md
skills/delegating-work/references/worker-memory.md
```

Future runtime:

```text
Worker registry / session adapter
```

---

# 6. Migration 2 — Distinguish Delegated Work From Subagent Maintenance

## Switchyard pattern

Switchyard distinguishes child lineage from actual delegated work. A child-related request may be maintenance rather than a new delegated engineering task.

The code recognizes Codex delegated-work kinds such as:

```text
x-openai-subagent: review
x-openai-subagent: collab_spawn
```

while a maintenance operation such as:

```text
x-openai-subagent: compact
```

is intentionally not forced through the delegated-work path.

### Source code

```text
crates/libsy/src/algorithms/util/subagent.rs

Key logic:
- Metadata::is_subagent_work checks
- SubagentGate::score()
- SubagentOverride::score()
```

Tests:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs

- harness_maintenance_turns_are_not_forced_to_the_worker
```

## Delegent migration

The Worker runtime should eventually classify operations such as:

```text
delegated_task
continuation
sync
compact
memory_maintenance
shutdown
```

Only actual task execution or continuation should be treated as delegated engineering work.

`sync`, `compact`, registry maintenance, and shutdown must not accidentally trigger a new routing/workflow decision.

---

# 7. Migration 3 — Stable Worker Identity

## Switchyard pattern

For delegated child work, affinity is keyed more finely than a root session. The design uses stable correlation metadata so sibling children do not inherit each other's assignment.

### Source code

```text
crates/libsy/src/algorithms/util/affinity.rs

Key symbols:
- AffinityRouter::affinity_key()
- retention_key()
```

The behavior is exercised in:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs

- distinct_children_are_pinned_independently
```

## Delegent migration

A raw OpenCode `session_id` is insufficient as our durable abstraction.

Target identity:

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
session_id: <opencode-session-id>
last_sync_commit: 92ac371
status: active
```

This lets one project hold independent contexts such as:

```text
scheduler-primary
auth-primary
scheduler-reviewer
security-reviewer
```

without confusing session continuity with task identity.

---

# 8. Migration 4 — Assignment Pinning

## Switchyard pattern

Once an affinity assignment is seeded, later requests with the same identity replay that assignment before consulting a later policy.

### Source code

```text
crates/libsy/src/algorithms/util/affinity.rs

Core state:
- assignments: HashMap<RoutingIdentity, ModelId>
```

Tests:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs

- the_override_seeds_a_pin_that_affinity_replays
- the_pin_outlives_the_policy_that_seeded_it
```

## Delegent migration

Adopt this principle:

> Once a work thread owns a useful Worker context, reuse it until an explicit invalidation condition fires.

Invalidation conditions include:

```text
context stale beyond cheap resync
context confused or contradictory
context near practical quality/size limit
scope changed substantially
independent judgment required
explicit fresh-Worker request
Worker retired/invalid
```

This avoids re-paying repository exploration on every follow-up task.

---

# 9. Migration 5 — Route/Dispatch Only the Delegated Task

## Switchyard pattern

`SubagentGate` constructs a prompt-only request for the delegated classifier rather than exposing the entire coding-agent harness trajectory.

### Source code

```text
crates/libsy/src/algorithms/util/subagent.rs

Key function:
- delegated_prompt_request(...)
```

The implementation extracts the relevant delegated user prompt and gives the classifier a compact request clone.

## Delegent migration

Delegent should dispatch a compact Worker task rather than copying the Lead's entire conversation.

Target contract:

```text
TASK
SCOPE
DECISIONS
CONSTRAINTS
FORBIDDEN
SUCCESS
```

The current `worker-contract.md` already moves in this direction. Future runtime code should make this an explicit dispatch object/structure rather than relying only on prose discipline.

Benefits:

- protects the Context Firewall in both directions;
- avoids accidental Lead-history leakage;
- reduces Worker startup noise;
- makes routing and Worker execution easier to test.

---

# 10. Migration 6 — Escalate From Observed Trajectory, Not Apparent Task Size

## Switchyard pattern

Switchyard's escalation router lets the efficient target execute first, then evaluates the completed trajectory and accumulates an escalation streak.

### Source code

```text
crates/libsy/src/algorithms/escalation.rs

Key symbols:
- EscalationClassifier
- STREAK_KEY
- streak()
- build_classifier(...)
```

The essential behavior is:

```text
execute
  ↓
judge completed turn
  ↓
escalate verdict?
  ├─ no  → reset streak
  └─ yes → increment streak
             ↓
        confirmations reached?
             ↓
          escalate
```

## Delegent migration

Do not route to Lead merely because a coding task appears difficult.

Use two escalation classes:

### Hard escalation

Immediate, deterministic Lead ownership:

- architecture ambiguity;
- security decisions;
- public API semantics;
- schema semantics;
- conflicting requirements;
- irreversible/high-blast-radius decisions.

This is already represented in the current Worker contract.

### Trajectory escalation

For ordinary execution failure, allow Worker recovery. Escalate only when failure is repeated/corroborated or the Worker explicitly reports inability to proceed.

Candidate signals:

```text
same error repeats
multiple failed fix/test cycles
long nonproductive loop
contradictory conclusions
repeated low-confidence handoffs
context degradation / repeated compaction
```

Do not copy Switchyard's exact threshold values; Delegent has a different routing objective.

---

# 11. Migration 7 — Multiple Confirmations Before Soft Escalation

## Switchyard pattern

The escalation judge config supports a `confirmations` count so one weak signal need not immediately move the session to the capable tier.

### Source code

```text
crates/libsy/src/algorithms/util/escalation.rs

Key type:
- EscalationJudgeConfig
```

At the reviewed snapshot, defaults include a confirmation count and bounded recent transcript window.

## Delegent migration

Borrow the structure, not the constants:

```text
single recoverable failure
→ Worker attempts recovery

repeated/corroborated failure
→ Lead escalation
```

Hard Lead boundaries remain immediate and bypass the soft confirmation mechanism.

---

# 12. Migration 8 — Condense Trajectory Before Escalation

## Switchyard pattern

The escalation judge does not consume an unlimited raw transcript. It preserves anchors and a recent window, truncating less valuable history.

### Source code

```text
crates/libsy/src/algorithms/util/escalation.rs

Key elements:
- SYSTEM_CHARS
- FIRST_USER_CHARS
- MAX_REQUEST_CHARS
- truncate_middle()
- summarize_for_judge()
```

## Delegent migration

The Context Firewall applies most strongly when a Worker is stuck.

Do not send a 100K-token debugging trajectory back to Codex.

Escalation should be compressed to something like:

```text
DECISION_NEEDED
Goal:
What I tried:
Observed:
Current blocker:
Relevant evidence:
Options:
Recommendation:
Confidence:
```

The current `worker-contract.md` already has the core `DECISION_NEEDED` structure. Future trajectory escalation should extend it without exposing raw Worker history.

---

# 13. Migration 9 — Deterministic Worker-Health Signals

## Switchyard pattern

Switchyard extracts deterministic signals from normalized tool calls/results before relying on an LLM classifier.

### Source code

```text
crates/libsy/src/algorithms/util/tool_signals.rs

Key symbols:
- ToolSignals
- ToolSignalProcessor
- classify_tool_call(...)
```

Signals include concepts such as:

- error severity;
- read/write/edit activity;
- planning activity;
- recent activity windows;
- tests passing;
- turn depth;
- context compaction.

The extractor also recognizes coding-agent-specific tool names, including Codex-style tool names.

## Delegent migration

Future Worker-health telemetry should collect at least:

```text
reads
writes
edits
test runs
test failures
same-error repetition
turn count
context/compaction events
```

The purpose is **not** to copy Switchyard's capable/efficient mapping. The purpose is to determine whether a delegated Worker is healthy, progressing, or should escalate/rotate.

---

# 14. Migration 10 — Hard Rules Before Soft Classification

## Switchyard pattern

The stage router uses an ordered decision cascade: hard overrides, hard settled-state behavior, signal scoring, then fallback/classifier behavior.

### Source code

```text
crates/libsy/src/algorithms/util/stage.rs

Key functions/types:
- pick_tier(...)
- should_escalate(...)
- should_deescalate(...)
- PickOutcome
```

## Delegent migration

Adopt the cascade structure but use our own semantics:

```text
1. hard Lead boundary
2. hard obvious Worker case
3. context-value heuristic
4. dispatch-overhead heuristic
5. Lead resolves ambiguity
```

Examples of hard Lead boundaries:

```text
security
public API behavior
schema semantics
architecture with high blast radius
user intent / conflicting requirements
```

Examples of strong Worker candidates:

```text
broad repository exploration
large logs
approved multi-file implementation
mechanical refactor
test/debug execution loops
```

---

# 15. Important Divergence — Do Not Copy Switchyard Stage Semantics

## Switchyard behavior

Switchyard's stage model treats exploration/spinning/error recovery as evidence for the capable tier and production intensity as evidence for the efficient tier.

### Source code

```text
crates/libsy/src/algorithms/util/stage.rs

Key symbols:
- CodingAgentDimensions
- dimensions_from_signal(...)
- score_signal(...)
- pick_tier(...)
```

## Why Delegent differs

Our resource asymmetry is different:

```text
large-context repository exploration
→ Worker / Nemotron

high-impact architecture or semantics
→ Lead / Sol
```

Therefore this mapping is explicitly rejected:

```text
exploring == Lead
```

We borrow the **observable-signal → deterministic-rule → ambiguity fallback** architecture, not the strong/weak tier mapping.

---

# 16. Migration 11 — Record Decision Source

## Switchyard pattern

Switchyard records which routing component produced a decision so behavior can be explained and calibrated.

### Source code

```text
crates/libsy/src/algorithms/util/stage.rs

Key type:
- DecisionSource
```

Sources include concepts such as override, settled tests, dimensions, ambiguity, LLM classifier, and fallback.

## Delegent migration

Future routing events should record a stable source vocabulary, for example:

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

Example event:

```text
owner: worker
decision_source: context_heavy
reason: broad repository exploration
worker_id: scheduler-primary
memory_action: reuse
```

This is required for meaningful evaluation rather than anecdotal tuning.

---

# 17. Migration 12 — Persistent State Needs a Lifecycle

## Switchyard pattern

Stateful `FallThrough` compositions retain private state per session and clean up inactive session state.

### Source code

```text
crates/libsy/src/algorithms/fall_through.rs

Key elements:
- SessionState<S>
- SessionStates<S>
- SESSION_STATE_TTL
- session_state(...)
- remove_session(...)
- cleanup_inactive_sessions(...)
```

## Delegent migration

Do not copy Switchyard's exact TTL. Persistent Worker sessions intentionally have longer semantic value than per-route state.

Borrow the lifecycle principle:

```text
created
active
stale
retired
invalid
```

Track at least:

```text
created_at
last_used_at
last_sync_commit
scope
status
context_health
```

A Worker should never be "persistent forever" merely because its session still exists.

---

# 18. Migration 13 — Subagent Router as a Future Runtime Reference

Switchyard now contains a dedicated subagent routing wrapper that routes delegated child work independently while preserving the parent algorithm for ordinary traffic.

### Source code

```text
crates/libsy/src/algorithms/subagent.rs

Key symbols:
- SubagentRouter
- SubagentRouterConfig
```

Notable behavior:

- delegated work is routed independently from parent/root traffic;
- child routing can use `ClassifyTrigger::NewSession` affinity;
- different child identities can retain separate target assignments;
- the classifier can receive only the delegated prompt;
- a default child target closes the cascade.

## Delegent migration

We should not directly embed this router in V0.1, but it is a strong runtime precedent for the future Worker registry/adapter boundary:

```text
root / Lead workflow
≠
delegated Worker execution
```

This supports the architectural decision that Worker session state should be managed independently rather than inferred from the Lead conversation.

---

# 19. Explicit Non-Migrations

## 19.1 Do not migrate the proxy layer

Out of scope for V0.1:

```text
OpenAI Responses
↔ OpenAI Chat
↔ Anthropic Messages
```

Switchyard may later be evaluated below the Worker layer when multiple Worker-side model providers exist.

## 19.2 Do not replace separate contexts with per-turn backend switching

Reject:

```text
one shared coding-agent trajectory
→ switch Sol/Nemotron backend per turn
```

Core requirement:

```text
Lead context
        │
        │ compact task / compact result
        ▼
separate Worker context
```

The Context Firewall is a first-class product requirement.

## 19.3 Do not copy exact thresholds

Do not blindly copy values such as:

```text
confidence threshold
confirmation count
recent-window length
session TTL
```

They were calibrated for Switchyard's model-routing problem, not Delegent's context-placement problem.

---

# 20. Mapping Into the Current Repository

Current files:

```text
skills/delegating-work/SKILL.md
skills/delegating-work/references/routing-policy.md
skills/delegating-work/references/worker-memory.md
skills/delegating-work/references/worker-contract.md
skills/delegating-work/references/worker-agent.md
skills/delegating-work/opencode.json
skills/delegating-work/scripts/nemotron-worker.ps1
```

Migration mapping:

| Borrowed pattern | Current/future home |
| --- | --- |
| Lead vs Worker placement | `routing-policy.md` |
| separate affinity policy | `worker-memory.md` + future registry |
| compact delegated task | `worker-contract.md` + future dispatch structure |
| hard escalation | `worker-contract.md` |
| trajectory escalation | future `escalation-policy.md` / runtime |
| Worker identity | future Worker registry |
| session lifecycle | future Worker registry |
| decision provenance | future eval/telemetry layer |
| Worker-health signals | future runtime telemetry |
| OpenCode/Nemotron execution | `worker-agent.md`, wrapper, `opencode.json` |
| top-level orchestration | future `skills/delegent/SKILL.md` |

---

# 21. Migration Priority

## P0 — Required for the Delegent V0.1 loop

1. Add the `Delegent` top-level orchestrator.
2. Preserve the existing separation between routing and Worker memory.
3. Keep the compact Worker contract / Context Firewall.
4. Preserve hard Lead escalation boundaries.
5. Make existing-vs-fresh Worker choice explicit during orchestration.
6. Keep final acceptance with Lead.

## P1 — Worker continuity runtime

7. Add stable Worker identity/registry.
8. Automatic OpenCode session lookup/reuse.
9. Track `last_sync_commit` and resynchronize stale Workers.
10. Distinguish delegated work from Worker maintenance operations.
11. Add Worker lifecycle states.

## P2 — Observed-trajectory quality control

12. Worker-health signals.
13. Repeated-failure escalation.
14. Decision-source logging.
15. Context-health / Worker rotation policy.

## P3 — Optional model-routing layer

16. Evaluate Switchyard below OpenCode when there are multiple Worker-side models/providers and model-level routing creates real value.

---

# 22. Evaluation Borrowed From Switchyard

Switchyard's calibration work reinforces an important principle: routing should be measured with counterfactual outcome categories rather than judged only by intuition.

Adapted Delegent categories:

```text
DELEGATE_SAFE
Worker succeeds; Lead intervention was unnecessary.

DELEGATE_LOSS
Delegation fails where Lead ownership would likely succeed.

CONTEXT_RESCUE
Worker succeeds while avoiding substantial disposable Lead context.

HARD
Neither ownership strategy succeeds cleanly.
```

Track:

```text
task success
Lead context burden
Worker context burden
Lead interventions
Worker reuse rate
fresh-Worker rate
escalation rate
false-escalation rate
handoff quality
wall-clock time
```

The first 10–20 representative tasks should be treated as policy calibration data, not just demos.

---

# 23. Source Code Map

All paths below refer to `NVIDIA-NeMo/Switchyard` at or around the reviewed snapshot `27fc1ce9ff3846760337fe42ab09c28f5b01c807`.

| Concept | Switchyard source |
| --- | --- |
| Parent vs delegated child routing | `crates/libsy/src/algorithms/subagent.rs` |
| Delegated-work detection | `crates/libsy/src/algorithms/util/subagent.rs` |
| Prompt-only child classification | `crates/libsy/src/algorithms/util/subagent.rs::delegated_prompt_request()` |
| Worker/model affinity | `crates/libsy/src/algorithms/util/affinity.rs::AffinityRouter` |
| Child identity and retention | `crates/libsy/src/algorithms/util/affinity.rs::affinity_key()` / `retention_key()` |
| Affinity integration behavior | `crates/libsy/src/algorithms/subagent_affinity_tests.rs` |
| Escalation streak | `crates/libsy/src/algorithms/escalation.rs` |
| Trajectory judge | `crates/libsy/src/algorithms/util/escalation.rs` |
| Trajectory compression | `crates/libsy/src/algorithms/util/escalation.rs::summarize_for_judge()` |
| Tool/progress signals | `crates/libsy/src/algorithms/util/tool_signals.rs` |
| Stage dimensions | `crates/libsy/src/algorithms/util/stage.rs::CodingAgentDimensions` |
| Deterministic decision cascade | `crates/libsy/src/algorithms/util/stage.rs::pick_tier()` |
| Decision-source telemetry | `crates/libsy/src/algorithms/util/stage.rs::DecisionSource` |
| Stateful classifier composition | `crates/libsy/src/algorithms/fall_through.rs` |
| Session lifecycle / cleanup | `crates/libsy/src/algorithms/fall_through.rs` |

---

# 24. Final Migration Principle

The most valuable Switchyard lessons for Delegent are architectural, not numerical:

```text
1. SEPARATE OWNERSHIP FROM AFFINITY
Where should work go?
≠
How long should that assignment live?

2. OBSERVE BEFORE SOFT ESCALATION
Task looks hard
≠
Worker is actually failing

3. HARD RULES BEFORE FUZZY JUDGMENT
Lead boundary
→ observable signals
→ higher-level judgment only when ambiguous

4. KEEP IDENTITY AND STATE EXPLICIT
Persistent context needs identity, lifecycle, resync, and retirement

5. RECORD WHY ROUTING HAPPENED
A routing system cannot be calibrated if it records only the final owner
```

Applied to Delegent:

```text
Delegent = workflow orchestration
Lead = strategic judgment + durable intent
Worker = repository context + execution memory
Affinity = reuse expensive Worker understanding
Escalation = protect quality when Worker reaches its boundary
Handoff = protect the Context Firewall
Repo = durable project knowledge
```

Switchyard informs these internal mechanisms, but Delegent remains distinct because its primary routing unit is a **work unit / agent context**, not an individual LLM request.