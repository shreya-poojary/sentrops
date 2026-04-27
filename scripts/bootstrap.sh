#!/usr/bin/env bash
# Bootstraps the SentrOps sandbox environment from scratch.
# Target: < 15 minutes from zero to working EKS + ArgoCD.
# Implemented in Sprint 1. This is a Sprint 0 placeholder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra/envs/sandbox"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

check_prerequisites() {
  local missing=()
  for cmd in terraform kubectl aws argocd; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
  aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1 \
    || die "AWS credentials not configured or invalid"
}

terraform_apply() {
  log "Initializing Terraform..."
  terraform -chdir="${INFRA_DIR}" init -upgrade

  log "Planning..."
  terraform -chdir="${INFRA_DIR}" plan -out=tfplan

  log "Applying..."
  terraform -chdir="${INFRA_DIR}" apply tfplan
  rm -f "${INFRA_DIR}/tfplan"
}

configure_kubeconfig() {
  local cluster_name
  cluster_name="$(terraform -chdir="${INFRA_DIR}" output -raw cluster_name)"
  log "Configuring kubeconfig for cluster: ${cluster_name}"
  aws eks update-kubeconfig \
    --region "${REGION}" \
    --name "${cluster_name}"
}

wait_for_argocd() {
  log "Waiting for ArgoCD to be ready..."
  kubectl wait deployment/argocd-server \
    --namespace argocd \
    --for=condition=Available \
    --timeout=300s
  log "ArgoCD is ready."
}

verify_cluster() {
  log "Verifying cluster health..."
  kubectl get nodes
  kubectl get applications -n argocd
  log "Bootstrap complete."
}

main() {
  log "=== SentrOps bootstrap starting ==="
  check_prerequisites
  terraform_apply
  configure_kubeconfig
  wait_for_argocd
  verify_cluster
  log "=== Bootstrap finished. Run 'scripts/teardown.sh' when done. ==="
}

main "$@"
