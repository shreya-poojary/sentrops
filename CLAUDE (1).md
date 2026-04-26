# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SentrOps is a portfolio/reference architecture project that demonstrates how a platform team can safely delegate AWS operations to an LLM-based agent. The core thesis is **"propose, never apply"**: an AI agent observes infrastructure, diagnoses issues, and opens Terraform pull requests — but has **zero direct write access** to production. All changes flow through PR + policy gates + human approval + ArgoCD.

Target completion: May 2026. The repo is currently in design/early implementation phase.

## Architecture

### Five Layers

1. **Developer Plane** — GitHub monorepo, GitHub Actions CI with OIDC federation to AWS. All Terraform PRs pass tfsec + Checkov + OPA policy gates. A scoped GitHub App (not a PAT) handles PR creation from the agent.

2. **AWS Account** — Two workloads on EKS:
   - *ShipPay demo*: API Gateway Service → Order Service → RDS Postgres + SQS → Payment Simulator → Stripe Mock; DLQ Viewer; k6 load generator
   - *Observability*: Prometheus + OTel Collector → CloudWatch; Cost Explorer

3. **AI Layer** — Three custom MCP servers (intended as open-source releases):
   - `sentrops-cost-mcp` — Cost Explorer tools (purpose-built for remediation)
   - `sentrops-cloudwatch-mcp` — CloudWatch metrics tools
   - `sentrops-terraform-mcp` — Terraform PR operations

   Tiered Bedrock orchestration: Haiku 4.5 (classification) → Sonnet 4.5 (orchestration) → Opus 4.7 (escalation). Eval harness with 10 scenarios and ground truth.

4. **Remediation Flow** — Info-only incidents → Slack. Infrastructure changes: Agent authenticates via GitHub App → opens Terraform PR → policy gates → human approval → ArgoCD applies. The agent can never directly apply changes.

5. **Audit & Safety Plane** — S3 Object Lock audit log (tool calls + PR diffs), AWS Budgets cost caps, SCPs, CloudTrail, per-run token and tool-call budgets.

## Technology Stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EKS + Karpenter, IRSA, SQS, RDS Postgres, CloudWatch, Cost Explorer, Bedrock, ArgoCD) |
| IaC | Terraform with tfsec, Checkov, OPA |
| Services | Python 3.12 + FastAPI |
| AI | Amazon Bedrock, Claude Haiku 4.5 / Sonnet 4.5 / Opus 4.7, MCP |
| Observability | Prometheus, OpenTelemetry Collector, CloudWatch |
| CI/CD | GitHub Actions (OIDC federation), ArgoCD (GitOps) |
| Load testing | k6 |
| Mocks | stripe-mock |

## Key Conventions

- **IRSA** for all AWS identity from EKS — no long-lived credentials in pods.
- **GitOps**: ArgoCD for all cluster changes; never `kubectl apply` directly.
- **MCP servers** are first-class components and will be released as standalone open-source packages under the `sentrops-*` namespace.
- Architecture diagram is maintained as Eraser.io DSL source in `docs/architecture-code-dsl.txt` — update that file when changing the architecture diagram.
- The `.gitignore` is Terraform-focused; extend it as Python and other components are added.
- **Conventional commits**: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. One logical change per PR. Squash-merge.
- **Secrets**: never in git. Use AWS Secrets Manager + External Secrets Operator. No environment variables with credentials.
- **ADRs**: every architectural decision in `docs/adr/NNNN-slug.md`, written before implementation.

## Agent Safety Boundary

The Bedrock agent is architecturally blocked from any direct infrastructure writes. The invariant to preserve across all implementation work:

```
Agent → proposes (MCP/GitHub App) → PR opened → policy gates (tfsec/Checkov/OPA) → human approves → ArgoCD applies
```

No code path should allow the agent to call `terraform apply` or `kubectl apply` directly.

## MCP Server Namespace

All custom MCP servers are namespaced under `sentrops-*`:

- `sentrops-cost-mcp` — Cost Explorer + cost anomaly detection
- `sentrops-cloudwatch-mcp` — CloudWatch metrics + Logs Insights
- `sentrops-terraform-mcp` — Terraform plan diff + PR opening via GitHub App

AWS Labs publishes general-purpose AWS MCP servers (`awslabs.cloudwatch-mcp-server`, `awslabs.terraform-mcp-server`, etc.) for query and analysis use cases. SentrOps does not duplicate that work. The `sentrops-*` MCPs are purpose-built for **remediation workflows** with three differentiators:

1. IRSA-scoped least-privilege IAM per server (not shared credentials)
2. Per-tool-call audit hooks writing to S3 Object Lock
3. Tool schemas tuned for the 10 ground-truth eval scenarios

If asked to "just use the AWS Labs MCPs," remind Shreya of these three differentiators and ask whether the request actually needs SentrOps's safety semantics or could be satisfied by the upstream packages.

## Sprint Discipline

Current sprint: **Sprint 0 — Pre-flight**

Sprint order (do not reorder without justification):

- **Sprint 0** — Repo, README, ADRs, CLAUDE.md, PLAN.md, STATUS.md
- **Sprint 1** — Terraform landing zone (EKS, VPC, IRSA, ArgoCD, budgets)
- **Sprint 2** — Observability + chaos + SLOs + ShipPay workload
- **Sprint 3** — MCP servers (one at a time, starting with `sentrops-cost-mcp`)
- **Sprint 4** — Bedrock agent + eval harness
- **Sprint 5** — Polish (portfolio integration, Loom walkthrough, LinkedIn launch)

Do not work on sprint N+1 code while sprint N is incomplete. If asked to jump sprints, push back and ask for justification. MCPs without infra to query are fake. Eval harnesses without agents are fake. Ship the infrastructure first.

## Learn-Don't-Generate Rule

For **AI engineering pieces** (MCP server tool schemas, Bedrock agent loop, eval harness, prompt design):

- Shreya writes the first version by hand, not Claude Code.
- Claude Code's role is to review and critique, not generate.
- Only after Shreya understands the pattern does Claude Code help refactor or scaffold similar patterns.

If Shreya asks Claude Code to "write an MCP server from scratch," refuse politely and explain the rule. Ask her to sketch it first. The slowness is the learning.

For **DevOps pieces she knows well** (Terraform modules, Helm charts, GitHub Actions workflows, Kubernetes manifests):

- Claude Code can write first drafts.
- Shreya reviews as if it were a junior engineer's PR.
- Claude Code should proactively suggest best practices she might not know (Karpenter provisioners, IRSA trust policies, OPA Rego patterns).

## Out of Scope (per ADR-002)

If asked to add any of these, push back and ask for an ADR justifying the change:

- Multi-region, multi-AZ beyond defaults, or multi-cloud
- Service mesh (Istio, Linkerd, Cilium)
- Self-hosted or fine-tuned LLMs
- Real payment integration or PCI scope
- Enterprise SSO, SAML, or identity federation
- Windows workloads or hybrid architectures
- Multi-tenant SaaS patterns
- Formal compliance certification (SOC2, HIPAA, PCI, FedRAMP)
- Custom UI / dashboard application beyond the DLQ Viewer
- Performance/throughput marketing claims

## Cost Discipline

- AWS Budgets hard cap at $50/month, alerts at $25 and $40
- After every session: run `scripts/teardown.sh` to tear down EKS
- Cluster restored next session via `scripts/bootstrap.sh` (target < 15 min)
- Bedrock: cap per-run token budget at 50K input, 10K output
- Cap total per-session Bedrock cost at $1
- If monthly spend exceeds $40, stop work and investigate

## Testing Conventions

- Every FastAPI service: pytest + httpx, coverage target 70%+
- Every MCP server: pytest against real AWS APIs in a sandbox account (use moto or localstack if credentials unavailable)
- Terraform: `terraform test` framework, at minimum for the `network` module
- No PR merges without tests passing

## What to Flag

Proactively mention when:

- A proposed change violates the Agent Safety Boundary
- The tech stack is being expanded without an ADR
- A sprint is being skipped or revisited after marked complete
- Cost exposure is increasing (new resource types, larger instances)
- An ADR should be written before this change
- Tests are being skipped
- A "just use the AWS Labs MCPs" request would bypass the three remediation-specific differentiators

## Session Start

When Shreya starts a Claude Code session, ask briefly:

1. What sprint are you in?
2. What did you ship last session?
3. What's blocking you right now?
4. What's the specific deliverable for this session?

If she can't answer #2 across multiple sessions in a row, surface it — it usually means planning is winning over building.
