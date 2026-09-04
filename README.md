# Agent Delegation Skill

Context-aware coding-agent orchestration for Codex.

The project separates **workflow semantics**, **work placement**, and **Worker execution**:

```text
$delegent $<workflow>
        │
        ▼
     Delegent
        │
        ├─ explicitly selected workflow
        └─ delegating-work placement policy
                 │
           ┌─────┴─────┐
           ▼           ▼
         Lead        Worker
       Codex/Sol     OpenCode
                       │
                       ▼
                    Nemotron
                       │
                       ▼
              validated handoff
                       │
                       ▼
                Lead acceptance
```

The optimization target is not "easy task vs hard task". It is:

- **decision-heavy work → Lead**
- **context-heavy / execution-heavy work → Worker**

Delegent is workflow-agnostic. Matt Pocock's `implement` workflow is an important real-world integration target, not a Delegent dependency.

See [`spec.md`](spec.md) for authoritative product requirements,
[`migration-spec.md`](migration-spec.md) for Switchyard-derived design provenance,
[`skills/delegating-work/references/runtime-protocol.md`](skills/delegating-work/references/runtime-protocol.md) for the Worker transport boundary, and
[`evals/next-test-plan.md`](evals/next-test-plan.md) for the current validation sequence.

## Current V0.1

Implemented:

- `delegent` user-invoked orchestration skill
- `delegating-work` Lead/Worker placement policy
- Worker reuse-vs-fresh policy
- compact dispatch and handoff contracts
- hard Lead-owned decision escalation
- OpenCode/Nemotron Worker adapter
- read-only `plan` and mutating `build` Worker roles
- wrapper-scoped OpenCode session discovery/reuse
- durable-first Worker session storage
- stable title convention for manual/deterministic Worker affinity
- limited read-only Git commands for Worker resynchronization
- repository-local `delegent-eval-workflow` for controlled composition testing

Validated so far:

- Nemotron `plan` Worker execution succeeds through the configured OpenCode/NIM path
- denied general-shell operations are enforced and the Worker can recover with allowed read tools
- same-session follow-up preserves useful continuity and can deliberately reuse prior Worker context
- read-only Git resynchronization (`status`, `log`, `diff`) works without broad repository rereading
- the first full Codex/Delegent run routed context-heavy work toward Workers, avoided mechanically reusing an unrelated Worker, selected a fresh independent reviewer after failure, and preserved Lead final acceptance
- Lead acceptance caught and rejected a destructive Worker-authored runtime-adapter change (`DELEGATE_LOSS`)

Current blockers / findings:

- prompt compliance alone is not a reliable machine-to-machine handoff boundary; delegated runs intermittently completed tool activity without a valid terminal handoff
- Worker protocol transport therefore needs structured result validation and deterministic `WORKER_PROTOCOL_ERROR` handling before another broad end-to-end test
- Worker-adapter code that loads credentials, constructs provider process state, parses protocol output, or controls session storage is security-sensitive and must remain Lead-owned for mutation/review
- exact staleness detection remains partial because V0.1 does not yet persist `last_sync_commit`
- if an explicitly selected companion workflow is unavailable, Delegent now fails fast instead of approximating its semantics

Detailed observations are recorded in [`evals/v0.1-smoke.md`](evals/v0.1-smoke.md).

## Validation order

Do not use Matt's `implement` as the next immediate runtime test. Validate in layers:

```text
A. Worker protocol
   fake/local runtime only
        ↓
B. Controlled composition
   $delegent $delegent-eval-workflow
        ↓
C. Real workflow integration
   Matt Pocock $implement (+ tdd/code-review)
        ↓
D. Real ticket/spec development
```

See [`evals/next-test-plan.md`](evals/next-test-plan.md) for exact preflight, stop conditions, and commands.

## Prerequisites

- Codex with the workflow skill you explicitly want to compose
- [OpenCode](https://opencode.ai/)
- an NVIDIA NIM API key with access to the configured Nemotron model for real Worker tests

Matt Pocock's skills are **not** required for Phase A/B controlled validation. For the later real-world `$implement` integration test, install/verify the actual Matt `implement`, `tdd`, and `code-review` workflows together so the selected workflow's completion semantics are available.

Install OpenCode:

```powershell
npm install -g opencode-ai
```

## Development install on Windows

Clone this repository, then expose the core skills through the global Agent Skills directory.

Example, if the repository is at `D:\Development\agent-delegation-skill`:

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\skills"

New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegent" `
  -Target "D:\Development\agent-delegation-skill\skills\delegent"

New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegating-work" `
  -Target "D:\Development\agent-delegation-skill\skills\delegating-work"

New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegent-eval-workflow" `
  -Target "D:\Development\agent-delegation-skill\skills\delegent-eval-workflow"
```

Create the ignored Worker credential file:

```text
skills/delegating-work/.env
```

with:

```text
api_key=<your NVIDIA NIM API key>
```

Never commit this file.

Restart Codex after changing global skill installation if the new skill does not appear immediately.

## Usage

V0.1 expects `Delegent` plus exactly one available companion workflow skill.

Controlled eval example:

```text
$delegent $delegent-eval-workflow

Change evals/fixtures/controlled-workflow.txt from mode=baseline to mode=delegated.
Only modify that fixture.
Run .\evals\check-controlled-workflow.ps1 -Expected delegated.
Do not commit.
```

Real-world integration example after Matt's workflows are installed:

```text
$delegent $implement

<ticket/spec, mutation scope, fixed decisions, and acceptance criteria>
```

The user selects the workflow and desired outcome. Delegent decides where each significant work unit should live, whether a Worker should be reused or created fresh, and when work must return to the Lead for a consequential decision or final acceptance.

If the explicitly selected workflow cannot be loaded, Delegent stops with a setup error rather than inventing equivalent workflow semantics.

## Worker sessions

The Worker wrapper keeps OpenCode state under one controlled runtime root. It prefers:

```text
%LOCALAPPDATA%\agent-delegation-skills\opencode
```

Set `DELEGENT_RUNTIME` to choose another durable location. If the durable default cannot be created, the wrapper falls back to the system temp directory; that fallback should not be relied on for long-lived Worker memory.

List only the sessions created in the delegated-worker runtime:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" sessions --format json
```

Reusable V0.1 sessions should use this title convention:

```text
delegent:<project>:<scope>:<role>
```

For example:

```text
delegent:personal-assistant-backend:scheduler:build
```

See [`skills/delegating-work/references/worker-agent.md`](skills/delegating-work/references/worker-agent.md) for invocation details.

## Design rules

1. The selected workflow owns **what must happen**.
2. Delegent owns **orchestration and final workflow completion**.
3. `delegating-work` owns **Lead-vs-Worker placement and Worker-selection policy**.
4. The Worker runtime owns **how delegated execution happens**.
5. Lead context keeps decisions and compact evidence; Worker context keeps repository exploration and execution history.
6. Final acceptance always stays with the Lead.
7. Delegent must remain independent of any one external workflow implementation.
