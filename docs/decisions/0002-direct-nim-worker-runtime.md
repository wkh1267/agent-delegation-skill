# 0002 — Direct NVIDIA NIM Worker runtime

**Date:** 2026-09-03  
**Status:** accepted  
**Supersedes:** the runtime choice in [0001](0001-codex-nim-worker-runtime.md). Everything
0001 says about Delegent being runtime-agnostic, about credential isolation, and
about the Context Firewall still stands.

## Context

0001 chose the Codex harness with a custom NVIDIA NIM provider, on the reasoning
that Codex already owns the agent loop, repository tools, sandbox, JSONL
lifecycle and sessions, so Delegent would only need a thin adapter.

That reasoning held for every layer except the one Delegent cannot compromise.
N0 through N3 all passed live, including a real `exec_command` repository read
under an enforced Windows sandbox. N4 then needed a machine boundary for the
terminal handoff, and neither available mechanism could provide one.

### Why `--output-schema` cannot be the boundary

Hosted NIM accepts the Responses `text.format` json_schema object that Codex
sends, and mostly honours it, but does not enforce it:

```text
exact conformance                8/10 sampled at the provider
failure mode                     always the same malformation
usable via codex exec            1 of 7 attempts
```

The six unusable attempts hung rather than failing. Codex re-requests when the
final message does not satisfy the schema, and a provider that never converges
turns that into a loop that only ends at the timeout. Attaching `text.format`
also suppresses function calling outright (0/3 observed), so a tool-using Worker
cannot carry the schema in the same turn at all.

A soft schema is not a machine boundary. Prompt compliance was already rejected
in 0001 for the same reason.

### Why the MCP tool boundary cannot be reached

The tool-call path is sound in isolation. `delegent-handoff-mcp.js` advertises
the shipped schema as its input schema, validates every submission, rejects a
non-conforming one with its specific violations, and never persists a rejected
payload. `evals/test-delegent-handoff-mcp.ps1` pins that with five rejection
controls and a reject-then-correct recovery.

Codex will not expose it. It launches the server and completes the handshake --
`initialize`, then `tools/list`, both traced from the server side -- yet the
model only ever receives `exec_command`, `list_mcp_resources` and `get_goal`.
MCP *resources* are surfaced; MCP *tools* are not. Having no callable tool, the
model invents names and the router refuses them:

```text
error=unsupported call: delegent_handoff
```

Every documented knob leaves it unexposed, while `codex mcp list` continues to
report the server enabled:

```text
enabled = true
required = true
default_tools_approval_mode = "auto"
enabled_tools = ["delegent_handoff"]
features.code_mode        both states
features.code_mode_host   both states
```

The cause is not visible from outside the binary. The plausible readings are
that this build routes MCP tools through the code-mode host it ships, and/or
gates the tool surface on model metadata Codex does not have for a custom NIM
model -- which is what the every-turn `Model metadata ... not found` notice
warns about. Either way the boundary is unreachable here.

## Decision

Own the loop. Drive NIM's `/v1/responses` directly and carry the terminal
handoff as **function-call arguments**, validated at the boundary.

Function calling is this provider's reliable path, which is the whole basis for
the choice: it passed N1 with valid arguments, and N3 with a real
`exec_command`. The boundary is `delegent_handoff`, a tool whose parameters are
the shipped handoff schema.

```text
Codex / GPT-5.6 Sol = Lead
        |
        | Delegent placement + Context Firewall
        v
delegent-nim-worker.js
        |
        +-- read_file            path-contained, read-only
        +-- delegent_handoff     the machine boundary
        |
        v
exact validation against delegent-handoff.schema.json
        |
        v
Context Firewall filtering
        |
        v
Lead final review
```

A rejected submission is never persisted and never reaches the Lead; its
violations go back so the Worker can correct itself. Nothing is repaired,
coerced or re-parsed at the boundary.

## What this costs

Codex was supplying real things, and they are now gone. This must not be
quietly assumed back:

- **The sandbox.** There is no managed sandbox any more. The tool surface is
  therefore read-only *by construction*: one repository read, containment
  checked on the resolved real path so a symlink cannot walk out, no shell and
  no writes. `mutation_capable=False` and `shell_tool_present=False` are
  asserted by the gate, not merely intended.
- **Mutation is blocked until sandboxing is solved.** The N6-equivalent gate
  cannot proceed by adding a shell tool to this runtime. That needs a real
  sandbox story first, and it is the largest open cost of this decision.
- **Session persistence and resume.** Codex's thread store and `codex exec
  resume` both worked and are not replaced. Worker continuity has to be built.
- **Codex's own repository tooling** -- ripgrep integration, apply_patch,
  review mode -- is not available.

What carries over unchanged: the Delegent protocol, both schemas, the exact
validator, the Context Firewall, and the boundary's reject-then-correct
behaviour, all shared as one implementation in `delegent-schema.js`.

## Consequences

- The handoff boundary is enforced by code we own, so it cannot be softened by a
  provider or a host runtime.
- One validator serves both hosts, so the boundary cannot validate differently
  depending on who calls it.
- The Worker's capability is honestly narrow. Read-only exploration and
  reporting work today; implementation and mutation do not.
- Codex+NIM is **not** deleted. N0-N3, the Windows sandbox fix and the
  diagnostics stay as a working baseline and as the comparison arm for the
  bake-off, and the MCP boundary server stays parked in case tool exposure
  changes in a later Codex.
- Provider reliability is now our problem to absorb: the endpoint intermittently
  404s a valid model id or drops the response stream, so the runtime retries
  requests with a bounded budget and reports the count.

## Validation

`evals/run-nim-worker-handoff.ps1` (D1) is the first gate and passes live:

```text
process_exit_code=0
read_file_succeeded=True
handoff_attempt_count=1
handoff_rejected_count=0
handoff_accepted_count=1
schema_exact=True
status_completed=True
evidence_has_readme_line=True
changes_empty=True
sensitive_filter_applied_to_strings>0
mutation_capable=False
shell_tool_present=False
working_tree_unchanged=True
credential_leak_detected=False
overall=PASS
```

The gate re-validates the persisted handoff itself rather than trusting the
runtime under test, and its task prompt never names the handoff fields, so exact
conformance cannot be explained by prompt-following.

`evals/test-delegent-boundary.js` pins the boundary deterministically in CI: the
validator's accept and reject behaviour, the firewall's redactions, and path
containment including absolute paths, parent-directory escapes, directories and
symlinks out of the repository.
