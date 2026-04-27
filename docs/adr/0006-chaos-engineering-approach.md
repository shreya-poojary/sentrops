# ADR-006 — Chaos Engineering Approach

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** Sprint 2 — Observability + chaos + ShipPay workload

---

## Context

The Bedrock agent needs real, observable incidents to diagnose and propose remediations for. Without injected faults, the system is a demo with no problems to solve. The chaos scenarios are the *primary input* to the agent's eval harness — they are not an afterthought.

The requirements for the chaos scenarios are:
1. **Deterministic:** the same injection produces the same observable signal every time
2. **Reversible:** removing the injection returns the system to a healthy state
3. **Distinct:** each scenario produces a signal profile that is distinguishable from the others
4. **Cheap:** no additional AWS services or tools that push cost over budget

The scenarios also need to map to real-world DevOps/FinOps incident types that interviewers recognize.

---

## Decision

### Four canonical scenarios

SentrOps uses four chaos scenarios, each targeting a different observability signal dimension:

| # | Name | Signal dimension | Primary tool the agent should use |
|---|---|---|---|
| 1 | Oversized replicas | Cost anomaly ($/hour spike) | `sentrops-cost-mcp`: `top_drivers_by_tag` |
| 2 | Poison pill messages | Reliability (DLQ depth) | `sentrops-cloudwatch-mcp`: `get_metric_statistics` |
| 3 | Latency injection | Latency SLO burn | `sentrops-cloudwatch-mcp`: `logs_insights_query` |
| 4 | Upstream 503 burst | Error rate + retry storm | `sentrops-cloudwatch-mcp`: `describe_alarm_state` |

These four cover the three primary signal types used in real-world on-call: cost anomalies, queue/reliability issues, and latency/error SLO burns. This breadth is intentional for the eval harness.

### Scenario definitions

#### Scenario 1 — Oversized replicas (cost anomaly)

**Injection:** Scale the `payment-simulator` Deployment from 1 replica to 10 replicas.

```bash
kubectl scale deployment payment-simulator --replicas=10 -n shippay
```

**Observable signal:** Pod count × node cost → Cost Explorer shows ~10× spend on `payment-simulator` tagged resources within the next Cost Explorer refresh window (hourly granularity).

**Expected agent diagnosis:** Replica count anomaly. Propose Terraform PR reducing `replicas` to 1 in the Helm values for `payment-simulator`.

**Reversal:** `kubectl scale deployment payment-simulator --replicas=1`

#### Scenario 2 — Poison pill messages (DLQ buildup)

**Injection:** A sidecar in the `order-service` pod publishes a malformed message to the SQS queue every 30 seconds (missing required fields). The `payment-simulator` consumer cannot process it → SQS visibility timeout expires → message enters the DLQ after 3 retries.

Implemented as an optional init container triggered by an environment variable (`INJECT_POISON_PILL=true`).

**Observable signal:** `ApproximateNumberOfMessagesVisible` on the DLQ rises monotonically. CloudWatch alarm (threshold: > 5 messages) fires within ~5 minutes.

**Expected agent diagnosis:** DLQ depth rising, no corresponding increase in error rate on the producer. Propose Terraform PR adding a dead-letter queue consumer Lambda (or increasing `maxReceiveCount`).

**Reversal:** Remove `INJECT_POISON_PILL=true` from the Deployment env vars; drain the DLQ manually.

#### Scenario 3 — stripe-mock latency injection

**Injection:** Configure stripe-mock to respond with a configurable delay:

```bash
kubectl set env deployment/stripe-mock STRIPE_MOCK_LATENCY=2000 -n shippay
```

stripe-mock supports a `--latency` flag; we expose it as an env var.

**Observable signal:** `payment-simulator` p95 latency rises above the 300ms SLO threshold. The SLO burn-rate alert (fast window: 1 hour) fires. Grafana shows the `order_processing_duration_seconds` histogram shifting right.

**Expected agent diagnosis:** Latency SLO breach on `payment-simulator`. Upstream latency from stripe-mock is the cause. Propose Terraform PR adding a circuit breaker timeout to the `payment-simulator` configuration.

**Reversal:** `kubectl set env deployment/stripe-mock STRIPE_MOCK_LATENCY=0`

#### Scenario 4 — stripe-mock 503 burst (error + retry storm)

**Injection:** Configure stripe-mock to return HTTP 503 for all requests for a configurable duration:

```bash
kubectl set env deployment/stripe-mock STRIPE_MOCK_ERROR_RATE=100 -n shippay
```

**Observable signal:** `payment-simulator` error rate spikes to 100%. Retry logic in `payment-simulator` generates a retry storm → SQS message visibility timeout churn → order processing throughput drops to zero. Two alarms fire: `payment_error_rate > 1%` and `order_processing_backlog > 100`.

**Expected agent diagnosis:** Upstream payment processor returning 503. Retry storm is amplifying the impact. Propose Terraform PR adding exponential backoff configuration and a circuit breaker.

**Reversal:** `kubectl set env deployment/stripe-mock STRIPE_MOCK_ERROR_RATE=0`

### Injection mechanism: `scripts/inject-fault.sh`

A single script handles all scenarios:

```bash
scripts/inject-fault.sh --scenario=<1|2|3|4> --duration=<minutes|permanent> [--revert]
```

- `--duration=permanent` leaves the fault in place until `--revert` is called
- `--duration=<N>` auto-reverts after N minutes (background job + kubectl command)
- `--revert` removes the injection regardless of duration

The script uses `kubectl` only (no AWS API calls) so it does not need AWS credentials.

### Scheduled chaos

A Kubernetes CronJob runs one scenario per day on a rotating basis (scenario 1 Monday, 2 Tuesday, etc.), using `--duration=120` (2 hours). This ensures the observability stack and agent always have fresh signal to work with, and validates that the system self-heals correctly after revert.

### Signal validation gate

Before Sprint 3 (MCP server development) can begin, all four scenarios must be manually injected and validated:
- Signal appears in CloudWatch/Grafana within 2 minutes of injection
- The specific metric or log pattern expected by the agent's ground-truth eval is confirmed present
- Revert restores healthy state within 5 minutes

The validation is documented in `docs/runbooks/scenario-<N>-signals.md`.

---

## Alternatives Considered

### Alternative: AWS Fault Injection Service (FIS)

AWS FIS is a managed chaos engineering service that can inject EC2 terminations, ECS task failures, EKS node drains, and latency into VPC traffic via network disruption actions.

**Rejected because:**
1. FIS has no native SQS poison-pill or stripe-mock latency injection action — the scenarios we care about require application-level chaos, not infrastructure-level
2. FIS experiments cost money (per-hour pricing for some action types)
3. FIS experiments are defined as JSON templates and managed by AWS — less transparent in the Git repository than a shell script

FIS would be the right tool if the chaos scenarios were infrastructure-level (node failures, AZ outages). For application-level signal, shell + `kubectl` is simpler and sufficient.

### Alternative: Chaos Monkey / LitmusChaos / ChaosMesh

Open-source chaos frameworks with richer injection libraries and scheduling.

**Rejected because:** These are additional Helm chart installs with their own RBAC, CRDs, and operational surface. They are excellent tools for teams running continuous chaos engineering in production. For four deterministic, script-controlled scenarios in a demo workload, a shell script is sufficient and keeps the dependency count low.

### Alternative: Real SQS poison pills (malformed JSON from a separate producer)

Use a real SQS producer application (not a sidecar) to inject malformed messages.

**Rejected because:** Requires an additional deployment (the fake producer) and network configuration. A sidecar with an env-var toggle is simpler, self-contained, and easier to revert.

### Alternative: More scenarios (10+)

Design 10+ chaos scenarios to match the eval harness 1:1.

**Deferred.** The eval harness in Sprint 4 will have 10 scenarios, but not all require distinct infrastructure chaos. Some scenarios will combine signals (e.g., scenario 5 = cost anomaly during a latency incident) by combining injections 1+3. The four base scenarios are sufficient to generate the full scenario space through combination.

### Alternative: Chaos on a schedule that runs overnight

Run chaos injections overnight so the signal is present at the start of the next session.

**Rejected because:** The nightly EKS teardown (ADR-001 Principle 6) removes all chaos injections at teardown. Overnight chaos would run on a dead cluster. The CronJob schedule runs during daytime hours (10am ET), not overnight.

---

## Consequences

**Positive:**
- Four deterministic scenarios produce four distinct, reproducible signal profiles — the eval harness has stable ground truth
- All injection/revert operations are single shell commands — easy to use in demos and in the CronJob
- No new AWS services or tools required — the entire chaos stack runs on existing EKS infrastructure

**Negative:**
- Scenario 1 (oversized replicas) generates a real cost increase while active (~10× `payment-simulator` pod cost). With nightly teardown, this is bounded. Should not be left running overnight.
- Scenario 2 (DLQ buildup) requires manual DLQ drain on revert — the `--revert` flag handles the env var but not the already-queued messages. A helper `scripts/drain-dlq.sh` will be needed.
- Scenario 4 (503 burst + retry storm) can spike SQS API call count significantly. Unlikely to exceed free tier in a demo workload, but worth monitoring.

**Neutral:**
- The chaos scenarios are the agent's "test cases." Changing a scenario after the eval harness is calibrated (Sprint 4) would invalidate the ground truth. Scenarios are frozen after Sprint 2 acceptance criteria are signed off.

---

## Related ADRs

- **ADR-001** — Architecture principles (cost discipline — Scenario 1 is cost chaos; Principle 4 audit log captures agent actions during chaos)
- **ADR-007** — MCP server design patterns (tool schemas tuned for these specific scenarios)
- **ADR-009** — Eval harness methodology (the four scenarios are the ground truth source)
