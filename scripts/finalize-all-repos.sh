#!/usr/bin/env bash
# finalize-all-repos.sh - configures ALL micro-market GitHub repositories
# with professional, production-grade settings in a single run.
#
# This is a convenience wrapper around finalize-github-repo.sh that calls it
# once per repository with the correct flags for each repo's role.
#
# Prerequisites:
#   - gh CLI authenticated with admin access to all repos
#   - jq installed
#   - GITHUB_ORG set (or present in .env.bootstrap.github)
#
# Usage:
#   ./scripts/finalize-all-repos.sh [--dry-run] [--push]

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FINALIZE_SCRIPT="${SCRIPT_DIR}/finalize-github-repo.sh"

[[ -f "${FINALIZE_SCRIPT}" ]] || die "finalize-github-repo.sh not found at ${FINALIZE_SCRIPT}"
[[ -x "${FINALIZE_SCRIPT}" ]] || chmod +x "${FINALIZE_SCRIPT}"

# Pass-through flags
DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    -h|--help)
      echo "Usage: finalize-all-repos.sh [--dry-run]"
      echo "  --dry-run   Pass --dry-run to each finalize-github-repo.sh invocation"
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

GITHUB_OWNER="devdanielgherasim"

# Common flags applied to every repository
COMMON_FLAGS=(
  --no-wiki
  --no-projects
  --delete-branch-on-merge
  --enable-dependabot
  --disable-default-codeql
)

run_finalize() {
  local repo="$1"; shift
  local description="$1"; shift
  local topics="$1"; shift
  # Remaining args are repo-specific extra flags

  echo
  echo "================================================================================"
  info "Configuring: ${repo}"
  echo "================================================================================"

  local cmd=(
    "${FINALIZE_SCRIPT}"
    --org "${GITHUB_OWNER}"
    --repo "${repo}"
    --description "${description}"
    --topics "${topics}"
    "${COMMON_FLAGS[@]}"
  )

  # Append any extra flags passed by the caller
  while [[ $# -gt 0 ]]; do
    cmd+=("$1"); shift
  done

  # Append pass-through flags
  [[ -n "${DRY_RUN}" ]] && cmd+=("${DRY_RUN}")

  "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# 1. Service repos (Quarkus microservices)
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-catalog" \
  "Quarkus catalog microservice for the micro-market platform" \
  "quarkus,microservices,java,catalog,graalvm,native-image"

run_finalize \
  "micro-market-orders" \
  "Quarkus orders microservice for the micro-market platform" \
  "quarkus,microservices,java,orders,graalvm,native-image"

run_finalize \
  "micro-market-audit" \
  "Quarkus audit microservice for the micro-market platform" \
  "quarkus,microservices,java,audit,graalvm,native-image"

run_finalize \
  "micro-market-frontend" \
  "Next.js frontend for the micro-market platform" \
  "nextjs,react,typescript,frontend,docker"

# ---------------------------------------------------------------------------
# 2. Deployment repo (ArgoCD manifests) — needs environments with reviewers
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-deployment" \
  "ArgoCD deployment manifests and Kustomize overlays for the micro-market platform" \
  "argocd,kubernetes,gitops,kustomize,deployment" \
  --environments "dev,staging,production" \
  --environment-reviewers "staging:devdanielgherasim,production:devdanielgherasim"

# ---------------------------------------------------------------------------
# 3. Infrastructure repo (Terraform multi-cloud) — needs environments with reviewers
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-infrastructure" \
  "Multi-cloud Terraform infrastructure (AWS, Azure, GCP) for the micro-market platform" \
  "terraform,infrastructure-as-code,aws,azure,gcp,iac" \
  --environments "dev,staging,production" \
  --environment-reviewers "staging:devdanielgherasim,production:devdanielgherasim"

# ---------------------------------------------------------------------------
# 4. Kubernetes infrastructure repo (cluster-level Terraform + Helm)
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-kubernetes-infrastructure" \
  "Kubernetes cluster infrastructure, Helm charts, and ArgoCD bootstrap for the micro-market platform" \
  "kubernetes,helm,argocd,terraform,infrastructure-as-code"

# ---------------------------------------------------------------------------
# 5. Platform GitOps repo (ArgoCD app-of-apps)
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-platform-gitops" \
  "ArgoCD app-of-apps root and platform-level GitOps definitions for the micro-market platform" \
  "argocd,gitops,kubernetes,app-of-apps"

# ---------------------------------------------------------------------------
# 6. Utilities repo (shared CI workflows, bootstrap scripts)
# ---------------------------------------------------------------------------

run_finalize \
  "micro-market-utilities" \
  "Shared GitHub Actions reusable workflows, bootstrap scripts, and CI tooling for the micro-market platform" \
  "github-actions,ci-cd,reusable-workflows,devops"

echo
success "All micro-market repositories have been configured."
