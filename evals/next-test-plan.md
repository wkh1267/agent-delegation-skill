# Delegent V0.1 Next-Test Plan

This document is the current validation order after the OpenCode 1.18.25 terminal-tool investigation and the decision to evaluate Codex CLI as the preferred NVIDIA NIM Worker harness.

See also:

- `docs/decisions/0001-codex-nim-worker-runtime.md`
- `evals/codex-nim-harness-plan.md`

## Current decision

Delegent remains workflow-agnostic and Worker-runtime-agnostic.

The core Lead/Worker architecture, Context Firewall, Worker continuity policy, handoff schema, escalation boundary, and Lead final acceptance remain accepted.

OpenCode is no longer assumed to be the required Worker runtime. It is retained as a frozen baseline/fallback while Codex harness + NVIDIA NIM is evaluated.

Do **not** continue adding OpenCode-specific lifecycle/plugin workarounds as the next activity. The next experiment is the isolated Codex+NIM compatibility spike.

## Current validation order

```text
A.  Delegent protocol foundation                         PASS
A.5 OpenCode/NIM compatibility isolation                PASS / blocker isolated
A.6 Terminal protocol fake/local validation             PASS
A.7 OpenCode live terminal handoff                      PAUSED / runtime-specific blocker

N0  Codex/NIM baseline + isolated CODEX_HOME            NEXT
N1  Hosted NIM Responses compatibility
N2  Minimal `codex exec` Nemotron Worker
N3  Real Codex repository tool use
N4  Deterministic terminal handoff via --output-schema
N5  Codex Worker session resume / continuity
N6  Controlled mutation + verifier
N7  Production-candidate Codex/NIM adapter
N8  OpenCode vs Codex/NIM runtime bake-off
N9  Controlled Delegent composition (B1/B2 equivalent)

C.  Matt implement integration (+ tdd/code-review)      WAITING ON N9
D.  Real ticket/spec development                        WAITING ON C
```

Do not skip a blocked layer.

## What the OpenCode work proved

The OpenCode path was valuable and should not be treated as failed work.

Validated facts include:

```text
NVIDIA NIM API connectivity                    PASS
Nemotron inference                             PASS
Nemotron normal tool calling                   PASS
Nemotron forced named tool calling             PASS
OpenCode plain plan/read Worker                PASS
OpenCode session creation/reuse                PASS
Delegent exact terminal validator              PASS
Context Firewall sensitive filtering           PASS
bounded process/session cleanup                PASS
Windows PowerShell 5.1 fake protocol suite     PASS 18/18
```

The original `format: json_schema` approach failed specifically in the OpenCode structured-output integration path.

The replacement normal-tool approach then exposed repeated OpenCode-specific custom-tool discovery/plugin/readiness complexity. A zero-inference diagnostic proved that the configured Delegent plugin can appear in effective config and ToolRegistry with both terminal tools registered, while the production A.7 path still returned `terminal_tools_unavailable`.

The latest OpenCode A.7 result is therefore recorded as a **runtime-specific reliability blocker**, not evidence that Delegent's protocol or NIM/Nemotron tool calling is invalid.

## Why Codex harness is the preferred next candidate

The target is:

```text
Codex Lead / GPT-5.6 Sol
        |
        v
Delegent placement
        |
        v
codex exec -p nim-worker
        |
        v
NVIDIA NIM / Nemotron
```

This reuses Codex's existing:

- headless `exec` mode;
- repository tools;
- sandboxing;
- JSONL event stream;
- final output schema support;
- persisted sessions and `resume`;
- process/tool orchestration.

It therefore has the potential to reduce the amount of runtime-specific code Delegent must own.

NVIDIA documents Codex CLI integration with NIM through a custom provider using `wire_api = "responses"`.

## Codex/NIM acceptance summary

The detailed commands and decision branches live in `evals/codex-nim-harness-plan.md`.

### N0 — isolation

PASS requires an isolated Delegent-controlled `CODEX_HOME`; the user's normal Codex config is not modified and no credential is written to tracked files.

### N1 — hosted Responses compatibility

Test the actual NVIDIA Developer hosted endpoint used by the project. Do not infer hosted `/v1/responses` support from self-hosted NIM documentation.

If Responses is unavailable, evaluate a small compatibility adapter only if the required mapping is bounded. Do not build a second full agent runtime by accident.

### N2 — minimal `codex exec`

A real Nemotron turn must complete through the custom NIM provider with parseable JSONL and no secret leakage.

### N3 — repository tools

Under read-only sandbox, Nemotron must use Codex's real repository tools to inspect `README.md` without modifying the tree.

### N4 — terminal handoff

Prefer Codex-native `--output-schema` for the final machine boundary.

The normal handoff remains exactly:

```text
status
summary
evidence
changes
tests
risks
decisions_needed
review_targets
```

The adapter still performs exact validation and sensitive filtering. Prompt-only JSON is not an acceptable silent fallback.

### N5 — continuity

Map stable Delegent Worker identity to Codex session/thread identity and validate `codex exec resume` for related follow-up. Independent review remains fresh-session work.

### N6 — controlled mutation

Use the repository-local fixture/verifier. Scope, architecture, security, and final acceptance remain Lead-owned.

### N7 — adapter

Only after standalone N0-N6 pass, implement the production candidate such as:

```text
skills/delegating-work/scripts/codex-nim-worker.ps1
skills/delegating-work/schemas/delegent-handoff.schema.json
skills/delegating-work/schemas/delegent-decision.schema.json
```

Do not reimplement Codex's tool loop, repo tools, sandbox, or session storage.

### N8 — runtime bake-off

Compare OpenCode baseline and Codex/NIM on the same controlled Worker tasks. Correctness and protocol reliability dominate small latency differences.

### N9 — controlled Delegent composition

Run the existing B1/B2 intent:

```text
B1 trivial task -> Lead may keep locally
B2 context-heavy task -> Codex/NIM Worker -> validated handoff -> Lead acceptance
```

Codex/NIM becomes the V0.1 preferred Worker runtime only after B2/N9 passes.

## Runtime pivot rule

```text
Delegent core      = accepted
Codex+NIM runtime  = preferred candidate under test
OpenCode runtime   = frozen baseline/fallback
```

Do not delete the OpenCode adapter until at least one realistic ticket/spec task passes on the selected replacement runtime.

If Codex+NIM fails for a structural reason rather than a small compatibility issue, next candidate order is:

```text
Direct minimal NIM runtime
-> Goose + NIM
-> revisit OpenCode
```

## Phase C — Matt `implement`

Only after runtime selection and N9 controlled composition pass, install/verify the current Matt workflows, at minimum:

```text
implement
tdd
code-review
```

The selected workflow owns what must happen. Delegent owns where significant work lives, continuity, escalation, Context Firewall enforcement, and Lead final acceptance.

## Phase D — realistic ticket/spec development

After Phase C passes, run a normal ticket/spec-driven task. This is the first layer treated as realistic product usage rather than a controlled runtime evaluation.

## Security preflight

Before any real Worker call:

1. credential exists only in the intended ignored secret location/environment;
2. working tree is clean;
3. credential residue scan is clean;
4. runtime adapter code remains Lead-owned for mutation/review;
5. stderr/logging is not merged into the machine protocol stream;
6. final handoff passes exact schema + sensitive-value filtering before entering Lead context.

For controlled composition:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireEvalWorkflow
```

For Matt integration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireMattWorkflows
```

## Immediate next action

Do not run another OpenCode A.7 as the next test.

Start Codex/NIM N0-N1:

1. record `codex --version`;
2. inspect `codex exec --help`;
3. create an isolated test `CODEX_HOME`;
4. configure the NIM custom provider without modifying normal Codex settings;
5. test the actual hosted NVIDIA `/v1/responses` behavior;
6. if compatible, run the first ephemeral read-only `codex exec -p nim-worker --json` smoke.
