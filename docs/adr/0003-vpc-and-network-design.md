# ADR-003 — VPC and Network Design

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** Sprint 1 — Terraform landing zone

---

## Context

SentrOps needs a VPC that supports:
- An EKS cluster (requires at least two AZs)
- Pods that call AWS APIs (Cost Explorer, CloudWatch, Secrets Manager, ECR) without traversing the public internet
- A $50/month hard budget cap (network egress and NAT costs are the primary variable)
- No external ingress to the workload from the public internet during development (access via `kubectl port-forward` or a bastion)

The network design must be simple enough to bootstrap from scratch in < 15 minutes and tear down cleanly with `terraform destroy`.

---

## Decision

### Region and AZ selection

- **Region:** `us-east-1` — mandated by ADR-002 (single-region scope)
- **AZs:** Two — `us-east-1a` and `us-east-1c` — the minimum required for an EKS managed node group

### Subnet layout

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| `public-1a` | `10.0.1.0/24` | `us-east-1a` | NAT instance, future ALB if needed |
| `public-1c` | `10.0.2.0/24` | `us-east-1c` | Spare public capacity |
| `private-1a` | `10.0.10.0/23` | `us-east-1a` | EKS nodes, pods, RDS |
| `private-1c` | `10.0.12.0/23` | `us-east-1c` | EKS nodes, pods, RDS |

VPC CIDR: `10.0.0.0/16`. Private subnets are `/23` (512 addresses) to give pod IP space headroom under the default VPC CNI secondary CIDR mode.

### NAT: instance, not gateway

Private subnets route `0.0.0.0/0` through a **single NAT instance** (`t3.nano`, Amazon Linux 2023, with IP forwarding enabled) in `public-1a`. There is no NAT Gateway.

The NAT instance runs a systemd unit that enables IP masquerading (`iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`). It is managed by Terraform; if it fails, pods lose outbound internet access but AWS API traffic continues via VPC endpoints (see below).

### VPC endpoints

The following **Interface VPC Endpoints** are provisioned in the private subnets, eliminating internet-routed traffic for all critical API calls:

| Endpoint | Why |
|---|---|
| `com.amazonaws.us-east-1.ecr.api` | Image pulls from ECR without NAT |
| `com.amazonaws.us-east-1.ecr.dkr` | Docker protocol pulls from ECR |
| `com.amazonaws.us-east-1.s3` | Audit log writes, Terraform state (Gateway endpoint — free) |
| `com.amazonaws.us-east-1.sts` | IRSA token exchange |
| `com.amazonaws.us-east-1.logs` | CloudWatch Logs from Fluent Bit |
| `com.amazonaws.us-east-1.secretsmanager` | External Secrets Operator |

The S3 endpoint is a **Gateway endpoint** (free). All others are Interface endpoints (~$7.20/month each at $0.01/AZ-hour × 2 AZs × 720 hours — provisioned in one AZ only to keep costs down).

### DNS

- `enableDnsSupport = true`, `enableDnsHostnames = true` — required for VPC endpoint resolution
- No custom Route 53 private hosted zone in Sprint 1; service discovery uses CoreDNS within the cluster

### Security groups

Three security groups established at the VPC layer:

| SG | Inbound | Outbound | Attached to |
|---|---|---|---|
| `sg-nat` | TCP 80/443 from `10.0.0.0/16` | 0.0.0.0/0 | NAT instance |
| `sg-eks-nodes` | All from cluster SG | All | EKS managed node group |
| `sg-rds` | TCP 5432 from `sg-eks-nodes` | None | RDS Postgres |

The EKS cluster security group is managed by the EKS service; the above are supplemental.

---

## Alternatives Considered

### Alternative: NAT Gateway instead of NAT instance

AWS-managed NAT Gateway: fully HA, no instance to manage, supports up to 45 Gbps.

**Rejected because:** Cost. A single NAT Gateway costs $0.045/hour = ~$32/month baseline, plus $0.045/GB of data processed. At the $50/month budget ceiling, a NAT Gateway alone would consume 64% of the budget before any other resource. A `t3.nano` NAT instance costs ~$3.80/month. The difference (~$28/month) is the margin that makes Sprint 1–4 affordable. The NAT instance is adequate for a demo workload with no SLA requirement.

### Alternative: Three AZs

Use all three `us-east-1` AZs for better fault tolerance.

**Rejected because:** EKS requires two; a third AZ adds a third NAT instance, a third private subnet, and ~50% more Interface VPC endpoint cost. The demo workload has no HA requirement (nightly teardown anyway).

### Alternative: No NAT, VPC endpoints only

Eliminate the NAT instance entirely and rely solely on VPC endpoints for all outbound.

**Rejected because:** Not all AWS APIs used in this project have VPC endpoints (Cost Explorer does not). The agent layer needs outbound internet access to reach Bedrock endpoints. Endpoint-only would break these paths silently and be harder to debug than a visible NAT instance.

### Alternative: Larger VPC CIDR (`/8`)

Use `10.0.0.0/8` for maximum IP space.

**Rejected because:** Single-account, single-region, single-cluster scope does not require it. A `/16` gives 65,534 addresses — more than sufficient. A larger CIDR has no cost benefit and makes subnet math harder to reason about.

### Alternative: AWS PrivateLink for Bedrock

Add a VPC endpoint for `com.amazonaws.us-east-1.bedrock-runtime`.

**Deferred to Sprint 4.** Bedrock VPC endpoints are supported but add ~$14/month. Worth evaluating when the agent is built and egress traffic patterns are known. Not provisioned in Sprint 1.

---

## Consequences

**Positive:**
- VPC endpoint traffic never traverses NAT; Cost Explorer, CloudWatch, and Secrets Manager calls stay in the AWS network
- NAT instance cost is ~$3.80/month vs. ~$32/month for NAT Gateway — material savings at this budget
- Two-AZ layout satisfies EKS requirements with the minimum additional cost

**Negative:**
- NAT instance is a single point of failure for outbound internet. Pods that need it (e.g., pulling images not in ECR) will lose connectivity if the instance is stopped or fails. Mitigation: critical images are pushed to ECR; NAT is for package installs and Bedrock.
- Interface endpoints in a single AZ mean cross-AZ calls to the endpoint add ~1ms latency and cross-AZ data transfer charges (~$0.01/GB). Acceptable for demo traffic volumes.

**Neutral:**
- The `infra/modules/network/` Terraform module encapsulates all of the above. Sprint 1 acceptance criterion includes `terraform test` coverage for CIDR math and endpoint attachment.

---

## Related ADRs

- **ADR-001** — Architecture principles (cost discipline, Principle 6; IRSA, Principle 2)
- **ADR-002** — Scope and non-goals (single-region mandate)
- **ADR-004** — IRSA design (depends on VPC endpoints for STS)
