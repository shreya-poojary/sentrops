# SentrOps — Project Plan

**Timeline:** April 24 → late May 2026 (portfolio freeze before June job search)
**Budget:** ~75 engineering hours at ~15 hrs/week across 5 sprints + 1 pre-flight
**Cost ceiling:** $50/month AWS + Bedrock
**Output:** Production-grade portfolio project with thesis, artifacts, and measurable outcomes

---

## Sprint 0 — Pre-flight (target: 4 hrs · weekend of April 24)

Goal: repo exists, foundations written, environment ready to build in.

### Tasks

- [x] Create GitHub repo `sentrops` (public, MIT license, Terraform .gitignore)
- [x] Clone locally, set up initial commit
- [x] Add `docs/architecture.png`, `docs/architecture.svg`, `docs/architecture-code-dsl.txt`
- [x] Write top-level `README.md` with thesis, status table, tech stack
- [x] Write `CLAUDE.md` at repo root with conventions and sprint discipline
- [x] Install Claude Code locally
- [ ] Create `docs/adr/` directory
- [ ] Write **ADR-001** — Architecture principles (7 principles, consequences, alternatives)
- [ ] Write **ADR-002** — Scope and non-goals (explicit out-of-scope list)
- [ ] First Claude Code session: read-only tour — no code generation yet
- [ ] Add `.pre-commit-config.yaml` with terraform fmt, tflint, shellcheck, yamllint
- [ ] Set up AWS Budgets for the target account: hard cap at $50/month with email alerts at $25/$40
- [ ] Enable AWS Cost Explorer on the account (free, but must be activated)
- [ ] Create `scripts/` directory with placeholder `bootstrap.sh` and `teardown.sh`
- [ ] Commit everything, push to `main`
- [ ] Post status update in Claude Project: "Sprint 0 complete. Starting Sprint 1."

### Acceptance criteria
- Repo visible publicly at github.com/[user]/sentrops
- README renders with diagram visible
- Two ADRs committed
- Claude Code installed and tested
- AWS budget alerts armed

### Resume bullet unlocked
*"Architected SentrOps, a reference system for safely delegating AWS operations to LLM agents, with explicit architectural principles and scope documented as ADRs before implementation."*

---

## Sprint 1 — Terraform landing zone (target: 15 hrs · week of April 27)

Goal: an empty AWS account becomes a working EKS cluster via Terraform in one command, with policy guardrails.

### Tasks

**Day 1–2 — Network foundation**
- [ ] `infra/modules/network/` — VPC, public + private subnets across 2 AZs, NAT instance (not gateway — cost), VPC endpoints for S3/ECR/STS/Logs/SecretsManager
- [ ] Module README with inputs, outputs, example usage
- [ ] Terraform test for the network module (validates CIDR math, endpoint attachments)
- [ ] Write **ADR-003** — VPC and network design

**Day 3–4 — EKS + Karpenter**
- [ ] `infra/modules/eks/` — EKS cluster (v1.30+), OIDC provider, IRSA trust policy, managed node group minimum (1 spot t3.medium for system pods)
- [ ] Karpenter provisioner with spot-first, on-demand fallback, cap at `m6i.large`
- [ ] Module README
- [ ] Write **ADR-004** — IRSA design + least-privilege IAM patterns

**Day 5 — ArgoCD bootstrap**
- [ ] `infra/modules/argocd-bootstrap/` — Helm-based install, app-of-apps pattern
- [ ] First ArgoCD `Application` manifest: deploys itself (GitOps loop closed)
- [ ] Write **ADR-005** — GitOps strategy (ArgoCD + Kustomize)

**Day 6 — Policy-as-code**
- [ ] `infra/policies/checkov/` — custom Checkov policies (require tags, reject unencrypted resources)
- [ ] `infra/policies/opa/` — Rego policies (block public S3, enforce VPC endpoints, tag compliance)
- [ ] `.github/workflows/terraform-plan.yml` — runs plan + tfsec + Checkov on every PR

**Day 7 — Wire it all together**
- [ ] `infra/envs/sandbox/main.tf` — root module composing network + eks + argocd
- [ ] `scripts/bootstrap.sh` — one command: `terraform apply` + wait for ArgoCD + verify
- [ ] `scripts/teardown.sh` — one command: clean `terraform destroy`
- [ ] Nightly teardown cron in GitHub Actions (runs `teardown.sh` at 10pm ET daily)
- [ ] Test full bootstrap → teardown → bootstrap cycle

### Acceptance criteria
- `scripts/bootstrap.sh` from scratch takes < 15 minutes to working EKS + ArgoCD
- `scripts/teardown.sh` cleans up in < 5 minutes
- tfsec, Checkov, OPA all run in CI and block merges on violations
- AWS Cost Explorer shows daily spend under $2/day when cluster is up
- Three ADRs committed (003, 004, 005)

### Resume bullet unlocked
*"Designed a production-grade AWS landing zone with Terraform: EKS on spot via Karpenter, IRSA, VPC endpoints, and policy-as-code guardrails (tfsec, Checkov, custom OPA). Nightly auto-teardown and AWS Budgets hard caps keep spend under $45/month."*

---

## Sprint 2 — Observability + chaos + ShipPay skeleton (target: 15 hrs · week of May 4)

Goal: the workload exists, emits signals, and chaos injection generates real incidents.

### Tasks

**Day 1–3 — ShipPay services (the skeleton, not full features)**
- [ ] `workload/api-gateway/` — FastAPI service, request routing, authentication stub
- [ ] `workload/order-service/` — FastAPI, persists to RDS, publishes to SQS
- [ ] `workload/payment-simulator/` — FastAPI consumer, calls stripe-mock
- [ ] `workload/dlq-viewer/` — FastAPI + minimal React/HTMX UI for DLQ inspection
- [ ] `workload/traffic-generator/` — k6 script + Kubernetes CronJob for scheduled chaos
- [ ] `workload/helm/shippay/` — Helm chart deploying all 5 services
- [ ] Each service has: `/healthz`, `/metrics` (Prometheus format), structured JSON logging, OTel trace emission
- [ ] ArgoCD Application manifest syncing the Helm chart
- [ ] Integration test: submit order → verify it hits RDS + SQS + Payment + stripe-mock

**Day 4 — Observability stack**
- [ ] Helm install `kube-prometheus-stack` via ArgoCD
- [ ] Helm install `opentelemetry-operator` + collector config
- [ ] Helm install `fluent-bit` → CloudWatch Logs
- [ ] Enable CloudWatch Container Insights
- [ ] Three purposeful Grafana dashboards:
  - **$/request** dashboard (FinOps — pulls from Cost Explorer + request count)
  - **Service health** (RED method — Rate, Errors, Duration)
  - **Queue depth + DLQ size** (the agent's primary signal for reliability incidents)
- [ ] Three SLOs defined in Sloth or as PrometheusRule:
  - API Gateway: 99.5% availability
  - Order Service: p95 latency < 300ms
  - Payment Simulator: error rate < 1%
- [ ] Alerting rules tied to burn-rate (fast + slow)

**Day 5–6 — Chaos scenarios (the agent's eval fodder)**
- [ ] `scripts/inject-fault.sh` with four scenarios:
  - `--scenario=1` — 3x oversized replicas on payment-simulator (cost anomaly)
  - `--scenario=2` — inject poison pill every 100th message (DLQ buildup)
  - `--scenario=3` — stripe-mock latency injection (p99 SLO burn)
  - `--scenario=4` — stripe-mock 503 burst (retry storm + circuit breaker needed)
- [ ] One scheduled chaos run per day via CronJob (rotates through scenarios)
- [ ] Write **ADR-006** — Chaos engineering approach

**Day 7 — Validate signal quality**
- [ ] Run each of the 4 scenarios manually, verify signals appear in dashboards within 2 min
- [ ] Document expected signal per scenario in `docs/runbooks/` (these become agent ground truth later)

### Acceptance criteria
- ShipPay running in EKS, accepting traffic from k6
- Three Grafana dashboards live
- Three SLOs with burn-rate alerts
- All four chaos scenarios produce distinct observable signals
- Cost Explorer shows per-service cost attribution via resource tags

### Resume bullet unlocked
*"Built unified observability stack (Prometheus, OpenTelemetry, CloudWatch Container Insights) with unit-economics dashboards ($/request) and SLO-based error budgets; validated resilience with scheduled chaos experiments producing deterministic cost and reliability anomalies."*

---

## Sprint 3 — MCP servers (target: 15 hrs · week of May 11) 🎯 HERO WEEK

Goal: three open-source MCP servers published under `sentrops-*` namespace, each exposing AWS infra to LLM agents in a remediation-aware way.

### Tasks

**Day 1 — MCP fundamentals (no code, just learning)**
- [ ] Read the MCP specification end-to-end at modelcontextprotocol.io
- [ ] Read the Python SDK README + examples
- [ ] **Read AWS Labs' upstream MCPs** (`awslabs.cloudwatch-mcp-server`, etc.) to understand what they do — and what they don't (no IRSA scoping, no audit hooks, no eval-tuned schemas)
- [ ] Sketch on paper: tool schemas, error shapes, pagination strategy for each of the three servers
- [ ] Design review: what distinguishes a remediation-aware MCP from a thin API wrapper

**Day 2–3 — `sentrops-cost-mcp` (the template for the other two)**
- [ ] `mcp-servers/sentrops-cost-mcp/` — repo structure, pyproject.toml, MIT license
- [ ] **Write the first tool by hand** (learn-don't-generate rule): `top_drivers_by_tag` — returns top cost drivers filtered by tag
- [ ] Unit tests against moto (mock AWS) + one integration test against real Cost Explorer
- [ ] Claude Code review pass: critique the hand-written tool against MCP best practices
- [ ] Apply critique by hand, then let Claude Code scaffold tools 2–4:
  - `detect_anomaly` — z-score based spike detection
  - `savings_plan_utilization` — current SP usage + recommendations
  - `untagged_spend` — cost attribution gaps
- [ ] **Implement audit hook** — every tool call writes to S3 Object Lock with structured payload
- [ ] **Implement IRSA scoping** — pod manifest binds to least-privilege role (`ce:Get*`, `ce:Describe*` only)
- [ ] Dockerfile with distroless base
- [ ] Helm chart deploying it to EKS
- [ ] README with tool schemas, example tool calls, auth requirements
- [ ] Publish to PyPI as `sentrops-cost-mcp`

**Day 4 — `sentrops-cloudwatch-mcp`**
- [ ] Tools: `logs_insights_query`, `get_metric_statistics`, `describe_alarm_state`, `get_container_insights`
- [ ] Same pattern: audit hooks, IRSA scoping, test coverage, Docker, Helm
- [ ] Publish to PyPI as `sentrops-cloudwatch-mcp`

**Day 5 — `sentrops-terraform-mcp`**
- [ ] Tools: `plan_diff`, `inspect_state`, `open_pr`, `comment_on_pr`
- [ ] GitHub App installation for `open_pr` (short-lived installation tokens)
- [ ] IRSA role for Terraform state access (scoped S3 read)
- [ ] Audit hook fires on every PR opened (PR diff + reasoning to S3)
- [ ] Publish to PyPI as `sentrops-terraform-mcp`

**Day 6 — Agent platform integration**
- [ ] `infra/modules/agent-platform/` — IAM roles, Bedrock permissions, MCP service accounts
- [ ] Network policy: MCP pods can reach AWS APIs + Bedrock endpoint, nothing else
- [ ] Secrets for GitHub App private key via AWS Secrets Manager + External Secrets Operator
- [ ] Write **ADR-007** — MCP server design patterns (tool schema conventions, error shapes, audit hook contract, IRSA boundary)

**Day 7 — Cross-MCP integration test**
- [ ] A Python script that: spins up local MCP client → connects to all three servers → calls one tool from each → validates responses + verifies audit log entries written
- [ ] This becomes the smoke test before every eval run in Sprint 4

### Acceptance criteria
- Three PyPI packages published under `sentrops-*` with real READMEs
- Three Helm charts deploying to EKS via IRSA
- Each MCP has pytest coverage ≥ 70%
- Audit hooks verified writing to S3 Object Lock
- Cross-MCP smoke test passes
- One ADR (007) committed

### Resume bullet unlocked
*"Designed and open-sourced three custom MCP servers (sentrops-cost-mcp, sentrops-cloudwatch-mcp, sentrops-terraform-mcp) exposing AWS Cost Explorer, CloudWatch Logs Insights, and Terraform plan/PR operations as LLM-invokable tools. Differentiated from upstream awslabs.\* MCPs by IRSA-scoped per-server IAM, per-call audit hooks, and remediation-tuned tool schemas. Published to PyPI with 70%+ test coverage."*

---

## Sprint 4 — Agent + eval harness (target: 15 hrs · week of May 18)

Goal: a working Bedrock agent that diagnoses incidents and proposes PRs; an eval harness that measures it.

### Tasks

**Day 1 — Agent foundations (learn-don't-generate for the loop)**
- [ ] `agent/custom/loop.py` — **write by hand** — Bedrock client, tool-use loop with explicit tool-call budget enforcement, cost tracking per run
- [ ] `agent/prompts/system_prompt.md` — the agent's identity: observe, diagnose, propose
- [ ] `agent/prompts/tool_schemas.yaml` — registry of MCP tools available per scenario
- [ ] Write **ADR-008** — Model tiering strategy (Haiku/Sonnet/Opus routing logic)
- [ ] Test: give it scenario-1 (oversized replicas) manually, verify it calls `sentrops-cost-mcp`, diagnoses, proposes a fix

**Day 2 — Managed Bedrock Agent path**
- [ ] `agent/managed/` — Terraform for Bedrock Agent resource with action groups mapping to MCPs
- [ ] Slack integration via Lambda webhook for info-only alerts
- [ ] GitHub App integration for PR proposals

**Day 3–4 — Eval harness (the most important deliverable this sprint)**
- [ ] `agent/evals/scenarios/` — 10 JSON files, each with:
  - Preconditions (which chaos scenario to inject)
  - Expected signals (what the agent should observe)
  - Ground truth action (which MCP tools, in what order, with what final output)
  - Scoring rubric (partial credit matrix)
- [ ] `agent/evals/scorer.py` — runs agent against a scenario, compares actions to ground truth, scores
- [ ] `agent/evals/runner.py` — executes all 10 scenarios, produces a report
- [ ] `agent/evals/report.md` — auto-generated, committed on every eval run
- [ ] `.github/workflows/eval-nightly.yml` — runs full eval nightly, posts results as GitHub Actions summary
- [ ] Write **ADR-009** — Eval harness methodology (ground truth, partial credit, cost tracking)

**Day 5 — End-to-end remediation test**
- [ ] Inject chaos scenario 1 manually
- [ ] Wait for agent to detect
- [ ] Verify: Slack notification fires OR Terraform PR opens (depending on scenario)
- [ ] Verify: PR passes CI policy gate
- [ ] Manually approve
- [ ] Verify: ArgoCD syncs the fix
- [ ] Verify: chaos signal clears in dashboards

**Day 6 — Safety hardening**
- [ ] Verify agent cannot write to any AWS API that mutates infrastructure (negative tests)
- [ ] Verify audit log (S3 Object Lock) captures every tool call with full input/output
- [ ] Verify per-run token + tool-call budgets are enforced (write a test that tries to exceed them)
- [ ] Write `docs/threat-model.md` — STRIDE analysis of the agent

**Day 7 — Full eval run + tuning**
- [ ] Run full 10-scenario eval
- [ ] Aim for honest 60–75% accuracy (99% is a red flag in interviews)
- [ ] Commit the report as `agent/evals/report.md`
- [ ] If accuracy is < 50%, diagnose systematically — prompt issue? Tool design? Scenario ambiguity?

### Acceptance criteria
- 10-scenario eval harness runs in CI
- Published accuracy number in README
- Full end-to-end remediation demo works (injection → detection → PR → approval → fix)
- Threat model document committed
- Two ADRs (008, 009) committed

### Resume bullet unlocked
*"Built a Bedrock-powered agent that autonomously diagnoses AWS cost anomalies and reliability incidents by chaining custom MCP tools, opening Terraform PRs with mandatory human approval gates. Achieves [X]% accuracy on a 10-scenario eval harness with published per-incident cost metrics. Zero-write-access design: every change passes tfsec + Checkov + OPA and human review before ArgoCD syncs."*

---

## Sprint 5 — Polish + portfolio integration (target: 10–15 hrs · week of May 25)

Goal: a portfolio that's ready to show in phone screens; a LinkedIn post that generates inbound; a demo that works on command.

### Tasks

**Day 1–2 — Portfolio website integration**
- [ ] Add SentrOps case study card to portfolio site (shreya-poojary.github.io)
- [ ] Link to GitHub repo + live Grafana snapshot (read-only public link) + Loom walkthrough
- [ ] Live metrics section pulling from the demo workload: last 7 days accuracy, PRs opened, $ saved

**Day 3 — Documentation polish**
- [ ] Top-level README: add screenshots, final accuracy numbers, cost actuals
- [ ] Demo walkthrough: `docs/demo-walkthrough.md` with step-by-step narration
- [ ] ADR index in `docs/adr/README.md`

**Day 4 — 5-minute Loom walkthrough**
- [ ] Script the demo (open with the thesis, show architecture, inject chaos, show agent response, show PR, show ArgoCD sync)
- [ ] Record, review, re-record if needed
- [ ] Upload to Loom, link from README and portfolio

**Day 5 — LinkedIn launch**
- [ ] Draft the post (lead with the thesis, attach diagram, link to repo)
- [ ] Schedule for Tuesday morning (best engagement window)
- [ ] Tag AWS, the MCP project, and relevant DevOps hashtags
- [ ] Have 3 follow-up comments ready for common questions

**Day 6 — Interview prep**
- [ ] Rehearse the 25-second opener until automatic
- [ ] Practice whiteboarding the architecture from memory
- [ ] Write up answers to 6 standard follow-up questions
- [ ] Mock interview with a friend or record yourself

**Day 7 — Freeze + review**
- [ ] Run through the full demo one last time from a clean AWS account
- [ ] Verify bootstrap.sh works from scratch
- [ ] Final commit with version tag `v1.0.0`
- [ ] Project declared done — no new features after this point

### Acceptance criteria
- Portfolio site updated with SentrOps case study
- Loom walkthrough published
- LinkedIn post live
- Final eval accuracy and cost numbers in README
- `v1.0.0` tagged

### Resume bullet unlocked
Full bullet package ready for job applications, with a public demo and published OSS artifacts.

---

## Overall success metrics (measure in Sprint 5)

| Metric | Target | Where measured |
|---|---|---|
| End-to-end bootstrap time | < 15 min | `time scripts/bootstrap.sh` |
| Monthly demo cost | < $45 | AWS Cost Explorer |
| Eval accuracy (10 scenarios) | 60–75% | `agent/evals/report.md` |
| Cost per incident (agent run) | < $0.50 | Bedrock billing ÷ incidents |
| MTTR vs manual runbook | ≥ 40% reduction | Manual time vs agent PR time |
| Tag compliance | 100% | OPA policy report |
| OSS packages published | 3 (sentrops-*) | PyPI links |
| ADRs committed | 8–10 | `docs/adr/` |

---

## Risk register (things that could derail)

| Risk | Mitigation |
|---|---|
| Bedrock cost runaway | Per-run token + tool-call budgets, $50/mo AWS budget hard cap |
| EKS cost creep | Nightly teardown, spot-only with on-demand fallback capped at `m6i.large` |
| Scope expansion | ADR-002 non-goals list + Claude Project enforcing it |
| Sprint skipping | Sprint order enforced in CLAUDE.md; Sprint N incomplete blocks Sprint N+1 |
| Diagram-style perfectionism | Already resolved in Sprint 0; diagram is locked |
| "Tutorial trap" on MCP servers | Learn-don't-generate rule on AI engineering work |
| Eval accuracy chasing (overfitting) | Honest accuracy target (60-75%); 99% is a red flag |
| Real-life disruption | 5-week timeline has no buffer; if a sprint slips, Sprint 5 polish shrinks first |

---

## How to use this plan

1. **Each sprint:** work through tasks roughly in order. Check boxes as you go.
2. **Each session start:** update `STATUS.md` with what sprint you're in, what you shipped last, what's blocking.
3. **Each sprint end:** verify acceptance criteria, write the sprint retro in `STATUS.md`, open the next sprint.
4. **If you're slipping:** don't add time, cut scope. Sprint 5 polish shrinks first, then Sprint 4 goes down to 1 remediation scenario working end-to-end instead of 4.
5. **If you're ahead:** don't add scope. Use buffer time to strengthen the weakest sprint's deliverables.
