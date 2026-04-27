# ADR-009 — Eval Harness Methodology

**Status:** Accepted  
**Date:** 2026-04-26  
**Author:** Shreya Poojary  
**Applies to:** Sprint 4 — Bedrock agent + eval harness

---

## Context

The Bedrock agent's accuracy is a central portfolio claim. Without a structured eval harness, "the agent works" is anecdote. With one, it is a number — and a number that can be explained, interrogated, and improved.

The eval harness must answer three questions per incident:
1. Did the agent call the right tools, in a reasonable order?
2. Did the agent arrive at the correct diagnosis?
3. Did the agent propose the correct remediation (or correctly decide to escalate)?

It must also produce per-run cost metrics (ADR-001 Principle 6) and write results to the audit log (ADR-001 Principle 4).

The honest target accuracy is **60–75%** across 10 scenarios. A published 99% would be a red flag in any technical interview — it suggests either an overfitted harness or scenarios designed to be trivially easy. The eval is the credibility mechanism, not the success metric.

---

## Decision

### Scenario format

Each scenario is a JSON file in `agent/evals/scenarios/`:

```json
{
  "id": "scenario-01",
  "name": "Oversized replicas — cost anomaly",
  "chaos_scenario": 1,
  "description": "payment-simulator scaled to 10 replicas; Cost Explorer shows 10x spend spike",
  "preconditions": {
    "inject_fault": "--scenario=1",
    "wait_minutes": 60,
    "signal_check": "cost_explorer_daily_delta_gt_5x"
  },
  "ground_truth": {
    "expected_tools": [
      "sentrops_cost_mcp.top_drivers_by_tag",
      "sentrops_cost_mcp.detect_cost_anomaly"
    ],
    "tool_order": "loose",
    "expected_diagnosis": "replica_count_anomaly",
    "expected_action": "terraform_pr",
    "expected_pr_contains": ["replicas", "payment-simulator"],
    "acceptable_escalation": false
  },
  "scoring": {
    "tool_selection": 30,
    "diagnosis": 40,
    "remediation": 30
  }
}
```

### Ground truth structure

#### `expected_tools`

A list of MCP tool names the agent should invoke. Order strictness is controlled by `tool_order`:
- `"strict"` — tools must be called in this exact sequence
- `"loose"` — all listed tools must appear in the trace, in any order
- `"subset"` — at least N of the listed tools must appear (N specified separately)

Most scenarios use `"loose"` — the agent may gather evidence in different orders and still reach the correct conclusion.

#### `expected_diagnosis`

A label from a fixed taxonomy of diagnosis types:

| Label | Meaning |
|---|---|
| `replica_count_anomaly` | Too many replicas for the load |
| `dlq_buildup` | Dead letter queue accumulating messages |
| `upstream_latency` | External dependency is slow |
| `retry_storm` | Retry backoff misconfiguration |
| `untagged_spend` | Cost attribution gap |
| `savings_plan_gap` | Savings Plan utilization below threshold |
| `unknown` | Agent correctly identified uncertainty |

The diagnosis label is extracted from the agent's structured output (a required field in the agent's final response schema).

#### `expected_action`

One of: `terraform_pr`, `slack_info`, `human_escalation`.

If `acceptable_escalation: true`, both `terraform_pr` and `human_escalation` receive full credit.

#### `expected_pr_contains`

A list of strings that must appear in the Terraform PR body. Used to verify the PR is about the right resource, not a generic template. Strings are checked with case-insensitive substring match.

### Scoring rubric

Each scenario is scored out of 100 points using a partial-credit matrix:

#### Tool selection (30 points)

| Condition | Points |
|---|---|
| All expected tools called | 30 |
| ≥ 50% of expected tools called | 15 |
| No expected tools called | 0 |
| Unexpected tools called (hallucinated tools) | −5 per call, min 0 |

"Unexpected tools" are tools that do not exist in the MCP server registry — a sign the agent fabricated a tool name. Unexpected-but-real tools (the agent called a real tool not in `expected_tools`) do not incur a penalty; the agent may find valid alternative evidence paths.

#### Diagnosis (40 points)

| Condition | Points |
|---|---|
| Exact match on `expected_diagnosis` | 40 |
| Semantically correct but different label | 20 (manual review required) |
| Incorrect diagnosis | 0 |

Semantic correctness is flagged by the scorer and requires a one-time manual review decision. The decision is recorded in a `semantic_overrides.json` file and applied consistently across all future runs.

#### Remediation (30 points)

| Condition | Points |
|---|---|
| Correct action type + PR contains all expected strings | 30 |
| Correct action type + PR contains ≥ 50% expected strings | 15 |
| Correct action type + PR contains 0 expected strings | 5 |
| Wrong action type (e.g., Slack instead of PR) | 0 |
| Acceptable escalation (if `acceptable_escalation: true`) | 25 |

### The 10 scenarios

The base four chaos scenarios (ADR-006) generate 10 eval scenarios through combinations and variations:

| # | Description | Chaos basis | Difficulty |
|---|---|---|---|
| 01 | Oversized replicas — straightforward cost spike | Scenario 1 | Easy |
| 02 | Oversized replicas — with misleading untagged spend also present | Scenario 1 + noise | Medium |
| 03 | DLQ buildup — clear poison pill | Scenario 2 | Easy |
| 04 | DLQ buildup — slow accumulation (12 hours, not 15 min) | Scenario 2 slow | Medium |
| 05 | Latency SLO breach — stripe-mock slow | Scenario 3 | Easy |
| 06 | Latency SLO breach + cost anomaly simultaneously | Scenario 3 + 1 | Hard |
| 07 | 503 burst — clear error rate spike | Scenario 4 | Easy |
| 08 | 503 burst + retry storm causing DLQ buildup | Scenario 4 + 2 | Hard |
| 09 | Untagged spend anomaly (no chaos — misconfigured tag) | None (config error) | Medium |
| 10 | No anomaly — false positive (healthy system, noisy alarm) | None | Hard |

Scenario 10 (false positive) is the most important: the agent must recognize that no remediation is needed and respond with `slack_info` (not a Terraform PR). A false-positive PR is worse than no response.

### Scorer implementation

`agent/evals/scorer.py` accepts a scenario ID and agent trace as input and returns a `ScenarioResult`:

```python
@dataclass
class ScenarioResult:
    scenario_id: str
    score: int              # 0–100
    tool_score: int
    diagnosis_score: int
    remediation_score: int
    passed: bool            # score >= 60
    needs_manual_review: bool
    cost_usd: float         # actual Bedrock cost for this run
    duration_seconds: float
    agent_trace: list[dict] # full tool call history
```

The scorer does not call the LLM — it compares the agent's output against the ground truth deterministically. This keeps the scorer itself free of model-dependent behavior.

### Runner and CI

`agent/evals/runner.py` executes all 10 scenarios sequentially (not in parallel — parallel runs would create conflicting chaos injections in the cluster):

```
for each scenario:
  1. inject chaos (if applicable)
  2. wait for signal to appear (via signal_check)
  3. run agent
  4. score result
  5. revert chaos
  6. wait 5 minutes (signal clear)
```

`runner.py` produces `agent/evals/report.md` with:
- Overall accuracy (score ≥ 60 = pass)
- Per-scenario breakdown
- Total and per-scenario Bedrock cost
- Wall-clock runtime
- Any scenarios flagged for manual review

The nightly GitHub Actions workflow (`.github/workflows/eval-nightly.yml`) runs the runner and posts the report as a GitHub Actions job summary. The report is also committed to the repo (`git commit -m "chore: nightly eval report <date>"`).

### Handling pre-production signals

Scenarios that require waiting for Cost Explorer to refresh (hourly granularity) are marked `"async_signal": true`. The runner calls `signal_check` every 5 minutes for up to 90 minutes before failing the scenario with `SIGNAL_NOT_OBSERVED`. This is logged in the report — a `SIGNAL_NOT_OBSERVED` failure is a harness issue, not an agent failure.

For the nightly CI run, scenarios with `async_signal: true` inject chaos 2 hours before the eval run starts (via a preceding CronJob step).

### Accuracy target and interpretation

The published accuracy target is **60–75%** (6–7.5 scenarios passing out of 10).

Interpretation guide committed alongside the report:
- **< 50%:** Systematic failure — likely a tool schema problem, a prompt issue, or a signal timing issue. Diagnose before re-running.
- **50–60%:** Weak — revisit the failing scenarios individually. Look for patterns (all hard scenarios failing? all DLQ scenarios failing?).
- **60–75%:** Target range — the agent handles common cases correctly and fails gracefully on ambiguous ones.
- **> 85%:** Investigate for overfitting — are the scenarios too easy, or is the ground truth too generous?
- **> 95%:** Red flag — the harness is almost certainly not testing the right things.

---

## Alternatives Considered

### Alternative: LLM-as-judge scoring

Use a separate LLM call to judge whether the agent's output is correct, rather than rule-based scoring.

**Rejected because:** LLM-as-judge introduces model-dependent variance into the scoring — the "correct" answer changes with the judge model's version. Rule-based scoring against explicit ground truth is reproducible and auditable. The partial exception (semantic diagnosis matching) is bounded to a one-time manual review, not a live LLM call.

### Alternative: Human evaluation only

Have Shreya manually review and score each agent run.

**Rejected because:** Manual evaluation does not scale to nightly CI runs. The portfolio value of the eval harness is that it runs automatically and produces a number. Manual review is preserved for the semantic diagnosis override cases only.

### Alternative: Binary pass/fail per scenario (no partial credit)

A scenario either passes or fails; no partial scores.

**Rejected because:** Binary scoring obscures *why* the agent failed. Partial credit reveals whether the agent found the right evidence but drew the wrong conclusion (tool selection: 30, diagnosis: 0) vs. never finding the evidence at all (tool selection: 0, diagnosis: 0). This distinction is valuable for debugging prompt and tool schema issues.

### Alternative: More than 10 scenarios

Run 50+ scenarios to get a statistically meaningful accuracy number.

**Rejected because:** Each scenario requires: a ground-truth definition, chaos injection configuration, signal validation, and manual review of edge cases. 10 scenarios is the maximum achievable in Sprint 4's time budget. 10 scenarios across 4 signal dimensions (cost, DLQ, latency, error rate) × easy/medium/hard gives sufficient coverage of the scenario space. 50 scenarios would require a full sprint of scenario design alone.

### Alternative: Parallel scenario execution

Run all 10 scenarios simultaneously to reduce eval runtime.

**Rejected because:** Parallel chaos injections on the same cluster interfere with each other (Scenario 1 scales replicas; Scenario 6 also touches replicas while monitoring cost — the signals would overlap). Sequential execution with 5-minute cool-down periods is required for clean signal separation.

---

## Consequences

**Positive:**
- The accuracy number is reproducible, auditable, and can be improved incrementally
- Partial credit reveals the failure mode, not just the failure — actionable debugging signal
- Nightly CI runs catch regressions when tool schemas or prompts change
- The false-positive scenario (Scenario 10) validates the most important safety property: the agent does not open PRs when no remediation is needed

**Negative:**
- Sequential execution with signal wait periods means a full 10-scenario eval run takes 3–4 hours wall clock (2-hour async signal waits + chaos injection + agent run time). Not suitable for PR-level CI — nightly only.
- The 60–75% accuracy target may be uncomfortable to publish. It is honest. A higher number would require either easier scenarios or less rigorous ground truth — both worse outcomes.
- Scenarios 9 and 10 (no-chaos scenarios) require the cluster to be in a genuinely healthy state when they run. If a residual fault from a prior scenario is present, these scenarios fail incorrectly.

**Neutral:**
- The eval harness is calibrated for the four chaos scenario types in ADR-006. If new chaos scenarios are added, new eval scenarios must be designed and the harness re-calibrated. The accuracy number resets on recalibration.

---

## Related ADRs

- **ADR-001** — Architecture principles (Principle 4: audit every tool call — audit records are the raw data for the scorer)
- **ADR-006** — Chaos engineering approach (the four scenarios generate the 10 eval scenarios)
- **ADR-007** — MCP server design patterns (tool names in ground truth must match actual tool names exactly)
- **ADR-008** — Model tiering strategy (per-run cost tracked by the runner; accuracy measured per tier)
