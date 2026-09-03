# Delegent V0.1 Next-Test Plan

This document is the current validation source of truth for the Delegent V0.1 Worker-runtime evaluation.

See also:

- `CONTEXT.md` — project vocabulary
- `docs/decisions/0003-mutation-boundary.md` — how a Worker may change a repo
- `docs/decisions/0002-direct-nim-worker-runtime.md` — current runtime decision
- `docs/decisions/0001-codex-nim-worker-runtime.md` — partially superseded by 0002
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

As of 2026-09-03 the selected Worker runtime is a **direct NVIDIA NIM loop**
(`skills/delegating-work/tools/delegent-nim-worker.js`), with the terminal
handoff carried as validated function-call arguments.

The Codex harness held for N0-N3 but could provide no machine boundary for the
handoff: `--output-schema` is not enforced by this provider, and Codex never
exposes an MCP tool to the model on it. That is a structural failure rather than
a bounded compatibility issue, so the documented pivot rule fired. See
[ADR-0002](../docs/decisions/0002-direct-nim-worker-runtime.md).

Codex+NIM is kept as a working baseline and bake-off arm, not deleted.

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
N4  Deterministic terminal handoff via --output-schema  BLOCKED / runtime pivoted
N5  Codex Worker session resume / continuity            SUPERSEDED by D-series
N6  Controlled mutation + verifier                      SUPERSEDED by D-series
N7  Production-candidate Codex/NIM adapter              SUPERSEDED by D-series

D1  Direct NIM Worker: read + validated handoff         PASS 10/10
D1b Read-only tool surface: list + search               PASS 5/5
D2  Worker continuity / session reuse                   PASS 3/3
D2b Injectable transport so provider retry is testable
D3  Mutation boundary decision (ADR-0003)               DECIDED
D4  Controlled mutation + verifier                      NEXT
D5  Production-candidate Delegent Worker adapter
D6  Shell tool + real isolation                         SEPARATE GATE

N8  Codex/NIM vs direct-NIM vs OpenCode bake-off
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

## N4 — deterministic terminal handoff — BLOCKED on Codex+NIM

Neither available mechanism could provide a machine boundary on this provider,
which triggered the runtime pivot. Full reasoning and evidence are in
[ADR-0002](../docs/decisions/0002-direct-nim-worker-runtime.md); the short form:

```text
--output-schema   provider does not enforce it (8/10 at the provider),
                  1 of 7 attempts usable through codex exec, rest hung,
                  and text.format suppresses function calling (0/3)

MCP tool          server connects (initialize + tools/list traced) but Codex
                  never exposes MCP tools to the model; only exec_command,
                  list_mcp_resources and get_goal reach it
```

Both probes are retained. `probe-nim-structured-output.ps1` characterizes the
provider and still passes as a characterization gate;
`run-codex-nim-handoff-schema.ps1` is kept as the failing-boundary record.

### N3's exact-message assertion is model-variance-prone

Observed on 2026-09-03: five N3 runs, four with `agent_message_exact=True` and
one with `False` while `command_execution_count=1` and the working tree stayed
clean. Nemotron simply did not reproduce the exact final string that once. Treat
a lone `agent_message_exact=False` with otherwise healthy fields as variance and
rerun, the same way the old OpenCode `native server ownership` flake is treated.
Do not "fix" it by loosening the comparison.

## D1 — direct NIM Worker read + validated handoff — PASS

Use:

```text
evals/run-nim-worker-handoff.ps1
```

This replaces N3 and N4 in one pass: owning the loop puts the repository read
and the validated handoff on the same proven mechanism, function calling.

```text
node skills/delegating-work/tools/delegent-nim-worker.js
  --schema skills/delegating-work/schemas/delegent-handoff.schema.json
  --out <runtime>/delegent-handoff.json
  --repo <repo root>
```

PASS requires all of:

```text
process exit 0 and parseable JSONL
a real repository read through the read_file tool
the handoff delivered as validated tool-call arguments, accepted exactly once
the persisted handoff satisfying the schema exactly, re-validated by the gate
evidence containing the line only a real read could produce
the sensitive filter having run over the handoff strings
mutation_capable=False and shell_tool_present=False
working tree unchanged, no credential leakage
```

Live result 2026-09-03:

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
working_tree_unchanged=True
credential_leak_detected=False
overall=PASS
```

The gate re-validates the handoff itself rather than trusting the runtime under
test, and the task prompt never names the handoff fields, so exact conformance
cannot be explained by prompt-following. A prose answer instead of a tool call
is pushed back and counted as `prose_answer_rejected_count`, never accepted.

### D1 reliability — 10 consecutive runs, 2026-09-03

```text
overall PASS                       10/10
read_file_succeeded                10/10
schema_exact                       10/10
status_completed                   10/10
evidence_has_readme_line           10/10
changes_empty                      10/10
working_tree_unchanged             10/10
credential_leak_detected            0/10

handoff attempts    total=10  max=1     (every submission correct first try)
boundary rejections total=0
provider retries    total=0
prose rejections    total=0
duration seconds    min=7 max=35 mean=22
```

Twelve successful runs in total including the two before this measurement. This
is the number that justifies the pivot, against the boundary it replaced:

```text
text.format at the provider          8/10
--output-schema through codex exec   1/7
function-call handoff (D1)          10/10
```

Same provider, same model, same schema. Function-call arguments are reliably
well-formed here; schema-constrained final messages are not.

### Two code paths have no live coverage

Worth stating plainly, because 10/10 makes it easy to forget:

- **Boundary rejection never fired live.** `handoff_rejected_count` was 0 in
  every run, so the reject-then-correct path is covered only by the
  deterministic tests (`test-delegent-boundary.js`,
  `test-delegent-handoff-mcp.ps1`). That is adequate coverage, but no live run
  has exercised it.
- **Provider retry has no coverage at all**, live or deterministic. The endpoint
  demonstrably 404s a valid model id and drops response streams -- that was
  observed repeatedly earlier the same day -- yet `provider_retry_count` was 0
  across all 10 runs, so provider weather clearly varies by the hour. The retry
  budget in `delegent-nim-worker.js` is therefore justified by design and by
  earlier observation, not by test. Closing that gap needs an injectable
  transport so a test can simulate a 404 and a dropped stream.

Do not read 10/10 as "the provider is reliable". It means the provider was
healthy during that window.

The boundary itself is pinned deterministically in CI by
`evals/test-delegent-boundary.js`: validator accept/reject, firewall redaction,
and path containment against absolute paths, parent escapes, directories and
symlinks out of the repository.

## D1b — read-only tool surface — PASS

Use:

```text
evals/run-nim-worker-explore.ps1
```

D1 proved the boundary with a single file read, which is too thin for the work
most worth delegating. Of the six Worker responsibilities in this plan, three
need no sandbox at all -- large-repository exploration, huge-file reading and
code tracing -- and those are exactly the context-heavy jobs that burn Lead
context. So the surface is now `list_files`, `search` and `read_file`, all still
read-only.

Design constraints, both enforced by tests rather than convention:

- Every tool routes through `resolveContainedEntry`. None resolves a
  model-supplied path itself.
- `search` is a **literal substring** match, not a regular expression. A
  model-supplied regex would be an easy way to hang the Worker on catastrophic
  backtracking. The walk also skips symlinks outright rather than resolving
  them, so it cannot leave the repository through a directory link, and it is
  bounded by file count, file size and result count.

The gate's expectations are grounded in checked repository facts, and it
verifies those facts before running so a repository change produces a clear
error instead of a mysterious failure: `docs/decisions` holds exactly two
records, and within that directory `unelevated` occurs in 0001 only.

### D1b reliability — 5 consecutive runs, 2026-09-03

```text
overall PASS                5/5
list_files_used             5/5
search_used                 5/5
read_file_used              5/5
schema_exact                5/5
both ADRs reported          5/5
adr_title_quoted            5/5
working_tree_unchanged      5/5

tool calls per run  min=3 max=5
boundary rejections total=0
provider retries    total=1
duration seconds    min=14 max=29 mean=22
```

A representative handoff, produced without the prompt naming a single field:

```json
{
  "status": "completed",
  "summary": "Found two architecture decision records in docs/decisions: ... The record
              mentioning the Windows sandbox setting unelevated is
              0001-codex-nim-worker-runtime.md, whose first line is ...",
  "evidence": [
    "docs/decisions/0001-codex-nim-worker-runtime.md",
    "docs/decisions/0002-direct-nim-worker-runtime.md",
    "# ADR-0001: Make the Worker runtime replaceable and prioritize Codex harness + NVIDIA NIM"
  ],
  "changes": [], "tests": [], "risks": [], "decisions_needed": [], "review_targets": []
}
```

### Correction: the provider-retry path is no longer uncovered

The D1 section above states that provider retry had no coverage at all. That was
true when written and is now out of date: one of these five runs recorded
`provider_retry_count=1` and still completed correctly, so the retry path has
been observed firing and recovering in a live run. It is still not covered by a
*test* -- that is what D2b is for -- but it is no longer unevidenced.

## D2 — Worker continuity — PASS

Use:

```text
evals/run-nim-worker-continuity.ps1
```

Continuity is opt-in. With no `--session` the runtime is stateless, exactly as
D1 and D1b validated it, so those gates are unaffected. With `--session <affinity>`
and `--session-dir`, the transcript is persisted locally and reloaded on the
next turn.

The affinity is the Delegent identity already in this plan,
`delegent:<project>:<scope>:<role>`. Reuse stays a Lead placement decision; the
runtime never infers it.

State is kept as a local transcript rather than through provider-side response
ids. Owning the loop was the point of the pivot, and a hosted conversation store
is one more provider behaviour to trust. The transcript holds whatever the
Worker read, so it lives outside the repository with the other runtime
artifacts, and it is bounded at 400 items keeping the tail, because an unbounded
transcript would exceed the model's context anyway.

### Why this gate is a differential

A reused Worker that simply re-read the repository would look identical from
outside. So the follow-up **forbids tool use**, and the same follow-up goes to a
fresh Worker as a control. The runtime emits `tool_call` items only for
non-handoff tools, which makes "did it look something up" directly countable.

```text
arm 1  seed    session A, do the exploration
arm 2  reuse   session A, follow-up with tools forbidden  -> must answer
arm 3  fresh   new session, same follow-up                -> must not answer
```

The expected answer is a long, specific ADR title, so a fresh Worker producing
it by guesswork is not a plausible confound.

### D2 result — 3 consecutive runs, 2026-09-03

```text
overall PASS                    3/3
continuity_differential         CONTINUITY_PROVEN  3/3

seed    session_reused=False  saved_turns=1  lookups=2  title=True
reuse   session_reused=True   prior_turns=1  lookups=0  title=True
fresh   session_reused=False  prior_turns=0  lookups=0  title=False
```

Both sides of the differential behaved honestly rather than passing on a
technicality. The reused Worker answered from memory and said so:

```json
{ "status": "completed",
  "summary": "Reported the exact first line of 0001-... from prior inspection.",
  "evidence": ["# ADR-0001: Make the Worker runtime replaceable and prioritize Codex harness + NVIDIA NIM"] }
```

The fresh Worker declined instead of inventing an answer:

```json
{ "status": "blocked",
  "summary": "I do not have prior knowledge of the first line of 0001-... from earlier exchange in this session.",
  "evidence": [] }
```

That fresh arm is also the first time any gate exercised the `blocked` status,
so both values of the status enum are now covered by a live run.

## D3 — mutation boundary — DECIDED, see ADR-0003

Settled by [ADR-0003](../docs/decisions/0003-mutation-boundary.md) on
2026-09-04. It turned out not to be a sandbox-selection problem: mutation's
worst case is recoverable and a command's is not, so the boundary is a staging
tree plus a narrow tool surface, with `codex sandbox` as a second layer rather
than the primary control.

```text
staging tree      git worktree per delegation, outside the user's tree,
                  lifetime tied to the Worker affinity's session
tool surface      create and overwrite only; no shell; delete and rename
                  are escalations
scope             Lead declares prefixes and exact paths, Worker reports in
                  the handoff's `changes`, verifier cross-checks the diff
second layer      the Worker process runs under
                  `codex sandbox -P :workspace -C <staging tree>`
```

Mechanism survey, so the unavailable options are not re-proposed: Windows
Sandbox needs Pro/Enterprise (this host is Home), WSL has zero distros
registered, Docker's daemon is down with no WSL backend, and codex custom
profiles need an elevated filesystem-filter driver. `codex sandbox -P :workspace`
is the only isolation primitive usable today, verified to block writes outside
cwd on both drives.

Two constraints from that survey that D4 must build around:

- `:workspace` denies `.git` specifically, so a sandboxed Worker cannot commit,
  add, stash, or checkout. Git reads work. Committing belongs to the unsandboxed
  orchestrator after the Worker returns.
- The sandbox scopes writes only. Reads are unrestricted and the network stays
  open, so it mitigates nothing about exfiltration — which is a further reason
  the shell waits for its own gate.

**Do not unblock D4 by adding a shell tool.** That remains the most dangerous
shortcut available here, and it is now explicitly a separate gate rather than a
missing piece of D4.

## Superseded Codex-specific gates

N5, N6 and N7 were written against the Codex harness. Session resume, controlled
mutation and the production adapter all still have to happen, but on the runtime
that owns the loop, so they continue as D2, D4 and D5.

## N4 — original plan, retained for context

The original intent was Codex-native `--output-schema` as the machine boundary.

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

## N5 — Worker continuity — SUPERSEDED by D2

Map stable Delegent Worker identity to Codex thread identity and validate `codex exec resume` for related work.

```text
same subsystem / follow-up / implement->test->debug
  -> reuse

independent review / security / spec compliance
  -> fresh
```

## N6 — controlled mutation — SUPERSEDED by D4

Use the repository-local fixture/verifier under a controlled write sandbox. Scope, architecture, security-sensitive adapter changes, and final acceptance remain Lead-owned.

## N7 — production candidate adapter — SUPERSEDED by D5

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

Current status, after the 2026-09-03 pivot:

```text
Delegent core      = accepted
Direct NIM runtime = selected; D1 proven, D2 next
Codex+NIM runtime  = working baseline; N0-N3 proven, N4 boundary blocked
OpenCode runtime   = frozen baseline/fallback
```

The pivot rule fired as written: Codex+NIM failed for a structural reason
rather than a bounded compatibility issue, and the next candidate in the
documented order was taken.

Do not delete the OpenCode adapter, and do not delete the Codex/NIM probes,
until at least one realistic ticket/spec task passes on the direct NIM runtime.
Both are now bake-off comparison arms with real live evidence behind them.

Remaining order if the direct NIM runtime also proves structurally unsound:

```text
Goose + NIM
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

N4 is closed as blocked and the runtime has pivoted. Do not reopen the Codex
handoff boundary unless a later Codex release changes MCP tool exposure — the
parked `delegent-handoff-mcp.js` and its tests are what to retry with.

D1 (10/10), D1b (5/5) and D2 (3/3) all pass, so the Worker now does read-only
exploration end to end, reports through the validated boundary, and carries
context across turns under a Lead-chosen affinity.

**Start D4 — controlled mutation.** D3 is settled by
[ADR-0003](../docs/decisions/0003-mutation-boundary.md), so D4 implements it
rather than re-deciding it. What D4 has to build:

```text
staging tree   git worktree per delegation, outside the user's tree, lifetime
               tied to the affinity's session
write tool     create and overwrite only, routed through resolveContainedEntry,
               scoped to the Lead's declared prefixes and exact paths
verifier       three-way agreement between declared scope, reported `changes`,
               and the observed diff
sandbox        the Worker process under
               `codex sandbox -P :workspace -C <staging tree>`
```

Two implementation traps already identified, so they are not rediscovered:

- The observed diff must come from `git status --porcelain` and not `git diff`
  alone, because a newly created file is untracked and invisible to plain
  `git diff`.
- A write outside the declared scope and a mismatch between reported changes and
  the observed diff are **different failures**. The first means our own
  containment is defective: fail hard, escalate, keep the staging tree, never
  retry. Only the second is a reject-and-correct case.

Also worth doing near D3, and cheap: **D2b**, an injectable transport so the
provider-retry path becomes testable rather than only observed.

Before starting, re-confirm the proven layers still hold on this machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\run-nim-worker-handoff.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\run-nim-worker-explore.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\run-nim-worker-continuity.ps1
node .\evals\test-delegent-boundary.js
```

The Codex/NIM baseline should also stay green as the bake-off arm, remembering
that a lone `agent_message_exact=False` there is model variance:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\diagnose-codex-nim-doctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\evals\run-codex-nim-repo-read.ps1
```

Do not integrate any Worker runtime into `$delegent` routing yet. D2, D3 and D4
must pass first.
