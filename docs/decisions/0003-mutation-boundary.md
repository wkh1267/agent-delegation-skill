# 0003 — The mutation boundary is a staging tree, not a jail

**Date:** 2026-09-04  
**Status:** accepted  
**Scope:** how a Delegent Worker is allowed to change a repository (gates D3/D4)

## Context

D4 needs a Worker that can change files. The pivot in
[0002](0002-direct-nim-worker-runtime.md) gave up Codex's managed sandbox, so
the obvious framing was "pick a replacement jail, then allow mutation".

That framing is wrong, and seeing why is the whole decision. The question is not
how much a Worker can be trusted; it is which capabilities carry an
unrecoverable worst case:

```text
writing a file in a git repository   recoverable — worst case is a dirty tree
executing an arbitrary command       unrecoverable — arbitrary code, user's
                                     privileges, nothing to restore from
```

Two capabilities can carry identical intent and warrant completely different
containment. Once that is separated, most of the isolation problem belongs to
the shell, and the shell is not what D4 needs.

## Decision

Four choices, together:

**1. Mutation lands in a staging tree.** A `git worktree` of the repository,
created per delegation, living outside the user's working tree. The Worker never
changes the user's tree, so "nothing outside the scope moved" holds
structurally instead of being proven after the fact. A worktree rather than a
plain copy because git reads work inside it, which preserves the history access
that makes an exploration Worker useful; the repository is ~1 MiB, so the cost
is nil. Its lifetime is the Worker affinity's session lifetime, so an
implement → test → debug sequence keeps its changes and deleting a session
deletes the tree.

**2. The tool surface writes; it does not execute.** Create and overwrite only.
Delete and rename become escalations, because accidental damage concentrates
there and because a rename is indistinguishable from a delete plus a create in a
diff — the operation hardest to verify would otherwise be the most dangerous.
There is no shell tool. Adding one is a separate, later gate, and it is the
point at which real isolation stops being optional.

**3. Scope is declared, reported, and cross-checked.** The Lead declares the
mutation scope as directory prefixes and exact paths before the work. The Worker
reports what it changed in the handoff's existing `changes` field. A verifier
compares both against the observed diff. Three-way agreement is decidable, so
every disagreement names a specific failure rather than needing judgement.

Glob patterns are rejected. Globs are a small language with Windows-specific
surprises — case sensitivity, `**` versus `*`, separator handling — and in a
security check every surprise is a hole. Prefix and exact matching is decided by
`resolveContainedEntry`, which is already covered by the CI boundary suite.

**4. `codex sandbox` is the second layer, not the first.** The whole Worker
process runs under `codex sandbox -P :workspace -C <staging tree>`. Our tool
layer stays the primary control because it is more precise; the sandbox is the
floor under it, so a defect in our own containment cannot escape the staging
tree. It costs essentially nothing, needs no elevation, credential, or model.

### The two verifier failures are not the same failure

This distinction is load-bearing and easy to collapse by accident:

```text
a write outside the declared scope   should be impossible; our tools enforce it.
                                     Observing one means the defect is OURS.
                                     Fail hard, escalate, keep the staging tree,
                                     and do not retry.

reported changes != observed diff    the Worker misreported. Hand back the
                                     specific disagreement and let it resubmit,
                                     exactly like the schema boundary.
```

Retrying a containment breach would smooth over a bug in our own code. That is
the one failure that must never be absorbed by a retry.

## Considered options

Recorded because four of these are unavailable on this machine and will
otherwise be suggested again.

| Mechanism | Verdict |
|---|---|
| `codex sandbox -P :workspace` | **Chosen as second layer.** Verified: writes outside cwd genuinely blocked on both C: and D:, including cross-drive. No elevation, credential, model, or network needed. |
| codex custom permission profiles | Rejected. Multi-root and deny-read require the elevated Windows backend, which means installing a filesystem-filter driver. |
| Windows Sandbox (OS feature) | Unavailable. This host is Windows 11 Home; the binaries are absent. |
| WSL | Unavailable without setup. Installed, but zero distros registered. |
| Docker | Unavailable without setup. Client only; daemon down and its WSL backend has no distro. |
| A jail as the *primary* control | Rejected on the reasoning above. Mutation's worst case is already recoverable, so a jail buys less here than a narrow tool surface plus a verifier. |

## Consequences

- **A sandboxed Worker cannot use git to write.** `:workspace` denies `.git`
  specifically — verified as a deliberate carve-out, since a sibling `.foo/`
  is writable while `.git/` is not. So `commit`, `add`, `stash`, `checkout` and
  `branch` all fail inside the sandbox, while git reads work fine. Committing
  and accepting are done by the unsandboxed orchestrator after the Worker
  returns. This is the safer split, but it is a real constraint and not a
  surprise to discover later.
- **The sandbox scopes writes only.** Reads are unrestricted and the network
  stays open; `--sandbox-state-disable-network` is a no-op unless a sandbox
  state is supplied. So the sandbox does not mitigate exfiltration, which is a
  further reason the shell stays out until a gate is dedicated to it.
- **One writable root.** Extra writable roots cannot be added unelevated, so the
  staging tree root is that single root and any finer scoping within it is
  enforced by our tool layer, not by the sandbox.
- **Read scope is deliberately not narrowed**, despite treating repository
  content as a possible injection vector. Injection cannot grant new write
  paths, because the scope is declared ahead of time and verified, which demotes
  a successful injection from a breach to a wasted turn. Narrowing reads would
  trade the exploration capability D1b delivered for protection the write
  boundary already provides.
- **Delete and rename are unavailable to a Worker** until a later decision
  revisits them. A Worker needing either escalates.
