#!/usr/bin/env bash
# bootstrap-github.sh - provisions the GitHub Actions secrets/variables and
# GitHub-side OIDC trust the project's CI now runs on (see
# Sources/plans/2026-07-08-gitlab-to-github-migration.md, complete).
#
# History: this script was originally written as an ADDITIVE companion to
# bootstrap.sh while GitLab CI was still live during the phased migration.
# GitLab CI has since been fully retired (.gitlab-ci.yml removed from every
# repo) and this is now the only live bootstrap path for CI credentials.
# bootstrap.sh (cloud foundation: IAM role/user, Terraform state backend) is
# still a prerequisite -- run it first on a fresh cloud, since this script
# only adds a GitHub OIDC trust statement to the AWS IAM role bootstrap.sh
# creates, it doesn't create that role itself.
#
# What this script does:
#   1. Sets per-repo GitHub Actions secrets/variables (gh secret/variable set).
#   2. Distributes DEPLOYMENT_DISPATCH_PAT (repository_dispatch promotion
#      trigger) to the 4 service repos.
#   3. Adds an AWS IAM trust statement for GitHub's OIDC issuer
#      (token.actions.githubusercontent.com) to the IAM role bootstrap.sh
#      creates (legacy-named gitlab-oidc-${PROJECT_NAMESPACE}, see that
#      script's header) -- additive, merges rather than overwrites.
#
# What this script does NOT do (out of scope, see the migration plan):
#   - Azure app-repo/GCP OIDC re-federation: those are Terraform-managed
#     (infrastructure/terraform/{azure,gcp}/identity.tf) -- add the new
#     azurerm_federated_identity_credential.github_ci /
#     google_iam_workload_identity_pool_provider.github resources there.
#     The Azure infrastructure repo is the bootstrap exception: this script
#     must add GitHub OIDC trust to the Terraform ARM_CLIENT_ID app first, or
#     the infrastructure workflow cannot run `terraform init` against the
#     Azure remote backend.
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
BOOTSTRAP_ENV_FILE="${SCRIPT_DIR}/.env.bootstrap"
GITHUB_ENV_FILE="${SCRIPT_DIR}/.env.bootstrap.github"

# -- load prior inputs ---------------------------------------------------------
# Read-only reuse of bootstrap.sh's persisted config (cloud provider,
# environment, namespace, account IDs) so this script doesn't re-ask for
# values that are already known.
if [[ -f "${BOOTSTRAP_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${BOOTSTRAP_ENV_FILE}"
  info "Loaded shared config from ${BOOTSTRAP_ENV_FILE}"
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

# -- Azure: resolve the scoped github_ci identity's client ID -------------------
# IMPORTANT: this is NOT the same identity as ARM_CLIENT_ID (the broad
# Terraform-bootstrap SP from .env.bootstrap). GitHub Actions must authenticate
# as the dedicated, AcrPush-only azurerm_user_assigned_identity.github_ci from
# infrastructure/terraform/azure/identity.tf. Reusing ARM_CLIENT_ID here would
# silently point every app repo's Azure OIDC login at the wrong (over-broad)
# identity. Tries `terraform output` first since that identity can be
# recreated (its client_id changes) independently of this script; falls back
# to a manual prompt if the state isn't reachable from here.
resolve_azure_github_ci_client_id() {
  [[ "${CLOUD_PROVIDER}" == "azure" ]] || return 0
  [[ -z "${AZURE_GITHUB_CI_CLIENT_ID:-}" ]] || return 0

  local tf_dir="${SCRIPT_DIR}/../../infrastructure/terraform/azure"
  if [[ -d "${tf_dir}" ]] && command -v terraform >/dev/null 2>&1; then
    AZURE_GITHUB_CI_CLIENT_ID="$(terraform -chdir="${tf_dir}" output -raw github_ci_client_id 2>/dev/null || true)"
  fi

  if [[ -z "${AZURE_GITHUB_CI_CLIENT_ID:-}" ]]; then
    warn "Could not auto-resolve github_ci_client_id via 'terraform output' (${tf_dir})."
    _prompt_if_empty AZURE_GITHUB_CI_CLIENT_ID "AZURE_GITHUB_CI_CLIENT_ID (github_ci identity's client ID, from 'terraform output github_ci_client_id')"
  else
    info "Resolved AZURE_GITHUB_CI_CLIENT_ID=${AZURE_GITHUB_CI_CLIENT_ID} via terraform output"
  fi
}

persist_github_inputs() {
  umask 077
  {
    printf 'GITHUB_ORG="%s"\n' "${GITHUB_ORG}"
    printf 'DEPLOYMENT_DISPATCH_PAT="%s"\n' "${DEPLOYMENT_DISPATCH_PAT}"
    [[ -z "${AZURE_GITHUB_CI_CLIENT_ID:-}" ]] || printf 'AZURE_GITHUB_CI_CLIENT_ID="%s"\n' "${AZURE_GITHUB_CI_CLIENT_ID}"
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
APP_AND_DEPLOYMENT_REPOS=(micro-market-catalog micro-market-orders micro-market-audit micro-market-frontend micro-market-deployment)
INFRASTRUCTURE_REPOS=(micro-market-infrastructure)

# Non-sensitive config: plain strings with hardcoded fallback defaults already
# visible in plaintext in every consuming ci.yml (e.g.
# ${{ vars.CLOUD_PROVIDER || 'aws' }}). These go through gh variable set, not
# gh secret set -- masking them in logs / hiding them from the UI buys nothing.
set_base_repo_variables() {
  echo
  echo "========================================"
  info "Setting base CI variables on GitHub repos"
  echo "========================================"

  local repo
  for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}" "${INFRASTRUCTURE_REPOS[@]}"; do
    set_repo_variable "${repo}" "CLOUD_PROVIDER" "${CLOUD_PROVIDER}"
    set_repo_variable "${repo}" "ENVIRONMENT" "${ENVIRONMENT}"
    set_repo_variable "${repo}" "PROJECT_NAMESPACE" "${PROJECT_NAMESPACE}"
  done
}

set_provider_repo_variables() {
  echo
  echo "========================================"
  info "Setting ${CLOUD_PROVIDER} CI variables on GitHub repos"
  echo "========================================"

  local repo
  case "${CLOUD_PROVIDER}" in
    aws)
      AWS_TF_STATE_BUCKET="${AWS_TF_STATE_BUCKET:-${STATE_BUCKET:-terraform-state-${AWS_ACCOUNT_ID}-${AWS_REGION}}}"
      for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}"; do
        set_repo_variable "${repo}" "AWS_REGION" "${AWS_REGION}"
      done
      set_repo_variable "micro-market-infrastructure" "AWS_REGION" "${AWS_REGION}"
      set_repo_variable "micro-market-infrastructure" "AWS_TF_STATE_BUCKET" "${AWS_TF_STATE_BUCKET}"
      ;;
    azure)
      AZURE_TF_STATE_RESOURCE_GROUP="${AZURE_TF_STATE_RESOURCE_GROUP:-${AZURE_STATE_RESOURCE_GROUP:-rg-infrastructure}}"
      AZURE_TF_STATE_STORAGE_ACCOUNT="${AZURE_TF_STATE_STORAGE_ACCOUNT:-${AZURE_STATE_STORAGE_ACCOUNT:-}}"
      AZURE_TF_STATE_CONTAINER="${AZURE_TF_STATE_CONTAINER:-${AZURE_STATE_CONTAINER:-tfstate}}"
      if [[ -z "${AZURE_TF_STATE_STORAGE_ACCOUNT}" ]]; then
        local sub_part env_part
        sub_part="$(printf '%s' "${ARM_SUBSCRIPTION_ID}" | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)"
        env_part="$(printf '%s' "${ENVIRONMENT}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-5)"
        AZURE_TF_STATE_STORAGE_ACCOUNT="tfstate${sub_part}${env_part}"
      fi
      set_repo_variable "micro-market-infrastructure" "AZURE_TF_STATE_RESOURCE_GROUP" "${AZURE_TF_STATE_RESOURCE_GROUP}"
      set_repo_variable "micro-market-infrastructure" "AZURE_TF_STATE_STORAGE_ACCOUNT" "${AZURE_TF_STATE_STORAGE_ACCOUNT}"
      set_repo_variable "micro-market-infrastructure" "AZURE_TF_STATE_CONTAINER" "${AZURE_TF_STATE_CONTAINER}"
      ;;
    gcp)
      for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}"; do
        set_repo_variable "${repo}" "GCP_REGION" "${GCP_REGION}"
      done
      set_repo_variable "micro-market-infrastructure" "GCP_TF_STATE_BUCKET" "${GCP_TF_STATE_BUCKET:-terraformmicroservicesstate}"
      ;;
    *)
      die "Unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER}'"
      ;;
  esac
}

# Genuinely sensitive per-cloud-provider credentials: these stay as secrets.
set_provider_repo_secrets() {
  echo
  echo "========================================"
  info "Setting ${CLOUD_PROVIDER} CI secrets on GitHub repos"
  echo "========================================"

  local repo
  case "${CLOUD_PROVIDER}" in
    aws)
      for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}"; do
        set_repo_secret "${repo}" "AWS_ACCOUNT_ID" "${AWS_ACCOUNT_ID:-}"
        set_repo_secret "${repo}" "AWS_ROLE_ARN" "${AWS_ROLE_ARN:-}"
      done
      set_repo_secret "micro-market-infrastructure" "AWS_ROLE_ARN" "${AWS_ROLE_ARN:-}"
      ;;
    azure)
      for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}"; do
        set_repo_secret "${repo}" "AZURE_CLIENT_ID" "${AZURE_GITHUB_CI_CLIENT_ID:-}"
        set_repo_secret "${repo}" "AZURE_TENANT_ID" "${ARM_TENANT_ID:-}"
        set_repo_secret "${repo}" "AZURE_SUBSCRIPTION_ID" "${ARM_SUBSCRIPTION_ID:-}"
      done
      set_repo_secret "micro-market-infrastructure" "ARM_CLIENT_ID" "${ARM_CLIENT_ID:-}"
      set_repo_secret "micro-market-infrastructure" "ARM_TENANT_ID" "${ARM_TENANT_ID:-}"
      set_repo_secret "micro-market-infrastructure" "ARM_SUBSCRIPTION_ID" "${ARM_SUBSCRIPTION_ID:-}"
      ;;
    gcp)
      for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}"; do
        set_repo_secret "${repo}" "GCP_WORKLOAD_IDENTITY_PROVIDER" "${GCP_WORKLOAD_IDENTITY_PROVIDER:-}"
        set_repo_secret "${repo}" "GCP_SERVICE_ACCOUNT_EMAIL" "${GCP_SERVICE_ACCOUNT_EMAIL:-}"
      done
      set_repo_secret "micro-market-infrastructure" "GCP_PROJECT_ID" "${GCP_PROJECT_ID:-}"
      set_repo_secret "micro-market-infrastructure" "GCP_WORKLOAD_IDENTITY_PROVIDER" "${GCP_WORKLOAD_IDENTITY_PROVIDER:-}"
      set_repo_secret "micro-market-infrastructure" "GCP_SERVICE_ACCOUNT_EMAIL" "${GCP_SERVICE_ACCOUNT_EMAIL:-}"
      ;;
    *)
      die "Unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER}'"
      ;;
  esac
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
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-${account_id}}"
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
    die "IAM role '${role_name}' does not exist yet -- run bootstrap.sh first; this script only adds a trust statement to the role it creates."
  fi

  local current_policy
  current_policy=$(aws iam get-role --role-name "${role_name}" --query 'Role.AssumeRolePolicyDocument' --output json)

  local github_subjects repo new_policy
  github_subjects="[]"
  for repo in "${APP_AND_DEPLOYMENT_REPOS[@]}" "${INFRASTRUCTURE_REPOS[@]}" micro-market-kubernetes-infrastructure micro-market-platform-gitops micro-market-utilities; do
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

# -- Azure: infrastructure Terraform OIDC trust --------------------------------
# The app-repo Azure identity is Terraform-managed and AcrPush-only. The
# infrastructure repo is different: it runs Terraform against the Azure backend
# and provider using ARM_CLIENT_ID from bootstrap.sh, so bootstrap-github.sh must
# configure GitHub OIDC on that app registration before the workflow can init.
ensure_github_azure_infra_oidc_trust() {
  [[ "${CLOUD_PROVIDER}" == "azure" ]] || { info "CLOUD_PROVIDER=${CLOUD_PROVIDER}; skipping Azure infrastructure OIDC trust."; return; }
  require_cmd az

  : "${GITHUB_ORG:?GITHUB_ORG is required}"
  : "${ARM_CLIENT_ID:?ARM_CLIENT_ID is required for Azure infrastructure OIDC trust}"

  echo
  echo "========================================"
  info "Adding GitHub OIDC trust on Azure infrastructure app"
  echo "========================================"

  az ad app show --id "${ARM_CLIENT_ID}" >/dev/null \
    || die "Azure app registration '${ARM_CLIENT_ID}' was not found. Run bootstrap.sh first."

  local repo="micro-market-infrastructure"
  local current_credentials
  current_credentials="$(az ad app federated-credential list --id "${ARM_CLIENT_ID}" -o json)"

  local names subjects
  names=(
    "github-${repo}-main"
    "github-${repo}-${ENVIRONMENT}"
  )
  subjects=(
    "repo:${GITHUB_ORG}/${repo}:ref:refs/heads/main"
    "repo:${GITHUB_ORG}/${repo}:environment:${ENVIRONMENT}"
  )

  local i name subject existing_subject credential_file
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    subject="${subjects[$i]}"
    existing_subject="$(echo "${current_credentials}" | jq -r --arg name "${name}" '.[] | select(.name == $name) | .subject' | head -n 1)"

    if [[ "${existing_subject}" == "${subject}" ]]; then
      success "Azure federated credential '${name}' already matches ${subject}"
      continue
    fi

    if [[ -n "${existing_subject}" && "${existing_subject}" != "null" ]]; then
      warn "Replacing Azure federated credential '${name}' because its subject differs."
      az ad app federated-credential delete \
        --id "${ARM_CLIENT_ID}" \
        --federated-credential-id "${name}" >/dev/null
    fi

    credential_file="$(mktemp)"
    jq -n \
      --arg name "${name}" \
      --arg subject "${subject}" \
      '{
        name: $name,
        issuer: "https://token.actions.githubusercontent.com",
        subject: $subject,
        description: "GitHub Actions OIDC for micro-market-infrastructure Terraform",
        audiences: ["api://AzureADTokenExchange"]
      }' > "${credential_file}"

    az ad app federated-credential create \
      --id "${ARM_CLIENT_ID}" \
      --parameters @"${credential_file}" >/dev/null
    rm -f "${credential_file}"
    success "Azure federated credential '${name}' added for ${subject}"
  done
}

# -- main ------------------------------------------------------------------
info "GitHub bootstrap (additive) for cloud provider: ${CLOUD_PROVIDER}"
prompt_github_inputs
resolve_azure_github_ci_client_id
ensure_github_aws_oidc_trust
ensure_github_azure_infra_oidc_trust
set_base_repo_variables
set_provider_repo_variables
set_provider_repo_secrets
distribute_deployment_dispatch_pat
persist_github_inputs

echo
echo "========================================"
echo -e "${GREEN}GitHub bootstrap complete${NC}"
echo "========================================"
echo "  Reminder: Azure app-repo/GCP GitHub OIDC trust is added via Terraform"
echo "  (infrastructure/terraform/{azure,gcp}/identity.tf)."
