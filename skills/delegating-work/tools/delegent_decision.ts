import { tool } from "@opencode-ai/plugin"

export default tool({
  description:
    "Escalate one hard Delegent decision to the Lead when Worker execution cannot safely choose. Call exactly once, then stop.",
  args: {
    question: tool.schema.string().min(1),
    evidence: tool.schema.string().min(1),
    options: tool.schema.string().min(1),
    recommendation: tool.schema.string().min(1),
    confidence: tool.schema.string().min(1),
  },
  async execute() {
    return "Delegent decision escalation recorded. Stop now; do not emit another handoff or decision."
  },
})
