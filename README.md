# Agent Delegation Skill

Context-aware coding-agent orchestration for Codex.

The project separates **workflow semantics**, **work placement**, and **Worker execution**:

```text
$delegent $implement
        │
        ▼
     Delegent
        │
        ├─ selected workflow (for example Matt's implement)
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
              compressed handoff
                       │
                       ▼
                Lead acceptance
```

The optimization target is not "easy task vs hard task". It is:

- **decision-heavy work → Lead**
- **context-heavy / execution-heavy work → Worker**

See [`spec.md`](spec.md) for authoritative product requirements and
[`migration-spec.md`](migration-spec.md) for Switchyard-derived design provenance.

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
- stable title convention for manual/deterministic Worker affinity
- limited read-only Git commands for Worker resynchronization

Not yet implemented:

- automatic Worker registry and `last_sync_commit` tracking
- trajectory-based failure escalation
- routing telemetry
- multi-Worker parallel runtime

## Prerequisites

- Codex with the engineering workflow skills you want to compose (for example Matt Pocock's `implement`)
- [OpenCode](https://opencode.ai/)
- an NVIDIA NIM API key with access to the configured Nemotron model

Install OpenCode:

```powershell
npm install -g opencode-ai
```

## Development install on Windows

Clone this repository, then expose both skills through the global Agent Skills directory.

Example, if the repository is at `D:\Development\agent-delegation-skill`:

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\skills"

New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegent" `
  -Target "D:\Development\agent-delegation-skill\skills\delegent"

New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegating-work" `
  -Target "D:\Development\agent-delegation-skill\skills\delegating-work"
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

V0.1 expects `Delegent` plus exactly one companion workflow skill:

```text
$delegent $implement

架構已確認，請實作 reminder retry。

允許修改：
- src/reminders/**
- tests/reminders/**

要求：
- retry 最多 3 次
- lease semantics 不變
- 補 regression tests
```

The user selects the workflow and desired outcome. Delegent decides where each significant work unit should live, whether a Worker should be reused or created fresh, and when work must return to the Lead for a consequential decision or final acceptance.

## Worker sessions

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
