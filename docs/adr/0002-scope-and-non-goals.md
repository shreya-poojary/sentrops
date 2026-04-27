# ADR-002 — Scope and Non-Goals

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** All sprints

---

## Context

Portfolio projects fail in two predictable ways: they ship nothing because scope expands continuously, or they ship something hollow because scope was never defined. SentrOps has a hard deadline (late May 2026), a fixed engineering budget (~75 hours), and a specific thesis to demonstrate. An explicit, binding non-goals list is the mechanism that keeps both failure modes from happening.

This ADR also serves an interview function: a system with a clear, defended scope boundary is more credible than one that claims to do everything. "We chose not to do X because Y" is a stronger signal than silence about X.

The decisions here were made in the week of April 23, 2026 during architecture planning. Any request to reverse them must be justified with a new ADR.

---

## Decision

### What SentrOps Is

SentrOps is a **single-region, single-account, single-tenant reference architecture** that demonstrates how a platform team can safely delegate AWS operations to an LLM-based agent.

The bounded scope:
- **One AWS region:** `us-east-1`
- **One AWS account:** the demo sandbox account
- **One workload:** ShipPay (order → payment → Stripe mock flow)
- **One agent:** Bedrock-hosted, propose-only, no direct infra writes
- **Three custom MCP servers:** cost, CloudWatch, Terraform PR
- **One deployment target:** EKS on spot instances with nightly teardown
- **One human-in-the-loop gate:** GitHub PR approval before ArgoCD applies

---

### What SentrOps Is Not

The following are **explicitly out of scope**. Any sprint task or PR that adds one of these requires a new ADR explaining why the scope change is justified and what is cut to compensate.

#### 1. Multi-region, multi-AZ beyond defaults, or multi-cloud

SentrOps deploys to `us-east-1` only. EKS uses two AZs because the managed node group requires it — not as a HA design goal. No cross-region replication, failover, or Route 53 health-check routing. No AWS GovCloud, no Azure, no GCP.

**Why:** Multi-region adds 3–5× infrastructure complexity and cost. The thesis (safe LLM delegation) does not require geographic redundancy to be demonstrated.

#### 2. Service mesh (Istio, Linkerd, Cilium)

No service mesh is installed. mTLS between services is not implemented. Network policies are Kubernetes-native.

**Why:** A service mesh solves real problems (mTLS, traffic shaping, canary routing) that are not in scope here. Adding one to appear production-grade without a workload that needs it is resume-driven development, not engineering.

#### 3. Self-hosted or fine-tuned LLMs

All LLM inference runs on **Amazon Bedrock with standard Claude models** (Haiku 4.5 / Sonnet 4.5 / Opus 4.7). No self-hosted vLLM, no Ollama, no SageMaker endpoints with custom weights, no fine-tuning.

**Why:** Fine-tuning and self-hosting are legitimate skills, but they are separate thesis statements. Adding them here dilutes the signal. Bedrock keeps inference cost predictable and requires no GPU instances.

#### 4. Real payment integration or PCI scope

The ShipPay workload calls **stripe-mock**, a local HTTP stub. No real Stripe API keys, no real card data, no PCI DSS scope.

**Why:** Real payments require compliance posture (PCI DSS Level 1–4), legal agreements, and security controls that are outside the scope of a demo workload. The chaos scenarios only need the mock to behave plausibly, not to process real transactions.

#### 5. Enterprise SSO, SAML, or identity federation for human users

No Okta, no Azure AD, no SAML federation for the GitHub or AWS consoles. Developer access uses standard GitHub accounts and AWS IAM users/roles managed by the repo owner.

**Why:** Enterprise identity federation is an integration concern, not an architecture concern for this project. IRSA (Principle 2 in ADR-001) covers machine identity, which is the relevant scope.

#### 6. Windows workloads or hybrid architectures

All compute is Linux (Amazon Linux 2023 or distroless containers). No Windows node groups, no EC2 hybrid nodes, no AWS Outposts.

**Why:** Out of scope by definition — no Windows workload exists in ShipPay.

#### 7. Multi-tenant SaaS patterns

The system is single-tenant. There is no tenant isolation layer, no per-tenant IAM boundary, no data partitioning by tenant.

**Why:** Multi-tenancy is a product architecture concern, not a platform infrastructure concern. SentrOps demonstrates platform engineering, not SaaS product design.

#### 8. Formal compliance certification (SOC 2, HIPAA, PCI, FedRAMP)

No compliance framework is being pursued, audited, or claimed. The system uses practices consistent with these frameworks (encryption at rest, audit logging, least-privilege IAM) but does not target certification.

**Why:** Certification requires sustained organizational process, third-party auditors, and legal commitments. A portfolio project cannot credibly claim a certification. Using practices from these frameworks is valuable; claiming the certification is not.

#### 9. Custom UI or dashboard beyond the DLQ Viewer

No custom application frontend is built for this project. The only UI deliverable is a minimal DLQ Viewer (FastAPI + HTMX or minimal React) to make the queue depth visible. No custom Grafana plugin, no custom admin portal, no SentrOps.dev dashboard.

**Why:** The Grafana dashboards provided by `kube-prometheus-stack` cover the observability need. A custom UI is a significant scope addition that does not advance the thesis.

#### 10. Performance or throughput marketing claims

SentrOps makes no claims about requests-per-second, latency at scale, or throughput benchmarks. The k6 load generator exists to produce realistic signal for the agent's observability tools — not to benchmark the system.

**Why:** Performance claims require controlled benchmarking methodology and are highly sensitive to instance type, AZ placement, and traffic shape. Demo workloads are not benchmarks.

---

## Alternatives Considered

### Alternative: Softer scope definition ("we're focused on X but might add Y")

Define the non-goals as aspirational rather than binding — leave the door open to adding scope if time permits.

**Rejected because:** "If time permits" is how scope expands to fill all available time. The deadline is fixed. Soft non-goals don't prevent last-minute scope additions that delay the actual deliverable. Binding non-goals force explicit trade-off conversations.

### Alternative: Define scope by workload instead of by principle

Instead of listing excluded categories, define scope by what the ShipPay workload needs and exclude everything else automatically.

**Rejected because:** Workload-derived scope is implicit and harder to enforce. New sprint tasks can be rationalized as "supporting the workload" without a clear gate. Explicit non-goals are a more reliable constraint mechanism.

### Alternative: Include a second demo workload

Add a second microservices workload to demonstrate the agent across heterogeneous systems.

**Rejected because:** The eval harness has 10 scenarios against ShipPay. A second workload doubles the scenario design work, doubles the infrastructure complexity, and does not change the agent's fundamental behavior. The marginal portfolio value is low; the marginal cost is high.

### Alternative: Use a real Stripe integration in a test mode

Use Stripe's test-mode API (not live payments) instead of stripe-mock.

**Rejected because:** Stripe test-mode still requires API key management, rate limit handling, and network egress to Stripe's servers. stripe-mock is fully local, deterministic, and can be configured to fail in controlled ways for chaos scenarios. Test-mode adds complexity without adding demonstrable value.

---

## Consequences

**Positive:**
- Sprint 0–5 tasks are bounded; no sprint can grow by adding out-of-scope work without a new ADR
- Interview conversations about scope reflect deliberate choices, not accidental omissions
- Cost stays within the $50/month budget (multi-region or multi-account would exceed it)
- The agent's eval harness can be exhaustive within the ShipPay workload rather than shallow across many workloads

**Negative:**
- Interviewers asking about multi-region HA, service mesh, or compliance will hear "out of scope" — this requires confident delivery to land correctly
- The DLQ Viewer is the only custom UI; the project has no visual front end beyond Grafana

**Neutral:**
- Any of the non-goals above could become a future project or blog post. This ADR does not say they are bad ideas — only that they are not *this* project.

---

## Enforcement

When a PR, sprint task, or Claude Code session introduces work that maps to a non-goal above:
1. Flag it immediately, citing this ADR by number
2. Do not implement the work while the flag is unresolved
3. If the work is genuinely justified, write a new ADR making the case and identifying what is cut to compensate

This applies to both new code and to documentation that implies a capability not in scope.

---

## Related ADRs

- **ADR-001** — Architecture principles (the "what we build" principles; this ADR bounds their scope)
- **ADR-003** — VPC and network design (single-region, two-AZ, informed by non-goal 1)
- **ADR-007** — MCP server design patterns (purpose-built MCPs, not general-purpose — informed by non-goals 1, 3)
- **ADR-009** — Eval harness methodology (10 scenarios against ShipPay only — informed by this ADR)
