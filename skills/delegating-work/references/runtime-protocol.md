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

These findings mean the Context Firewall must be enforced by the runtime
adapter, not only by prompts.

## Required boundary

Target flow:

```text
Codex Lead
    |
    | compact dispatch contract
    v
nemotron-worker.ps1
    |
    | structured OpenCode output
    v
runtime event parser
    |
    | discard/contain tool trajectory
    | identify terminal assistant result
    v
handoff validator
    |
    +-- valid --> compact handoff only --> Lead
    |
    +-- invalid --> WORKER_PROTOCOL_ERROR --> Lead
```

The Lead must not parse arbitrary human-formatted OpenCode terminal output.

## Structured transport

Normal delegated runs should use a structured OpenCode output mode when the
installed OpenCode version supports it (for example JSON event output). The
adapter owns compatibility handling and event parsing.

The adapter must distinguish at least:

- tool/progress/trajectory events;
- assistant text events;
- process/runtime errors;
- the terminal assistant result for the delegated task.

Raw tool trajectory may remain observable for debugging outside Lead context,
but it is not the handoff channel.

## Handoff validation

A normal Worker result is valid only when the extracted terminal assistant
result contains each field exactly once:

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

1. `STATUS` is exactly `completed` or `blocked`.
2. All eight fields are present exactly once.
3. A field may contain `none` when genuinely inapplicable, but may not be
   silently omitted.
4. The Worker must not substitute a handoff file for the terminal response.
5. The adapter must not infer missing fields from tool logs or reconstruct the
   Worker's reasoning.
6. Malformed or missing terminal output is a protocol failure, not successful
   delegation.

Hard escalation remains a separate accepted terminal shape:

```text
DECISION_NEEDED
Question:
Evidence:
Options:
Recommendation:
Confidence:
```

## Protocol errors

If OpenCode exits successfully but no valid terminal handoff/escalation can be
extracted, return a compact adapter-level failure such as:

```text
WORKER_PROTOCOL_ERROR
kind: missing_terminal_handoff | malformed_handoff | runtime_output_error
session_id: <when known>
exit_code: <process exit code>
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
- control durable session storage;
- parse and filter data crossing the Context Firewall.

Rules:

- general build Workers must not autonomously rewrite credential-loading or
  protocol-boundary code;
- Workers may perform read-only diagnosis and propose a patch;
- Lead owns or explicitly approves adapter mutations and performs final review;
- credentials must never be interpolated into generated source, logs, handoffs,
  tests, or committed artifacts;
- adapter tests should use fake credentials and a fake OpenCode executable or
  fixture output whenever possible.

## Local test-first requirement

Before another remote Worker end-to-end test, the adapter implementation should
pass local deterministic tests that do not call NVIDIA NIM.

Minimum cases:

1. valid eight-field handoff -> accepted and emitted alone;
2. valid hard escalation -> accepted;
3. tool/progress JSON before final handoff -> trajectory ignored by handoff output;
4. missing terminal text -> `WORKER_PROTOCOL_ERROR`;
5. malformed/missing handoff field -> `WORKER_PROTOCOL_ERROR`;
6. duplicate field -> `WORKER_PROTOCOL_ERROR`;
7. non-zero OpenCode exit -> deterministic runtime failure;
8. fake credential remains absent from generated files/output;
9. normal `sessions --format json` behavior remains compatible;
10. existing `--session`, `--title`, `--agent`, and `--dir` forwarding remains
    compatible.

Only after these local checks pass should the adapter be exercised against the
real OpenCode/Nemotron runtime.

## V0.1 acceptance impact

The direct `plan` Worker path has demonstrated that Nemotron can return the
compact contract, but the complete product loop is not accepted until the
adapter reliably enforces this protocol for delegated runs.

A successful next validation should demonstrate:

```text
Codex Lead
  -> Delegent placement
  -> structured Worker runtime
  -> validated compact handoff
  -> Lead review/final acceptance
```

without Lead-side ad-hoc regex parsing of raw OpenCode terminal output.
