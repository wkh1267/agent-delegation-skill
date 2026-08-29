# Migration Spec: Switchyard-Inspired Delegation Architecture

## 1. Purpose

本文件定義哪些 NVIDIA NeMo Switchyard 設計應借鑑到我們的 `delegating-work` 系統，以及如何調整成：

```text
Codex / GPT-5.6 Sol
        │
        │ strategic lead
        ▼
delegating-work
        │
        ├── Lead-owned decision
        │
        └── Delegated work
                │
                ▼
             OpenCode
                │
                ▼
             Nemotron
```

核心原則：

> **借 Switchyard 已驗證過的 routing / affinity / escalation patterns，但不搬它的 model-proxy architecture。**

Switchyard 解的是 LLM/model routing；我們主要解的是：

> **work-unit ownership + context isolation + worker memory reuse。**

---

# 2. Source Repository

Upstream:

```text
NVIDIA-NeMo/Switchyard
```

License:

```text
Apache-2.0
```

目前 Switchyard 自己仍標示為 pre-alpha，因此此 migration 以 **design borrowing** 為主，不將其 runtime 當 dependency。

若未來直接複製或衍生 source code，必須遵守 Apache-2.0 attribution/license requirements。

---

# 3. Migration Summary

| Switchyard concept                      | 我們                           | Action                           |
| --------------------------------------- | ---------------------------- | -------------------------------- |
| Subagent detection                      | 判斷 delegated work            | **ADOPT**                        |
| Parent vs child routing                 | Lead vs Worker               | **ADOPT**                        |
| Affinity                                | Persistent worker reuse      | **ADOPT + EXTEND**               |
| Session + agent identity                | Worker identity              | **ADAPT**                        |
| Assignment pinning                      | Worker session reuse         | **ADOPT**                        |
| Subagent prompt isolation               | Worker task contract         | **ADOPT**                        |
| Escalation streak                       | Worker → Lead escalation     | **ADOPT**                        |
| Trajectory judge                        | Worker-health evaluation     | **ADAPT**                        |
| Tool signals                            | worker-health signals        | **ADAPT**                        |
| Decision source telemetry               | delegation observability     | **ADOPT**                        |
| Context overflow fallback               | worker rotation / escalation | **ADAPT**                        |
| Stage model routing                     | strong/weak per-turn routing | **DO NOT MIGRATE V0.1**          |
| API protocol proxy                      | Responses ↔ Chat translation | **DO NOT MIGRATE V0.1**          |
| Model switching inside one conversation | shared-context routing       | **REJECT for core architecture** |

---

# 4. Migration 1 — Separate Assignment Policy From Memory Policy

## Switchyard design

Switchyard 有一個非常值得直接採用的 separation：

```text
SubagentOverride
→ decides WHICH target

AffinityRouter
→ decides HOW LONG that choice survives
```

它的 source comment 甚至直接說：

> override decides which target delegated work belongs on; affinity decides how long a decision lives.

### Source Code

```text
crates/libsy/src/algorithms/util/subagent.rs

Key symbols:
- SubagentOverride
- SubagentGate
```

以及：

```text
crates/libsy/src/algorithms/util/affinity.rs

Key symbols:
- AffinityRouter
- AffinityRouter::for_subagents()
- retention_key()
```

官方 integration tests 更直接驗證：

```text
override seeds assignment
        ↓
affinity remembers assignment
        ↓
later turns reuse it
```

Source:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs
```

---

## Migration

我們保持相同 separation：

```text
routing-policy.md
      │
      │ decides WHERE work belongs
      ▼
Lead / Worker
      │
      ▼
worker-memory.md
      │
      │ decides WHICH worker context
      ▼
existing / fresh
```

### Target files

```text
delegating-work/
└── references/
    ├── routing-policy.md
    └── worker-memory.md
```

**禁止把 worker reuse rules 寫進 routing-policy。**

這兩件事是不同 decision。

---

# 5. Migration 2 — Distinguish Delegated Work From Subagent Maintenance

這是 Switchyard 一個很細但非常好的設計。

它不是看到：

```text
is_subagent = true
```

就直接當成 worker task。

因為 Codex 可能存在：

```text
x-openai-subagent: compact
```

這代表 subagent lineage / maintenance，但不是新的 delegated work。

Switchyard因此區分：

```text
is_subagent
vs
is_subagent_work
```

例如：

```text
review
collab_spawn
→ delegated work

compact
→ maintenance
```

### Source Code

```text
crates/libsy/src/algorithms/util/subagent.rs

SubagentOverride::score()
SubagentGate::score()
```

Integration test：

```text
harness_maintenance_turns_are_not_forced_to_the_worker
```

位於：

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs
```

---

## Migration

我們也必須區分：

```text
WORKER OPERATION
│
├── delegated task
├── continuation
├── sync
├── compact
├── memory maintenance
└── shutdown
```

只有：

```text
delegated task
continuation
```

需要重新進 routing/worker execution flow。

像：

```text
sync
compact
memory maintenance
```

不應被誤判成新的 engineering task。

---

# 6. Migration 3 — Worker Identity / Affinity

## Switchyard design

Switchyard 不單純以 session ID 判斷 child。

它對 subagent 使用：

```text
session + agent
```

作為 identity。

因此：

```text
session-1 / child-1
→ worker

session-1 / child-2
→ reviewer
```

兩者 assignment 可以獨立。

### Source Code

```text
crates/libsy/src/algorithms/util/affinity.rs
```

`AffinityRouter::affinity_key()`：

* root → session identity
* child → session + agent identity
* child 沒有完整 identity 時，不 fallback 到 message hash

對應 test：

```text
distinct_children_are_pinned_independently
```

Source:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs
```

---

## Migration

我們不能只使用：

```text
OpenCode session_id
```

而應建立：

```text
WorkerIdentity {
    project
    role
    scope
    worker_id
    session_id
    last_sync_commit
}
```

例如：

```text
project:
personal-assistant-backend

role:
implementation

scope:
scheduler

worker_id:
scheduler-primary

session_id:
opencode-abc123

last_sync_commit:
92ac371
```

這使：

```text
scheduler worker
auth worker
independent reviewer
```

可以在同一 project 中同時存在。

---

# 7. Migration 4 — First Assignment Wins / Worker Pinning

Switchyard affinity 的重要特性：

> first assignment wins.

當 child 第一次被 assign：

```text
child-1 → worker
```

後續即使 routing policy 改變：

```text
policy now says reviewer
```

同一 child 仍然：

```text
child-1 → worker
```

直到 affinity 被清除。

### Source Code

```text
AffinityRouter

assignments:
HashMap<RoutingIdentity, ModelId>
```

以及：

```text
the_pin_outlives_the_policy_that_seeded_it
```

Source:

```text
crates/libsy/src/algorithms/subagent_affinity_tests.rs
```

---

## Migration

我們採用：

> **Once a work thread owns a worker context, reuse it unless a specific invalidation condition fires.**

不要每一 turn 重新問：

```text
Should scheduler task use worker A or B?
```

而是：

```text
scheduler implementation
        ↓
scheduler-primary
        ↓
reuse
        ↓
reuse
        ↓
reuse
```

Invalidation conditions：

```text
worker context stale
worker context confused
context near practical limit
task scope changed substantially
independent judgment required
explicit fresh-worker request
```

---

# 8. Migration 5 — Classify Only the Delegated Prompt

Switchyard 的 `SubagentGate` 不把整份 coding-agent conversation 給 classifier。

它會從 request 中抽：

```text
last non-empty user task
```

建立新的 prompt-only request。

### Source Code

```text
crates/libsy/src/algorithms/util/subagent.rs

fn delegated_prompt_request(...)
```

這避免 classifier 被：

```text
system prompt
harness reminders
大量歷史 context
tool traces
```

污染。

---

## Migration

我們的 routing decision 同樣只應該看到：

```text
TASK
CONSTRAINTS
CURRENT DECISIONS
WORKER STATE SUMMARY
```

而不是把 Lead 的完整 conversation 傳給 routing logic。

Worker dispatch contract：

```text
TASK
What needs to be accomplished.

SCOPE
Relevant subsystem / boundaries.

DECISIONS
Already-fixed architectural decisions.

FORBIDDEN
Things worker may not decide/change.

SUCCESS
Observable completion criteria.
```

這同時降低：

```text
routing token cost
worker startup context
accidental Lead-context leakage
```

---

# 9. Migration 6 — Escalation Should Depend on Trajectory, Not Task Size

這是 Switchyard 最值得借的第二大 idea。

它不只做：

```text
"這個 task 看起來難"
→ strong
```

它還做：

```text
先讓 weak 做
      ↓
觀察實際 trajectory
      ↓
卡住了嗎？
      ↓
escalate
```

### Source Code

```text
crates/libsy/src/algorithms/escalation.rs

Key symbols:
- EscalationClassifier
- STREAK_KEY
- streak()
```

它的 flow：

```text
efficient executes
       ↓
judge evaluates actual result
       ↓
escalate?
       │
       ├─ no → streak = 0
       │
       └─ yes → streak += 1
                    │
           confirmations reached?
                    │
                    ▼
                 capable
```

---

# 10. Migration 7 — Require Multiple Escalation Confirmations

Switchyard default：

```text
confirmations = 2
```

不是 worker 一出錯就升級。

Source：

```text
crates/libsy/src/algorithms/util/escalation.rs

EscalationJudgeConfig
```

Default：

```text
confirmations: 2
recent_turn_window: 28
window_message_chars: 500
```

---

## Migration

我們採用同樣 concept：

```text
single recoverable failure
→ Nemotron自己處理

repeated / corroborated failure
→ Lead escalation
```

第一版可以定義：

```text
EscalationScore
```

觸發來源：

```text
+1 repeated same failure
+1 failed fix/test cycle
+1 contradictory understanding
+1 architecture uncertainty
+2 explicit decision boundary
+2 security/API/schema ambiguity
```

其中：

```text
architecture/security/API/schema
```

仍然是 hard escalation，不需要等 streak。

---

# 11. Migration 8 — Condense Trajectory Before Escalation

Switchyard 沒有把整份 conversation 丟給 escalation judge。

它會保留：

```text
system/developer anchor
first user task
recent trajectory
```

而且：

* system anchor 有 cap
* first user task 有較高 cap
* recent messages individually truncate
* 整份 judge input 有 total cap
* 越舊的 activity 越先移除

### Source Code

```text
crates/libsy/src/algorithms/util/escalation.rs
```

Key components：

```text
SYSTEM_CHARS
FIRST_USER_CHARS
MAX_REQUEST_CHARS

truncate_middle()
summarize_for_judge()
```

---

## Migration

Worker escalation 不應該把：

```text
100K debugging transcript
```

送回 Lead。

應壓縮成：

```text
DECISION_NEEDED

Goal:
...

What I tried:
1. ...
2. ...

Observed:
...

Current blocker:
...

Relevant evidence:
- file:line
- test
- error

Options:
A
B

Worker recommendation:
...

Confidence:
...
```

這是我們 Context Firewall 的核心之一。

---

# 12. Migration 9 — Deterministic Worker-Health Signals

Switchyard 不全部依賴 LLM judge。

它先從 tools deterministic 地抽 signal。

### Source Code

```text
crates/libsy/src/algorithms/util/tool_signals.rs
```

它辨識：

```text
error severity
read count
write count
edit count
planning count
tests passed
recent activity
turn depth
context compaction
```

也直接支援 Codex tool names，例如：

```text
apply_patch
update_plan
exec_command
```

---

## Migration

我們不需要完整複製 scorer。

但 Worker runtime 未來至少應記：

```text
reads
writes
edits
test runs
test failures
same-error repetition
turn count
context usage
compaction count
```

用途不是：

> 「exploration → Sol」

而是：

> **判斷 Nemotron worker 是否 healthy。**

---

# 13. IMPORTANT DIVERGENCE — Do Not Copy Their Stage Policy

Switchyard stage scoring是：

```text
severity ↑
spinning ↑
exploring ↑
        ↓
capable tier

production intensity ↑
        ↓
efficient tier
```

Source：

```text
crates/libsy/src/algorithms/util/stage.rs

CodingAgentDimensions
dimensions_from_signal()
score_signal()
pick_tier()
```

這不符合我們的主要 optimization objective。

我們是：

```text
large-context exploration
→ Nemotron

high-impact judgment
→ Sol
```

因此：

```text
exploring == Lead
```

**不可直接 migration。**

---

## What we borrow instead

只拿：

```text
observable signals
        ↓
deterministic rules
        ↓
confidence / ambiguity
        ↓
fallback to higher-level judgment
```

不拿它的：

```text
signal → strong/weak model
```

mapping。

---

# 14. Migration 10 — Hard Rules Before Soft Classification

Switchyard `pick_tier()` 有很好的 priority structure：

```text
1. hard escalation
2. hard de-escalation
3. signal scorer
4. classifier / fallback
```

這比全部交給 LLM 自由判斷穩定。

---

## Migration

我們也採：

```text
1. HARD LEAD OWNERSHIP

security
public API
schema semantics
irreversible architecture
user intent

        ↓ otherwise

2. HARD WORKER CASES

large exploration
large logs
mechanical implementation

        ↓ otherwise

3. CONTEXT-VALUE HEURISTIC

Does Lead need intermediate context?

        ↓ ambiguous

4. Lead decides
```

因此 LLM-based fuzzy routing永遠不是第一層。

---

# 15. Migration 11 — Explicit Decision Source

Switchyard會記錄：

```text
override
tests_passed
dimensions
ambiguous
llm-classifier
fall_open
```

### Source

```text
crates/libsy/src/algorithms/util/stage.rs

enum DecisionSource
```

這對 tuning 非常重要。

---

## Migration

每次 delegation 記：

```text
owner: worker

decision_source:
context_heavy

reason:
broad repository exploration

worker:
scheduler-primary

memory_action:
reuse

confidence:
high
```

或者：

```text
owner: lead

decision_source:
hard_lead_boundary

reason:
database schema semantics
```

未來才有辦法分析：

> routing policy 到底準不準？

---

# 16. Migration 12 — Session State Must Be Bounded

Switchyard對 session state 不讓它永遠長。

`FallThrough`：

```text
session_id
→ private State
```

並有：

```text
SESSION_STATE_TTL = 1 hour
```

以及 cleanup。

### Source Code

```text
crates/libsy/src/algorithms/fall_through.rs

SessionState
SessionStates
SESSION_STATE_TTL
session_state()
remove_session()
```

---

## Migration

我們不照抄一小時 TTL。

因為 Nemotron worker 的價值就是跨工作 reuse。

但要借它的：

> **Memory must have lifecycle.**

Worker registry需要：

```text
created_at
last_used_at
last_sync_commit
scope
context_health
status
```

例如：

```text
active
stale
retired
invalid
```

而不是 session 永遠存在。

---

# 17. Proposed Target Architecture

Migration 完成後：

```text
                       Codex Lead
                           │
                           ▼
                    delegating-work
                           │
              ┌────────────┴────────────┐
              │                         │
        hard Lead boundary       delegatable work
              │                         │
              ▼                         ▼
             Sol                Worker Registry
                                        │
                             ┌──────────┴──────────┐
                             │                     │
                       affinity hit          no affinity
                             │                     │
                             ▼                     ▼
                    existing worker          fresh worker
                             │                     │
                             └──────────┬──────────┘
                                        ▼
                                    OpenCode
                                        │
                                    Nemotron
                                        │
                                execution trajectory
                                        │
                               ┌────────┴─────────┐
                               │                  │
                           healthy             stuck
                               │                  │
                            continue      escalation policy
                                                  │
                                         confirmed problem?
                                             │        │
                                            NO       YES
                                             │        │
                                          worker    Codex
```

---

# 18. Target Files

## V0.1 — Skill Layer

```text
delegating-work/
├── SKILL.md
└── references/
    ├── routing-policy.md
    ├── worker-memory.md
    ├── worker-contract.md
    └── escalation-policy.md
```

### `routing-policy.md`

Inspired by:

```text
Switchyard:
util/subagent.rs
util/stage.rs
```

Contains:

```text
Lead ownership
Context-value routing
Hard rules
Delegation overhead
Decision source
```

---

### `worker-memory.md`

Inspired mainly by:

```text
util/affinity.rs
subagent_affinity_tests.rs
fall_through.rs
```

Contains:

```text
worker identity
affinity
reuse
fresh worker
staleness
lifecycle
```

---

### `worker-contract.md`

Inspired by:

```text
util/subagent.rs
```

Contains:

```text
minimal delegated prompt
task scope
forbidden decisions
return schema
```

---

### `escalation-policy.md`

Inspired by:

```text
algorithms/escalation.rs
util/escalation.rs
util/tool_signals.rs
```

Contains:

```text
hard escalation
failure streak
trajectory compression
worker-health signals
```

---

# 19. V0.2 — Runtime State

Later add:

```text
worker-registry.json
```

Conceptually:

```json
{
  "workers": {
    "scheduler-primary": {
      "scope": "scheduler",
      "session_id": "...",
      "last_sync_commit": "...",
      "status": "active"
    }
  }
}
```

Do not implement this inside `SKILL.md`.

The skill expresses policy.

Runtime/wrapper manages state.

---

# 20. V0.3 — Observability

Record for every significant work unit:

```text
task_id
task_type

owner:
lead | worker

decision_source

worker_id
worker_reused

context_estimate

result:
success | fail | escalated

escalation_reason

turns
tests
failures
```

Then build our own equivalent of Switchyard calibration.

---

# 21. Benchmark Design Borrowed From Switchyard

Switchyard's Stage Router documentation suggests comparing strong/efficient outcomes through categories such as:

```text
SAFE
LOSS
RESCUE
HARD
```

We adapt them to delegation:

```text
DELEGATE_SAFE
Worker succeeds; Lead not needed.

DELEGATE_LOSS
Worker fails where Lead would succeed.

CONTEXT_RESCUE
Worker succeeds and avoids major Lead context consumption.

HARD
Neither workflow succeeds cleanly.
```

Primary metrics:

```text
task success
Lead context consumed
Worker context consumed
Lead interventions
worker reuse rate
escalation rate
false escalation rate
decision quality
wall-clock time
```

---

# 22. Explicit Non-Migrations

Do NOT copy into V0.1:

### Switchyard proxy

```text
OpenAI Responses
↔ Anthropic Messages
↔ Chat Completions
```

Not our current problem.

---

### Per-turn model switching

Do not replace:

```text
separate Sol context
+
separate Nemotron context
```

with:

```text
one shared conversation
switch backend models
```

That would destroy the Context Firewall.

---

### Their strong/weak stage mapping

Especially do not copy:

```text
exploration → capable
```

Our environment has a long-context worker specifically intended for exploration.

---

### Their exact numeric thresholds

Do not blindly copy:

```text
confidence_threshold = 0.5
confirmations = 2
recent_window = 3
TTL = 1 hour
```

The **structure** is useful.

The numbers were calibrated for Switchyard's routing objective, not ours.

---

# 23. Migration Priority

## P0 — Implement now

1. **Assignment / affinity separation**
2. **Lead vs delegated-work distinction**
3. **Existing vs fresh worker decision**
4. **Worker identity**
5. **Minimal delegated prompt**
6. **Compressed handoff**
7. **Hard Lead boundaries**

---

## P1 — After OpenCode/Nemotron connection works

8. Worker trajectory signals
9. Repeated-failure escalation
10. Worker staleness detection
11. Worker registry
12. Decision-source logging

---

## P2 — After real-world usage data

13. Threshold calibration
14. Adaptive escalation
15. Worker-health scoring
16. context-limit rotation
17. multi-worker routing

---

## P3 — Optional

Evaluate Switchyard itself as:

```text
OpenCode worker
      ↓
Switchyard
      ↓
multiple API models
```

only when multiple Worker models actually exist.

---

# 24. Source Code Map

| Concept                           | Switchyard Source                                              |
| --------------------------------- | -------------------------------------------------------------- |
| Parent vs delegated child routing | `crates/libsy/src/algorithms/subagent.rs`                      |
| Delegated-work detection          | `crates/libsy/src/algorithms/util/subagent.rs`                 |
| Prompt-only child classification  | `util/subagent.rs::delegated_prompt_request()`                 |
| Worker affinity                   | `crates/libsy/src/algorithms/util/affinity.rs::AffinityRouter` |
| Child identity + retention        | `util/affinity.rs::affinity_key()` / `retention_key()`         |
| Affinity behavior tests           | `crates/libsy/src/algorithms/subagent_affinity_tests.rs`       |
| Escalation streak                 | `crates/libsy/src/algorithms/escalation.rs`                    |
| Trajectory judge                  | `crates/libsy/src/algorithms/util/escalation.rs`               |
| Trajectory compression            | `util/escalation.rs::summarize_for_judge()`                    |
| Tool activity signals             | `crates/libsy/src/algorithms/util/tool_signals.rs`             |
| Stage dimensions                  | `util/stage.rs::CodingAgentDimensions`                         |
| Deterministic decision cascade    | `util/stage.rs::pick_tier()`                                   |
| Decision-source telemetry         | `util/stage.rs::DecisionSource`                                |
| Stateful classifier composition   | `crates/libsy/src/algorithms/fall_through.rs`                  |
| Session lifecycle / TTL           | `fall_through.rs::SessionState`                                |

---

# 25. Final Design Principle

從 Switchyard 最值得 migration 的不是它的 routing formula，而是三個 architecture patterns：

```text
1. SEPARATION

Which worker?
≠
How long should that assignment live?


2. OBSERVE BEFORE ESCALATING

Task looks difficult
≠
Worker is actually failing.


3. HARD RULES → SIGNALS → JUDGMENT

deterministic boundary
        ↓
observable trajectory
        ↓
LLM judgment only when ambiguous
```

套到我們系統後：

```text
Lead
= strategic judgment + durable intent

Worker
= repository context + execution

Affinity
= reuse expensive worker understanding

Escalation
= protect quality when worker exceeds its capability

Handoff
= prevent worker context from leaking back into Lead
```

這些是 Switchyard 最值得我們保留的部分。
