export default {
  description:
    "Return the one terminal Delegent Worker handoff after all assigned work and verification are complete. Call exactly once, then stop.",
  args: {
    status: { type: "string", enum: ["completed", "blocked"] },
    summary: { type: "string", minLength: 1 },
    evidence: { type: "string", minLength: 1 },
    changes: { type: "string", minLength: 1 },
    tests: { type: "string", minLength: 1 },
    risks: { type: "string", minLength: 1 },
    decisions_needed: { type: "string", minLength: 1 },
    review_targets: { type: "string", minLength: 1 },
  },
  async execute() {
    return "Delegent terminal handoff recorded. Stop now; do not emit another handoff or decision."
  },
}
