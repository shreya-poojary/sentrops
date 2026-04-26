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
   - `aws-cost-mcp` — Cost Explorer tools
   - `cloudwatch-mcp` — CloudWatch metrics tools
   - `terraform-mcp` — Terraform PR operations
   
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
- **MCP servers** are first-class components and will be released as standalone open-source packages.
- Architecture diagram is maintained as Eraser.io DSL source in `docs/architecture-code-dsl.txt` — update that file when changing the architecture diagram.
- The `.gitignore` is Terraform-focused; extend it as Python and other components are added.

## Agent Safety Boundary

The Bedrock agent is architecturally blocked from any direct infrastructure writes. The invariant to preserve across all implementation work:

```
Agent → proposes (MCP/GitHub App) → PR opened → policy gates (tfsec/Checkov/OPA) → human approves → ArgoCD applies
```

No code path should allow the agent to call `terraform apply` or `kubectl apply` directly.
