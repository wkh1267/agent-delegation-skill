# Delegent V0.1 Next-Test Plan

This document records the validation order after the first direct-Worker/full-Delegent smoke runs and the live OpenCode compatibility probes.

## Decision record

Delegent remains workflow-agnostic. Matt Pocock's `implement` workflow is a later real-world integration target, not a runtime dependency. Do not install or exercise it until the controlled runtime/composition layers pass.

## Validation layers

```text
A. Worker protocol — fake/local                         PASS (initial structured design)
A.5 Live compatibility isolation                       PASS/isolated blocker
A.6 Terminal-tool protocol implementation + fake tests PASS (18/18 + catalog/discovery invariants)
A.7 Live terminal-tool Worker probe                    BLOCKED (custom-tool discovery fix pending live recheck)
B. Controlled Delegent composition                     WAITING ON A.7
   B1 trivial Lead-owned routing
   B2 controlled delegated routing
C. Matt implement integration (+ tdd/code-review)
D. Real ticket/spec development
```

Do not skip a blocked layer.

## Phase A — local protocol foundation

The first implementation passed 14 fake-only cases plus AST/diff/credential/process-lifecycle checks. It established the authenticated loopback OpenCode server, bounded session API handling, persisted-session recovery, credential isolation, and deterministic `WORKER_PROTOCOL_ERROR` behavior.

The original terminal representation used OpenCode `format: json_schema`.

## Phase A.5 — live compatibility isolation

Live probes on OpenCode 1.18.25 established:

```text
preflight / clean branch                         PASS
opencode serve + health + Basic Auth             PASS
session creation                                 PASS
plain OpenCode/Nemotron plan Worker              PASS
README read tool                                 PASS
direct NVIDIA Nemotron inference                 PASS
direct forced named StructuredOutput tool call  PASS
OpenCode format=json_schema message path         FAIL
```

Removing the HTTP message `agent` field did not fix the failure. Therefore the active blocker is OpenCode's special structured-output integration path, not the NVIDIA key, basic NIM connectivity, Nemotron inference, or Nemotron's named tool-calling capability.

## Phase A.6 — terminal custom-tool protocol

The broken special `format: json_schema` transport was replaced with normal OpenCode custom tools:

```text
delegent_handoff
  status
  summary
  evidence
  changes
  tests
  risks
  decisions_needed
  review_targets

delegent_decision
  question
  evidence
  options
  recommendation
  confidence
```

The tools are side-effect free and are installed only into the wrapper-controlled OpenCode config directory. The adapter reads only `parts[].state.input` for exactly one terminal Delegent tool call.

Deterministic acceptance covers:

- valid handoff;
- valid decision escalation;
- ordinary trajectory exclusion;
- missing terminal call;
- missing/extra arguments;
- duplicate terminal call;
- handoff + decision conflict;
- runtime/API failure;
- bounded timeout/abort;
- persisted-session recovery;
- stale reused-session call rejection;
- credential/sensitive-value filtering;
- terminal-tool runtime installation;
- no `format: json_schema` or direct `agent` field in Worker message body;
- wrapper flag/session compatibility;
- server lifecycle cleanup;
- terminal-tool catalog validation and deterministic unavailable-tool error;
- explicit `OPENCODE_CONFIG_DIR` discovery path regression.

Current Windows PowerShell 5.1 CI:

```text
PASS 18/18
PASS 3/3 catalog invariant
PASS explicit terminal tool discovery config
```

During test-harness debugging, the apparent 12/18 failure was traced to fixture parameters named `$Input` (and defensively `$Error`), which collide with PowerShell automatic variables. Renaming them to `$ToolInput` and `$ResponseError` fixed the fixtures without relaxing or changing the production protocol validator.

No real NIM call is needed for these deterministic tests.

## Phase A.7 — live terminal-tool probe

The first live terminal-tool call passed preflight but returned:

```text
WORKER_PROTOCOL_ERROR
kind: missing_terminal_handoff
session_id: ses_fad1d4ebbffer6qn1CM3aLB22z
exit_code: none
summary: Supported session sources contained no terminal structured result.
```

That result did not distinguish missing tool discovery from a model that simply ended without calling a terminal tool, so a runtime catalog invariant was added using OpenCode's `GET /experimental/tool/ids` endpoint.

The next live call returned before inference:

```text
WORKER_PROTOCOL_ERROR
kind: terminal_tools_unavailable
session_id: none
exit_code: none
summary: OpenCode did not register the required Delegent terminal tools.
```

This proved the current blocker was custom-tool discovery, not Nemotron tool-choice behavior.

Inspection of OpenCode 1.18.25 showed that `OPENCODE_CONFIG_DIR` is an explicit discovery directory. OpenCode loads `tools/*.ts` from that exact directory, installs `@opencode-ai/plugin` for it, and waits for the dependency before importing matching custom tools. The wrapper therefore no longer infers the global custom-tool path from `XDG_CONFIG_HOME`; it now:

```text
DELEGENT_RUNTIME
  -> delegent-config
      -> tools
          -> delegent_handoff.ts
          -> delegent_decision.ts
```

and exports that `delegent-config` path through `OPENCODE_CONFIG_DIR` before starting `opencode serve`.

The runtime catalog invariant remains in place. The next live call therefore has three meaningful outcomes:

- `terminal_tools_unavailable`: explicit discovery still failed; investigate OpenCode import/dependency loading without spending a Worker inference call.
- `missing_terminal_handoff`: both terminal tools were registered before inference, but Nemotron did not produce a completed terminal call; investigate normal-tool/tool-choice behavior.
- compact eight-field handoff: A.7 passes.

OpenCode 1.18.25's normal message path leaves tool choice to the provider/model; its special `format: json_schema` path is the path that explicitly requires a tool call, and that special path is already known to fail in this stack. Do not re-enable it merely to force a terminal call.

From the repository root:

```powershell
$worker = "$HOME\.agents\skills\delegating-work\scripts\nemotron-worker.ps1"

& $worker `
  --title "delegent:agent-delegation-skill:terminal-probe:plan" `
  --agent plan `
  --dir (Get-Location).Path `
  "Read only README.md. Do not modify files. Complete the task, then use the required Delegent terminal handoff mechanism. SUMMARY must say terminal protocol probe completed. CHANGES and TESTS should be none when inapplicable."
```

Expected Lead-visible output is only the compact eight-field handoff. No OpenCode banner, reasoning, normal tool output, CLIXML, server logs, or credential content should appear.

Stop before Phase B if A.7 returns `WORKER_PROTOCOL_ERROR`, leaks trajectory/secrets, changes repository files, hangs beyond the configured timeout, or leaves the OpenCode server alive.

## Phase B — controlled Delegent composition

Use the repository-local companion workflow:

```text
$delegent $delegent-eval-workflow
```

Run two controlled routing cases rather than treating one trivial fixture edit as sufficient evidence.

### B1 — trivial Lead-owned case

Use a tiny deterministic operation where delegation overhead is not worthwhile. PASS means Delegent is allowed to keep the work with Lead rather than mechanically dispatching every task.

### B2 — controlled delegated case

Use a bounded repository-local task with enough inspection/verification work to cross the dispatch-overhead gate, while keeping architecture, security, public contracts, and final acceptance fixed and Lead-owned.

PASS requires proof of:

```text
Lead
  -> Delegent placement
  -> Worker through terminal-tool runtime protocol
  -> compact validated handoff only
  -> Lead review/final acceptance
```

No Matt/external workflow semantics should be involved yet.

## Phase C — Matt `implement` integration

Only after A.7 and B pass, install/verify the actual current Matt Pocock skills used by `implement`, at minimum:

```text
implement
tdd
code-review
```

Use the installed version as source of truth. Verify that Delegent preserves the workflow's completion gates while keeping high-impact architecture/security/public-contract decisions and final acceptance with Lead.

## Phase D — realistic ticket/spec development

After Phase C passes, exercise Delegent on normal ticket/spec-driven development. This is the first layer to treat as realistic product usage rather than controlled validation.

## Security preflight before any real Worker call

Before A.7, B2, C, or D:

1. affected NVIDIA credentials must be rotated if required;
2. credential lives only in ignored `skills/delegating-work/.env`;
3. working tree is clean;
4. credential-residue scan is clean;
5. general build Workers do not mutate credential/protocol adapter code.

For controlled composition:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireEvalWorkflow
```

For Matt integration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireMattWorkflows
```

## Acceptance progression

```text
A.6 PASS = terminal-tool protocol is deterministic locally
A.7 PASS = terminal-tool protocol works on real OpenCode/Nemotron runtime
B PASS   = Delegent composition/routing works in controlled cases
C PASS   = primary real-world workflow composes correctly
D PASS   = realistic ticket/spec use is ready for broader evaluation
```
