# ADR-004 — IRSA Design and Least-Privilege IAM Patterns

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** Sprint 1 — Terraform landing zone; Sprint 3 — MCP servers

---

## Context

SentrOps runs multiple pods that call AWS APIs: the three MCP servers, the External Secrets Operator, the OTel Collector (CloudWatch Metrics), and Fluent Bit (CloudWatch Logs). Each of these needs AWS credentials. The choice of credential mechanism directly determines the blast radius if any pod is compromised.

ADR-001 Principle 2 mandates IRSA for all AWS identity. This ADR defines how IRSA is structured, what the IAM roles look like, and what conventions apply across all roles in the project.

---

## Decision

### Mechanism: IRSA (IAM Roles for Service Accounts)

IRSA works by binding a Kubernetes Service Account to an AWS IAM role via an OIDC trust policy. When a pod uses the annotated Service Account, the EKS token projector injects a short-lived OIDC token into the pod filesystem. The AWS SDK exchanges this token for STS credentials scoped to the bound IAM role. Tokens are valid for one hour and rotated automatically.

No long-lived access keys exist anywhere in the system. No instance-profile credentials are shared across pods.

### OIDC provider

An OIDC provider is provisioned in IAM pointing at the EKS cluster's OIDC issuer URL:

```
https://oidc.eks.us-east-1.amazonaws.com/id/<CLUSTER_ID>
```

This is managed by the `infra/modules/eks/` Terraform module and is a prerequisite for all IRSA bindings.

### Role naming convention

All IRSA roles follow the pattern:

```
sentrops-<component>-<env>
```

Examples:
- `sentrops-cost-mcp-sandbox`
- `sentrops-cloudwatch-mcp-sandbox`
- `sentrops-terraform-mcp-sandbox`
- `sentrops-external-secrets-sandbox`
- `sentrops-otel-collector-sandbox`
- `sentrops-fluent-bit-sandbox`

### Trust policy pattern

Every IRSA role uses the following trust policy structure (parameterized):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<CLUSTER_ID>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/<CLUSTER_ID>:sub": "system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT_NAME>",
          "oidc.eks.us-east-1.amazonaws.com/id/<CLUSTER_ID>:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

The `sub` condition locks the role to a specific namespace + service account combination. A pod in a different namespace using the same service account name cannot assume this role.

### Permission sets per component

All permissions are read-only or tightly scoped. No role has `*` actions or `*` resources.

#### `sentrops-cost-mcp-sandbox`
```
ce:GetCostAndUsage
ce:GetCostForecast
ce:GetDimensionValues
ce:GetReservationUtilization
ce:GetSavingsPlanUtilization
ce:GetUsageForecast
ce:ListCostAllocationTags
```

#### `sentrops-cloudwatch-mcp-sandbox`
```
cloudwatch:GetMetricData
cloudwatch:GetMetricStatistics
cloudwatch:ListMetrics
cloudwatch:DescribeAlarms
logs:StartQuery
logs:GetQueryResults
logs:DescribeLogGroups
logs:DescribeLogStreams
logs:FilterLogEvents
xray:GetTraceSummaries
xray:GetServiceGraph
```

#### `sentrops-terraform-mcp-sandbox`
```
s3:GetObject
s3:ListBucket
```
Resource scoped to: `arn:aws:s3:::sentrops-terraform-state-*`

Plus GitHub App private key read via Secrets Manager:
```
secretsmanager:GetSecretValue
```
Resource scoped to: `arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:sentrops/github-app-key-*`

#### `sentrops-external-secrets-sandbox`
```
secretsmanager:GetSecretValue
secretsmanager:DescribeSecret
secretsmanager:ListSecrets
```
Resource scoped to: `arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:sentrops/*`

#### `sentrops-otel-collector-sandbox`
```
cloudwatch:PutMetricData
xray:PutTraceSegments
xray:PutTelemetryRecords
```
Resource: `*` (CloudWatch PutMetricData does not support resource-level restrictions)

#### `sentrops-fluent-bit-sandbox`
```
logs:CreateLogGroup
logs:CreateLogStream
logs:PutLogEvents
logs:DescribeLogStreams
```
Resource scoped to: `arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/sentrops/*`

### S3 audit log role

The audit log bucket (`sentrops-audit-<account_id>`) is written to by all three MCP servers via their own IRSA roles:

```
s3:PutObject
```
Resource: `arn:aws:s3:::sentrops-audit-<account_id>/tool-calls/*`

Object Lock prevents deletion. No role has `s3:DeleteObject` on the audit bucket.

### Kubernetes Service Account annotation

Each Service Account is annotated to trigger IRSA credential injection:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sentrops-cost-mcp
  namespace: sentrops
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/sentrops-cost-mcp-sandbox
```

### Permission boundary (optional, deferred)

A permission boundary policy capping all IRSA roles at read-only for production AWS APIs is under consideration for Sprint 3. Not provisioned in Sprint 1 — the per-role scoping is sufficient. If any role is found to have broader-than-needed permissions during a Sprint 3 audit, a permission boundary will be added at that point.

---

## Alternatives Considered

### Alternative: EC2 instance profile on EKS nodes

Assign an IAM instance profile to the EKS managed node group with union permissions for all workloads.

**Rejected because:** Any pod on any node inherits the full permission set. A compromised pod gets all AWS permissions assigned to the node. This violates least-privilege categorically and is the pattern IRSA was designed to replace.

### Alternative: Long-lived IAM access keys in Kubernetes Secrets

Create IAM users with access keys, store them in Kubernetes Secrets, mount as environment variables.

**Rejected because:** Keys do not rotate automatically. Kubernetes Secrets are base64-encoded (not encrypted at rest by default). A misconfigured RBAC policy or an etcd backup leak exposes long-lived credentials. IRSA tokens expire in one hour with no manual rotation required.

### Alternative: AWS Vault or HashiCorp Vault for credential injection

Use Vault with the AWS Secrets Engine to issue short-lived STS credentials.

**Rejected because:** Vault is an additional infrastructure component to operate, secure, and pay for. IRSA achieves the same short-lived credential property using only EKS + IAM + STS — all managed services. ADR-002 (scope) prohibits adding infrastructure components without justification.

### Alternative: One shared IRSA role for all MCP servers

Single role with union permissions for cost, cloudwatch, and terraform operations.

**Rejected because:** This directly violates ADR-001 Principle 7 — per-server IRSA scoping is one of the three stated differentiators of the `sentrops-*` MCP servers. A compromised cost-mcp pod would gain CloudWatch and Secrets Manager access it has no business reason to have.

### Alternative: ABAC (Attribute-Based Access Control) with IAM tags

Use IAM tags and condition keys to implement one role with dynamic permission scoping.

**Rejected because:** ABAC adds significant complexity to the trust policy and permission policy design without meaningful benefit at this scale (6 roles total). RBAC with per-component roles is simpler, more auditable, and sufficient for the workload.

---

## Consequences

**Positive:**
- Blast radius of a compromised pod is limited to exactly the AWS APIs that pod legitimately needs
- No credential rotation burden — IRSA tokens expire in one hour automatically
- IAM role per component makes it trivial to audit "what can this service do?" — one role, one policy
- The per-server IRSA scoping is a defensible, demonstrable differentiator for the MCP servers

**Negative:**
- Six IRSA roles to provision and maintain in Terraform (vs. one shared role). Manageable at this scale; would need automation at larger scale.
- OIDC provider is a prerequisite — EKS must be up before any IRSA role can be tested
- Trust policy conditions must be updated if a service account is renamed or moved to a different namespace

**Neutral:**
- The `infra/modules/eks/` module provisions the OIDC provider. Each MCP server's `infra/modules/` submodule provisions its own IRSA role and policy. This keeps IAM close to the workload that needs it.

---

## Related ADRs

- **ADR-001** — Architecture principles (Principle 2: IRSA for all AWS identity)
- **ADR-003** — VPC design (VPC endpoint for STS required for IRSA token exchange)
- **ADR-007** — MCP server design patterns (IRSA as first differentiator)
