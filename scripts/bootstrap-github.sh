#!/usr/bin/env bash
# bootstrap-github.sh - provisions the GitHub-side equivalents of what
# bootstrap.sh currently sets up on GitLab, for the GitLab -> GitHub Actions
# migration (see Sources/plans/ for the migration plan).
#
# This is ADDITIVE, not a replacement: bootstrap.sh (GitLab) keeps running
# untouched throughout the phased migration, and this script only adds the
# GitHub-side equivalents alongside it. Nothing here removes or rotates any
# GitLab-side resource.
#
# What this script does:
#   1. Sets per-repo GitHub Actions secrets (gh secret set) equivalent to the
#      GitLab group/project CI/CD variables bootstrap.sh sets today.
#   2. Distributes DEPLOYMENT_DISPATCH_PAT (the repository_dispatch replacement
#      for GITLAB's DEPLOYMENT_TRIGGER_TOKEN) to the 4 service repos.
#   3. Adds an AWS IAM trust statement for GitHub's OIDC issuer
#      (token.actions.githubusercontent.com) to the SAME IAM role GitLab's
#      OIDC already trusts (gitlab-oidc-${PROJECT_NAMESPACE}) -- additive,
#      GitLab's trust statement is left untouched.
#
# What this script does NOT do (out of scope, see the migration plan):
#   - Azure/GCP OIDC re-federation: those are Terraform-managed
#     (infrastructure/terraform/{azure,gcp}/identity.tf) -- add the new
#     azurerm_federated_identity_credential.github_ci /
#     google_iam_workload_identity_pool_provider.github resources there
#     instead, applied via the still-live GitLab pipeline (Phase 5).
#   - Creating the DEPLOYMENT_DISPATCH_PAT itself: GitHub has no CLI/API path
#     to mint a fine-grained PAT non-interactively. A human must create it at
#     https://github.com/settings/personal-access-tokens/new, scoped to ONLY
#     the deployment repo with "Contents: Read and write" permission, then
#     paste it when this script prompts for it.
#   - ArgoCD's git-read credential for deployment/platform-gitops (Phase 6,
#     a kubernetes-infrastructure Terraform change, not a CI secret).
#
# Usage:
#   chmod +x bootstrap-github.sh
#   GITHUB_ORG=my-github-user ./bootstrap-github.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GITLAB_ENV_FILE="${SCRIPT_DIR}/.env.bootstrap"
GITHUB_ENV_FILE="${SCRIPT_DIR}/.env.bootstrap.github"

# -- load prior inputs ---------------------------------------------------------
# Read-only reuse of the GitLab bootstrap's persisted config (cloud provider,
# environment, namespace, account IDs) so this script doesn't re-ask for
# values that are already known and unrelated to which CI provider is used.
if [[ -f "${GITLAB_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${GITLAB_ENV_FILE}"
  info "Loaded shared config from ${GITLAB_ENV_FILE}"
fi
if [[ -f "${GITHUB_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${GITHUB_ENV_FILE}"
  info "Loaded GitHub-specific inputs from ${GITHUB_ENV_FILE}"
fi

CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAMESPACE="${PROJECT_NAMESPACE:-danielgherasim-microservices}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
GCP_REGION="${GCP_REGION:-europe-west3}"

require_cmd() {
  command -v "${1}" >/dev/null 2>&1 || die "${1} is not installed. Install it first."
}
for cmd in gh jq curl; do
  require_cmd "${cmd}"
done

gh_auth_check() {
  gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated. Run 'gh auth login' first."
}
gh_auth_check

_prompt_if_empty() {
  local var_name="${1}" prompt_text="${2}" required="${3:-true}" secret="${4:-false}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ "${secret}" == "true" ]]; then
      read -rsp "${prompt_text}: " "${var_name?}"
      echo
    else
      read -rp "${prompt_text}: " "${var_name?}"
    fi
    if [[ "${required}" == "true" && -z "${!var_name:-}" ]]; then
      die "${var_name} is required."
    fi
  fi
}

prompt_github_inputs() {
  echo
  echo "--------------------------------------------------------"
  echo "  GitHub setup"
  echo "--------------------------------------------------------"
  echo

  _prompt_if_empty GITHUB_ORG "GitHub org/username repos live under (e.g. your-username)"

  echo
  echo "  DEPLOYMENT_DISPATCH_PAT: a fine-grained PAT scoped ONLY to the"
  echo "  '${GITHUB_ORG}/micro-market-deployment' repo, 'Contents: Read and write' permission."
  echo "  Create one at: https://github.com/settings/personal-access-tokens/new"
  echo
  _prompt_if_empty DEPLOYMENT_DISPATCH_PAT "DEPLOYMENT_DISPATCH_PAT (paste the token)" true true
}

persist_github_inputs() {
  umask 077
  {
    printf 'GITHUB_ORG="%s"\n' "${GITHUB_ORG}"
    printf 'DEPLOYMENT_DISPATCH_PAT="%s"\n' "${DEPLOYMENT_DISPATCH_PAT}"
  } > "${GITHUB_ENV_FILE}"
  chmod 600 "${GITHUB_ENV_FILE}"
  success "GitHub inputs saved to ${GITHUB_ENV_FILE} (chmod 600, gitignored)"
}

# Set (or update) a single repo secret. Value is piped via stdin so it never
# appears in argv/process listing or shell history.
set_repo_secret() {
  local repo="${1}" key="${2}" value="${3}"
  if [[ -z "${value}" ]]; then
    warn "Skipping ${key} on ${repo} (empty value)"
    return
  fi
  printf '%s' "${value}" | gh secret set "${key}" --repo "${GITHUB_ORG}/${repo}" >/dev/null
  echo -e "    ${GREEN}+${NC} ${repo}: ${key}"
}

# Set (or update) a single repo variable. Mirrors set_repo_secret() above, but
# for plain config values that aren't sensitive -- gh variable set instead of
# gh secret set, so the value stays visible in the GitHub UI and un-masked in
# Actions logs.
set_repo_variable() {
  local repo="${1}" key="${2}" value="${3}"
  if [[ -z "${value}" ]]; then
    warn "Skipping ${key} on ${repo} (empty value)"
    return
  fi
  printf '%s' "${value}" | gh variable set "${key}" --repo "${GITHUB_ORG}/${repo}" >/dev/null
  echo -e "    ${GREEN}+${NC} ${repo}: ${key}"
}

# GitHub repo names use a "micro-market-" prefix (micro-market-frontend already
# had it on GitLab; the others are renamed on GitHub -- see
# Sources/plans/2026-07-08-gitlab-to-github-migration.md).
SERVICE_REPOS=(micro-market-catalog micro-market-orders micro-market-audit micro-market-frontend)
ALL_APP_REPOS=(micro-market-catalog micro-market-orders micro-market-audit micro-market-frontend micro-market-deployment)

# Non-sensitive config: plain strings with hardcoded fallback defaults already
# visible in plaintext in every consuming ci.yml (e.g.
# ${{ vars.CLOUD_PROVIDER || 'aws' }}). These go through gh variable set, not
# gh secret set -- masking them in logs / hiding them from the UI buys nothing.
set_common_repo_variables() {
  echo
  echo "========================================"
  info "Setting common CI variables on app repos"
  echo "========================================"

  local repo
  for repo in "${ALL_APP_REPOS[@]}"; do
    set_repo_variable "${repo}" "CLOUD_PROVIDER" "${CLOUD_PROVIDER}"
    set_repo_variable "${repo}" "ENVIRONMENT" "${ENVIRONMENT}"
    set_repo_variable "${repo}" "PROJECT_NAMESPACE" "${PROJECT_NAMESPACE}"
    set_repo_variable "${repo}" "AWS_REGION" "${AWS_REGION}"
    set_repo_variable "${repo}" "GCP_REGION" "${GCP_REGION}"
  done
}

# Genuinely sensitive per-cloud-provider credentials: these stay as secrets.
set_common_repo_secrets() {
  echo
  echo "========================================"
  info "Setting common CI secrets on app repos"
  echo "========================================"

  local repo
  for repo in "${ALL_APP_REPOS[@]}"; do
    case "${CLOUD_PROVIDER}" in
      aws)
        set_repo_secret "${repo}" "AWS_ACCOUNT_ID" "${AWS_ACCOUNT_ID:-}"
        set_repo_secret "${repo}" "AWS_ROLE_ARN" "${AWS_ROLE_ARN:-}"
        ;;
      azure)
        set_repo_secret "${repo}" "AZURE_CLIENT_ID" "${ARM_CLIENT_ID:-}"
        set_repo_secret "${repo}" "AZURE_TENANT_ID" "${ARM_TENANT_ID:-}"
        set_repo_secret "${repo}" "AZURE_SUBSCRIPTION_ID" "${ARM_SUBSCRIPTION_ID:-}"
        ;;
      gcp)
        set_repo_secret "${repo}" "GCP_WORKLOAD_IDENTITY_PROVIDER" "${GCP_WORKLOAD_IDENTITY_PROVIDER:-}"
        set_repo_secret "${repo}" "GCP_SERVICE_ACCOUNT_EMAIL" "${GCP_SERVICE_ACCOUNT_EMAIL:-}"
        ;;
      *)
        die "Unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER}'"
        ;;
    esac
  done
}

distribute_deployment_dispatch_pat() {
  echo
  echo "========================================"
  info "Distributing DEPLOYMENT_DISPATCH_PAT to service repos"
  echo "========================================"

  local repo
  for repo in "${SERVICE_REPOS[@]}"; do
    set_repo_secret "${repo}" "DEPLOYMENT_DISPATCH_PAT" "${DEPLOYMENT_DISPATCH_PAT}"
  done
}

# -- AWS: additive GitHub OIDC trust --------------------------------------------
# Adds a trust statement for token.actions.githubusercontent.com to the SAME
# IAM role GitLab's OIDC already trusts. GitLab's existing trust statement is
# read back and preserved untouched (this is a merge, not an overwrite).
ensure_github_aws_oidc_trust() {
  [[ "${CLOUD_PROVIDER}" == "aws" ]] || { info "CLOUD_PROVIDER=${CLOUD_PROVIDER}; skipping AWS OIDC trust (Azure/GCP are Terraform-managed, see header comment)."; return; }
  require_cmd aws
  require_cmd openssl

  echo
  echo "========================================"
  info "Adding GitHub OIDC trust on AWS (additive)"
  echo "========================================"

  local caller account_id oidc_provider_arn role_name
  caller=$(aws sts get-caller-identity 2>/dev/null) || die "AWS credentials not configured."
  account_id=$(echo "${caller}" | jq -r '.Account')
  oidc_provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"
  role_name="gitlab-oidc-${PROJECT_NAMESPACE}"

  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${oidc_provider_arn}" >/dev/null 2>&1; then
    warn "GitHub OIDC provider already exists; skipping creation."
  else
    info "Fetching TLS thumbprint for token.actions.githubusercontent.com..."
    local thumbprint
    thumbprint=$(echo | openssl s_client -servername token.actions.githubusercontent.com \
        -connect token.actions.githubusercontent.com:443 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout \
      | sed 's/.*=//;s/://g' \
      | tr '[:upper:]' '[:lower:]')
    aws iam create-open-id-connect-provider \
      --url "https://token.actions.githubusercontent.com" \
      --client-id-list "sts.amazonaws.com" \
      --thumbprint-list "${thumbprint}" > /dev/null
    success "OIDC provider created: token.actions.githubusercontent.com"
  fi

  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    die "IAM role '${role_name}' does not exist yet -- run bootstrap.sh (GitLab) first; this script only adds a trust statement to the role it creates."
  fi

  local current_policy
  current_policy=$(aws iam get-role --role-name "${role_name}" --query 'Role.AssumeRolePolicyDocument' --output json)

  local github_subjects repo new_policy
  github_subjects="[]"
  for repo in "${ALL_APP_REPOS[@]}" micro-market-infrastructure micro-market-kubernetes-infrastructure micro-market-platform-gitops micro-market-utilities; do
    github_subjects=$(echo "${github_subjects}" | jq --arg s "repo:${GITHUB_ORG}/${repo}:ref:refs/heads/main" '. + [$s]')
  done

  local github_statement
  github_statement=$(jq -n \
    --arg oidc_arn "${oidc_provider_arn}" \
    --argjson subjects "${github_subjects}" \
    '{
      Effect: "Allow",
      Principal: { Federated: $oidc_arn },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        StringLike: { "token.actions.githubusercontent.com:sub": $subjects }
      }
    }')

  # Merge: drop any prior GitHub statement on this role (idempotent re-run),
  # keep every other existing statement (GitLab's included) untouched, append
  # the fresh GitHub statement.
  new_policy=$(echo "${current_policy}" | jq --argjson gh "${github_statement}" '
    .Statement = ([.Statement[] | select(.Principal.Federated | test("token.actions.githubusercontent.com") | not)] + [$gh])
  ')

  aws iam update-assume-role-policy --role-name "${role_name}" --policy-document "${new_policy}"
  success "GitHub OIDC trust added to role '${role_name}' (GitLab's existing trust statement preserved)"

  local role_arn
  role_arn=$(aws iam get-role --role-name "${role_name}" --query 'Role.Arn' --output text)
  info "AWS_ROLE_ARN for GitHub secrets: ${role_arn}"
  AWS_ROLE_ARN="${AWS_ROLE_ARN:-${role_arn}}"
}

# -- main ------------------------------------------------------------------
info "GitHub bootstrap (additive) for cloud provider: ${CLOUD_PROVIDER}"
prompt_github_inputs
ensure_github_aws_oidc_trust
set_common_repo_variables
set_common_repo_secrets
distribute_deployment_dispatch_pat
persist_github_inputs

echo
echo "========================================"
echo -e "${GREEN}GitHub bootstrap complete${NC}"
echo "========================================"
echo "  Reminder: Azure/GCP GitHub OIDC trust is added via Terraform"
echo "  (infrastructure/terraform/{azure,gcp}/identity.tf), not this script."
echo "  Reminder: GitLab's pipelines are untouched and still live."
