# Nemotron Worker

Install OpenCode. The wrapper loads `api_key` from the ignored `.env` beside
`opencode.json` and keeps OpenCode runtime under the system temp directory;
never commit `.env`.

```powershell
npm install -g opencode-ai
```

Start a fresh read-only worker from the target repository:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" --agent plan --dir "<project-path>" "<task>"
```

Use the build agent only when the task explicitly permits changes:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" --agent build --dir "<project-path>" "<task>"
```

List sessions, then reuse one when the worker-memory policy calls for continuity:

```powershell
opencode session list
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" --agent <plan-or-build> --dir "<project-path>" --session <session-id> "<task>"
```

Nemotron reasoning is enabled by the model default; no custom request-body
fields are required.

The task must include the scope, approved decisions, constraints, expected
verification, and allowed files. The worker must follow
[worker-contract.md](worker-contract.md), escalating lead-owned decisions and
returning its concise handoff format.
