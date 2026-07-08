#!/usr/bin/env bash
# bootstrap.sh - one-time cloud + GitLab setup for the microservices project.
#
# Supports:
#   - CLOUD_PROVIDER=aws   (default): IAM deploy user, GitLab OIDC role, S3 state bucket, GitLab variables.
#   - CLOUD_PROVIDER=azure: Azure Terraform state backend, Azure auth variables, ACR naming, GitLab variables.
#
# Usage:
#   chmod +x bootstrap.sh
#   CLOUD_PROVIDER=aws   ENVIRONMENT=dev ./bootstrap.sh
#   CLOUD_PROVIDER=azure ENVIRONMENT=dev ./bootstrap.sh
#
# Required common inputs, prompted interactively when not present in .env.bootstrap:
#   - GitLab PAT with api scope (for setting CI/CD variables)
#   - GitLab PAT with read_repository scope (for ArgoCD to pull repos)
#   - GitLab username
#   - Let's Encrypt email
#   - Cloudflare API token + zone ID (optional; press Enter to skip)
#
# Azure behavior:
#   - Uses the active `az login` session for the initial bootstrap.
#   - If ARM_CLIENT_ID is absent, creates or reuses a named service principal.
#   - Generates ARM_CLIENT_SECRET for the non-OIDC bootstrap path.
#
# AWS inputs:
#   - AWS CLI credentials configured before running the script

set -euo pipefail

# -- colour helpers ------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -- static config (matches the project defaults) -----------------------------
AWS_IAM_USER="terraform-deploy"
AWS_REGION="${AWS_REGION:-eu-central-1}"
AZURE_LOCATION="${AZURE_LOCATION:-germanywestcentral}"
AZURE_STATE_RESOURCE_GROUP="${AZURE_STATE_RESOURCE_GROUP:-rg-infrastructure}"
AZURE_STATE_STORAGE_ACCOUNT="${AZURE_STATE_STORAGE_ACCOUNT:-}"
AZURE_STATE_CONTAINER="${AZURE_STATE_CONTAINER:-tfstate}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.bootstrap"

# -- load saved inputs before provider selection ------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  info "Loaded inputs from ${ENV_FILE}"
fi

CLOUD_PROVIDER="${CLOUD_PROVIDER:-azure}"
CLOUD_PROVIDER="$(echo "${CLOUD_PROVIDER}" | tr '[:upper:]' '[:lower:]')"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAMESPACE="${PROJECT_NAMESPACE:-danielgherasim-microservices}"
AZURE_SP_NAME="${AZURE_SP_NAME:-sp-${PROJECT_NAMESPACE}-${ENVIRONMENT}-bootstrap}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
GITLAB_GROUP="${GITLAB_GROUP:-microservices1691715}"

# GitLab project paths (used to look up numeric project IDs via API)
PROJ_INFRASTRUCTURE="${GITLAB_GROUP}/infrastructure"
PROJ_K8S_INFRA="${GITLAB_GROUP}/kubernetes-infrastructure"
PROJ_DEPLOYMENT="${GITLAB_GROUP}/deployment"
PROJ_CATALOG="${GITLAB_GROUP}/catalog"
PROJ_ORDERS="${GITLAB_GROUP}/orders"
PROJ_AUDIT="${GITLAB_GROUP}/audit"
PROJ_FRONTEND="${GITLAB_GROUP}/micro-market-frontend"

SERVICE_PROJECT_IDS=()

case "${CLOUD_PROVIDER}" in
  aws|azure) ;;
  *) die "Unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER}'. Expected 'aws' or 'azure'." ;;
esac

# -- prerequisite checks -------------------------------------------------------
require_cmd() {
  local cmd="${1}"
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is not installed. Install it first."
}

az_cli() {
  # Git Bash/MSYS rewrites arguments that look like Unix paths. Azure resource
  # scopes such as /subscriptions/<id> must reach Azure CLI unchanged.
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" az "$@"
}

az_sub_cli() {
  az_cli "$@" --subscription "${ARM_SUBSCRIPTION_ID}"
}

for cmd in curl jq python3 openssl; do
  require_cmd "${cmd}"
done

case "${CLOUD_PROVIDER}" in
  aws)
    require_cmd aws
    ;;
  azure)
    require_cmd az
    ;;
esac

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

prompt_common_inputs() {
  echo
  echo "--------------------------------------------------------"
  echo "  GitLab setup - using .env.bootstrap where available"
  echo "  Create PATs at: ${GITLAB_URL}/-/user_settings/personal_access_tokens"
  echo "--------------------------------------------------------"
  echo

  _prompt_if_empty GITLAB_API_PAT       "GitLab PAT with 'api' scope (to set CI/CD variables)" true true
  _prompt_if_empty GITLAB_REPO_PAT      "GitLab PAT with 'read_repository' scope (for ArgoCD)" true true
  _prompt_if_empty GITLAB_USERNAME      "GitLab username"
  _prompt_if_empty LETSENCRYPT_EMAIL    "Let's Encrypt email [adriangherasim1@gmail.com]" false
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-adriangherasim1@gmail.com}"
  _prompt_if_empty CLOUDFLARE_TOKEN     "Cloudflare API token (press Enter to skip)" false true
  _prompt_if_empty CLOUDFLARE_ZONE_ID   "Cloudflare zone ID   (press Enter to skip)" false
}

prompt_azure_inputs() {
  echo
  echo "--------------------------------------------------------"
  echo "  Azure setup - dev environment"
  echo "--------------------------------------------------------"
  echo

  ARM_USE_OIDC="${ARM_USE_OIDC:-false}"
  ARM_TENANT_ID="${ARM_TENANT_ID:-${CURRENT_TENANT_ID}}"
  ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-${CURRENT_SUBSCRIPTION_ID}}"

  _prompt_if_empty ARM_TENANT_ID       "Azure tenant ID [${CURRENT_TENANT_ID}]"
  _prompt_if_empty ARM_SUBSCRIPTION_ID "Azure subscription ID [${CURRENT_SUBSCRIPTION_ID}]"

  if [[ -z "${ARM_CLIENT_ID:-}" ]]; then
    info "ARM_CLIENT_ID is not set; bootstrap will create or reuse service principal '${AZURE_SP_NAME}'."
  elif [[ "${ARM_USE_OIDC}" != "true" ]]; then
    _prompt_if_empty ARM_CLIENT_SECRET "Azure client secret" true true
  fi
}

ensure_azure_service_principal() {
  local scope="/subscriptions/${ARM_SUBSCRIPTION_ID}"

  if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
    if az_cli ad sp show --id "${ARM_CLIENT_ID}" >/dev/null 2>&1; then
      success "Using existing service principal: ${ARM_CLIENT_ID}"
      ensure_azure_role_assignment "Contributor" "${scope}"
      ensure_azure_role_assignment "User Access Administrator" "${scope}"

      if [[ "${ARM_USE_OIDC}" != "true" && -z "${ARM_CLIENT_SECRET:-}" ]]; then
        die "ARM_CLIENT_SECRET is required for non-OIDC Azure bootstrap."
      fi
      return
    else
      warn "ARM_CLIENT_ID '${ARM_CLIENT_ID}' does not resolve to a service principal; creating or reusing '${AZURE_SP_NAME}' instead."
      ARM_CLIENT_ID=""
    fi
  fi

  local existing_app_id=""

  info "Looking for existing Azure service principal: ${AZURE_SP_NAME}"
  existing_app_id=$(az_cli ad sp list \
    --display-name "${AZURE_SP_NAME}" \
    --query "[0].appId" \
    --output tsv 2>/dev/null || true)

  if [[ -n "${existing_app_id}" ]]; then
    ARM_CLIENT_ID="${existing_app_id}"
    success "Reusing service principal '${AZURE_SP_NAME}' (${ARM_CLIENT_ID})"

    if [[ "${ARM_USE_OIDC}" != "true" && -z "${ARM_CLIENT_SECRET:-}" ]]; then
      info "Creating a new client secret for '${AZURE_SP_NAME}'..."
      ARM_CLIENT_SECRET=$(az_cli ad app credential reset \
        --id "${ARM_CLIENT_ID}" \
        --append \
        --display-name "bootstrap-${ENVIRONMENT}-$(date +%Y%m%d%H%M%S)" \
        --years 1 \
        --query password \
        --output tsv)
      success "Client secret created; it will be stored as a masked GitLab variable."
    fi
  else
    info "Creating Azure service principal '${AZURE_SP_NAME}' with Contributor on ${scope}..."
    local sp_output
    sp_output=$(az_cli ad sp create-for-rbac \
      --name "${AZURE_SP_NAME}" \
      --role Contributor \
      --scopes "${scope}" \
      --years 1 \
      --output json)
    ARM_CLIENT_ID=$(echo "${sp_output}" | jq -r '.appId')
    ARM_CLIENT_SECRET=$(echo "${sp_output}" | jq -r '.password')
    ARM_TENANT_ID="${ARM_TENANT_ID:-$(echo "${sp_output}" | jq -r '.tenant')}"
    success "Service principal created: ${ARM_CLIENT_ID}"
    warn "The generated secret is shown once by Azure CLI and will be stored in GitLab/.env.bootstrap."
  fi

  ensure_azure_role_assignment "Contributor" "${scope}"
  ensure_azure_role_assignment "User Access Administrator" "${scope}"

  if [[ "${ARM_USE_OIDC}" != "true" && -z "${ARM_CLIENT_SECRET:-}" ]]; then
    die "ARM_CLIENT_SECRET is required for non-OIDC Azure bootstrap."
  fi
}

ensure_azure_role_assignment() {
  local role="${1}"
  local scope="${2}"
  local assignment_count

  assignment_count=$(az_sub_cli role assignment list \
    --assignee "${ARM_CLIENT_ID}" \
    --scope "${scope}" \
    --role "${role}" \
    --query "length(@)" \
    --output tsv 2>/dev/null || echo "0")

  if [[ "${assignment_count}" == "0" ]]; then
    info "Adding ${role} role assignment on ${scope}..."
    az_sub_cli role assignment create \
      --assignee "${ARM_CLIENT_ID}" \
      --role "${role}" \
      --scope "${scope}" \
      --output none
    success "${role} role assignment added"
  else
    success "${role} role assignment already exists"
  fi
}

ensure_azure_resource_providers() {
  local providers=(
    "Microsoft.Authorization"
    "Microsoft.ContainerRegistry"
    "Microsoft.ContainerService"
    "Microsoft.KeyVault"
    "Microsoft.ManagedIdentity"
    "Microsoft.Network"
    "Microsoft.Storage"
  )

  echo
  echo "========================================"
  info "Registering Azure resource providers"
  echo "========================================"

  local provider state
  for provider in "${providers[@]}"; do
    state=$(az_sub_cli provider show \
      --namespace "${provider}" \
      --query registrationState \
      --output tsv 2>/dev/null || true)

    if [[ "${state}" == "Registered" ]]; then
      success "${provider} already registered"
    else
      info "Registering ${provider}..."
      az_sub_cli provider register --namespace "${provider}" --output none
    fi
  done

  info "Waiting for Microsoft.Storage registration..."
  for _ in {1..30}; do
    state=$(az_sub_cli provider show \
      --namespace "Microsoft.Storage" \
      --query registrationState \
      --output tsv 2>/dev/null || true)
    if [[ "${state}" == "Registered" ]]; then
      success "Microsoft.Storage registered"
      return
    fi
    sleep 10
  done

  die "Microsoft.Storage did not finish registering in time. Check Azure Portal > Subscriptions > Resource providers."
}

set_default_azure_state_storage_account() {
  if [[ -n "${AZURE_STATE_STORAGE_ACCOUNT:-}" && "${AZURE_STATE_STORAGE_ACCOUNT}" != "terraformmicrostate" ]]; then
    return
  fi

  local subscription_part environment_part
  subscription_part=$(echo "${ARM_SUBSCRIPTION_ID}" | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)
  environment_part=$(echo "${ENVIRONMENT}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-5)
  AZURE_STATE_STORAGE_ACCOUNT="tfstate${subscription_part}${environment_part}"
  info "Using generated Azure state storage account: ${AZURE_STATE_STORAGE_ACCOUNT}"
}

persist_inputs() {
  umask 077
  {
    printf 'CLOUD_PROVIDER="%s"\n' "${CLOUD_PROVIDER}"
    printf 'ENVIRONMENT="%s"\n' "${ENVIRONMENT}"
    printf 'PROJECT_NAMESPACE="%s"\n' "${PROJECT_NAMESPACE}"
    printf 'GITLAB_API_PAT="%s"\n' "${GITLAB_API_PAT}"
    printf 'GITLAB_REPO_PAT="%s"\n' "${GITLAB_REPO_PAT}"
    printf 'GITLAB_USERNAME="%s"\n' "${GITLAB_USERNAME}"
    printf 'LETSENCRYPT_EMAIL="%s"\n' "${LETSENCRYPT_EMAIL}"
    printf 'CLOUDFLARE_TOKEN="%s"\n' "${CLOUDFLARE_TOKEN:-}"
    printf 'CLOUDFLARE_ZONE_ID="%s"\n' "${CLOUDFLARE_ZONE_ID:-}"
    if [[ "${CLOUD_PROVIDER}" == "azure" ]]; then
      printf 'AZURE_LOCATION="%s"\n' "${AZURE_LOCATION}"
      printf 'AZURE_STATE_RESOURCE_GROUP="%s"\n' "${AZURE_STATE_RESOURCE_GROUP}"
      printf 'AZURE_STATE_STORAGE_ACCOUNT="%s"\n' "${AZURE_STATE_STORAGE_ACCOUNT}"
      printf 'AZURE_STATE_CONTAINER="%s"\n' "${AZURE_STATE_CONTAINER}"
      printf 'AZURE_SP_NAME="%s"\n' "${AZURE_SP_NAME}"
      printf 'ARM_USE_OIDC="%s"\n' "${ARM_USE_OIDC:-false}"
      printf 'ARM_CLIENT_ID="%s"\n' "${ARM_CLIENT_ID}"
      printf 'ARM_TENANT_ID="%s"\n' "${ARM_TENANT_ID}"
      printf 'ARM_SUBSCRIPTION_ID="%s"\n' "${ARM_SUBSCRIPTION_ID}"
      printf 'ARM_CLIENT_SECRET="%s"\n' "${ARM_CLIENT_SECRET:-}"
    fi
  } > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  success "Inputs saved to ${ENV_FILE} (chmod 600)"
}

# -- GitLab API helpers --------------------------------------------------------
urlencode() {
  local value="${1}"
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${value}"
}

gitlab_project_id() {
  local path="${1}" encoded
  encoded="$(urlencode "${path}")"
  curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    "${GITLAB_URL}/api/v4/projects/${encoded}" \
    | jq -r '.id'
}

gitlab_group_id() {
  local path="${1}" encoded
  encoded="$(urlencode "${path}")"
  curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    "${GITLAB_URL}/api/v4/groups/${encoded}" \
    | jq -r '.id'
}

# Create or update a variable. Works for both groups and projects.
# Usage: upsert_var <base_url> <key> <value> [masked=false] [protected=true] [env_scope=*]
upsert_var() {
  local base_url="${1}"
  local key="${2}"
  local value="${3}"
  local masked="${4:-false}"
  local protected="${5:-true}"
  local env_scope="${6:-*}"

  local encoded_key http_code method url
  encoded_key="$(urlencode "${key}")"
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    "${base_url}/${encoded_key}" 2>/dev/null || echo "000")

  method="POST"
  url="${base_url}"
  if [[ "${http_code}" == "200" ]]; then
    method="PUT"
    url="${base_url}/${encoded_key}"
  fi

  curl -sf -X "${method}" "${url}" \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    --form "key=${key}" \
    --form "value=${value}" \
    --form "masked=${masked}" \
    --form "protected=${protected}" \
    --form "environment_scope=${env_scope}" \
    > /dev/null

  echo -e "    ${GREEN}+${NC} ${key}"
}

create_trigger_token() {
  local project_id="${1}"
  local description="${2:-deployment-promotion}"
  curl -sf -X POST \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    --form "description=${description}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/triggers" \
    | jq -r '.token'
}

resolve_gitlab_ids() {
  echo
  echo "========================================"
  info "Resolving GitLab group and project IDs"
  echo "========================================"

  GROUP_ID=$(gitlab_group_id "${GITLAB_GROUP}") \
    || die "Could not resolve group '${GITLAB_GROUP}'. Check GITLAB_GROUP and PAT scope."
  success "Group '${GITLAB_GROUP}' -> ID ${GROUP_ID}"

  info "Resolving project IDs..."
  PROJ_INFRASTRUCTURE_ID=$(gitlab_project_id "${PROJ_INFRASTRUCTURE}")
  PROJ_DEPLOYMENT_ID=$(gitlab_project_id "${PROJ_DEPLOYMENT}")
  PROJ_CATALOG_ID=$(gitlab_project_id "${PROJ_CATALOG}")
  PROJ_ORDERS_ID=$(gitlab_project_id "${PROJ_ORDERS}")
  PROJ_AUDIT_ID=$(gitlab_project_id "${PROJ_AUDIT}")
  PROJ_FRONTEND_ID=$(gitlab_project_id "${PROJ_FRONTEND}")
  PROJ_K8S_INFRA_ID=$(gitlab_project_id "${PROJ_K8S_INFRA}")
  SERVICE_PROJECT_IDS=("${PROJ_CATALOG_ID}" "${PROJ_ORDERS_ID}" "${PROJ_AUDIT_ID}" "${PROJ_FRONTEND_ID}")
  success "All project IDs resolved"
}

set_common_gitlab_variables() {
  local group_vars_url="${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables"

  echo
  echo "========================================"
  info "Setting common GitLab group CI/CD variables"
  echo "========================================"

  upsert_var "${group_vars_url}" "CLOUD_PROVIDER"          "${CLOUD_PROVIDER}"          false false
  upsert_var "${group_vars_url}" "ENVIRONMENT"             "${ENVIRONMENT}"             false false
  upsert_var "${group_vars_url}" "PROJECT_NAMESPACE"       "${PROJECT_NAMESPACE}"       false false
  upsert_var "${group_vars_url}" "CONTAINER_REGISTRY_NAME" "${CONTAINER_REGISTRY_NAME}" false false
  upsert_var "${group_vars_url}" "GITLAB_ACCESS_TOKEN"     "${GITLAB_REPO_PAT}"         true  true
  upsert_var "${group_vars_url}" "GITLAB_USERNAME"         "${GITLAB_USERNAME}"         false false
}

set_kubernetes_project_variables() {
  local k8s_vars_url="${GITLAB_URL}/api/v4/projects/${PROJ_K8S_INFRA_ID}/variables"

  echo
  echo "========================================"
  info "Setting kubernetes-infrastructure project variables"
  echo "========================================"

  upsert_var "${k8s_vars_url}" "TF_VAR_lets_encrypt_email" "${LETSENCRYPT_EMAIL}" false false

  if [[ -n "${CLOUDFLARE_TOKEN:-}" ]]; then
    upsert_var "${k8s_vars_url}" "TF_VAR_cloudflare_api_token" "${CLOUDFLARE_TOKEN}"   true  true
    upsert_var "${k8s_vars_url}" "TF_VAR_cloudflare_zone_id"   "${CLOUDFLARE_ZONE_ID}" false false
    success "Cloudflare variables set"
  else
    warn "Cloudflare variables skipped (no token provided; DNS-01 cert issuance will not work)"
  fi
}

create_and_distribute_trigger_token() {
  echo
  echo "========================================"
  info "Creating deployment pipeline trigger token"
  echo "========================================"

  TRIGGER_TOKEN=$(create_trigger_token "${PROJ_DEPLOYMENT_ID}" "service-promotion")
  [[ -z "${TRIGGER_TOKEN}" || "${TRIGGER_TOKEN}" == "null" ]] \
    && die "Failed to create pipeline trigger token in deployment project."
  success "Pipeline trigger token created"

  info "Setting DEPLOYMENT_TRIGGER_TOKEN in all service repos and deployment..."
  for project_id in "${SERVICE_PROJECT_IDS[@]}" "${PROJ_DEPLOYMENT_ID}"; do
    upsert_var \
      "${GITLAB_URL}/api/v4/projects/${project_id}/variables" \
      "DEPLOYMENT_TRIGGER_TOKEN" "${TRIGGER_TOKEN}" true true
  done
  success "DEPLOYMENT_TRIGGER_TOKEN set"
}

# -- AWS bootstrap -------------------------------------------------------------
bootstrap_aws() {
  echo
  echo "========================================"
  info "Checking current AWS credentials"
  echo "========================================"

  CALLER=$(aws sts get-caller-identity 2>/dev/null) \
    || die "AWS credentials not configured. Run 'aws configure' first."
  CURRENT_USER=$(echo "${CALLER}" | jq -r '.Arn')
  AWS_ACCOUNT_ID=$(echo "${CALLER}" | jq -r '.Account')
  STATE_BUCKET="${AWS_TF_STATE_BUCKET:-terraform-state-${AWS_ACCOUNT_ID}-${AWS_REGION}}"
  CONTAINER_REGISTRY_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  success "Authenticated as: ${CURRENT_USER}"
  success "Account ID: ${AWS_ACCOUNT_ID}"
  success "State bucket name: ${STATE_BUCKET}"

  echo
  echo "========================================"
  info "Creating IAM user: ${AWS_IAM_USER}"
  echo "========================================"

  if aws iam get-user --user-name "${AWS_IAM_USER}" >/dev/null 2>&1; then
    warn "IAM user '${AWS_IAM_USER}' already exists; skipping creation."
  else
    aws iam create-user --user-name "${AWS_IAM_USER}" > /dev/null
    success "IAM user created: ${AWS_IAM_USER}"
  fi

  local policy_arn="arn:aws:iam::aws:policy/AdministratorAccess"
  if aws iam list-attached-user-policies --user-name "${AWS_IAM_USER}" \
      | jq -r '.AttachedPolicies[].PolicyArn' | grep -q "${policy_arn}"; then
    warn "AdministratorAccess already attached; skipping."
  else
    aws iam attach-user-policy \
      --user-name "${AWS_IAM_USER}" \
      --policy-arn "${policy_arn}"
    success "Attached AdministratorAccess to ${AWS_IAM_USER}"
  fi

  local existing_keys
  existing_keys=$(aws iam list-access-keys --user-name "${AWS_IAM_USER}" \
    | jq -r '.AccessKeyMetadata | length')
  if [[ "${existing_keys}" -gt 0 ]]; then
    warn "IAM user already has ${existing_keys} access key(s); skipping key creation."
    DEPLOY_ACCESS_KEY_ID=""
    DEPLOY_SECRET_ACCESS_KEY=""
  else
    info "Creating access key for ${AWS_IAM_USER}..."
    KEY_OUTPUT=$(aws iam create-access-key --user-name "${AWS_IAM_USER}")
    DEPLOY_ACCESS_KEY_ID=$(echo "${KEY_OUTPUT}" | jq -r '.AccessKey.AccessKeyId')
    DEPLOY_SECRET_ACCESS_KEY=$(echo "${KEY_OUTPUT}" | jq -r '.AccessKey.SecretAccessKey')
    success "Access key created: ${DEPLOY_ACCESS_KEY_ID}"
    warn "The secret key is shown once. It will be stored in GitLab as a masked variable."
  fi

  echo
  echo "========================================"
  info "Creating GitLab OIDC provider and IAM role"
  echo "========================================"

  local gitlab_oidc_url="https://gitlab.com"
  local oidc_provider_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/gitlab.com"
  local oidc_role_name="gitlab-oidc-${PROJECT_NAMESPACE}"

  if aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "${oidc_provider_arn}" >/dev/null 2>&1; then
    warn "OIDC provider for gitlab.com already exists; skipping."
  else
    info "Fetching TLS thumbprint for gitlab.com..."
    local thumbprint
    thumbprint=$(echo | openssl s_client -servername gitlab.com -connect gitlab.com:443 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout \
      | sed 's/.*=//;s/://g' \
      | tr '[:upper:]' '[:lower:]')
    aws iam create-open-id-connect-provider \
      --url "${gitlab_oidc_url}" \
      --client-id-list "https://gitlab.com" \
      --thumbprint-list "${thumbprint}" > /dev/null
    success "OIDC provider created: gitlab.com"
  fi

  local trust_policy
  trust_policy=$(cat <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${oidc_provider_arn}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "gitlab.com:sub": "project_path:${GITLAB_GROUP}/*:ref_type:branch:ref:*"
        },
        "StringEquals": {
          "gitlab.com:aud": "https://gitlab.com"
        }
      }
    }
  ]
}
TRUST
)

  if aws iam get-role --role-name "${oidc_role_name}" >/dev/null 2>&1; then
    warn "IAM role '${oidc_role_name}' already exists; skipping creation."
    OIDC_ROLE_ARN=$(aws iam get-role \
      --role-name "${oidc_role_name}" \
      --query 'Role.Arn' --output text)
  else
    OIDC_ROLE_ARN=$(aws iam create-role \
      --role-name "${oidc_role_name}" \
      --assume-role-policy-document "${trust_policy}" \
      --query 'Role.Arn' --output text)
    aws iam attach-role-policy \
      --role-name "${oidc_role_name}" \
      --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
    success "OIDC role created: ${OIDC_ROLE_ARN}"
  fi

  echo
  echo "========================================"
  info "Creating S3 state bucket: ${STATE_BUCKET}"
  echo "========================================"

  if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
    warn "Bucket '${STATE_BUCKET}' already exists; skipping creation."
  else
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" > /dev/null
    else
      aws s3api create-bucket \
        --bucket "${STATE_BUCKET}" \
        --region "${AWS_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
        > /dev/null
    fi
    success "Bucket created: ${STATE_BUCKET}"
  fi

  aws s3api put-bucket-versioning \
    --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled
  success "Versioning enabled"

  aws s3api put-public-access-block \
    --bucket "${STATE_BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  success "Public access blocked"

  aws s3api put-bucket-encryption \
    --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
      }]
    }'
  success "Server-side encryption enabled (AES256)"

  resolve_gitlab_ids
  set_common_gitlab_variables

  local group_vars_url="${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables"
  if [[ -n "${DEPLOY_ACCESS_KEY_ID}" ]]; then
    upsert_var "${group_vars_url}" "AWS_ACCESS_KEY_ID"     "${DEPLOY_ACCESS_KEY_ID}"     true  true
    upsert_var "${group_vars_url}" "AWS_SECRET_ACCESS_KEY" "${DEPLOY_SECRET_ACCESS_KEY}" true  true
  else
    warn "Skipping AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (existing key kept in GitLab)"
  fi
  upsert_var "${group_vars_url}" "AWS_ACCOUNT_ID"      "${AWS_ACCOUNT_ID}" false true
  upsert_var "${group_vars_url}" "AWS_REGION"          "${AWS_REGION}"     false false
  upsert_var "${group_vars_url}" "AWS_TF_STATE_BUCKET" "${STATE_BUCKET}"   false false
  upsert_var "${group_vars_url}" "AWS_ROLE_ARN"        "${OIDC_ROLE_ARN}"  false true

  set_kubernetes_project_variables
  create_and_distribute_trigger_token

  echo
  echo "========================================"
  echo -e "${GREEN}AWS bootstrap complete${NC}"
  echo "========================================"
  echo "  IAM user:        ${AWS_IAM_USER}"
  echo "  Access key ID:   ${DEPLOY_ACCESS_KEY_ID:-<existing key - not rotated>}"
  echo "  OIDC role ARN:   ${OIDC_ROLE_ARN}"
  echo "  S3 state bucket: ${STATE_BUCKET} (${AWS_REGION})"
  echo "  ECR registry:    ${CONTAINER_REGISTRY_NAME}"
}

# -- Azure bootstrap -----------------------------------------------------------
bootstrap_azure() {
  echo
  echo "========================================"
  info "Checking current Azure account"
  echo "========================================"

  AZ_ACCOUNT=$(az_cli account show --output json 2>/dev/null) \
    || die "Azure CLI is not authenticated. Run 'az login' or 'az login --service-principal' first."
  CURRENT_SUBSCRIPTION_ID=$(echo "${AZ_ACCOUNT}" | jq -r '.id')
  CURRENT_TENANT_ID=$(echo "${AZ_ACCOUNT}" | jq -r '.tenantId')

  prompt_azure_inputs

  if [[ "${CURRENT_SUBSCRIPTION_ID}" != "${ARM_SUBSCRIPTION_ID}" ]]; then
    info "Switching Azure subscription to ${ARM_SUBSCRIPTION_ID}"
    az_cli account set --subscription "${ARM_SUBSCRIPTION_ID}"
  fi

  if [[ "${CURRENT_TENANT_ID}" != "${ARM_TENANT_ID}" ]]; then
    warn "Azure CLI tenant '${CURRENT_TENANT_ID}' differs from ARM_TENANT_ID '${ARM_TENANT_ID}'. Terraform will use ARM_TENANT_ID."
  fi

  set_default_azure_state_storage_account
  ensure_azure_service_principal
  ensure_azure_resource_providers

  local acr_project
  acr_project="${PROJECT_NAMESPACE//-/}"
  CONTAINER_REGISTRY_NAME="acr${acr_project}${ENVIRONMENT}.azurecr.io"

  echo
  echo "========================================"
  info "Creating Azure Terraform state backend"
  echo "========================================"

  if az_sub_cli group show --name "${AZURE_STATE_RESOURCE_GROUP}" >/dev/null 2>&1; then
    warn "Resource group '${AZURE_STATE_RESOURCE_GROUP}' already exists; skipping creation."
  else
    az_sub_cli group create \
      --name "${AZURE_STATE_RESOURCE_GROUP}" \
      --location "${AZURE_LOCATION}" \
      --output none
    success "Resource group created: ${AZURE_STATE_RESOURCE_GROUP}"
  fi

  if az_sub_cli storage account show \
      --resource-group "${AZURE_STATE_RESOURCE_GROUP}" \
      --name "${AZURE_STATE_STORAGE_ACCOUNT}" >/dev/null 2>&1; then
    warn "Storage account '${AZURE_STATE_STORAGE_ACCOUNT}' already exists; skipping creation."
  else
    az_sub_cli storage account create \
      --resource-group "${AZURE_STATE_RESOURCE_GROUP}" \
      --name "${AZURE_STATE_STORAGE_ACCOUNT}" \
      --location "${AZURE_LOCATION}" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --allow-blob-public-access false \
      --output none
    success "Storage account created: ${AZURE_STATE_STORAGE_ACCOUNT}"
  fi

  az_sub_cli storage account blob-service-properties update \
    --resource-group "${AZURE_STATE_RESOURCE_GROUP}" \
    --account-name "${AZURE_STATE_STORAGE_ACCOUNT}" \
    --enable-versioning true \
    --enable-delete-retention true \
    --delete-retention-days 7 \
    --output none
  success "Blob versioning and soft delete enabled"

  local account_key
  account_key=$(az_sub_cli storage account keys list \
    --resource-group "${AZURE_STATE_RESOURCE_GROUP}" \
    --account-name "${AZURE_STATE_STORAGE_ACCOUNT}" \
    --query '[0].value' \
    --output tsv)

  if az_sub_cli storage container show \
      --name "${AZURE_STATE_CONTAINER}" \
      --account-name "${AZURE_STATE_STORAGE_ACCOUNT}" \
      --account-key "${account_key}" >/dev/null 2>&1; then
    warn "Storage container '${AZURE_STATE_CONTAINER}' already exists; skipping creation."
  else
    az_sub_cli storage container create \
      --name "${AZURE_STATE_CONTAINER}" \
      --account-name "${AZURE_STATE_STORAGE_ACCOUNT}" \
      --account-key "${account_key}" \
      --public-access off \
      --output none
    success "Storage container created: ${AZURE_STATE_CONTAINER}"
  fi

  resolve_gitlab_ids
  set_common_gitlab_variables

  local group_vars_url="${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables"
  upsert_var "${group_vars_url}" "ARM_USE_OIDC"        "${ARM_USE_OIDC:-false}"       false true
  upsert_var "${group_vars_url}" "ARM_CLIENT_ID"       "${ARM_CLIENT_ID}"             false true
  upsert_var "${group_vars_url}" "ARM_TENANT_ID"       "${ARM_TENANT_ID}"             true  true
  upsert_var "${group_vars_url}" "ARM_SUBSCRIPTION_ID" "${ARM_SUBSCRIPTION_ID}"       true  true
  if [[ "${ARM_USE_OIDC:-false}" != "true" ]]; then
    upsert_var "${group_vars_url}" "ARM_CLIENT_SECRET" "${ARM_CLIENT_SECRET}"         true  true
  else
    warn "ARM_USE_OIDC=true; ARM_CLIENT_SECRET was not written."
  fi

  upsert_var "${group_vars_url}" "AZURE_LOCATION"              "${AZURE_LOCATION}"                false false
  upsert_var "${group_vars_url}" "AZURE_TF_STATE_RESOURCE_GROUP" "${AZURE_STATE_RESOURCE_GROUP}"  false false
  upsert_var "${group_vars_url}" "AZURE_TF_STATE_STORAGE_ACCOUNT" "${AZURE_STATE_STORAGE_ACCOUNT}" false false
  upsert_var "${group_vars_url}" "AZURE_TF_STATE_CONTAINER"    "${AZURE_STATE_CONTAINER}"         false false

  local infra_vars_url="${GITLAB_URL}/api/v4/projects/${PROJ_INFRASTRUCTURE_ID}/variables"
  upsert_var "${infra_vars_url}" "TF_VAR_gitlab_project_path" "${PROJ_INFRASTRUCTURE}" false true
  upsert_var "${infra_vars_url}" "TF_VAR_gitlab_ref"          "prod"                  false true

  set_kubernetes_project_variables
  create_and_distribute_trigger_token

  echo
  echo "========================================"
  echo -e "${GREEN}Azure bootstrap complete${NC}"
  echo "========================================"
  echo "  Subscription ID: ${ARM_SUBSCRIPTION_ID}"
  echo "  Tenant ID:       ${ARM_TENANT_ID}"
  echo "  Location:        ${AZURE_LOCATION}"
  echo "  State backend:   ${AZURE_STATE_RESOURCE_GROUP}/${AZURE_STATE_STORAGE_ACCOUNT}/${AZURE_STATE_CONTAINER}"
  echo "  ACR registry:    ${CONTAINER_REGISTRY_NAME}"
}

# -- main ----------------------------------------------------------------------
info "Bootstrap provider: ${CLOUD_PROVIDER}"
info "Environment: ${ENVIRONMENT}"
info "Project namespace: ${PROJECT_NAMESPACE}"

prompt_common_inputs

case "${CLOUD_PROVIDER}" in
  aws)
    bootstrap_aws
    ;;
  azure)
    bootstrap_azure
    ;;
esac

persist_inputs

echo
echo "  GitLab group variables set: $(curl -sf \
  --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
  "${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables" | jq 'length') variables"
echo
echo "  Next steps for ${CLOUD_PROVIDER}/${ENVIRONMENT}:"
echo "  1. Push to infrastructure repo and run validate/plan."
echo "  2. Manually approve apply_infrastructure after reviewing the Terraform plan."
echo "  3. Build the utilities ci-base-${CLOUD_PROVIDER} image."
echo "  4. Run kubernetes-infrastructure apply after the cloud foundation is ready."
echo "  5. Push service repos to build and promote dev images."
echo
warn "Secrets were stored in GitLab CI/CD variables and ${ENV_FILE}; protect and rotate them after the demo."
