# Spec: Context-Aware Delegation Skill for Coding Agents

## 1. Overview

建立一個可全域使用的 coding-agent skill，讓高能力但 context 較珍貴的 Lead Agent，能自動判斷哪些工作應保留在自己的 context 中，哪些工作應委派給具有大型 context window 的 Worker Agent。

第一版目標環境：

* **Lead Agent:** Codex / GPT-5.6 Sol high/xhigh
* **Worker Harness:** OpenCode
* **Worker Model:** NVIDIA Nemotron 3 Super 120B
* **Worker Context:** up to ~1M tokens
* **Skill Framework:** based on `mattpocock/skills`
* **Delegation inspiration:** `axiomantic/spellbook/dispatching-parallel-agents`

核心設計理念不是：

> easy task → cheap model
> hard task → expensive model

而是：

> **decision-heavy work → Lead**
> **context-heavy / execution-heavy work → Worker**

更精確地說，本 skill 要回答：

> **Where should this work live?**

可能的答案包括：

1. Lead context
2. Existing persistent worker context
3. Fresh worker context
4. Persistent project memory

---

# 2. Problem

Codex Lead Agent 擁有較強的 reasoning ability，但大型 repository 工作會快速消耗 context。

常見低價值 context 包括：

* 大量 source code
* repository exploration
* grep/search results
* dependency tracing
* generated files
* test output
* debugging logs
* failed hypotheses
* repetitive implementation details

這些資訊通常只有在執行過程中有用，Lead Agent 最後只需要：

* 結論
* evidence
* architecture implications
* implementation summary
* risks
* unresolved decisions

如果 Lead 親自完成所有探索與 implementation：

```text
Lead context
├─ requirements
├─ architecture
├─ 50 source files
├─ grep output
├─ test output
├─ debug attempt #1
├─ debug attempt #2
├─ implementation details
└─ review
```

其 reasoning context 會被大量低 reuse-value information 佔據。

理想架構應為：

```text
Lead context
├─ user intent
├─ requirements
├─ architecture
├─ important decisions
├─ worker findings
├─ risks
└─ final review
```

而大量 implementation context 留在 Worker。

---

# 3. Goals

## G1. Preserve Lead Context

讓 Lead context 的成長：

> roughly proportional to number of decisions

而不是：

> roughly proportional to amount of codebase work

---

## G2. Delegate Context-Heavy Work

以下工作原則上應優先交給 Worker：

* repository exploration
* broad code reading
* large-file reading
* dependency tracing
* implementation of approved designs
* routine refactoring
* test generation
* running tests
* debugging
* log analysis
* documentation
* mechanical migrations
* independent verification

---

## G3. Keep High-Impact Decisions With Lead

以下工作原則上由 Lead 負責：

* interpreting user intent
* requirement clarification
* high-level planning
* architecture
* public API semantics
* database/schema semantics
* security-sensitive decisions
* irreversible/high-blast-radius decisions
* resolving conflicting requirements
* reviewing important Worker conclusions
* final acceptance

---

## G4. Reuse Valuable Worker Context

Worker 不應全部是 disposable subagents。

如果 Worker 已經花費大量 context 理解某個 subsystem，後續相關工作應優先 reuse 相同 session。

例如：

```text
scheduler worker
├─ explore scheduler architecture
├─ implement retry
├─ run tests
├─ debug lease failure
└─ implement follow-up fix
```

而不是每一步重新建立新 worker。

---

## G5. Preserve Independent Judgment When Needed

某些工作應刻意使用 Fresh Worker：

* independent code review
* security review
* spec compliance review
* second opinion
* root-cause verification
* challenging an existing architecture

因為 persistent worker 的既有 assumptions 可能造成 confirmation bias。

---

# 4. Non-Goals for V0.1

第一版不處理：

* generic multi-provider model routing
* automatic cost optimization across many models
* large worker pools
* complex task DAG scheduler
* automatic worktree management
* automatic merge orchestration
* distributed workers
* advanced performance telemetry
* autonomous long-running project management

V0.1 只驗證：

> **Lead / Worker routing + Worker memory reuse 是否有效。**

---

# 5. Integration With `mattpocock/skills`

使用 `mattpocock/skills` 作為主 engineering workflow。

現有 workflow：

```text
grill-with-docs
      ↓
   to-spec
      ↓
  to-tickets
      ↓
  implement
      ↓
     tdd
      ↓
 code-review
```

新增一個 model-invoked shared discipline：

```text
delegating-work
```

它不取代任何既有 skill。

它作為底層 policy，被其他 engineering skills 自動使用。

---

# 6. Proposed Repository Structure

```text
skills/
└─ engineering/
   └─ delegating-work/
      ├─ SKILL.md
      └─ references/
         ├─ routing-policy.md
         ├─ worker-memory.md
         └─ worker-contract.md
```

另外在使用者環境中提供 Worker adapter：

```text
docs/
└─ agents/
   └─ worker-agent.md
```

責任分離：

```text
delegating-work
→ WHEN / WHERE should work be delegated?

worker-agent
→ HOW is the worker invoked?
```

因此 routing policy 不 hardcode：

* NVIDIA
* Nemotron
* OpenCode
* API endpoint

未來可以替換 Worker 而不修改 delegation logic。

---

# 7. Core Routing Model

每個 significant work unit 都經過 routing decision。

## Stage 1 — Lead Ownership Gate

判斷：

> Does the Lead need to own this decision?

以下情況保留給 Lead：

* user intent
* ambiguous requirements
* architecture
* public contracts
* schema semantics
* security
* high blast radius
* irreversible decisions
* conflicting requirements
* final acceptance

若 YES：

```text
→ Lead
```

若 NO：

進入 Stage 2。

---

## Stage 2 — Context Value Gate

判斷：

> Does the Lead need the intermediate context, or only the result?

如果只有 result 有長期價值：

```text
→ Delegate
```

例如：

* search many files
* trace call graph
* investigate subsystem
* analyze logs
* run tests
* routine implementation
* mechanical refactor

如果 intermediate reasoning 對之後決策仍然重要：

```text
→ Lead
```

---

## Stage 3 — Delegation Overhead Gate

如果 task 極小：

```text
dispatch cost > task cost
```

則 Lead 可以直接完成。

例如：

* read one targeted small file
* inspect one known symbol
* trivial local lookup

避免 over-delegation。

---

# 8. Worker Selection

一旦決定 Delegate，不代表一定建立 Fresh Worker。

第二個 routing problem 是：

> **Which worker context should own this work?**

---

## 8.1 Existing Persistent Worker

Reuse when:

* same subsystem
* same feature thread
* implementation → test → debug loop
* follow-up task benefits from previous exploration
* prior context is still trustworthy

Example:

```text
Task 1: understand scheduler
        ↓
scheduler worker

Task 2: implement retry
        ↓
same scheduler worker

Task 3: fix failing scheduler test
        ↓
same scheduler worker
```

---

## 8.2 Fresh Worker

Start fresh when:

* unrelated subsystem
* independent verification needed
* second opinion required
* security review
* spec compliance review
* existing worker assumptions should be challenged
* previous worker became confused
* existing context is excessively stale

---

# 9. Worker Memory Model

分成三種 memory。

## 9.1 Lead Memory

Lives in:

```text
Codex context
```

Contains:

* user intent
* requirements
* high-level plans
* architectural decisions
* worker summaries
* unresolved decisions
* risks
* acceptance state

Does not normally contain:

* broad source dumps
* raw logs
* complete test output
* debugging history

---

## 9.2 Worker Working Memory

Lives in:

```text
OpenCode / Nemotron session
```

Contains:

* detailed repository understanding
* implementation context
* file relationships
* test history
* debugging state
* temporary hypotheses

Worker sessions should be reused where continuity provides value.

---

## 9.3 Persistent Project Memory

Lives in repository artifacts.

Possible layout:

```text
.agent/
├─ project-map.md
├─ subsystems/
│  ├─ scheduler.md
│  ├─ auth.md
│  └─ database.md
└─ decisions/
```

Only persist information that is:

* expensive to rediscover
* relatively stable
* important to future work
* architectural or invariant-level knowledge

Examples:

```text
scheduler owns recurrence calculation
dispatcher intentionally remains stateless
timestamps are persisted in UTC
lease acquisition happens before dispatch
```

Do NOT persist:

* temporary logs
* raw source summaries
* failed hypotheses
* easily rediscoverable implementation details
* transient debugging output

---

# 10. Worker Staleness Handling

Persistent worker memory may become stale when repository HEAD changes.

Each worker tracks at minimum:

```text
SESSION_ID
SCOPE
LAST_SYNC_COMMIT
LAST_TASK
```

Before reuse:

```text
previous worker commit
        ↓
compare with current HEAD
        ↓
inspect relevant changed files
        ↓
update mental model
        ↓
continue
```

The Worker should not reread the entire repository unless necessary.

---

# 11. Worker Escalation Protocol

Worker must stop and escalate when encountering a decision owned by Lead.

Examples:

* architecture ambiguity
* public API behavior change
* DB schema semantics
* security-sensitive behavior
* conflicting requirements
* destructive or irreversible choice

Worker sends:

```text
DECISION_NEEDED

Question:
...

Relevant evidence:
- file:line
- behavior
- alternatives

Options:
A ...
B ...

Worker recommendation:
...

Confidence:
...
```

Lead decides.

Worker then resumes using that decision.

---

# 12. Worker Handoff Contract

Worker should return compressed, high-information reports.

Required format:

```text
STATUS
completed | blocked | decision-needed

SUMMARY
Short description of result.

EVIDENCE
Relevant files, symbols, commands, or observations.

CHANGES
Files and major behaviors changed.

TESTS
Commands executed and results.

RISKS
Known risks or uncertainty.

DECISIONS_NEEDED
Questions requiring Lead judgment.

REVIEW_TARGETS
Specific files / functions Lead should inspect.
```

Worker should NOT return:

* entire source files
* giant logs
* full chain-of-thought
* complete repository maps
* detailed failed attempts unless relevant

Target principle:

```text
Worker may consume 300K+ tokens internally.

Lead receives ~0.5–2K tokens of useful output.
```

---

# 13. Parallelism Policy

Delegation and parallelism are separate decisions.

First:

```text
Should this be delegated?
```

Then:

```text
Can multiple delegated tasks safely run in parallel?
```

Parallelize only if:

* tasks are independent
* they do not modify the same files
* they do not depend on shared mutable state
* completion of one does not invalidate another
* no hidden sequential dependency exists

Unknown-scope investigation should normally start with:

```text
one explorer worker
```

After independent domains are identified:

```text
worker A
worker B
worker C
```

may run in parallel.

---

# 14. Relationship With Matt's Phase Boundaries

Matt's existing phase-boundary logic handles:

```text
Continue
Clear
Handoff
Subagent
Compact
```

This operates at:

> session / phase level

The new `delegating-work` skill operates at:

> work-unit level inside a phase

Example:

```text
Implementation Phase
        │
        ├─ architecture decision
        │       → Lead
        │
        ├─ explore scheduler
        │       → Worker
        │
        ├─ implement change
        │       → same Worker
        │
        ├─ security question
        │       → Lead
        │
        └─ verification
                → Fresh Worker
```

The two systems are complementary.

---

# 15. Global Installation Strategy

The customized skills repository is the single source of truth.

Example:

```text
D:\Development\skills
```

Global skill path:

```text
~/.agents/skills/delegating-work
```

Use symlink/junction from:

```text
~/.agents/skills/delegating-work
```

to:

```text
D:\Development\skills\
skills\engineering\delegating-work
```

Result:

```text
Project A ─┐
Project B ─┼→ Codex / OpenCode
Project C ─┘        ↓
              global delegating-work
```

No per-project skill copy is required.

Project-specific constraints may remain in local:

```text
AGENTS.md
```

or project-level skill override.

---

# 16. V0.1 Implementation Scope

Create:

```text
skills/engineering/delegating-work/
├─ SKILL.md
└─ references/
   ├─ routing-policy.md
   ├─ worker-memory.md
   └─ worker-contract.md
```

And:

```text
docs/agents/worker-agent.md
```

### `SKILL.md`

Contains only:

* core routing decision
* when to keep Lead
* when to delegate
* when to reuse/fresh worker
* pointers to detailed references

Keep it short and model-invokable.

### `routing-policy.md`

Contains:

* Lead ownership rules
* context-value routing
* delegation overhead
* parallelism gate
* escalation cases

### `worker-memory.md`

Contains:

* ephemeral vs persistent worker
* reuse rules
* fresh-worker rules
* stale context handling
* project memory rules

### `worker-contract.md`

Contains:

* worker task input schema
* result schema
* escalation schema
* compression requirements

### `worker-agent.md`

Contains:

* OpenCode invocation
* Nemotron model/provider configuration
* session creation/reuse
* session identifiers
* execution details

---

# 17. V0.1 Validation

Before adding more orchestration features, evaluate routing quality on real coding tasks.

Collect approximately 10–20 representative tasks.

Examples:

1. Locate implementation of feature X.
2. Read a large subsystem and explain behavior.
3. Make a small architecture decision.
4. Implement an approved API change.
5. Refactor 15 similar files.
6. Debug failing tests.
7. Review a completed change.
8. Investigate a security-sensitive issue.
9. Continue work in a previously explored subsystem.
10. Work on an unrelated subsystem.

For each task record:

```text
Expected owner
Actual owner
Worker reused?
Fresh worker?
Was delegation useful?
Did Lead duplicate Worker investigation?
Did Lead receive enough evidence?
Did Worker escalate appropriately?
```

---

# 18. Success Criteria

V0.1 is successful if:

### Routing

* context-heavy tasks are consistently delegated
* high-impact decisions remain with Lead
* trivial tasks are not excessively delegated

### Context Preservation

* Lead rarely performs broad repository exploration
* raw logs/test output do not significantly pollute Lead context
* Worker outputs remain concise

### Memory Reuse

* related follow-up work reuses an existing Worker
* independent review uses fresh context
* stale Worker sessions correctly resync before continuing

### Decision Safety

* Workers escalate architecture/security/API/schema decisions
* Lead retains final acceptance authority

### Workflow Compatibility

* Matt's existing `/implement`, `/tdd`, `/code-review`, etc. remain independently usable
* `delegating-work` acts as reusable shared discipline rather than owning the whole workflow

---

# 19. Future Versions

## V0.2

Add:

* automatic OpenCode/Nemotron execution wrapper
* persistent session registry
* session scope metadata
* automatic git-based worker resync

## V0.3

Add:

* multiple persistent subsystem workers
* parallel independent workers
* worktree isolation
* automatic reviewer workers

## V0.4

Add:

* model/provider routing
* task success statistics
* token/cost tracking
* adaptive routing thresholds
* automatic worker escalation

---

# 20. Design Principle

The central optimization target is not:

> use the cheapest model possible.

It is:

> **Keep high-value decisions in the strongest context, and move high-volume disposable context into the worker context.**

The Lead should know:

* what is being built
* why it is being built
* what important decisions were made
* what risks remain
* whether the result is acceptable

The Worker should know:

* how the repository actually works
* which files matter
* how to implement the approved design
* how to test and debug it

In short:

```text
Lead = strategic memory + judgment
Worker = execution memory + repository context
Repo  = durable project knowledge
```

That separation is the foundation of the system.
