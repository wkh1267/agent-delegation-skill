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

Before reuse, compare the worker's last known repository state with the current
state and inspect relevant changes. Do not reread the whole repository unless
those changes invalidate the worker's model. The current runtime does not yet
persist `last_sync_commit`, so carry it in the task/handoff when known or
conservatively rediscover the relevant baseline.

Persist only stable, expensive-to-rediscover project facts in repository
documentation. Keep raw logs, failed hypotheses, and transient debugging state
inside the worker context.
