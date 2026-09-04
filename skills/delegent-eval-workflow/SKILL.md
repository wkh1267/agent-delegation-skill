---
name: delegent-eval-workflow
description: Minimal deterministic workflow used only to validate Delegent orchestration without depending on an external engineering workflow.
disable-model-invocation: true
---

# Delegent Eval Workflow

This is a controlled evaluation workflow, not a general development workflow.

Its purpose is to isolate workflow composition from external workflow behavior so Delegent can be tested deterministically.

When explicitly selected with `$delegent`:

1. Read only the task, the named fixture, and the verifier needed to understand the requested one-line change.
2. Preserve the user's exact mutation scope and expected value.
3. Make exactly the approved fixture mutation; do not broaden scope.
4. Run exactly the named focused verifier.
5. Do not introduce architecture, schema, security, or public-contract decisions.
6. Do not invoke nested workflow skills.
7. Do not commit the change.
8. Leave the fixture mutation in the working tree for Lead review and final acceptance.

The workflow owns these completion requirements. Delegent still owns Lead-vs-Worker placement, Worker continuity, escalation, Context Firewall enforcement, and final acceptance.
