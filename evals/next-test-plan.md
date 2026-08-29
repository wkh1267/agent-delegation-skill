# Delegent V0.1 Next-Test Plan

This document records the testing decisions reached after the first direct-Worker and full Codex/Delegent smoke runs and defines the order for the next validation cycle.

## Decision record

### Matt Pocock `implement` is an integration target, not a dependency

The `$implement` example used during design refers to Matt Pocock's `skills/engineering/implement` workflow. That workflow is intended for ticket/spec-driven development and currently requires implementation discipline such as TDD where appropriate, regular typechecking/focused tests, a final full test run, code review, and a commit.

Delegent itself must remain workflow-agnostic:

- Delegent does **not** require Matt's skills to function.
- The next Worker-runtime test must not depend on `$implement`.
- A repository-local controlled workflow should validate Delegent composition before external workflow integration is introduced.
- Matt's `implement` should later be installed together with the workflow skills it relies on (notably `tdd` and `code-review`) and used as a high-value real-world integration test.

This separation avoids confusing Delegent/runtime failures with external workflow requirements such as TDD, nested code review, or commit behavior.

### Test layers

Run validation in this order:

```text
A. Worker protocol
   fake/local runtime only
        ↓
B. Controlled Delegent workflow
   $delegent $delegent-eval-workflow
        ↓
C. Real workflow integration
   Matt Pocock $implement (+ tdd/code-review)
        ↓
D. Real ticket/spec development
```

Do not skip directly to layer C while layer A is still failing.

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

Minimum deterministic cases are listed in `runtime-protocol.md` and must pass before Phase B.

Adapter code is security-sensitive. Workers may perform read-only diagnosis or propose a patch, but Lead owns/explicitly approves mutation and final review.

## Phase B — Controlled workflow composition

Use the repository-local workflow:

```text
$delegent $delegent-eval-workflow
```

Test task:

```text
Change evals/fixtures/controlled-workflow.txt from:

mode=baseline

to:

mode=delegated

Only modify that fixture. Run:

powershell -NoProfile -ExecutionPolicy Bypass -File .\evals\check-controlled-workflow.ps1 -Expected delegated

Do not commit. Leave the one-line fixture change for Lead review.
```

Expected orchestration:

- companion workflow is found and loaded;
- Delegent keeps intent/scope/final acceptance with Lead;
- the one-line implementation and focused verification may be delegated if the placement policy says dispatch is worthwhile;
- no external/nested workflow skills are involved;
- Worker returns only a validated compact handoff through the runtime protocol;
- Lead inspects the one-line diff and verifier evidence;
- after recording the result, restore the fixture to `mode=baseline`.

This phase intentionally removes Matt/TDD/code-review/commit semantics from the experiment.

## Phase C — Matt `implement` integration

Only after Phases A and B pass, install/verify the Matt Pocock engineering workflows used by `implement`.

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

Matt `implement` is a major real-world acceptance target, but a failure here must be classified separately from Phase A/B runtime correctness.

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

PowerShell checks:

```powershell
git status --short
git diff

Get-ChildItem -Recurse -File |
  Where-Object {
    $_.FullName -notmatch '\\.git\\' -and
    $_.FullName -notlike '*\skills\delegating-work\.env'
  } |
  Select-String -Pattern 'nvapi-' -List |
  Select-Object -ExpandProperty Path
```

All three should produce no unexpected output before a real Worker test.

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

Verify the core Delegent skills are visible to Codex before Phase B:

```powershell
Test-Path "$HOME\.agents\skills\delegent\SKILL.md"
Test-Path "$HOME\.agents\skills\delegating-work\SKILL.md"
Test-Path "$HOME\.agents\skills\delegent-eval-workflow\SKILL.md"
```

For Phase C only, also verify the selected Matt workflow installation (actual installed paths are authoritative):

```text
implement
tdd
code-review
```

If an explicitly selected workflow is unavailable, Delegent must fail fast instead of reconstructing or approximating its semantics.

## Stop conditions

Do not continue to the next phase when:

- the Worker adapter cannot deterministically validate/recover the terminal structured result;
- the adapter leaks or interpolates a credential;
- companion workflow discovery is ambiguous or missing;
- a Worker mutation crosses a Lead-owned security/architecture boundary;
- Lead must reconstruct the Worker handoff from raw tool trajectory;
- the controlled fixture/test cannot be restored to a clean baseline.

## Acceptance progression

```text
Phase A PASS
  = Worker protocol boundary is trustworthy

Phase B PASS
  = Delegent workflow composition is trustworthy in a controlled case

Phase C PASS
  = Delegent composes the primary real-world Matt workflow correctly

Phase D PASS
  = realistic ticket/spec-driven use is ready for broader evaluation
```
