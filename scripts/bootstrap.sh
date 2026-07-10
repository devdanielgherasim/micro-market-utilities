#!/usr/bin/env bash
# bootstrap.sh - one-time cloud foundation setup for the microservices project.
#
# Historical note: this script originally also pushed GitLab CI/CD variables
# (group + project) and created a GitLab-OIDC-federated AWS IAM role, back
# when GitLab CI was the live pipeline. GitLab CI has since been retired in
# favor of GitHub Actions (see Sources/plans/2026-07-08-gitlab-to-github-migration.md)
# and the GitLab-variable-pushing logic was removed as dead code. The AWS IAM
# role this script creates is still named `gitlab-oidc-${PROJECT_NAMESPACE}`
# and is still the LIVE role GitHub Actions authenticates through today --
# bootstrap-github.sh merges a GitHub OIDC trust statement into this same
# role rather than creating a new one. Renaming it would be a real AWS
# change (new role, re-point trust + the AWS_ROLE_ARN secret, delete old);
# out of scope for this cleanup, so the legacy name stays.
#
# Supports:
#   - CLOUD_PROVIDER=aws   (default): IAM deploy user, OIDC role, S3 state bucket.
#   - CLOUD_PROVIDER=azure: Azure Terraform state backend, Azure auth, ACR naming.
#
# Usage:
#   chmod +x bootstrap.sh
#   CLOUD_PROVIDER=aws   ENVIRONMENT=dev ./bootstrap.sh
#   CLOUD_PROVIDER=azure ENVIRONMENT=dev ./bootstrap.sh
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
      success "Client secret created; it will be stored in ${ENV_FILE}."
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
    warn "The generated secret is shown once by Azure CLI and will be stored in .env.bootstrap."
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
    warn "The secret key is shown once. It will be stored in ${ENV_FILE}."
  fi

  echo
  echo "========================================"
  info "Creating CI OIDC provider and IAM role (legacy 'gitlab-oidc-*' name, now also trusted by GitHub Actions)"
  echo "========================================"

  local gitlab_oidc_url="https://gitlab.com"
  local gitlab_group="microservices1691715"
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
          "gitlab.com:sub": "project_path:${gitlab_group}/*:ref_type:branch:ref:*"
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
echo "  Next steps for ${CLOUD_PROVIDER}/${ENVIRONMENT}:"
echo "  1. Run bootstrap-github.sh to push the values above as GitHub Actions secrets/variables."
echo "  2. Push to the infrastructure repo and run validate/plan/apply via GitHub Actions."
echo "  3. Run kubernetes-infrastructure apply after the cloud foundation is ready."
echo "  4. Push service repos to build and promote dev images."
echo
warn "Secrets were stored in ${ENV_FILE}; protect and rotate them after the demo."
