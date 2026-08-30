# Worker Runtime Protocol

This document defines the V0.1 reliability boundary between Delegent and the configured OpenCode/Nemotron Worker runtime.

The Worker contract defines **what** a Worker must report. This protocol defines **how** the adapter transports and validates that result without leaking the Worker's raw trajectory into Lead context.

## Why the boundary is structured

Early end-to-end runs showed that prompt compliance and human terminal output are not reliable machine-to-machine interfaces. Workers sometimes completed tool activity without a usable final handoff; `opencode run` could omit final text or mix it with banners, stderr/CLIXML, and tool trajectory; and a Worker-authored wrapper repair briefly expanded a credential into generated source before Lead rejected it.

Therefore the Context Firewall is enforced by the adapter, not by prompts alone.

## V0.1 transport

The accepted V0.1 path is:

```text
Codex Lead
  -> compact dispatch
  -> Delegent Worker adapter
  -> authenticated loopback OpenCode session API
  -> normal OpenCode/Nemotron tool execution
  -> exactly one terminal Delegent custom tool
       delegent_handoff
       OR
       delegent_decision
  -> adapter reads only that tool part's state.input
  -> exact validation
  -> compact Lead-visible handoff / escalation
```

The adapter must never reconstruct a missing handoff from assistant prose, tool output, reasoning, stdout/stderr, or other trajectory.

## Why terminal custom tools replaced `format: json_schema`

Phase A initially used OpenCode's special `format: json_schema` structured-output feature. Local fake tests passed, but live compatibility testing on OpenCode 1.18.25 showed:

- `opencode serve`, health, Basic Auth, and session creation worked;
- plain OpenCode/Nemotron execution worked, including repository `read` tool use;
- direct NVIDIA NIM inference with Nemotron 3 Super worked;
- a direct forced named `StructuredOutput` tool call to the same NVIDIA hosted model worked;
- the OpenCode `POST /session/:id/message` path using `format: json_schema` still failed with a runtime error.

This isolates the blocker to OpenCode's special structured-output integration rather than NVIDIA connectivity or Nemotron tool-calling ability.

Delegent therefore uses ordinary OpenCode custom tools for its terminal boundary. This stays machine-readable while avoiding the broken special path.

## Terminal tools

### `delegent_handoff`

Arguments must contain exactly:

```text
status: completed | blocked
summary
evidence
changes
tests
risks
decisions_needed
review_targets
```

### `delegent_decision`

Arguments must contain exactly:

```text
question
evidence
options
recommendation
confidence
```

The adapter converts `delegent_decision` into the Lead-facing `DECISION_NEEDED` contract.

Both terminal tools are side-effect free. They do not read credentials, mutate the repository, or persist handoff files. OpenCode records their structured arguments in the normal session message tool part, and the adapter reads `parts[].state.input`.

The tools live under the Delegent skill and are copied into the wrapper-controlled OpenCode config root before the isolated server starts. Target repositories are not modified.

## Validation rules

For the current delegated task:

1. exactly one terminal Delegent tool call is accepted;
2. zero terminal calls is `missing_terminal_handoff`;
3. multiple handoffs, multiple decisions, or handoff + decision is `malformed_handoff`;
4. the terminal tool must have completed;
5. all required arguments must exist exactly once and be non-empty strings;
6. unexpected arguments are rejected;
7. normal handoff `status` must be exactly `completed` or `blocked`;
8. stale terminal calls from a reused session baseline are ignored;
9. ordinary read/edit/bash/tool parts, reasoning, and assistant text never cross the Context Firewall;
10. any configured sensitive value appearing in the terminal arguments causes deterministic failure;
11. the adapter never fills missing fields from trajectory.

## Session reuse and recovery

For a reused session, the adapter reads the baseline assistant message IDs before sending the new task. Only terminal calls from new assistant messages can satisfy the current dispatch.

Preferred source is the synchronous message response. If that response is empty or lacks the terminal call, the adapter may recover from the supported persisted session-message API while excluding baseline messages.

Do not read OpenCode's SQLite database as the primary protocol source.

## Agent selection

OpenCode 1.18.x has a reported failure mode when the `agent` field is supplied directly on `POST /session/:id/message`. Delegent preserves `--agent` semantics by selecting the requested `default_agent` in the isolated server's runtime configuration instead of putting `agent` in the message body.

## Protocol errors

Failures cross the boundary only as compact deterministic diagnostics:

```text
WORKER_PROTOCOL_ERROR
kind: missing_terminal_handoff | malformed_handoff | timeout | runtime_output_error
session_id: <when known>
exit_code: <when applicable>
summary: <small deterministic diagnostic>
```

Raw runtime exceptions, server logs, provider bodies, Worker prose, and tool trajectory must not be forwarded automatically.

## Security boundary

The adapter is Lead-owned security-sensitive code because it loads ignored provider credentials, builds runtime configuration, owns the authenticated loopback server, controls durable session storage, installs terminal tools, and filters data crossing the Context Firewall.

Rules:

- general build Workers may diagnose this boundary read-only but must not autonomously mutate it;
- Lead owns or explicitly approves adapter mutations and final review;
- credentials remain environment-only and must never be interpolated into source, fixtures, logs, tool files, handoffs, or committed artifacts;
- terminal tools themselves are side-effect free and credential-blind;
- deterministic tests use fake credentials and fake session/API responses before any live NIM call.

## Deterministic acceptance cases

Before live validation, test at minimum:

1. valid `delegent_handoff` accepted;
2. valid `delegent_decision` accepted;
3. ordinary trajectory before the terminal call excluded;
4. missing terminal tool rejected;
5. missing argument rejected;
6. unexpected argument rejected;
7. duplicate terminal call rejected;
8. handoff + decision together rejected;
9. runtime/API failure deterministic and sanitized;
10. timeout bounded and abort attempted;
11. persisted-session recovery succeeds;
12. stale reused-session terminal result rejected;
13. sensitive content in trajectory remains hidden and sensitive content in terminal args is rejected;
14. terminal tools install only into the Delegent-owned runtime config root;
15. Worker message body contains no `format: json_schema` dependency and no direct `agent` field;
16. `sessions`, `--session`, `--title`, `--agent`, and `--dir` compatibility remains intact;
17. OpenCode server process ownership/cleanup remains bounded.

Only after deterministic tests pass should the real terminal-tool path be probed.

## V0.1 acceptance target

```text
Codex Lead
  -> Delegent placement
  -> OpenCode/Nemotron normal tool path
  -> terminal Delegent custom tool
  -> validated compact handoff
  -> Lead review/final acceptance
```

No human terminal scraping and no raw Worker trajectory should be required for a successful delegation.
