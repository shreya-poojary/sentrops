# ADR-005 — GitOps Strategy (ArgoCD + Kustomize)

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** Sprint 1 — Terraform landing zone; all subsequent sprints

---

## Context

SentrOps has two distinct infrastructure layers that need a change management strategy:

1. **Cloud resources** (VPC, EKS, IAM, RDS, S3) — managed by Terraform
2. **Cluster state** (Deployments, Services, ConfigMaps, Helm chart releases, ArgoCD Applications) — needs a separate mechanism

ADR-001 Principle 3 mandates GitOps for all cluster state changes: no `kubectl apply` by hand, no `helm upgrade` by hand. This ADR defines which GitOps tool, which templating approach, and what the sync policies look like.

It also defines the handoff point between Terraform (provisions the cluster) and ArgoCD (manages what runs on the cluster).

---

## Decision

### GitOps engine: ArgoCD

ArgoCD is the sole mechanism for applying changes to the EKS cluster. It watches the Git repository and reconciles cluster state to match.

Reasons for ArgoCD over Flux (the primary alternative):
- ArgoCD has a built-in UI (useful for the portfolio demo — visible state at a glance)
- ArgoCD's `Application` CRD is more explicit than Flux's `Kustomization` + `HelmRelease` split
- ArgoCD's sync status and health status are separate concepts, which matches how this project reasons about deployments
- ArgoCD's RBAC model maps cleanly to the agent's read-only access requirement (the agent can inspect Applications; it cannot sync them)

### Templating: Kustomize for manifests, Helm for external charts

Two categories of cluster resources:

**Category A — Internal manifests** (ShipPay services, OTel collector config, MCP server deployments):
- Templated with **Kustomize**
- Base manifests in `workload/<service>/base/`
- Environment overlay in `workload/<service>/overlays/sandbox/`
- No Helm chart required — Kustomize patches are sufficient for the single-environment scope

**Category B — External charts** (ArgoCD itself, `kube-prometheus-stack`, External Secrets Operator, Fluent Bit):
- Deployed as **Helm chart** ArgoCD Applications
- `values.yaml` committed to the repo under `infra/helm-values/<chart>/sandbox.yaml`
- ArgoCD manages the Helm release; `helm` CLI is never run manually

This split avoids the anti-pattern of wrapping Helm charts in Kustomize (`helmChartInflationGenerator`), which produces hard-to-read diffs.

### App-of-apps pattern

A root ArgoCD `Application` (the "app of apps") is deployed by Terraform during bootstrap:

```
infra/argocd/apps/root-app.yaml
```

This Application watches `infra/argocd/apps/` and creates child Applications for:
- `kube-prometheus-stack`
- `external-secrets-operator`
- `fluent-bit`
- `opentelemetry-operator`
- `shippay` (the ShipPay Helm chart)
- Each `sentrops-*` MCP server

The root app itself is the only ArgoCD resource created outside of ArgoCD — it is applied by Terraform as the final step of `scripts/bootstrap.sh`.

### Sync policies

| Application | Auto-sync | Prune | Self-heal | Reason |
|---|---|---|---|---|
| `root-app` | Yes | Yes | Yes | Bootstrap artifact, must always match git |
| `kube-prometheus-stack` | Yes | No | Yes | External chart; prune disabled to avoid losing metrics data on upgrade |
| `external-secrets-operator` | Yes | Yes | Yes | Pure operator, no stateful resources |
| `fluent-bit` | Yes | Yes | Yes | Stateless DaemonSet |
| `opentelemetry-operator` | Yes | Yes | Yes | Stateless operator |
| `shippay` | Yes | No | Yes | Prune disabled — protects RDS connection pods from accidental deletion |
| `sentrops-*-mcp` | Yes | Yes | Yes | Stateless; fast rollback desired |

**Self-heal = Yes** means ArgoCD corrects manual `kubectl` changes within the sync interval (default 3 minutes). This enforces the GitOps invariant automatically.

### Health checks

ArgoCD uses built-in Kubernetes health checks (Deployment rollout complete, Pod running) for all workloads. Custom health checks are not defined in Sprint 1; revisit in Sprint 2 when SLO burn-rate metrics are available.

### The agent's relationship to ArgoCD

The Bedrock agent has **read-only access** to ArgoCD's API:
- Can call `argocd app get <name>` to inspect sync status
- Can call `argocd app history <name>` to inspect recent deploys
- Cannot call `argocd app sync` or `argocd app rollback`

This is enforced by ArgoCD RBAC policy: the agent's service account is bound to the built-in `read-only` role.

When the agent opens a Terraform PR and it is approved, ArgoCD syncs the change automatically — the agent does not trigger the sync. This preserves ADR-001 Principle 1 (propose, never apply).

### Repository layout

```
infra/
  argocd/
    apps/
      root-app.yaml          # Bootstrapped by Terraform
      kube-prometheus-stack.yaml
      external-secrets.yaml
      fluent-bit.yaml
      otel-operator.yaml
      shippay.yaml
      sentrops-cost-mcp.yaml
      sentrops-cloudwatch-mcp.yaml
      sentrops-terraform-mcp.yaml
  helm-values/
    kube-prometheus-stack/
      sandbox.yaml
    fluent-bit/
      sandbox.yaml
    ...

workload/
  api-gateway/
    base/
    overlays/sandbox/
  order-service/
    base/
    overlays/sandbox/
  ...
```

---

## Alternatives Considered

### Alternative: Flux CD instead of ArgoCD

Flux is the other major GitOps operator. It has stronger multi-tenancy support and a more Kubernetes-native API surface.

**Rejected because:** ArgoCD's UI provides visible, tangible evidence of the GitOps loop for portfolio demonstration. Flux is UI-less by default (third-party UIs exist but add complexity). For an architecture that proposes "all changes flow through GitOps," being able to show the sync state in a 5-minute Loom walkthrough is worth the marginal complexity of ArgoCD.

### Alternative: Manual `kubectl apply` with CI enforcement

Use GitHub Actions CI to run `kubectl apply` on merge to `main` rather than a running GitOps operator.

**Rejected because:** This is imperative, not declarative. If the cluster drifts from git state (a pod crashes, a resource is manually edited), CI does not detect or correct it. ArgoCD's continuous reconciliation loop catches drift within 3 minutes. The portfolio thesis explicitly values the reconciliation guarantee.

### Alternative: Helm-only (no Kustomize)

Write all internal manifests as Helm charts.

**Rejected because:** Helm adds templating overhead (Chart.yaml, values.yaml, `{{- if }}` blocks) for workloads that have a single environment. Kustomize patches are lighter and more readable for the ShipPay services. External charts (Prometheus stack, ESO) are already Helm — using Kustomize for internal work avoids a Helm-inside-Helm nesting problem.

### Alternative: Pulumi or CDK8s for cluster state

Use a higher-level abstraction (Pulumi, CDK8s) that generates Kubernetes manifests programmatically.

**Rejected because:** Adds a new language/tool to the stack without a clear benefit at this scale. The manifest count is small enough that Kustomize is readable. CDK8s and Pulumi are interesting for large teams generating hundreds of microservice manifests; they are unnecessary here.

---

## Consequences

**Positive:**
- Cluster drift is detected and corrected automatically within 3 minutes of a git push
- The ArgoCD UI gives a live view of what is deployed — useful for the Loom demo walkthrough
- The agent's read-only ArgoCD access is a natural, low-effort capability (read current sync state without giving it write access)
- The app-of-apps pattern means adding a new service is a single file addition to `infra/argocd/apps/`

**Negative:**
- ArgoCD adds ~300MB of cluster resources (the ArgoCD control plane itself). This increases the minimum cluster cost slightly.
- The bootstrap sequence has an ordering dependency: Terraform provisions EKS → Terraform applies root ArgoCD app → ArgoCD bootstraps everything else. If ArgoCD fails to start, everything else is blocked.
- Kustomize overlays can diverge from the base if the base is updated without updating the overlay. Requires discipline in the single-environment case.

**Neutral:**
- `scripts/bootstrap.sh` must wait for the ArgoCD Application pods to be running before returning. The target is < 15 minutes total including ArgoCD and the first sync wave.

---

## Related ADRs

- **ADR-001** — Architecture principles (Principle 3: GitOps over imperative operations)
- **ADR-002** — Scope and non-goals (no service mesh, single environment)
- **ADR-004** — IRSA design (ArgoCD's own service account needs IRSA for syncing Helm secrets from Secrets Manager)
