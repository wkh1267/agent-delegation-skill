# ADR-0001: Make the Worker runtime replaceable and prioritize Codex harness + NVIDIA NIM

- **Status:** Partially superseded by [ADR-0002](0002-direct-nim-worker-runtime.md) on 2026-09-03. The runtime choice below did not survive N4: Codex+NIM passed N0-N3 but could provide no machine boundary for the terminal handoff, so the Worker runtime is now a direct NIM loop. Everything here about Delegent being runtime-agnostic, about credential and configuration isolation, and about the Context Firewall still holds, and Codex+NIM remains a working baseline and the bake-off comparison arm.
- **Date:** 2026-08-31
- **Scope:** Delegent V0.1 Worker runtime
- **Supersedes:** The implicit assumption that OpenCode is the required Worker harness

## Context

Delegent's core architecture remains sound:

```text
Lead = strategic memory + judgment
Worker = execution memory + repository context
Repo = durable project knowledge
Delegent = orchestration across boundaries
```

The product goal is not to make OpenCode work. The product goal is to let the Codex Lead reliably place context-heavy work in a cheaper long-context Worker while keeping architecture, security-sensitive decisions, final review, and acceptance with the Lead.

The OpenCode path proved several useful pieces:

- direct NVIDIA NIM inference works;
- Nemotron normal tool calling works;
- direct forced named tool calling works;
- plain OpenCode + Nemotron repository inspection works;
- the Delegent terminal protocol and Context Firewall validate deterministically in fake/local tests;
- Worker session continuity and durable storage are feasible.

However, the live OpenCode integration repeatedly exposed runtime-specific failure surfaces that are not part of Delegent's product value:

- OpenCode `format: json_schema` failed in the live 1.18.25 stack;
- custom-tool discovery and plugin loading required several runtime-specific workarounds;
- a zero-inference diagnostic proved the same configured plugin can appear correctly in the effective config and ToolRegistry while the production wrapper still observes transient/unavailable registration states;
- the latest production A.7 probe still returned `terminal_tools_unavailable`.

At this point, additional OpenCode lifecycle/config/plugin debugging has diminishing value compared with testing a thinner Worker harness.

## Decision

### 1. Delegent is runtime-agnostic

The Worker runtime is an adapter boundary, not part of Delegent's core architecture.

The conceptual interface is:

```text
WorkerAdapter
  StartWorker / StartTask
  ResumeWorker
  AbortWorker
  CollectTerminalResult
```

The Lead/Worker placement policy, Worker identity, Context Firewall, handoff schema, escalation rules, and final Lead acceptance remain unchanged across runtimes.

### 2. OpenCode becomes a candidate/fallback runtime

Do not delete the existing OpenCode adapter yet.

It remains:

- a working baseline for plain Nemotron repository work;
- a source of validated session/security/protocol lessons;
- a fallback until another runtime passes controlled Delegent composition.

But stop expanding OpenCode-specific workaround logic unless it is required to preserve the current baseline or to obtain a decisive comparison result.

### 3. Prioritize a Codex harness + NVIDIA NIM Worker spike

The preferred next runtime candidate is:

```text
Main Codex / GPT-5.6 Sol
        = Lead
          |
          | Delegent placement
          v
codex exec -p nim-worker
        = Worker harness
          |
          v
NVIDIA NIM / Nemotron
        = Worker model
```

This is attractive because Codex already provides the agent loop, repository tools, sandboxing, non-interactive execution, persisted sessions/resume, JSONL events, and final-output schema support.

NVIDIA also documents Codex CLI as a supported NIM integration using a custom Codex model provider with `wire_api = "responses"`.

### 4. Use `codex exec` first, not Codex app-server

V0.1 should start with the smallest headless surface:

```text
codex exec
codex exec --json
codex exec --output-schema <schema>
codex exec resume <session>
```

Do not begin with app-server.

Reason:

- `codex exec` directly matches a delegated Worker invocation;
- it already exposes JSONL, output-schema, ephemeral, resume, and fork primitives;
- current Codex reports include a custom-provider/profile inheritance bug in the app-server `thread/start` path, while the same profile works with `codex exec`.

App-server may be reconsidered after the basic Worker path is stable.

### 5. Prefer Codex-native final output schema for the terminal handoff

The first Codex Worker terminal boundary to test is `codex exec --output-schema`.

The desired normal schema remains exactly:

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

Decision escalation remains logically equivalent to the current `DECISION_NEEDED` contract.

The Delegent adapter must still perform exact local validation and sensitive-value filtering. `--output-schema` is a transport/enforcement mechanism, not a replacement for the Context Firewall.

If the NIM Responses implementation cannot support the schema feature required by Codex, record that as a compatibility result and evaluate the fallback path explicitly rather than silently weakening the protocol.

### 6. Keep credentials and Codex configuration isolated

The spike must not modify the user's normal `~/.codex/config.toml`.

Use a Delegent-controlled or temporary `CODEX_HOME` for the NIM Worker profile/config and load the NIM key only from an environment variable/ignored secret source.

No credential values may appear in tracked config, JSONL logs, handoffs, diagnostics, or CI output.

### 7. Pin the Windows sandbox backend explicitly

The isolated Worker config must declare:

```toml
[windows]
sandbox = "unelevated"
```

On Codex 0.151.0 for Windows an unspecified backend resolves to `disabled`. A
restricted permission profile with no enforceable sandbox makes non-interactive
`codex exec` exec-policy reject otherwise-benign unmatched commands, because
there is no approval prompt available to fall back on. That is what blocked N3b.
`unelevated` selects the RestrictedToken backend, and the zero-inference doctor
differential is unambiguous:

```text
no [windows] sandbox key   -> sandbox backend = disabled
sandbox = "unelevated"     -> sandbox backend = <redacted>  (i.e. enabled)
```

Do not treat `--sandbox danger-full-access` as the remedy. It is a diagnostic
control only; the Worker must stay inside Codex's managed sandbox.

Consequence for diagnostics: Codex redacts an *enabled* backend's name in both
the `--json` and human doctor reports (`--json` is documented as "Emit a
redacted machine-readable report"), while printing `disabled` verbatim. The
backend can therefore only be gated **negatively**, against `disabled`. Also,
`filesystem sandbox`/`network sandbox` report the requested policy and read
`restricted` whether or not a backend is active, so neither may be used to infer
that the sandbox is enforced.

### 8. Classify error-typed stream entries; never gate on their presence

Codex delivers non-fatal notices on the same JSONL stream as real failures, both
as top-level `error` events and as error-typed items. Two are expected on this
runtime and must be reported rather than treated as turn failures:

- the fallback-metadata notice, which appears on **every** turn because a custom
  NIM model is never in Codex's model catalog;
- `Reconnecting... n/5` notices, when the hosted NIM endpoint answers a valid
  model id with `404 Model not found` or drops the response stream.

A turn's outcome is decided by `turn.completed`/`turn.failed` plus exact output
validation, never by the mere presence of an error-typed entry — otherwise the
gates go flaky on provider weather. Any *unrecognized* stream error still fails.
Retry counts and the 404 signal are recorded because their rate is a reliability
input for the runtime bake-off.

## Consequences

### Positive

- Lead and Worker use the same Codex harness semantics.
- Delegent no longer translates between Codex concepts and OpenCode-specific agent/plugin/session concepts.
- Tool execution, repository mutation, sandboxing, and session lifecycle are delegated to Codex instead of being reimplemented.
- The Worker adapter can become thinner.
- `codex exec --output-schema` may remove the need for a custom terminal plugin entirely.
- Runtime choice becomes testable and replaceable.

### Costs / risks

- NVIDIA's documented Codex integration requires a Responses-compatible NIM endpoint.
- The hosted Developer endpoint used by this project must be tested; do not assume `/v1/responses` support merely because self-hosted/current NIM supports it.
- Third-party Responses compatibility may differ from OpenAI's implementation for built-in/custom tools or structured output.
- `codex exec --json` is useful for lifecycle telemetry, but the Context Firewall must not depend on reconstructing every internal tool call from JSONL.
- Persistent Worker reuse through `codex exec resume` needs explicit validation with a custom NIM provider.
- Codex has no catalog metadata for a custom NIM model, so it applies fallback metadata (observed context window `258400`) and warns that this can degrade behavior. `model_context_window` is a real config key, but the hosted NIM `/v1/models` response exposes only `id`/`object`/`created`/`owned_by`, so no authoritative Nemotron context length is available to pin. Guessing a value is worse than the documented fallback; revisit before N5/N6 grow long Worker threads.
- The hosted NIM endpoint is intermittently unreliable for a valid model id: one observed N2b turn needed four Codex retries (twice `404 Model not found`, twice a dropped response stream) before completing correctly, while adjacent runs needed none. Worker-facing timeouts and retry budgets must assume this.

## Runtime selection gate

Do not formally replace OpenCode merely because the Codex path can answer a prompt.

Codex+NIM becomes the V0.1 preferred Worker runtime only after it passes all of:

1. hosted NIM Responses compatibility; **PASS (N1)**
2. Codex custom-provider execution; **PASS (N2a/N2b)**
3. real repository read/tool use; **PASS (N3, 2026-09-03)**
4. deterministic terminal handoff; **next (N4)**
5. session resume/continuity;
6. controlled repository mutation + verifier;
7. credential/trajectory isolation;
8. controlled Delegent B2 composition with Lead final acceptance.

Until then:

```text
Delegent core      = accepted
Codex+NIM runtime  = preferred candidate
OpenCode runtime   = frozen baseline/fallback
```

## References

- NVIDIA NIM: Codex CLI integration  
  https://docs.nvidia.com/nim/large-language-models/3.0.0/ai-assistant-integrations/codex-cli.html
- OpenAI Codex source: `codex exec` supports `--ephemeral`, `--json`, `--output-schema`, `resume`, and `fork`  
  https://github.com/openai/codex
- Current Codex custom-provider/app-server profile caveat  
  https://github.com/openai/codex/issues/23417
