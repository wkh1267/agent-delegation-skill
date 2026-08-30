# Delegent V0.1 Next-Test Plan

This document is the current validation order after the OpenCode 1.18.25 terminal-tool investigation and the decision to evaluate Codex CLI as the preferred NVIDIA NIM Worker harness.

See also:

- `docs/decisions/0001-codex-nim-worker-runtime.md`
- `evals/codex-nim-harness-plan.md`

## Current decision

Delegent remains workflow-agnostic and Worker-runtime-agnostic.

The core Lead/Worker architecture, Context Firewall, Worker continuity policy, handoff schema, escalation boundary, and Lead final acceptance remain accepted.

OpenCode is no longer assumed to be the required Worker runtime. It is retained as a frozen baseline/fallback while Codex harness + NVIDIA NIM is evaluated.

Do **not** continue adding OpenCode-specific lifecycle/plugin workarounds as the next activity.

## Current validation order

```text
A.  Delegent protocol foundation                         PASS
A.5 OpenCode/NIM compatibility isolation                PASS / blocker isolated
A.6 Terminal protocol fake/local validation             PASS
A.7 OpenCode live terminal handoff                      PAUSED / runtime-specific blocker

N0  Codex/NIM baseline + isolated CODEX_HOME            PASS
N1  Hosted NIM Responses compatibility                  PASS
N2  Minimal `codex exec` Nemotron Worker                IN PROGRESS
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
Dedicated isolated Codex Worker harness
        |
        v
NVIDIA NIM / Nemotron
```

The dedicated Worker uses its own isolated `CODEX_HOME`. Because that home exists only for the NIM Worker, its base `config.toml` directly selects the Nemotron model and `nim` provider. A separate Codex profile is unnecessary and is no longer part of the N2 design.

This reuses Codex's existing headless `exec` mode, repository tools, sandboxing, JSONL event stream, final output schema support, persisted sessions/resume, and process/tool orchestration.

NVIDIA documents Codex CLI integration with NIM through a custom provider using `wire_api = "responses"`.

## N0/N1 live evidence — 2026-08-31

The actual local Codex installation and actual NVIDIA Developer hosted endpoint were tested.

### N0 PASS

```text
codex_version=codex-cli 0.151.0
codex_home=C:\Users\wkh12\AppData\Local\agent-delegation-skills\codex-nim\codex-home
base_url=https://integrate.api.nvidia.com/v1
model=nvidia/nemotron-3-super-120b-a12b
config_written=True
credential_value_logged=False
```

The setup is isolated from the user's normal Codex config and writes no credential value.

### N1 PASS

The actual hosted endpoint `https://integrate.api.nvidia.com/v1/responses` returned:

```text
basic_request=ok
basic_http_status=200
basic_decode=ok
basic_output_shape=True

tool_request=ok
tool_http_status=200
tool_decode=ok
function_call_present=True
function_name_match=True
call_id_present=True
arguments_valid=True

overall=PASS
credential_value_logged=False
```

This proves the hosted Developer endpoint currently provides the core Responses semantics Codex requires for this Worker candidate:

```text
/v1/responses          PASS
auto function calling  PASS
function call_id        PASS
function arguments      PASS
```

Do not build a Responses compatibility proxy unless a later Codex-specific request shape exposes a bounded incompatibility.

## Codex/NIM acceptance summary

### N0 — isolation — PASS

The isolated `CODEX_HOME` setup is implemented in `evals/setup-codex-nim.ps1`.

The current setup writes one dedicated Worker config:

```toml
model = "nvidia/nemotron-3-super-120b-a12b"
model_provider = "nim"

[model_providers.nim]
name = "NVIDIA NIM"
base_url = "https://integrate.api.nvidia.com/v1"
env_key = "NIM_API_KEY"
wire_api = "responses"
```

Earlier experiments generated `nim-worker.config.toml`; current setup removes that stale generated file so profile state cannot affect N2.

### N1 — hosted Responses compatibility — PASS

The secret-safe live probe is implemented in `evals/probe-nim-responses.ps1`.

### N2 — minimal `codex exec` — IN PROGRESS

Use `evals/run-codex-nim-smoke.ps1`.

The first two live N2 attempts exited before `thread.started` with exit code 1 and no JSONL output. This proves those failures occurred in Codex startup/config/bootstrap before a model turn; they do not invalidate the N1 hosted Responses result.

A diagnostic attempt then exposed an incorrect assumption in our test tooling: Codex 0.151.0 rejects `--profile` for `codex doctor`. Rather than maintain separate doctor and exec config paths, N2 was simplified so both commands read the same dedicated base `config.toml` with no profile.

Exact Codex 0.151.0 source also confirms the N2 exec flags used by the smoke are valid: `--strict-config`, `--ephemeral`, `--json`, `--sandbox`, and `--ignore-rules` are all supported.

The current smoke runs the equivalent of:

```text
codex exec
--strict-config
--ephemeral
--json
--sandbox read-only
--ignore-rules
```

with stdin task:

```text
Reply with exactly WORKER_OK.
```

PASS requires:

```text
process exit code 0
parseable JSONL
thread.started with thread_id
turn.completed
no turn.failed/error
exact final agent message WORKER_OK
no credential leakage
```

The smoke handles native Codex executables and Windows npm PowerShell/CMD shims and bounds the process tree on timeout.

### N2 zero-inference doctor diagnostic

`evals/diagnose-codex-nim-doctor.ps1` uses the same isolated base config and runs `codex doctor --json` without a profile. It uses `ProcessStartInfo` rather than invoking the PowerShell shim directly, so native stderr is captured and sanitized instead of surfacing as a PowerShell `NativeCommandError`.

The diagnostic is intended to report only safe derived fields such as config load, active model/provider, credential-env presence, reachability status, and whether raw output contained the credential. It does not run an agent turn.

### N3 — repository tools

After N2 passes, use the same isolated Worker config under read-only sandbox and require Nemotron to inspect `README.md` through Codex's real repository/tool path without modifying the tree.

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

## Immediate next action

Do not run another OpenCode A.7.

Sync the latest branch, then run the zero-inference Codex doctor diagnostic first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\diagnose-codex-nim-doctor.ps1
```

If the dedicated Worker config/provider/auth checks are healthy, rerun N2:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\run-codex-nim-smoke.ps1
```

If N2 passes, proceed immediately to a separate N3 read-only README tool-use probe. Do not integrate the Codex runtime into `$delegent` routing before N3/N4/N5/N6 are validated.
