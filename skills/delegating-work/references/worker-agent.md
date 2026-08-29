# Nemotron Worker

Install OpenCode. The wrapper loads `api_key` from the ignored `.env` beside
`opencode.json` and keeps all delegated-worker OpenCode state under one runtime
directory; never commit `.env`.

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

## Persistent session titles

When a Worker is expected to survive follow-up work, give it a stable title so
V0.1 can find it without a registry:

```text
delegent:<project>:<scope>:<role>
```

Example:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" `
  --agent build `
  --dir "<project-path>" `
  --title "delegent:personal-assistant-backend:scheduler:build" `
  "<task>"
```

Use a fresh title/session for independent review or other work where prior
assumptions are intentionally undesirable.

## Session reuse

Always list delegated-worker sessions through the wrapper so OpenCode reads the
same XDG data/state directories that the wrapper used when creating them:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" sessions
```

For machine-readable output:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" sessions --format json
```

Match the stable title described by `worker-memory.md`, then reuse the session
when its scope, role, and memory are still suitable:

```powershell
& "$env:USERPROFILE\.agents\skills\delegating-work\scripts\nemotron-worker.ps1" --agent <plan-or-build> --dir "<project-path>" --session <session-id> "<task>"
```

Do not use a bare `opencode session list` for delegated-worker discovery unless
you have manually reproduced the wrapper's runtime environment; otherwise it may
look at a different OpenCode data directory.

## Read-only resynchronization

The `plan` agent cannot edit files. It may use only narrowly scoped read-only Git
commands (`git status`, `git log`, `git diff`, `git show`, and `git rev-parse`) in
addition to normal read/search tools. Use these commands to compare the reused
Worker's last-known repository state with current HEAD before trusting stale
working memory.

The current V0.1 runtime does not yet persist `last_sync_commit` automatically,
so the Lead/Worker must carry or rediscover the relevant previous commit until a
Worker registry lands.

Nemotron reasoning is enabled by the model default; no custom request-body
fields are required.

The task must include the scope, approved decisions, constraints, expected
verification, and allowed files. The worker must follow
[worker-contract.md](worker-contract.md), escalating lead-owned decisions and
returning its concise handoff format.
