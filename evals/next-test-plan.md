# Delegent V0.1 Next-Test Plan

This document is the current validation source of truth for the Delegent V0.1 Worker-runtime evaluation.

See also:

- `docs/decisions/0001-codex-nim-worker-runtime.md`
- `evals/codex-nim-harness-plan.md`
- `evals/v0.1-smoke.md`

## Current decision

Delegent remains workflow-agnostic and Worker-runtime-agnostic.

The accepted architecture remains:

```text
Codex Lead / GPT-5.6 Sol
        |
        v
Delegent placement + Context Firewall
        |
        v
Worker adapter
        |
        v
long-context execution Worker
```

Lead/Worker ownership, persistent-vs-fresh Worker policy, compact handoff, decision escalation, sensitive filtering, and Lead final acceptance remain unchanged.

OpenCode is retained as a frozen baseline/fallback. Do **not** add more OpenCode-specific lifecycle/plugin workarounds as the next activity.

Codex harness + NVIDIA NIM is now the preferred Worker-runtime candidate under validation.

## Current validation order

```text
A.  Delegent protocol foundation                         PASS
A.5 OpenCode/NIM compatibility isolation                PASS / blocker isolated
A.6 Terminal protocol fake/local validation             PASS
A.7 OpenCode live terminal handoff                      PAUSED / runtime-specific blocker

N0  Codex/NIM baseline + isolated CODEX_HOME            PASS
N1  Hosted NIM Responses compatibility                  PASS
N2a Codex config/auth/provider doctor                    PASS
N2b Minimal `codex exec` Nemotron Worker                PASS
N3  Real Codex repository tool use                      PASS
N4  Deterministic terminal handoff via --output-schema  NEXT
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

The OpenCode path remains useful evidence rather than failed work.

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

The original `format: json_schema` approach failed in OpenCode's structured-output integration. The normal-tool replacement then exposed OpenCode-specific custom-tool discovery/plugin/readiness complexity. A zero-inference diagnostic proved the Delegent plugin and both terminal tools can register correctly while the production A.7 path still reports `terminal_tools_unavailable`.

That is recorded as an OpenCode runtime-specific reliability blocker, not a NIM, Nemotron, or Delegent protocol failure.

## Codex/NIM live evidence — 2026-08-31

### N0 — isolated Worker home — PASS

`evals/setup-codex-nim.ps1` creates a dedicated Worker-only `CODEX_HOME` and does not modify the user's normal Codex configuration.

Current generated config:

```toml
model = "nvidia/nemotron-3-super-120b-a12b"
model_provider = "nim"

[model_providers.nim]
name = "NVIDIA NIM"
base_url = "https://integrate.api.nvidia.com/v1"
env_key = "NIM_API_KEY"
wire_api = "responses"
```

Observed:

```text
codex_version=codex-cli 0.151.0
config_mode=isolated-default
config_written=True
credential_value_logged=False
```

A separate Codex profile is intentionally not used. The dedicated Worker home directly selects the Worker model/provider so `doctor` and `exec` share the same effective configuration.

### N1 — hosted Responses API — PASS

`evals/probe-nim-responses.ps1` tested the actual NVIDIA Developer hosted endpoint:

```text
https://integrate.api.nvidia.com/v1/responses
```

Observed:

```text
basic_http_status=200
basic_output_shape=True
tool_http_status=200
function_call_present=True
function_name_match=True
call_id_present=True
arguments_valid=True
overall=PASS
credential_value_logged=False
```

Therefore the hosted endpoint currently supplies the key Codex wire primitives:

```text
/v1/responses          PASS
auto function calling  PASS
function call_id        PASS
function arguments      PASS
```

Do not build a Responses compatibility proxy unless a later Codex request shape proves one is necessary.

### N2a — zero-inference Codex doctor — PASS

`evals/diagnose-codex-nim-doctor.ps1` validated the same dedicated Worker config without model inference.

Observed:

```text
doctor_exit_code=0
doctor_decode_ok=True
config_status=ok
config_loaded=True
active_model=nvidia/nemotron-3-super-120b-a12b
active_provider=nim
provider_selected=True
model_selected=True
auth_status=ok
provider_env_present=True
reachability_status=ok
overall=PASS
model_inference_used=false
credential_value_logged=False
```

This proves config loading, model selection, provider selection, credential discovery, and provider reachability.

The doctor now also gates the Windows sandbox backend, re-verified 2026-09-03:

```text
codex_launcher=cmd-shim
sandbox_status=ok
sandbox_backend_class=enabled-redacted
windows_sandbox_enabled=True
approval_policy=OnRequest
filesystem_sandbox=restricted
network_sandbox=restricted
overall=PASS
model_inference_used=false
```

`sandbox_backend_class` replaces the earlier raw `sandbox_backend` field, which
could never satisfy a `RestrictedToken|Elevated` match because Codex redacts an
enabled backend's name. The classes are `disabled`, `enabled-redacted`,
`enabled-<name>`, `missing`, and `unrecognized`; only an `enabled*` class passes.

Two defects were fixed here on 2026-09-03, both of which made this gate report a
false negative while the runtime was actually healthy:

- `checks.<id>.details` is a JSON **object**, not an array of `"name: value"`
  strings, so the line-oriented detail parser returned `missing` for every
  sandbox field. All details are now read by name.
- `Get-Command codex` resolves `codex.ps1` ahead of `codex.cmd` on this PATH, so
  the doctor was launching through the known-unsafe npm PowerShell shim. It now
  probes `codex.exe` -> `codex.cmd` -> `codex.ps1`, matching every other probe.

### N2b — minimal `codex exec` — PASS

`evals/run-codex-nim-smoke.ps1` now uses the minimal proven harness:

```text
codex exec --json -
```

with stdin task:

```text
Reply with exactly WORKER_OK.
```

Live result:

```text
codex_version=codex-cli 0.151.0
codex_launcher=cmd-shim
harness_mode=minimal
process_exit_code=0
failure_class=none
stderr_summary=none
jsonl_line_count=5
jsonl_decode_errors=0
event_types=thread.started,item.completed,turn.started,turn.completed
thread_id_present=True
turn_completed=True
turn_failed=False
agent_message_present=True
agent_message_exact=True
credential_leak_detected=False
overall=PASS
credential_value_logged=False
```

This proves, on the actual Windows machine and actual hosted NVIDIA endpoint:

```text
Codex CLI headless harness      PASS
custom NIM model provider       PASS
hosted NVIDIA Responses         PASS
Nemotron real model turn        PASS
Codex thread lifecycle          PASS
Codex JSONL machine stream      PASS
```

#### N2 root cause record

Earlier N2 runs returned exit code 1, zero JSONL lines, and no `thread.started`. A sanitized stderr probe eventually showed:

```text
[codex.ps1] ... PSArgumentException
```

The failure occurred in the npm PowerShell shim before Codex's Rust runtime received the command. It was specifically exposed by Windows PowerShell 5.1 + redirected stdin + the `-` stdin sentinel.

The launcher now prefers:

```text
codex.exe
-> codex.cmd
-> codex.ps1 only as fallback
```

The passing live run used:

```text
codex_launcher=cmd-shim
```

Therefore the earlier N2 failures must **not** be interpreted as Codex/NIM runtime incompatibility.

## N3 — real repository tool use — PASS

Use:

```text
evals/run-codex-nim-repo-read.ps1
```

N3 deliberately adds only the first required hardening/tool surface to the proven N2 harness:

```text
codex exec --json --sandbox read-only -
```

The Worker is instructed to read `README.md` using available repository/shell tools and return the first non-empty line after the top-level heading. The prompt does **not** contain the expected line.

PASS requires all of the following:

```text
process exit code 0
parseable JSONL
thread.started with thread_id
turn.completed
no turn.failed/error
at least one completed command_execution
at least one successful command_execution whose command references README.md
zero file_change items
working tree identical before and after the Worker turn
exact final evidence:
  README_TOOL_OK|Context-aware coding-agent orchestration for Codex.
no credential leakage
```

This gate proves that Nemotron is not merely answering through Codex; it can actually use Codex's repository execution path under a read-only sandbox while preserving the tree.

### N3 live result — 2026-09-03 — PASS

```text
codex_version=codex-cli 0.151.0
codex_launcher=cmd-shim
process_exit_code=0
failure_class=none
invalid_tool_args_seen=False
exec_policy_blocked_seen=False
windows_process_failure_seen=False
jsonl_decode_errors=0
turn_completed=True
turn_failed=False
command_execution_count=1
readme_tool_command_succeeded=True
file_change_item_count=0
working_tree_unchanged=True
agent_message_exact=True
credential_leak_detected=False
overall=PASS
```

The Worker turn ran under an enforced sandbox, confirmed from the session
rollout rather than inferred:

```text
approval_policy = never
sandbox_policy  = {"type": "read-only"}
```

So the open question from the N3b blocker is answered: Codex 0.151.0 on this
Windows machine *can* execute the required benign repository command under an
enforceable managed sandbox with non-interactive exec-policy.

### Why the Windows sandbox fix works — zero-inference differential

`codex doctor` reports the Windows backend, and the two arms differ only by the
`[windows]` block in the isolated Worker config:

```text
no [windows] sandbox key   -> sandbox backend = disabled
sandbox = "unelevated"     -> sandbox backend = <redacted>
```

This is the confirmation of the original hypothesis: an unspecified Windows
backend resolves to `disabled`, and a restricted permission profile with no
enforceable sandbox makes non-interactive exec-policy reject benign unmatched
commands because no approval prompt exists.

Two Codex 0.151.0 quirks matter for any future diagnostic:

- `codex doctor --json` is documented as "Emit a redacted machine-readable
  report". `sandbox.helpers -> sandbox backend` is one of only two redacted
  fields, and the human report redacts it too. The concrete backend name is
  therefore **not observable**, so the backend can only be gated negatively
  against `disabled`. Asserting `RestrictedToken|Elevated` can never pass.
- `filesystem sandbox` and `network sandbox` both read `restricted` in *both*
  arms. They reflect the requested policy, not the backend, so neither
  discriminates an enabled backend from a disabled one. Do not gate on them.

### Known non-fatal stream conditions

Both live probes classify error-typed JSONL entries instead of treating any of
them as a turn failure. Two conditions are expected and are reported rather than
swallowed:

```text
model_metadata_fallback_seen   -> "Model metadata for `nvidia/nemotron-3-super-120b-a12b`
                                  not found. Defaulting to fallback metadata"
provider_retry_notice_count    -> "Reconnecting... n/5 (...)"
provider_model_not_found_seen  -> a retry whose cause was 404 Model not found
```

The fallback-metadata notice arrives on **every** turn, because a custom NIM
model is never in Codex's model catalog. Observed fallback context window is
`258400`. Pinning `model_context_window` is deferred: the hosted NIM
`/v1/models` response carries only `id`/`object`/`created`/`owned_by`, so no
authoritative Nemotron context length is available yet, and guessing one is
worse than the documented fallback. Revisit before N5/N6 grow long Worker
threads.

The retry notices are provider weather. One observed N2b run needed four
retries, twice because the hosted endpoint answered a valid model id with
`404 Model not found` and twice on a dropped response stream; the turn still
completed with the exact expected answer, and the next two runs needed zero
retries. Retry rate is a reliability input for the N8 bake-off, not a gate
failure — the gate still depends on `turn.completed` plus the exact answer, and
any *unrecognized* stream error still fails it.

That last property is the risk in tolerating any notice at all, so it is pinned
by a deterministic CI test rather than left to review:

```text
evals/test-codex-nim-stream-error-classifier.ps1
```

It extracts the classifier verbatim from the shipping probe, requires both live
probes to share one implementation, and runs it over the two real observed
streams plus negative controls — an unrecognized error, an explicit
`turn.failed`, a de-duplicated error item, and a clean stream.

## N4 — deterministic terminal handoff — NEXT

Now that N3 passes, evaluate Codex-native `--output-schema` as the machine boundary.

Normal handoff remains exactly:

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

Decision escalation remains exactly:

```text
kind
question
evidence
options
recommendation
confidence
```

The adapter must still perform exact validation and sensitive filtering. Prompt-only JSON is not an acceptable silent fallback.

## N5 — Worker continuity

Map stable Delegent Worker identity to Codex thread identity and validate `codex exec resume` for related work.

```text
same subsystem / follow-up / implement->test->debug
  -> reuse

independent review / security / spec compliance
  -> fresh
```

## N6 — controlled mutation

Use the repository-local fixture/verifier under a controlled write sandbox. Scope, architecture, security-sensitive adapter changes, and final acceptance remain Lead-owned.

## N7 — production candidate adapter

Only after N0-N6 pass, implement the production candidate, e.g.:

```text
skills/delegating-work/scripts/codex-nim-worker.ps1
skills/delegating-work/schemas/delegent-handoff.schema.json
skills/delegating-work/schemas/delegent-decision.schema.json
```

Do not reimplement Codex's tool loop, repository tools, sandbox, or session storage.

## N8 — runtime bake-off

Compare the frozen OpenCode baseline and Codex/NIM on the same controlled Worker tasks. Correctness and protocol reliability dominate small latency differences.

## N9 — controlled Delegent composition

Run the existing B1/B2 intent:

```text
B1 trivial task
  -> Lead may keep locally

B2 context-heavy task
  -> Codex/NIM Worker
  -> validated compact handoff
  -> Lead review / acceptance
```

Codex/NIM becomes the preferred V0.1 Worker runtime only after this composition gate passes.

## Runtime pivot rule

Current status:

```text
Delegent core      = accepted
Codex+NIM runtime  = preferred candidate; N0-N3 proven, N4 next
OpenCode runtime   = frozen baseline/fallback
```

Do not delete the OpenCode adapter until at least one realistic ticket/spec task passes on the selected replacement runtime.

If Codex+NIM later fails for a structural reason rather than a bounded compatibility issue, candidate order remains:

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

The selected workflow owns what must happen. Delegent owns placement, continuity, escalation, Context Firewall enforcement, and Lead final acceptance.

## Phase D — realistic ticket/spec development

After Phase C passes, run a normal ticket/spec-driven task. This is the first layer treated as realistic product usage rather than controlled runtime evaluation.

## Security preflight

Before any real Worker call:

1. credential exists only in the intended ignored secret location/environment;
2. working tree is clean or its baseline is explicitly captured;
3. credential residue scan is clean;
4. runtime adapter code remains Lead-owned for mutation/review;
5. stderr/logging is not merged into the machine protocol stream;
6. final handoff passes exact schema + sensitive-value filtering before entering Lead context.

## Immediate next action

Do not run another OpenCode A.7.

N3 has passed, so the Windows sandbox / exec-policy investigation is closed. Do
not reopen it, and do not spend further time on
`diagnose-codex-windows-sandbox.ps1` or
`diagnose-codex-powershell-profile-gap.ps1`; both are retained only as
regression controls.

Start N4 — Codex-native `--output-schema` as the machine boundary:

```text
Nemotron Worker
-> Codex native tools
-> --output-schema
-> exact Delegent handoff
-> adapter exact validation + sensitive filtering
-> Lead
```

Prompt-only JSON is not an acceptable fallback for the terminal handoff.

Before starting, re-confirm the proven layers still hold on the current machine
(both are fast and both must stay green):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\diagnose-codex-nim-doctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\run-codex-nim-repo-read.ps1
```

Do not integrate Codex/NIM into `$delegent` routing yet. N4, N5, and N6 must pass first.
