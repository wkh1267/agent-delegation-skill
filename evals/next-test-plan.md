# Delegent V0.1 Next-Test Plan

This document records the testing decisions reached after the first direct-Worker and full Codex/Delegent smoke runs and defines the order for the next validation cycle.

## Decision record

### Matt Pocock `implement` is an integration target, not a dependency

The `$implement` example used during design refers to Matt Pocock's `skills/engineering/implement` workflow. That workflow is intended for ticket/spec-driven development and currently requires implementation discipline such as TDD where appropriate, regular typechecking/focused tests, a final full test run, code review, and a commit.

Delegent itself must remain workflow-agnostic:

- Delegent does **not** require Matt's skills to function.
- Worker-runtime validation must not depend on `$implement`.
- A repository-local controlled workflow should validate Delegent composition before external workflow integration is introduced.
- Matt's `implement` should later be installed together with the workflow skills it relies on (notably `tdd` and `code-review`) and used as a high-value real-world integration test.

This separation avoids confusing Delegent/runtime failures with external workflow requirements such as TDD, nested code review, or commit behavior.

### Test layers

Run validation in this order:

```text
A. Worker protocol
   fake/local runtime only
        ↓
A.5 Live Worker transport compatibility
   direct read-only wrapper probe
        ↓
B. Controlled Delegent composition
   B1 trivial Lead-owned routing
   B2 controlled delegated routing
        ↓
C. Real workflow integration
   Matt Pocock $implement (+ tdd/code-review)
        ↓
D. Real ticket/spec development
```

Do not skip directly to layer C while an earlier layer is still failing.

## Phase A — Worker runtime protocol

Goal: make the Worker boundary deterministic before another remote orchestration test.

Source of truth:

```text
skills/delegating-work/references/runtime-protocol.md
```

Requirements:

- no NVIDIA NIM call during local protocol tests;
- use fake credentials;
- use fake OpenCode/session responses or a fake executable/server fixture;
- validate structured Worker results rather than scraping arbitrary human terminal output;
- return a compact valid handoff/escalation or deterministic `WORKER_PROTOCOL_ERROR`;
- preserve existing session/title/agent/dir behavior;
- do not leak credential values into source, logs, fixtures, errors, or handoffs.

Minimum deterministic cases are listed in `runtime-protocol.md` and must pass before Phase A.5.

Adapter code is security-sensitive. Workers may perform read-only diagnosis or propose a patch, but Lead owns/explicitly approves mutation and final review.

### Phase A result

The first implementation passed 14 deterministic fake-only cases, PowerShell AST parsing, diff hygiene, credential-residue checks, and process-lifecycle cleanup. Worker execution no longer depends on parsing `opencode run` human terminal output; normal Worker runs use an authenticated loopback OpenCode server/session API and JSON-schema structured result validation.

Phase A establishes local protocol correctness, but it does **not** prove compatibility with the installed OpenCode server/NVIDIA provider runtime because real Worker execution was intentionally forbidden during Phase A.

## Phase A.5 — Live Worker transport compatibility

Goal: verify the smallest possible real OpenCode/NIM path before combining it with Delegent workflow composition.

This phase makes one bounded, read-only Worker call through the wrapper. It is not a repository mutation test and does not use `$delegent`.

Preconditions:

- Phase A is PASS;
- the affected NVIDIA API key has been rotated;
- repository preflight passes;
- working tree is clean;
- no build Worker is asked to modify security-sensitive adapter code.

Recommended probe from the repository root:

```powershell
$worker = "$HOME\.agents\skills\delegating-work\scripts\nemotron-worker.ps1"

& $worker `
  --title "delegent:agent-delegation-skill:protocol-probe:plan" `
  --agent plan `
  --dir (Get-Location).Path `
  "Read only README.md and return a normal Worker handoff. Do not modify files. SUMMARY must say protocol probe completed. CHANGES and TESTS should be none when inapplicable."
```

Expected:

- the OpenCode server becomes healthy on loopback;
- Basic Auth works without exposing the server password;
- the configured NVIDIA/Nemotron model is accepted;
- `POST /session/:id/message` accepts the JSON-schema `format` request;
- the adapter emits only the compact eight-field handoff;
- no raw tool/text trajectory reaches Lead-visible output;
- no repository files change;
- the server process and descendants terminate after the wrapper exits.

Known upstream compatibility risk: some OpenCode versions have had bugs when rereading sessions that contain output-format metadata. The primary synchronous structured response should therefore be considered the preferred source; persisted-session recovery is a fallback and may fail deterministically on affected versions rather than reconstructing output from raw trajectory.

Stop before Phase B if this probe returns `WORKER_PROTOCOL_ERROR`, hangs beyond the configured timeout, leaks trajectory/secrets, changes files, or leaves the server running.

## Phase B — Controlled Delegent composition

Use the repository-local workflow:

```text
$delegent $delegent-eval-workflow
```

Phase B contains two routing cases because Delegent must prove both sides of the dispatch-overhead gate.

### B1 — Trivial local work stays with Lead

Use the existing one-line fixture task:

```text
Change evals/fixtures/controlled-workflow.txt from:

mode=baseline

to:

mode=delegated

Only modify that fixture. Run:

powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\check-controlled-workflow.ps1 -Expected delegated

Do not commit. Leave the one-line fixture change for Lead review.
```

Expected:

- companion workflow is found and loaded;
- Delegent preserves exact scope and completion requirements;
- Lead may correctly keep this task local because dispatch overhead exceeds context savings;
- final acceptance stays with Lead;
- after recording the result, restore the fixture to `mode=baseline`.

B1 validates that Delegent does not delegate mechanically merely because a workflow is active. It does **not** prove the live Worker path.

### B2 — Controlled delegated work crosses the Worker boundary

Run a controlled task whose exploration/verification context is intentionally large enough to make Worker placement clearly worthwhile while keeping mutations deterministic and narrow.

The task must satisfy all of the following:

- architecture and expected outputs are already fixed;
- no security/public-contract/schema decision is required;
- Worker scope is explicit and confined to eval fixtures/tests;
- multiple reads/checks or enough disposable execution context exist that dispatch overhead is lower than Lead context cost;
- the final mutation remains small and easy for Lead to review;
- a deterministic focused verifier defines success;
- no nested external workflow skills or commit behavior are involved.

Expected orchestration:

- context-heavy exploration/verification is delegated to a Worker;
- Worker selection follows reuse/fresh policy deliberately;
- Worker result crosses the new structured runtime boundary;
- Lead receives only the validated compact handoff;
- Lead verifies the narrow diff/evidence and performs final acceptance;
- raw Worker trajectory is not reconstructed by Lead.

B2 is the controlled proof of the full path:

```text
Codex Lead
  -> Delegent
  -> delegating-work placement
  -> OpenCode/Nemotron Worker
  -> structured validated handoff
  -> Lead acceptance
```

Do not mark Phase B complete until both B1 and B2 behave as expected.

## Phase C — Matt `implement` integration

Only after Phases A, A.5, and B pass, install/verify the Matt Pocock engineering workflows used by `implement`.

Primary target repository:

```text
https://github.com/mattpocock/skills
```

At minimum verify that Codex can actually load:

```text
implement
tdd
code-review
```

Use the installed Matt version as the source of truth because its workflow contract may evolve.

Then run a small real integration test:

```text
$delegent $implement

<small ticket/spec with fixed architecture and narrow mutation scope>
```

Validation questions:

- Does Delegent preserve the complete `implement` workflow semantics?
- Does context-heavy exploration/implementation/test output stay with Workers where appropriate?
- Are architecture/security/public-contract decisions still Lead-owned?
- When `implement` requires TDD or code review, are those completion gates preserved rather than approximated?
- Does nested workflow activity avoid bypassing the Context Firewall?
- Does final acceptance remain with Lead?

Matt `implement` is a major real-world acceptance target, but a failure here must be classified separately from Phase A/A.5/B runtime correctness.

## Phase D — Real ticket/spec development

After Phase C passes, use Delegent on the normal ticket/spec-driven development workflow for which `$implement` is commonly used.

This is the first phase that should be treated as realistic product usage rather than controlled validation.

## Security preflight before the next real Worker call

The previous end-to-end run caused a Worker-authored adapter rewrite to temporarily expand a configured API credential into generated source before Lead rejected/restored the change.

Before any real NIM call:

1. rotate the affected NVIDIA NIM API key;
2. update only the ignored `skills/delegating-work/.env`;
3. confirm the working tree is clean;
4. confirm no credential-shaped value exists outside ignored secret storage;
5. do not allow a general build Worker to mutate credential-loading/protocol adapter code.

A repository-local preflight script performs the non-secret checks without requiring `rg` and never prints the API key value:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1
```

For controlled Delegent runs, require the eval workflow junction too:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireEvalWorkflow
```

For Phase C, require the Matt workflows too:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\preflight.ps1 -RequireMattWorkflows
```

`PREFLIGHT: PASS` is required before proceeding to the corresponding real Worker/integration test.

## Repository / Codex preflight

Synchronize the feature branch before starting a fresh Codex session:

```powershell
cd D:\wkh12\LEARNING\Development\agent-delegation-skills
git fetch origin
git switch feat/delegent-v0.1
git pull --ff-only origin feat/delegent-v0.1
git status --short
git branch --show-current
```

Expected branch:

```text
feat/delegent-v0.1
```

Before Phase B, expose the controlled workflow alongside the two core skills:

```powershell
New-Item -ItemType Junction `
  -Path "$HOME\.agents\skills\delegent-eval-workflow" `
  -Target "D:\wkh12\LEARNING\Development\agent-delegation-skills\skills\delegent-eval-workflow"
```

If the junction already exists and points to the correct target, do not recreate it.

For Phase C only, install/verify the selected Matt workflows (`implement`, `tdd`, `code-review`) using their actual installed skill paths as authoritative.

If an explicitly selected workflow is unavailable, Delegent must fail fast instead of reconstructing or approximating its semantics.

## Stop conditions

Do not continue to the next phase when:

- the Worker adapter cannot deterministically validate/recover the terminal structured result;
- the live transport probe cannot produce a valid structured handoff;
- the adapter leaks or interpolates a credential;
- companion workflow discovery is ambiguous or missing;
- a Worker mutation crosses a Lead-owned security/architecture boundary;
- Lead must reconstruct the Worker handoff from raw tool trajectory;
- the controlled fixture/test cannot be restored to a clean baseline.

## Acceptance progression

```text
Phase A PASS
  = local Worker protocol boundary is deterministic under fake/runtime tests

Phase A.5 PASS
  = installed OpenCode/NIM transport is compatible with the structured boundary

Phase B PASS
  = Delegent routing and workflow composition are trustworthy in controlled Lead-owned and delegated cases

Phase C PASS
  = Delegent composes the primary real-world Matt workflow correctly

Phase D PASS
  = realistic ticket/spec-driven use is ready for broader evaluation
```
