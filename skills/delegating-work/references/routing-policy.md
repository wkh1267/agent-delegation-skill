# Routing Policy

Apply these gates in order.

1. **Lead ownership:** Keep decisions about intent, requirements, architecture,
   public contracts, schema semantics, security, irreversible changes, or final
   acceptance with the lead.
2. **Context value:** Delegate when the lead needs a verified result but not the
   searches, source reading, logs, test output, or implementation history used
   to produce it.
3. **Dispatch overhead:** Keep a small, known, local lookup or edit with the lead
   when dispatch would cost more than the work.

If a delegated task reaches a lead-owned decision, the worker must stop and
request that decision with evidence and options before continuing.

Delegation does not imply parallelism. Parallelize only independent tasks that
do not modify the same files, share mutable state, or depend on each other's
findings. Begin unknown-scope exploration with one worker; split only after
independent domains are known.
