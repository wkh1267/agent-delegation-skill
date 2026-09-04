# Codex Harness + NVIDIA NIM Execution Plan

## Goal

Validate whether Delegent can replace the OpenCode Worker harness with a Codex Worker harness whose model provider is NVIDIA NIM/Nemotron.

Target architecture:

```text
Codex Lead (GPT-5.6 Sol)
        |
        | placement / dispatch
        v
Delegent Worker Adapter
        |
        v
codex exec -p nim-worker
        |
        v
NVIDIA NIM / Nemotron
        |
        v
Codex native repo tools + sandbox
        |
        v
validated compact handoff
        |
        v
Codex Lead review / acceptance
```

This plan is intentionally staged. Do not integrate it into `$delegent` routing until the standalone harness passes the runtime gates below.

## Operating principles

1. **Preserve Delegent semantics.** Runtime changes must not change Lead-owned decisions, Worker placement policy, Context Firewall, handoff fields, escalation rules, or final Lead acceptance.
2. **Use Codex as the harness, not as another orchestration layer.** V0.1 starts with `codex exec`; do not introduce Codex multi-agent or app-server unless the simpler path is insufficient.
3. **No production OpenCode deletion during the spike.** Keep it as the comparison baseline.
4. **Fail closed on protocol uncertainty.** A plain prose answer is not accepted as the final machine-to-machine handoff when a structured boundary is required.
5. **Do not touch the user's main Codex config.** Use isolated `CODEX_HOME`.
6. **No secret logging.** Diagnostics may prove variable presence, never values.

---

## Phase N0 — Baseline and isolation

### Objective

Create a reproducible Codex/NIM test environment without changing Delegent production routing.

### Tasks

- Record `codex --version`, current repo commit, target NIM model, target hosted base URL, and whether the test is hosted or self-hosted NIM.
- Create a Delegent-controlled temporary or ignored `CODEX_HOME`.
- Generate only test configuration inside that isolated home.
- Load the NVIDIA key from an environment variable.
- Ensure test output/log files are ignored or temporary.

### Proposed config shape

Use NVIDIA's documented provider shape as the starting point:

```toml
[model_providers.nim]
name = "NVIDIA NIM"
base_url = "<NIM_BASE_URL>/v1"
env_key = "NIM_API_KEY"
wire_api = "responses"

[profiles.nim-worker]
model = "nvidia/nemotron-3-super-120b-a12b"
model_provider = "nim"
```

Treat exact profile syntax as version-sensitive and verify it against the installed Codex version before committing production config.

### PASS

- isolated config is used;
- no existing user Codex config is modified;
- credential residue scan stays clean.

---

## Phase N1 — Hosted NIM Responses compatibility

### Objective

Answer the first gating question:

> Can the NVIDIA Developer hosted endpoint used by this project serve the Responses API semantics Codex needs?

### Probe order

1. Verify the model is reachable.
2. Probe `/v1/responses` with a minimal non-tool request.
3. Probe a normal function tool call.
4. Verify streaming if Codex requires it for the selected provider path.
5. Verify no secret appears in response/error output.

Do not infer hosted support from self-hosted/current NIM documentation.

### Outcomes

#### N1-A — Responses works

Proceed directly to N2.

#### N1-B — `/v1/responses` unavailable/incompatible

Do not return to OpenCode automatically.

Evaluate a **small Responses compatibility adapter** as a separate decision:

```text
Codex Responses client
        |
        v
Delegent Responses Adapter
        |
        v
NIM Chat Completions
```

Only build it if the required mapping is bounded and preserves streaming/lifecycle needed by Codex, function calls + call IDs, function outputs, finish/status semantics, error propagation, and structured final output needed for the handoff.

If that adapter begins to reproduce a large portion of the Responses API, reject it and reconsider Goose/direct-NIM/OpenCode instead.

### PASS

A real `codex exec` request can reach Nemotron through the isolated provider.

---

## Phase N2 — Minimal Codex Worker execution

### Objective

Prove that Codex can use Nemotron as the model for a non-interactive Worker.

### First task

```text
Reply with exactly WORKER_OK.
```

Run with the equivalent of:

```text
codex exec
-p nim-worker
--ephemeral
--json
--sandbox read-only
```

Exact CLI placement may vary by installed Codex version; use `codex exec --help` as source of truth.

### Verify

- requested provider is NIM, not OpenAI;
- request completes;
- stdout JSONL is parseable;
- stderr is kept separate from the protocol stream;
- no credential content appears.

### PASS

Nemotron completes a Codex `exec` turn through the custom provider.

---

## Phase N3 — Real Codex repository tools

### Objective

Prove the value of using Codex as the Worker harness rather than building our own agent loop.

### Task

```text
Read README.md only.
Do not modify files.
Return two factual observations.
```

### Requirements

- `--sandbox read-only`;
- repository working tree unchanged;
- Worker actually inspects the file through Codex's normal tool path;
- no OpenCode process or config involved.

### PASS

Codex/Nemotron successfully performs real repository inspection under the sandbox.

### Stop condition

If basic Codex tools cannot be represented through the NIM Responses endpoint, record the exact unsupported tool type/schema before adding any workaround.

---

## Phase N4 — Terminal handoff via `--output-schema`

### Objective

Replace the OpenCode custom terminal plugin with a Codex-native structured final response if compatible.

### Schema

Create a JSON Schema requiring exactly:

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

All fields are non-empty strings. `status` is `completed | blocked`. No extra properties.

### Run

Use the equivalent of:

```text
codex exec
-p nim-worker
--output-schema <delegent-handoff.schema.json>
--output-last-message <temporary-file>
```

Optionally keep `--json` for telemetry, but the final handoff should be read from the dedicated final-message channel/file and then passed through the existing exact Delegent validator.

### Verify

- exact schema;
- no extra prose;
- sensitive-value filtering;
- malformed output fails closed;
- trajectory/internal tool events do not enter Lead context.

### Decision escalation

After normal handoff passes, test a decision schema/path equivalent to:

```text
kind = decision_needed
question
evidence
options
recommendation
confidence
```

The adapter may choose separate schemas/invocations or a tagged union, but the Lead-visible contract must remain deterministic.

### PASS

A real Nemotron Worker produces a validated compact terminal result without a custom OpenCode plugin.

### If `--output-schema` is unsupported by NIM

Do not silently downgrade to prompt-only JSON.

Record the compatibility failure and evaluate, in order:

1. whether the NIM Responses endpoint supports the necessary structured-output field with a small request/config change;
2. whether a second bounded finalization turn can safely enforce the schema;
3. whether a terminal MCP/function tool is cleaner;
4. whether this incompatibility disqualifies Codex+NIM for V0.1.

---

## Phase N5 — Worker continuity

### Objective

Map Delegent persistent Worker identity to Codex sessions.

### Proposed mapping

```text
delegent:<project>:<scope>:<role>
        |
        v
Codex session/thread id
```

### Test sequence

1. Start a Worker that inspects one subsystem.
2. Capture the Codex session/thread ID from the supported output/session record.
3. Resume with `codex exec resume <session-id> <follow-up>`.
4. Ask a related follow-up that should reuse prior context.
5. Verify it does not need to rediscover the entire subsystem.
6. Start a fresh session for an independent-review task and confirm isolation.

### PASS

- same-subsystem follow-up reuses useful context;
- unrelated/independent-review work can start fresh;
- stale-session errors fail explicitly;
- persistent state does not leak secrets.

### V0.1 policy

```text
implementation continuity -> reuse
independent judgment       -> fresh
```

---

## Phase N6 — Controlled mutation Worker

### Objective

Prove that Codex/Nemotron can safely perform a bounded edit, not just read.

Use the existing controlled fixture and verifier where possible.

### Requirements

- fixed mutation scope;
- architecture/security/public contracts fixed by Lead;
- Codex sandbox permits only the required workspace mutation;
- run focused verifier;
- no commit;
- validated terminal handoff;
- Lead independently inspects the diff.

### PASS

The Worker edits only the allowed fixture, verifier passes, handoff is valid, and Lead acceptance catches any scope violation.

---

## Phase N7 — Adapter implementation

Only after N1-N6 pass, implement a production candidate:

```text
skills/delegating-work/
  scripts/
    codex-nim-worker.ps1
  schemas/
    delegent-handoff.schema.json
    delegent-decision.schema.json
```

### Adapter responsibilities

- resolve isolated Codex config/profile;
- load credential without printing it;
- invoke `codex exec`;
- separate stdout/stderr;
- enforce timeout and process cleanup;
- capture session/thread identity;
- parse only the supported final result channel;
- exact-schema validation;
- sensitive-value filtering;
- normalize to the existing Lead-visible handoff;
- support resume for persistent Workers;
- expose deterministic protocol errors.

### Adapter non-responsibilities

Do **not** reimplement repository read/search/edit tools, shell execution loop, model tool orchestration, sandbox engine, or Codex session storage. Those are reasons for choosing Codex as the harness.

---

## Phase N8 — Runtime bake-off

Compare OpenCode and Codex+NIM on the same controlled Worker tasks.

| Criterion | OpenCode baseline | Codex+NIM candidate |
|---|---|---|
| NIM connectivity | known pass | |
| repo read/tools | known pass | |
| terminal handoff reliability | blocked | |
| persistent session | known feasible | |
| sandbox/mutation control | | |
| protocol surface area owned by Delegent | high | |
| cold-start reliability | | |
| trajectory isolation | | |
| implementation complexity | high | |
| maintenance risk | high | |

### Selection rule

Prefer Codex+NIM if it passes N1-N7 and is no worse than OpenCode on the controlled task, especially on terminal-boundary reliability, amount of runtime-specific code Delegent must own, session continuity, and security/sandbox behavior.

Do not optimize for tiny latency differences before correctness.

---

## Phase N9 — Delegent composition gate

Only after selecting Codex+NIM as the preferred adapter:

```text
$delegent $delegent-eval-workflow
```

Run the existing controlled routing pair:

- B1: trivial Lead-owned task;
- B2: context-heavy delegated task.

B2 must prove:

```text
Codex Lead
  -> Delegent placement
  -> Codex/NIM Worker
  -> validated compact handoff
  -> Lead diff/review
  -> Lead final acceptance
```

Only after this passes should Matt `implement` integration resume.

---

## Pivot / rollback rules

### Pivot to Codex+NIM

Make Codex+NIM the V0.1 default Worker runtime when:

- N1-N7 pass;
- runtime bake-off favors it or shows equivalent reliability with materially less adapter complexity;
- B2 controlled Delegent composition passes.

### Keep OpenCode fallback

Keep the OpenCode adapter until at least one realistic ticket/spec task passes with Codex+NIM.

### Reject Codex+NIM for V0.1

Do not force the path if any of these are structural rather than fixable edge cases:

- hosted NIM cannot provide the Responses semantics Codex needs and a proxy would be large/fragile;
- Codex built-in tool representations are incompatible with the NIM endpoint;
- structured terminal output cannot be made deterministic without recreating a custom agent protocol;
- resume/session behavior cannot preserve Worker continuity;
- sandbox/security behavior is weaker than the current baseline.

If rejected, next candidate order is:

```text
Direct minimal NIM runtime
-> Goose + NIM
-> revisit OpenCode
```

---

## Immediate next action

Do **not** run another OpenCode A.7 as the next experiment.

Start with N0/N1:

1. confirm installed Codex version and `codex exec --help`;
2. create isolated Codex/NIM config;
3. test the hosted NVIDIA endpoint's `/v1/responses` behavior;
4. if compatible, run the first `codex exec -p nim-worker --ephemeral --json` smoke.

No Delegent production routing change is required for this first spike.
