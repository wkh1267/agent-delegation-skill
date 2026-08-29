# Worker Runtime Protocol

This document defines the V0.1 reliability target for the boundary between
Delegent and the configured OpenCode/Nemotron Worker runtime.

The Worker contract defines **what the Worker must report**. This runtime
protocol defines **how the adapter must transport and validate that report**
without leaking the Worker's raw trajectory into Lead context.

## Motivation

End-to-end smoke testing showed that prompt compliance alone is not a reliable
machine-to-machine boundary:

- a build Worker attempted to create `handoff.txt` and `test.txt` instead of
  returning the required terminal handoff;
- some Worker runs completed tool activity but produced no terminal eight-field
  handoff;
- same-session handoff-only retries could produce no usable output;
- human-oriented terminal output may mix banners, tool trajectory, ANSI output,
  stderr/PowerShell serialization noise, and the final assistant text;
- an attempted Worker-authored wrapper rewrite introduced a PowerShell parse
  failure and expanded a credential value into generated source before Lead
  acceptance rejected the change.

External OpenCode behavior also matters. Current OpenCode documentation exposes
session/message APIs and SDK structured output with JSON Schema, while recent
OpenCode issue reports show that `opencode run --format json` can intermittently
omit final text/step events or hang even after the answer is persisted,
including headless, container, reused-session, and Windows cases (for example
OpenCode issues #26855, #31404, and #32506).

These findings mean the Context Firewall must be enforced by the runtime
adapter, not only by prompts, and that CLI stdout must not be the sole source of
truth for Worker completion.

## Required boundary

Preferred target flow:

```text
Codex Lead
    |
    | compact dispatch contract
    v
Delegent Worker adapter
    |
    | OpenCode session API / SDK
    | + JSON-schema structured result
    v
validated assistant result
    |
    +-- valid --> compact handoff only --> Lead
    |
    +-- invalid --> WORKER_PROTOCOL_ERROR --> Lead
```

The Lead must not parse arbitrary human-formatted OpenCode terminal output.

## Preferred transport: session API / SDK

Prefer OpenCode's supported session/message API or SDK for the Worker protocol
boundary rather than scraping `opencode run` terminal output.

Current OpenCode docs expose:

```text
POST /session/:id/message
GET  /session/:id/message
GET  /session/:id/message/:messageID
```

and the SDK exposes `session.prompt`, `session.messages`, and `session.message`.
The SDK also supports structured output by supplying a JSON Schema to the
prompt format. The model uses OpenCode's structured-output mechanism to return
validated JSON matching that schema.

For Delegent, the structured result should represent one of two shapes:

1. normal Worker handoff;
2. hard `DECISION_NEEDED` escalation.

The adapter should create/reuse the intended session explicitly, submit the
compact dispatch contract, wait for completion with a bounded timeout, and
read the persisted assistant result through the supported session interface.

If the synchronous prompt surface is unreliable in the installed OpenCode
version, an acceptable implementation is:

```text
submit prompt
  -> bounded wait / session-status polling
  -> read latest assistant message from persisted session API
  -> validate structured result
```

Do not read OpenCode's SQLite database directly as the primary design while a
supported session API is available.

## CLI JSON compatibility path

`opencode run --format json` may still be useful as a compatibility/debug path,
but it is not sufficient as the only V0.1 protocol transport.

If used, the adapter must treat the JSONL stream as provisional telemetry:

- parse JSON events rather than human terminal text;
- keep tool/progress events behind the Context Firewall;
- record the session ID when available;
- never assume process exit or `step_finish` alone proves a terminal handoff was
  captured;
- if terminal text is missing, recover the persisted result through the
  supported session API before declaring protocol failure;
- bound hangs/timeouts and abort or fail deterministically.

The adapter must not depend on ad-hoc regex extraction from merged stdout/stderr
or PowerShell CLIXML.

## Handoff schema

The preferred machine representation is structured JSON rather than a
human-formatted eight-line block. It must contain exactly these logical fields:

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

The adapter may render that structured object into the existing textual handoff
for the Lead boundary:

```text
STATUS: completed | blocked
SUMMARY:
EVIDENCE:
CHANGES:
TESTS:
RISKS:
DECISIONS_NEEDED:
REVIEW_TARGETS:
```

Validation requirements:

1. `status` is exactly `completed` or `blocked`.
2. All eight logical fields are present exactly once in the structured result.
3. A field may contain `none` when genuinely inapplicable, but may not be
   silently omitted.
4. The Worker must not substitute a handoff file for the protocol result.
5. The adapter must not infer missing fields from tool logs or reconstruct the
   Worker's reasoning.
6. Missing, malformed, or ambiguous structured output is a protocol failure,
   not successful delegation.

Hard escalation remains a separate accepted structured shape with:

```text
kind: decision_needed
question
evidence
options
recommendation
confidence
```

The adapter may render it for the Lead as:

```text
DECISION_NEEDED
Question:
Evidence:
Options:
Recommendation:
Confidence:
```

## Protocol errors

If no valid handoff/escalation can be obtained from the supported session
interface within the bounded completion window, return a compact adapter-level
failure such as:

```text
WORKER_PROTOCOL_ERROR
kind: missing_terminal_handoff | malformed_handoff | timeout | runtime_output_error
session_id: <when known>
exit_code: <when applicable>
summary: <small deterministic diagnostic>
```

Do not forward the entire raw Worker transcript to the Lead automatically.
Specific diagnostic evidence may be inspected only when needed to repair the
runtime boundary.

## Security boundary

The Worker adapter is security-sensitive because it may:

- read the ignored credential configuration;
- set provider credentials in process environment;
- construct OpenCode configuration;
- create/reuse/query durable Worker sessions;
- parse and filter data crossing the Context Firewall.

Rules:

- general build Workers must not autonomously rewrite credential-loading or
  protocol-boundary code;
- Workers may perform read-only diagnosis and propose a patch;
- Lead owns or explicitly approves adapter mutations and performs final review;
- credentials must never be interpolated into generated source, logs, handoffs,
  tests, fixtures, or committed artifacts;
- adapter tests should use fake credentials and a fake OpenCode executable,
  mock server, or fixture responses whenever possible.

## Local test-first requirement

Before another remote Worker end-to-end test, the adapter implementation should
pass local deterministic tests that do not call NVIDIA NIM.

Minimum cases:

1. valid structured eight-field handoff -> accepted and rendered alone;
2. valid hard escalation -> accepted;
3. tool/progress events before final result -> trajectory does not cross into
   Lead handoff;
4. missing terminal structured result -> `WORKER_PROTOCOL_ERROR`;
5. malformed/missing field -> `WORKER_PROTOCOL_ERROR`;
6. duplicate/ambiguous field representation -> `WORKER_PROTOCOL_ERROR`;
7. runtime/API non-zero/error response -> deterministic runtime failure;
8. timeout / session remains non-idle -> bounded failure, no indefinite hang;
9. CLI JSON missing final text but persisted session contains the result ->
   session-interface recovery succeeds;
10. fake credential remains absent from generated files/output;
11. session creation, title-based discovery/reuse, and scope/role behavior remain
    compatible;
12. existing `--session`, `--title`, `--agent`, and `--dir` user-facing wrapper
    behavior remains compatible or receives a documented migration path.

Only after these local checks pass should the adapter be exercised against the
real OpenCode/Nemotron runtime.

## V0.1 acceptance impact

The direct `plan` Worker path has demonstrated that Nemotron can return the
compact contract, and the first full Delegent run demonstrated useful placement,
fresh-review selection, and Lead rejection of bad Worker changes. The product
loop is still blocked on a reliable runtime protocol.

A successful next validation should demonstrate:

```text
Codex Lead
  -> Delegent placement
  -> OpenCode session API / structured output
  -> validated compact handoff
  -> Lead review/final acceptance
```

without Lead-side ad-hoc regex parsing of raw OpenCode terminal output and
without relying on CLI stdout as the sole record of Worker completion.
