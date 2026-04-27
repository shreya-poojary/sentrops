# ADR-001 — Architecture Principles

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** All sprints

---

## Context

SentrOps delegates AWS infrastructure operations to an LLM-based agent. That combination — autonomous AI + production cloud — creates real failure modes: cost runaway, unintended mutations, audit gaps, credential exposure, and scope creep. Before writing any code, we need an explicit set of principles that act as load-bearing constraints on every design decision. These principles define what the system *is* before we decide what it *does*.

The principles below were derived from three sources:
1. The security properties required of any AI system with infrastructure access.
2. AWS Well-Architected lens: security, operational excellence, cost optimization.
3. The portfolio thesis: the project must demonstrate these properties *demonstrably*, not just claim them.

---

## Decision

We adopt the following seven architecture principles. Every future ADR, PR, and design decision must be consistent with these or must explicitly justify the exception.

---

### Principle 1 — Propose, Never Apply

The agent has **zero direct write access** to any AWS resource or Kubernetes cluster. The only outputs the agent can produce are:
- A Terraform PR via `sentrops-terraform-mcp`
- A Slack notification

The full remediation flow is:

```
Agent observes → diagnoses → proposes PR
→ tfsec + Checkov + OPA gates → human approves → ArgoCD applies
```

No code path may allow the agent to call `terraform apply`, `kubectl apply`, or any AWS mutating API. This invariant is enforced architecturally (IAM denies, not just policy), not just by convention.

**Why this matters:** An agent that can propose is a tool. An agent that can apply is a liability. The proposal-only model preserves human judgment for the highest-stakes step.

---

### Principle 2 — IRSA for All AWS Identity

Every pod that touches AWS APIs authenticates via **IRSA (IAM Roles for Service Accounts)**. No exceptions:
- No long-lived access keys
- No instance-profile credentials shared across pods
- No environment variables carrying AWS credentials
- Each MCP server binds to its own, narrowly-scoped IAM role

IRSA scoping follows least privilege: `sentrops-cost-mcp` gets `ce:Get*` and `ce:Describe*` only. `sentrops-cloudwatch-mcp` gets `cloudwatch:Get*`, `logs:StartQuery`, `logs:GetQueryResults`. No role has write permissions.

**Why this matters:** Shared credentials create a blast radius. If one pod is compromised, its IRSA role limits the attacker to exactly the APIs that pod needed — nothing more.

---

### Principle 3 — GitOps over Imperative Operations

All cluster state changes flow through ArgoCD. The Git repository is the single source of truth for cluster state:
- `kubectl apply` is never run by hand or by automation
- `helm upgrade` is never run by hand or by automation
- ArgoCD syncs are the only mechanism that mutates cluster state

Bootstrap (initial ArgoCD install) is the only exception and is itself captured in Terraform.

**Why this matters:** GitOps makes every change auditable, reversible, and reviewable before it reaches the cluster. It also means the agent's PRs are automatically deployable once approved — no additional runbook step.

---

### Principle 4 — Audit Every Tool Call

Every call to a `sentrops-*` MCP tool writes a structured audit record to **S3 with Object Lock** (WORM — write once, read many):
- Tool name and version
- Full input arguments
- Full response payload
- IRSA role ARN that invoked the tool
- Timestamp (UTC, ISO 8601)
- Associated incident ID or agent run ID

The S3 bucket has Object Lock in Compliance mode with a 90-day retention period. No IAM principal — including root — can delete these records before expiry.

**Why this matters:** When an AI system takes consequential actions, auditability is not optional. The audit log lets us answer "what did the agent see, what did it decide, and what did it do?" for any incident, retroactively.

---

### Principle 5 — Secrets Never in Git

No secret, credential, token, or private key is ever committed to this repository. The secret management stack is:
- **AWS Secrets Manager** — stores the secret value
- **External Secrets Operator** — syncs it into Kubernetes Secrets at runtime
- Kubernetes Secrets are never logged, printed, or included in audit payloads

The GitHub App private key for `sentrops-terraform-mcp` is stored in Secrets Manager, injected at pod start via External Secrets Operator, and rotated annually.

**Why this matters:** Git history is permanent. One accidental commit of a credential requires key rotation and creates a permanent audit finding. Structural prevention is cheaper than remediation.

---

### Principle 6 — Cost Discipline is a First-Class Constraint

Cost management is not an afterthought — it is built into the system's operating model:

| Constraint | Limit | Enforcement |
|---|---|---|
| Monthly AWS spend | $50 hard cap | AWS Budgets + SCP deny |
| Email alert thresholds | $25 and $40 | AWS Budgets |
| Per-agent-run token budget | 50K input / 10K output | Enforced in agent loop |
| Per-session Bedrock cost | $1 | Enforced in agent loop |
| EKS when idle | Zero | Nightly teardown at 10pm ET |

If monthly spend exceeds $40, work stops until the anomaly is diagnosed. EKS clusters are torn down after every session and restored from scratch in < 15 minutes.

**Why this matters:** A cost anomaly in the demo workload is one of the primary signals the agent must detect. Running a cost-blind system to demo cost awareness is self-defeating. This project must demonstrate cost hygiene as a first-class engineering discipline.

---

### Principle 7 — MCP Servers as Purpose-Built Remediation Tools

The `sentrops-*` MCP servers are not thin API wrappers. They are purpose-built for remediation workflows and differ from general-purpose query tools (including the `awslabs.*` MCP servers) in three specific ways:

1. **IRSA-scoped IAM per server** — each MCP pod binds to a unique, narrowly-scoped role rather than shared credentials
2. **Per-tool-call audit hooks** — every tool invocation is written to S3 Object Lock before the response is returned to the agent
3. **Tool schemas tuned for the 10 ground-truth eval scenarios** — inputs, outputs, error shapes, and pagination are designed around what the agent actually needs to diagnose and remediate the specific scenarios in this system

These servers are designed to be released as standalone open-source packages under the `sentrops-*` namespace. Their design must be defensible on those terms — not just "it works in the demo."

**Why this matters:** If the differentiators are real, they belong in the tool design, not just in the pitch. This principle prevents the servers from being collapsed into the upstream packages in the name of "simplicity."

---

## Alternatives Considered

### Alternative: Use the AWS Labs MCP servers directly

AWS Labs publishes `awslabs.cloudwatch-mcp-server`, `awslabs.cost-explorer-mcp-server`, and `awslabs.terraform-mcp-server`. Using them would eliminate Sprint 3 almost entirely.

**Rejected because:** The three differentiators in Principle 7 (IRSA-scoped IAM, audit hooks, eval-tuned schemas) are the core thesis of this project. Using upstream packages would produce a system that *uses* MCP servers rather than one that *demonstrates how to build remediation-aware MCP servers*. The portfolio value is in the design decisions, not the API calls.

### Alternative: Give the agent write access with rate limits

Allow the agent to apply changes but throttle or gate the rate. Recoverable changes (scaling replicas) could be allowed; destructive ones (deleting databases) blocked.

**Rejected because:** The complexity of correctly classifying "recoverable" vs. "destructive" at the IAM layer is higher than the benefit. Human review for the specific scenario count (10 eval scenarios, ~a few per day in demo) is not a bottleneck. The propose-only model is simpler, safer, and produces a stronger portfolio story.

### Alternative: Single shared IAM role for all MCP servers

One IAM role with union permissions for all three MCP servers, simpler to manage.

**Rejected because:** This violates least-privilege and eliminates one of the three stated differentiators of the `sentrops-*` MCPs. In a real production system, a compromised cost-mcp pod should not be able to invoke CloudWatch or Terraform APIs.

### Alternative: Store audit logs in CloudTrail only

Use CloudTrail for all audit needs rather than a custom S3 Object Lock log.

**Rejected because:** CloudTrail captures AWS API calls but not the agent's reasoning, tool input arguments, or response payloads. The audit requirement is "what did the agent see and decide," which CloudTrail cannot answer. Custom audit hooks fill this gap. CloudTrail remains in use as a complementary control.

### Alternative: Keep EKS running continuously

Skip nightly teardown; use Reserved Instances to reduce cost.

**Rejected because:** The $50/month budget does not accommodate a continuously running EKS cluster. Nightly teardown is the mechanism that makes the budget feasible. As a side effect, the teardown/restore cycle validates that `bootstrap.sh` is actually reliable, which is a required acceptance criterion.

---

## Consequences

**Positive:**
- The safety invariant (propose, never apply) is architecturally enforced, not policy-dependent
- Every design decision has an explicit principle to evaluate against
- The differentiated MCP server design is justified and defensible in a portfolio context
- Cost discipline reduces financial risk while demonstrating the skill being showcased

**Negative:**
- Principle 1 (propose, never apply) means the agent cannot close the feedback loop autonomously — a human must approve every PR. This is intentional, but it slows the remediation MTTR metric.
- Principle 7 (purpose-built MCPs) adds Sprint 3 scope. A system that used upstream packages would ship faster.
- Principle 6 (nightly teardown) means development sessions must account for ~15 minutes of bootstrap time at the start of every session.

**Neutral:**
- These principles are architectural constraints, not implementation prescriptions. Sprint-specific ADRs (003–009) will make the concrete implementation choices within these constraints.

---

## Related ADRs

- **ADR-002** — Scope and non-goals (what is explicitly out of scope)
- **ADR-003** — VPC and network design (informed by Principles 2 and 6)
- **ADR-004** — IRSA design and least-privilege IAM (implements Principle 2)
- **ADR-005** — GitOps strategy (implements Principle 3)
- **ADR-007** — MCP server design patterns (implements Principle 7)
- **ADR-008** — Model tiering strategy (informed by Principle 6 — cost per run)
- **ADR-009** — Eval harness methodology (uses Principle 4 audit log as ground truth)
