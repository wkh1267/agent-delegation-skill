# Worker Memory

Reuse an existing worker when continuity is useful:

- the same subsystem or feature is still in scope
- work continues through implementation, testing, and debugging
- prior exploration remains relevant and trustworthy

Use a fresh worker when independence is useful:

- the subsystem or task is unrelated
- review, security analysis, or a second opinion should challenge assumptions
- the existing context is confused or too stale to resynchronize cheaply

Before reuse, compare the worker's last known repository state with the current
state and inspect relevant changes. Do not reread the whole repository unless
those changes invalidate the worker's model.

Persist only stable, expensive-to-rediscover project facts in repository
documentation. Keep raw logs, failed hypotheses, and transient debugging state
inside the worker context.
