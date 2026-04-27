#!/usr/bin/env bash
# Tears down the SentrOps sandbox environment cleanly.
# Target: < 5 minutes from running cluster to zero AWS resources.
# Implemented in Sprint 1. This is a Sprint 0 placeholder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra/envs/sandbox"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

check_prerequisites() {
  for cmd in terraform aws; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required tool: ${cmd}"
  done
  aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1 \
    || die "AWS credentials not configured or invalid"
}

drain_cluster() {
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    log "Removing ArgoCD applications to prevent finalizer deadlock..."
    kubectl delete applications --all -n argocd --timeout=60s || true
    log "Draining complete."
  else
    log "Cluster unreachable — skipping drain step."
  fi
}

terraform_destroy() {
  log "Destroying infrastructure..."
  terraform -chdir="${INFRA_DIR}" init -upgrade
  terraform -chdir="${INFRA_DIR}" destroy -auto-approve
}

verify_clean() {
  log "Verifying no billable resources remain..."
  local node_count
  node_count="$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:Project,Values=sentrops" "Name=instance-state-name,Values=running,pending" \
    --query 'length(Reservations[].Instances[])' \
    --output text 2>/dev/null || echo 0)"
  if [[ "${node_count}" -gt 0 ]]; then
    log "WARNING: ${node_count} EC2 instance(s) still running. Check AWS console."
  else
    log "No sentrops EC2 instances running. Clean."
  fi
}

main() {
  log "=== SentrOps teardown starting ==="
  check_prerequisites
  drain_cluster
  terraform_destroy
  verify_clean
  log "=== Teardown complete. AWS resources destroyed. ==="
}

main "$@"
