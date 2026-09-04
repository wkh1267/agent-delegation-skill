# Worker Memory

Reuse an existing worker when continuity is useful:

- the same subsystem or feature is still in scope
- work continues through implementation, testing, and debugging
- prior exploration remains relevant and trustworthy

Use a fresh worker when independence is useful:

- the subsystem or task is unrelated
- review, security analysis, or a second opinion should challenge assumptions
- the existing context is confused or too stale to resynchronize cheaply

## V0.1 affinity convention

Until an automatic Worker registry exists, make reusable sessions discoverable
with a stable OpenCode title:

```text
delegent:<project>:<scope>:<role>
```

Examples:

```text
delegent:personal-assistant-backend:scheduler:build
delegent:personal-assistant-backend:reminders:plan
```

When creating a Worker expected to survive follow-up tasks, pass that title with
`--title`. List sessions through the configured Worker wrapper, match the title,
and reuse the matching session with `--session <session-id>`.

Do not reuse a session merely because its title matches. First confirm that its
scope and role still fit the task and that its working memory is trustworthy.

## Resynchronization

Before reuse, compare the Worker's last known repository state with the current
state and inspect relevant changes. Do not reread the whole repository unless
those changes invalidate the Worker's model.

The exact long-term baseline contract is:

```text
last_sync_commit
      ↓
git diff last_sync_commit..HEAD
      ↓
inspect the complete changed-path set
      ↓
refresh only affected knowledge
      ↓
continue
```

Do not substitute an arbitrary relative window such as `HEAD~N` for
`last_sync_commit`; it cannot prove what changed since the Worker actually
synchronized. Likewise, evidence gathered from one file must not be generalized
into a repository-wide staleness conclusion unless the complete changed-path set
supports it.

The current runtime does not yet persist `last_sync_commit`, so exact automatic
staleness detection remains incomplete. Carry an exact baseline in the task or
handoff when known. If it is not known, use conservative resynchronization rather
than inventing a baseline.

Persist only stable, expensive-to-rediscover project facts in repository
documentation. Keep raw logs, failed hypotheses, and transient debugging state
inside the worker context.
