export default {
  description:
    "Escalate one hard Delegent decision to the Lead when Worker execution cannot safely choose. Call exactly once, then stop.",
  args: {
    question: { type: "string", minLength: 1 },
    evidence: { type: "string", minLength: 1 },
    options: { type: "string", minLength: 1 },
    recommendation: { type: "string", minLength: 1 },
    confidence: { type: "string", minLength: 1 },
  },
  async execute() {
    return "Delegent decision escalation recorded. Stop now; do not emit another handoff or decision."
  },
}
