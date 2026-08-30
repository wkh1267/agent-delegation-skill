import { tool } from "@opencode-ai/plugin"

export default tool({
  description:
    "Return the one terminal Delegent Worker handoff after all assigned work and verification are complete. Call exactly once, then stop.",
  args: {
    status: tool.schema.enum(["completed", "blocked"]),
    summary: tool.schema.string().min(1),
    evidence: tool.schema.string().min(1),
    changes: tool.schema.string().min(1),
    tests: tool.schema.string().min(1),
    risks: tool.schema.string().min(1),
    decisions_needed: tool.schema.string().min(1),
    review_targets: tool.schema.string().min(1),
  },
  async execute() {
    return "Delegent terminal handoff recorded. Stop now; do not emit another handoff or decision."
  },
})
