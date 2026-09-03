# AGENTS.md

Delegent: a Lead agent delegates context-heavy work to a Worker runtime, which
reports back through a validated compact handoff. `README.md` and `spec.md`
describe the product; this file carries what you cannot learn by reading the
code.

## Sources of truth

- `CONTEXT.md` — the project's vocabulary. Read it before naming a new concept,
  and challenge it when a term you need conflicts with one already defined.
- `evals/next-test-plan.md` — gate status, live evidence, and the next gate.
  Read it before starting, resuming, or reporting on any gate.
- `docs/decisions/` — why the runtime, the handoff boundary, and the mutation
  boundary are what they are. Read before proposing a change to any of them.
  ADR-0002 supersedes ADR-0001's runtime choice; the rest of 0001 still holds.

Both are current. Prefer them over any handoff document in the repo root, which
is a dated snapshot.

## The boundary is the point

Everything else here is negotiable. These are not.

- **The handoff crosses as validated tool-call arguments.** Prompt-only JSON is
  not a boundary — the model complying is not the same as the contract holding.
- **Reject, never repair.** A non-conforming submission is discarded and
  re-asked with its violations. Coercing, unwrapping, or re-parsing model output
  turns the boundary into a suggestion.
- **One validator implementation**, shared by every host that needs it
  (`skills/delegating-work/tools/delegent-schema.js`). A boundary that validates
  differently depending on its caller is not a boundary.
- **A Worker never changes the user's working tree.** Mutation lands in a
  staging tree, its scope is declared before the work and cross-checked against
  the observed diff afterwards, and there is **no shell tool** — adding one is
  the most dangerous shortcut available in this repo, and it is gated on its own
  decision. Every tool routes through `resolveContainedEntry` rather than
  resolving a model-supplied path itself. ADR-0003 has the reasoning; the short
  version is that a file write is recoverable and a command is not.
- **Diagnostics emit booleans, counts, and classifications.** A Worker once
  expanded a configured API key into tracked source before review caught it.
  Report `credential_present=True`, never the value, and sanitize any captured
  stderr before it reaches output.

## Evidence discipline

- **Repeat before concluding a capability.** A single passing sample proves
  nothing about a probabilistic system. Structured output looked "enforced" at
  n=1 and turned out to be 8/10 at n=10 — the conclusion inverted. Report a
  rate, and say what n was.
- **Prove a mechanism with a differential**, not one observation. Two arms that
  differ in exactly one thing tell you the cause; one arm tells you the weather.
  This is how the Windows sandbox fix was confirmed and how soft schema
  enforcement was caught.
- **Separate model variance from a real break.** A gate that asserts an exact
  model string will occasionally fail while every other field stays healthy.
  Rerun it and record the rate. Loosening the assertion destroys the signal.
- **Name the paths a green run left untested.** A 10/10 result hides which
  branches never executed; say which ones, so nobody reads coverage into luck.

## Traps that already cost hours here

Each of these produced a confusing failure, none is discoverable from config.

**Bash heredocs collapse backslashes.** `\\0` arrives as `\0`, which a Python
string literal reads as an octal escape and emits as a real NUL byte; `\\r?\\n`
becomes literal CR and LF and breaks the JS regex literal it was meant to
produce. Symptom: `Binary file ... matches` from git or grep, or a syntax error
on a line that looks fine.
→ Write backslash-bearing content with Write/Edit, which passes it verbatim. If
a script must generate it, build the bytes without backslash literals in the
source (`bytes([92])`).

**PowerShell `@($null).Count` is 1.** An absent JSON Schema `enum` therefore
looks like an enum whose only allowed value is `$null`, and every free-text
field reports "outside its allowed values".
→ Drop nulls before deciding a collection is non-empty:
`@(@($x) | Where-Object { $null -ne $_ })`.

**PowerShell variable names are case-insensitive.** A local `$extra` silently
overwrites the function's `[hashtable]$Extra` parameter. Symptom: `Cannot
convert the "0" value of type "System.Int32" to type "System.Collections.Hashtable"`.
→ Name locals so they cannot collide with a parameter under case folding.

**PowerShell `-replace` takes a regex replacement string.** `-replace '\\', '\\\\'`
turns one backslash into four, so a Windows path escaped for TOML parses back to
a doubled-backslash path that no longer resolves.
→ Use `.Replace('\', '\\')` for literal escaping.

**Node on Windows aborts if you exit with stdin open.** Symptom: exit code
`-1073740791` (`0xC0000409`) plus `Assertion failed: !(handle->flags &
UV_HANDLE_CLOSING)` in `async.c`, which hides the real outcome.
→ Set `process.exitCode` and let the loop unwind. Read stdin asynchronously.

**Codex `doctor --json` is a redacted report.** An enabled Windows sandbox
backend comes back as the literal string `<redacted>`, while `disabled` prints
verbatim — so matching on a backend name can never succeed.
→ Gate it negatively, against `disabled`.

**`Get-Command codex` resolves `codex.ps1` before `codex.cmd`.** The npm
PowerShell shim fails on redirected stdin.
→ Probe `codex.exe` → `codex.cmd` → `codex.ps1`, in that order.

## Running the gates

Static suites are in CI (`.github/workflows/worker-protocol-windows.yml`) and
need no credential. Live gates read the NIM key from `NIM_API_KEY`,
`DELEGENT_API_KEY`, or the ignored `skills/delegating-work/.env`, in that order.

Each probe is self-contained and independently runnable, which is why several
carry their own copy of the schema validator. That duplication is deliberate for
now and consolidates at D5.
