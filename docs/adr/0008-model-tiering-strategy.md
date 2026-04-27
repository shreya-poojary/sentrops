# ADR-008 — Model Tiering Strategy

**Status:** Accepted  
**Date:** 2026-04-26  
**Author:** Shreya Poojary  
**Applies to:** Sprint 4 — Bedrock agent + eval harness

---

## Context

SentrOps uses Amazon Bedrock for all LLM inference. Three Claude models are available in the relevant capability range:

| Model | Bedrock ID | Input $/MTok | Output $/MTok | Context window |
|---|---|---|---|---|
| Claude Haiku 4.5 | `us.anthropic.claude-haiku-4-5-20251001` | $0.80 | $4.00 | 200K |
| Claude Sonnet 4.5 | `us.anthropic.claude-sonnet-4-5-20251101` | $3.00 | $15.00 | 200K |
| Claude Opus 4.7 | `us.anthropic.claude-opus-4-7-20260101` | $15.00 | $75.00 | 200K |

(Pricing as of April 2026. Verify current pricing at aws.amazon.com/bedrock/pricing before Sprint 4.)

The per-session Bedrock cost cap is $1 (ADR-001 Principle 6). A full 10-scenario eval run must stay under $5 total. A single incident diagnosis must cost < $0.50.

The agent must handle incidents across four scenarios with varying complexity. Not all incidents require the same model capability. Routing every request through Opus 4.7 would exceed the cost cap on a single complex incident.

---

## Decision

### Three-tier routing

The agent implements a three-tier model routing strategy:

```
Incident arrives
      ↓
Haiku 4.5 — Classification (always)
      ↓
Is this info-only? → Slack notification (no further LLM calls)
      ↓
Sonnet 4.5 — Orchestration (tool calling loop)
      ↓
Confidence ≥ 0.8? → Open Terraform PR
      ↓
Confidence < 0.8 or tool budget exceeded → Escalate to Opus 4.7
      ↓
Opus 4.7 — Escalation (single reasoning pass, no tool calls)
      ↓
Open PR or page human if Opus also uncertain
```

### Tier 1 — Haiku 4.5 (classification)

**Role:** Classify every incoming incident and decide whether it needs remediation or is info-only.

**Input:** Raw incident payload (CloudWatch alarm JSON, cost anomaly notification, or Slack mention)

**Output:** Structured classification:
```json
{
  "severity": "INFO | WARN | CRITICAL",
  "category": "COST | RELIABILITY | LATENCY | ERROR_RATE | UNKNOWN",
  "needs_remediation": true,
  "confidence": 0.95,
  "summary": "DLQ depth on payment-simulator-dlq rose from 0 to 47 messages in 15 minutes"
}
```

**Why Haiku:** Classification is a simple, well-structured task that Haiku handles reliably. It sees a short input (alarm JSON is rarely > 2K tokens) and produces a small structured output. Running this on Opus 4.7 would cost 19× more per classification with no benefit.

**Cost per call:** ~$0.001–0.002 (1–2K input tokens, ~200 output tokens at Haiku rates)

### Tier 2 — Sonnet 4.5 (orchestration)

**Role:** Drive the tool-calling loop. Calls MCP tools iteratively to gather evidence, diagnose the root cause, and propose a specific Terraform remediation.

**Input:** Classification output + system prompt + tool schemas + running tool call history

**Budget:** Maximum 10 tool calls per incident. Maximum 30K input tokens + 5K output tokens per run. If either budget is exceeded, escalate to Opus.

**Output:** One of:
- A specific Terraform change with justification → passed to `sentrops-terraform-mcp.open_pr`
- An escalation signal (`{"escalate": true, "reason": "..."}`
- An info-only summary for Slack

**Why Sonnet:** Sonnet 4.5 handles multi-step tool use well and is the cost-performance optimum for orchestration tasks with 5–15 tool calls. At $3/MTok input, a 20K-token orchestration loop costs ~$0.06 — well within the $0.50/incident budget.

**Cost per call:** ~$0.06–0.15 per incident (varies with tool-call chain length)

### Tier 3 — Opus 4.7 (escalation)

**Role:** Called only when Sonnet produces low-confidence output or exhausts its tool-call budget. Receives the full tool-call history from Sonnet's run and reasons over it in a single pass (no additional tool calls).

**Input:** System prompt + full tool call history from Sonnet's run + escalation reason

**Budget:** Single call. Maximum 50K input tokens (the full Sonnet run history). No tool calls — this is a pure reasoning pass over collected evidence.

**Output:** Either a high-confidence diagnosis + PR justification, or a human escalation signal with a summary of what was observed and why the agent is uncertain.

**Why Opus:** Opus 4.7 is the strongest available reasoning model on Bedrock. It is reserved for cases where Sonnet has already collected the data but cannot synthesize a confident conclusion — a task that benefits from superior reasoning, not more tool calls. At $15/MTok, a 50K-token Opus call costs $0.75 — this is the escalation cost ceiling, acceptable for genuinely ambiguous incidents.

**Cost per escalation:** ~$0.75–1.00 (50K input, ~2K output)

### Escalation triggers

Sonnet escalates to Opus when any of the following conditions are met:
1. `confidence < 0.8` in the proposed remediation after completing the tool-call loop
2. Tool-call budget exhausted (10 calls reached) without a confident conclusion
3. A tool returns `retryable: false` error and no alternative diagnostic path exists
4. The proposed Terraform change would affect a resource type not seen in the training eval scenarios (safety heuristic)

Human escalation (Slack page, no PR) triggers when:
1. Opus also returns `confidence < 0.7`
2. The incident category is `UNKNOWN` after classification
3. The proposed change involves a resource tagged `Environment=production` (not `sandbox`) — impossible in the demo, but a hard stop if it were ever to occur

### Model IDs and cross-region inference

All models use the **cross-region inference profile** prefix (`us.`) for US East 1:
- `us.anthropic.claude-haiku-4-5-20251001`
- `us.anthropic.claude-sonnet-4-5-20251101`
- `us.anthropic.claude-opus-4-7-20260101`

Cross-region inference improves availability by routing across AWS regions transparently. It does not change pricing.

### Per-run cost accounting

The agent loop tracks cumulative token counts and estimated cost in real time:

```python
@dataclass
class RunBudget:
    max_input_tokens: int = 50_000
    max_output_tokens: int = 10_000
    max_tool_calls: int = 10
    max_cost_usd: float = 1.00

    current_input_tokens: int = 0
    current_output_tokens: int = 0
    current_tool_calls: int = 0
    current_cost_usd: float = 0.0
```

If any limit is reached mid-run, the agent stops, logs the budget exhaustion reason, and escalates to human rather than continuing to spend.

---

## Alternatives Considered

### Alternative: Opus 4.7 for all calls

Use only Opus 4.7 for all classification and orchestration. Simpler code, maximum capability.

**Rejected because:** At $15/MTok input, a 10-tool-call orchestration chain (30K tokens) costs ~$0.45 — before output tokens and before the classification step. Including output at $75/MTok, a complex incident could easily cost $1.50, exceeding the per-incident cap before the Sonnet+Opus tiering is even considered. The $1/session cap would allow fewer than one complex incident per session.

### Alternative: Haiku 4.5 for all calls

Use only Haiku 4.5 for cost minimization. Evaluate whether it can handle the orchestration task.

**Rejected because:** Haiku 4.5 is not reliably capable of multi-step tool use with 5+ tool calls while maintaining coherent diagnostic reasoning. This was tested during architecture planning: Haiku dropped tool context after 3 calls on scenario 4 (503 burst + retry storm), which requires correlating signals from three different tools. Sonnet 4.5 handled the same scenario correctly. The cost difference for orchestration (~$0.06 Sonnet vs. ~$0.015 Haiku per run) is worth the reliability.

### Alternative: A single model with prompt routing

Use one model but change the system prompt based on the task type (classify vs. orchestrate vs. escalate).

**Rejected because:** Prompt routing does not change the per-token cost. If the model is Sonnet, classification at Sonnet rates costs 4× more than Haiku for no benefit. The tiering is about cost, not just capability separation.

### Alternative: Self-hosted open-weight model (Llama, Mistral)

Run a self-hosted model on a GPU instance for zero marginal inference cost.

**Rejected because:** ADR-002 explicitly prohibits self-hosted or fine-tuned LLMs. Additionally, a GPU instance (`g4dn.xlarge` minimum) costs ~$0.53/hour = ~$15/month idle — unacceptable at the $50/month budget ceiling. And capability comparisons would need to be done and documented before using an open-weight model for production-like tool use.

### Alternative: OpenAI GPT-4 via AWS Bedrock (partner models)

Use GPT-4o on Bedrock as the orchestration model.

**Rejected because:** The portfolio thesis is explicitly about the Claude model family on Bedrock. Using GPT-4o would require justifying the choice in every interview. More importantly, the MCP tool schemas and eval harness are calibrated against Claude's tool-use behavior. Mixing model providers in a single agent loop introduces reliability variance that is hard to attribute during debugging.

---

## Consequences

**Positive:**
- Per-incident cost is bounded: typical incident ~$0.07 (Haiku + Sonnet no escalation), escalated incident ~$0.80 (Haiku + Sonnet + Opus)
- 10-scenario eval run estimated cost: 6 typical × $0.07 + 4 escalated × $0.80 = $0.42 + $3.20 = $3.62 — well within $5 target
- The tiering is visible in the audit log: each tier's calls appear as separate audit records with the model ID
- Escalation to human is a first-class outcome — the agent is designed to know when to stop, not to hallucinate a confident answer

**Negative:**
- Three-tier routing adds code complexity: the agent loop must track budget, evaluate confidence, and hand off between models
- The `confidence` score is self-reported by Sonnet — it is a heuristic, not a calibrated probability. The eval harness will measure how well confidence correlates with ground-truth correctness during Sprint 4.
- Escalation to Opus adds up to 1–2 seconds of additional latency (Opus inference for long contexts is slower than Sonnet). For an async remediation flow, this is acceptable; for a real-time response requirement, it would not be.

**Neutral:**
- Model IDs must be updated if Anthropic releases new model versions. The eval harness must be re-run on a new model before it is promoted to the orchestration tier — model upgrades are not automatic.

---

## Related ADRs

- **ADR-001** — Architecture principles (Principle 6: cost discipline; $1/session Bedrock cap)
- **ADR-007** — MCP server design patterns (tool schemas designed for Sonnet's tool-use behavior)
- **ADR-009** — Eval harness methodology (measures accuracy per tier; tracks per-run cost)
