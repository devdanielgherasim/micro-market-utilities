#!/usr/bin/env bash
# bootstrap.sh — one-time AWS + GitLab setup for the microservices project.
#
# What it does:
#   1. Creates an IAM user (terraform-deploy) with AdministratorAccess
#   2. Generates an AWS access key for that user
#   3. Creates the S3 bucket used for all Terraform remote state
#   4. Sets all required CI/CD variables at the GitLab group level
#   5. Sets project-specific variables (secrets, trigger token) per repo
#
# Prerequisites:
#   - AWS CLI configured with admin credentials (aws configure)
#   - curl + jq installed
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Required inputs (prompted interactively):
#   - GitLab PAT with api scope (for setting CI/CD variables)
#   - GitLab PAT with read_repository scope (for ArgoCD to pull repos)
#   - GitLab username
#   - Let's Encrypt email
#   - Cloudflare API token + zone ID (optional — press Enter to skip)

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── static config (matches the project defaults) ──────────────────────────────
IAM_USER="terraform-deploy"
AWS_REGION="${AWS_REGION:-eu-central-1}"
# Bucket name derived after AWS_ACCOUNT_ID is known (see below)
PROJECT_NAMESPACE="danielgherasim-microservices"
GITLAB_URL="https://gitlab.com"
GITLAB_GROUP="microservices1691715"

# GitLab project paths (used to look up numeric project IDs via API)
PROJ_K8S_INFRA="microservices1691715/kubernetes-infrastructure"
PROJ_DEPLOYMENT="microservices1691715/deployment"
PROJ_CATALOG="microservices1691715/catalog"
PROJ_ORDERS="microservices1691715/orders"
PROJ_AUDIT="microservices1691715/audit"
PROJ_FRONTEND="microservices1691715/micro-market-frontend"

# ── prerequisite checks ───────────────────────────────────────────────────────
for cmd in aws curl jq openssl; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is not installed. Install it first."
done

# ── verify existing AWS credentials ──────────────────────────────────────────
info "Checking current AWS credentials..."
CALLER=$(aws sts get-caller-identity 2>/dev/null) \
  || die "AWS credentials not configured. Run 'aws configure' first."
CURRENT_USER=$(echo "${CALLER}" | jq -r '.Arn')
AWS_ACCOUNT_ID=$(echo "${CALLER}" | jq -r '.Account')
STATE_BUCKET="terraform-state-${AWS_ACCOUNT_ID}-${AWS_REGION}"
success "Authenticated as: ${CURRENT_USER}"
success "Account ID: ${AWS_ACCOUNT_ID}"
success "State bucket name: ${STATE_BUCKET}"

# ── load or prompt for inputs ─────────────────────────────────────────────────
ENV_FILE="${BASH_SOURCE%/*}/.env.bootstrap"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  info "Loaded inputs from ${ENV_FILE}"
fi

# Prompt only for values that are still unset
_prompt_if_empty() {
  local var_name="${1}" prompt_text="${2}" required="${3:-true}"
  if [[ -z "${!var_name:-}" ]]; then
    read -rp "${prompt_text}: " "${var_name?}"
    if [[ "${required}" == "true" && -z "${!var_name:-}" ]]; then
      die "${var_name} is required."
    fi
  fi
}

echo
echo "────────────────────────────────────────────────────────"
echo "  GitLab setup — using .env.bootstrap where available"
echo "  (create PATs at: https://gitlab.com/-/user_settings/personal_access_tokens)"
echo "────────────────────────────────────────────────────────"
echo

_prompt_if_empty GITLAB_API_PAT  "GitLab PAT with 'api' scope (to set CI/CD variables)"
_prompt_if_empty GITLAB_REPO_PAT "GitLab PAT with 'read_repository' scope (for ArgoCD)"
_prompt_if_empty GITLAB_USERNAME  "GitLab username"
_prompt_if_empty LETSENCRYPT_EMAIL "Let's Encrypt email [adriangherasim1@gmail.com]" false
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-adriangherasim1@gmail.com}"
_prompt_if_empty CLOUDFLARE_TOKEN   "Cloudflare API token (press Enter to skip)" false
_prompt_if_empty CLOUDFLARE_ZONE_ID "Cloudflare zone ID   (press Enter to skip)" false

# Persist all inputs so the next run is fully non-interactive
cat > "${ENV_FILE}" <<EOF
GITLAB_API_PAT="${GITLAB_API_PAT}"
GITLAB_REPO_PAT="${GITLAB_REPO_PAT}"
GITLAB_USERNAME="${GITLAB_USERNAME}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL}"
CLOUDFLARE_TOKEN="${CLOUDFLARE_TOKEN}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID}"
EOF
chmod 600 "${ENV_FILE}"
success "Inputs saved to ${ENV_FILE} (chmod 600)"

echo

# ── GitLab API helpers ────────────────────────────────────────────────────────

# Resolve a project path (e.g. "mygroup/myrepo") to its numeric project ID.
gitlab_project_id() {
  local path="${1}"
  local encoded
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${path}', safe=''))")
  curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    "${GITLAB_URL}/api/v4/projects/${encoded}" \
    | jq -r '.id'
}

# Resolve a group path to its numeric group ID.
gitlab_group_id() {
  local path="${1}"
  local encoded
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${path}', safe=''))")
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

  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    "${base_url}/${key}" 2>/dev/null || echo "000")

  local method="POST"
  local url="${base_url}"
  if [[ "${http_code}" == "200" ]]; then
    method="PUT"
    url="${base_url}/${key}"
  fi

  curl -sf -X "${method}" "${url}" \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    --form "key=${key}" \
    --form "value=${value}" \
    --form "masked=${masked}" \
    --form "protected=${protected}" \
    --form "environment_scope=${env_scope}" \
    > /dev/null

  echo -e "    ${GREEN}✓${NC} ${key}"
}

# Create a pipeline trigger token in a project and return the token value.
create_trigger_token() {
  local project_id="${1}"
  local description="${2:-deployment-promotion}"
  curl -sf -X POST \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    --form "description=${description}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/triggers" \
    | jq -r '.token'
}

# ── Step 1: Create IAM user ───────────────────────────────────────────────────
echo "════════════════════════════════════════"
info "Step 1 — Creating IAM user: ${IAM_USER}"
echo "════════════════════════════════════════"

if aws iam get-user --user-name "${IAM_USER}" >/dev/null 2>&1; then
  warn "IAM user '${IAM_USER}' already exists — skipping creation."
else
  aws iam create-user --user-name "${IAM_USER}" > /dev/null
  success "IAM user created: ${IAM_USER}"
fi

# Attach AdministratorAccess policy
POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"
if aws iam list-attached-user-policies --user-name "${IAM_USER}" \
    | jq -r '.AttachedPolicies[].PolicyArn' | grep -q "${POLICY_ARN}"; then
  warn "AdministratorAccess already attached — skipping."
else
  aws iam attach-user-policy \
    --user-name "${IAM_USER}" \
    --policy-arn "${POLICY_ARN}"
  success "Attached AdministratorAccess to ${IAM_USER}"
fi

# Create access key only if the user has none yet
EXISTING_KEYS=$(aws iam list-access-keys --user-name "${IAM_USER}" \
  | jq -r '.AccessKeyMetadata | length')
if [[ "${EXISTING_KEYS}" -gt 0 ]]; then
  warn "IAM user already has ${EXISTING_KEYS} access key(s) — skipping key creation."
  warn "Existing keys in GitLab CI/CD variables will be used as-is."
  DEPLOY_ACCESS_KEY_ID=""
  DEPLOY_SECRET_ACCESS_KEY=""
else
  info "Creating access key for ${IAM_USER}..."
  KEY_OUTPUT=$(aws iam create-access-key --user-name "${IAM_USER}")
  DEPLOY_ACCESS_KEY_ID=$(echo "${KEY_OUTPUT}" | jq -r '.AccessKey.AccessKeyId')
  DEPLOY_SECRET_ACCESS_KEY=$(echo "${KEY_OUTPUT}" | jq -r '.AccessKey.SecretAccessKey')
  success "Access key created: ${DEPLOY_ACCESS_KEY_ID}"
  warn "The secret key is shown once. It will be stored in GitLab as a masked variable."
fi

# ── Step 2: Create GitLab OIDC provider + IAM role ───────────────────────────
echo
echo "════════════════════════════════════════"
info "Step 2 — Creating GitLab OIDC provider and IAM role"
echo "════════════════════════════════════════"

GITLAB_OIDC_URL="https://gitlab.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/gitlab.com"
OIDC_ROLE_NAME="gitlab-oidc-${PROJECT_NAMESPACE}"

# Create the OIDC identity provider if it doesn't exist yet
if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  warn "OIDC provider for gitlab.com already exists — skipping."
else
  info "Fetching TLS thumbprint for gitlab.com..."
  THUMBPRINT=$(echo | openssl s_client -servername gitlab.com -connect gitlab.com:443 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout \
    | sed 's/.*=//;s/://g' \
    | tr '[:upper:]' '[:lower:]')
  aws iam create-open-id-connect-provider \
    --url "${GITLAB_OIDC_URL}" \
    --client-id-list "https://gitlab.com" \
    --thumbprint-list "${THUMBPRINT}" > /dev/null
  success "OIDC provider created: gitlab.com"
fi

# Build trust policy scoped to this GitLab group (any branch)
TRUST_POLICY=$(cat <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
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

if aws iam get-role --role-name "${OIDC_ROLE_NAME}" >/dev/null 2>&1; then
  warn "IAM role '${OIDC_ROLE_NAME}' already exists — skipping creation."
  OIDC_ROLE_ARN=$(aws iam get-role \
    --role-name "${OIDC_ROLE_NAME}" \
    --query 'Role.Arn' --output text)
else
  OIDC_ROLE_ARN=$(aws iam create-role \
    --role-name "${OIDC_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy \
    --role-name "${OIDC_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
  success "OIDC role created: ${OIDC_ROLE_ARN}"
fi

# ── Step 3: Create S3 state bucket ───────────────────────────────────────────
echo
echo "════════════════════════════════════════"
info "Step 3 — Creating S3 state bucket: ${STATE_BUCKET}"
echo "════════════════════════════════════════"

if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  warn "Bucket '${STATE_BUCKET}' already exists — skipping creation."
else
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
    > /dev/null
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

# ── Step 3: Resolve GitLab IDs ────────────────────────────────────────────────
echo
echo "════════════════════════════════════════"
info "Step 4 — Resolving GitLab group and project IDs"
echo "════════════════════════════════════════"

GROUP_ID=$(gitlab_group_id "${GITLAB_GROUP}") \
  || die "Could not resolve group '${GITLAB_GROUP}'. Check GITLAB_GROUP and PAT scope."
success "Group '${GITLAB_GROUP}' → ID ${GROUP_ID}"

info "Resolving project IDs..."
PROJ_DEPLOYMENT_ID=$(gitlab_project_id "${PROJ_DEPLOYMENT}")
PROJ_CATALOG_ID=$(gitlab_project_id "${PROJ_CATALOG}")
PROJ_ORDERS_ID=$(gitlab_project_id "${PROJ_ORDERS}")
PROJ_AUDIT_ID=$(gitlab_project_id "${PROJ_AUDIT}")
PROJ_FRONTEND_ID=$(gitlab_project_id "${PROJ_FRONTEND}")
PROJ_K8S_INFRA_ID=$(gitlab_project_id "${PROJ_K8S_INFRA}")
success "All project IDs resolved"

# ── Step 4: Set GitLab group-level variables ──────────────────────────────────
echo
echo "════════════════════════════════════════"
info "Step 5 — Setting GitLab group-level CI/CD variables"
echo "════════════════════════════════════════"

GROUP_VARS_URL="${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables"
CONTAINER_REGISTRY_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Deployment credentials — only written when a new key was created this run
if [[ -n "${DEPLOY_ACCESS_KEY_ID}" ]]; then
  upsert_var "${GROUP_VARS_URL}" "AWS_ACCESS_KEY_ID"     "${DEPLOY_ACCESS_KEY_ID}"     true  true
  upsert_var "${GROUP_VARS_URL}" "AWS_SECRET_ACCESS_KEY" "${DEPLOY_SECRET_ACCESS_KEY}" true  true
else
  warn "Skipping AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (existing key kept in GitLab)"
fi
upsert_var "${GROUP_VARS_URL}" "AWS_ACCOUNT_ID"        "${AWS_ACCOUNT_ID}"           false true
upsert_var "${GROUP_VARS_URL}" "AWS_REGION"            "${AWS_REGION}"               false false
upsert_var "${GROUP_VARS_URL}" "AWS_TF_STATE_BUCKET"   "${STATE_BUCKET}"             false false

# Project-wide constants
upsert_var "${GROUP_VARS_URL}" "CLOUD_PROVIDER"          "aws"                       false false
upsert_var "${GROUP_VARS_URL}" "ENVIRONMENT"             "dev"                       false false
upsert_var "${GROUP_VARS_URL}" "PROJECT_NAMESPACE"       "${PROJECT_NAMESPACE}"      false false
upsert_var "${GROUP_VARS_URL}" "CONTAINER_REGISTRY_NAME" "${CONTAINER_REGISTRY_NAME}" false false

# GitLab credentials for ArgoCD repo access
upsert_var "${GROUP_VARS_URL}" "AWS_ROLE_ARN"        "${OIDC_ROLE_ARN}"    false true

# GitLab credentials for ArgoCD repo access
upsert_var "${GROUP_VARS_URL}" "GITLAB_ACCESS_TOKEN" "${GITLAB_REPO_PAT}"  true  true
upsert_var "${GROUP_VARS_URL}" "GITLAB_USERNAME"     "${GITLAB_USERNAME}"  false false

success "Group variables set"

# ── Step 5: Set kubernetes-infrastructure project variables ───────────────────
echo
echo "════════════════════════════════════════"
info "Step 6 — Setting kubernetes-infrastructure project variables"
echo "════════════════════════════════════════"

K8S_VARS_URL="${GITLAB_URL}/api/v4/projects/${PROJ_K8S_INFRA_ID}/variables"

upsert_var "${K8S_VARS_URL}" "TF_VAR_lets_encrypt_email" "${LETSENCRYPT_EMAIL}" false false

if [[ -n "${CLOUDFLARE_TOKEN}" ]]; then
  upsert_var "${K8S_VARS_URL}" "TF_VAR_cloudflare_api_token" "${CLOUDFLARE_TOKEN}"   true  true
  upsert_var "${K8S_VARS_URL}" "TF_VAR_cloudflare_zone_id"   "${CLOUDFLARE_ZONE_ID}" false false
  success "Cloudflare variables set"
else
  warn "Cloudflare variables skipped (no token provided — DNS-01 cert issuance will not work)"
fi

success "kubernetes-infrastructure project variables set"

# ── Step 6: Create deployment pipeline trigger + set in service repos ─────────
echo
echo "════════════════════════════════════════"
info "Step 7 — Creating deployment pipeline trigger token"
echo "════════════════════════════════════════"

TRIGGER_TOKEN=$(create_trigger_token "${PROJ_DEPLOYMENT_ID}" "service-promotion")
[[ -z "${TRIGGER_TOKEN}" || "${TRIGGER_TOKEN}" == "null" ]] \
  && die "Failed to create pipeline trigger token in deployment project."
success "Pipeline trigger token created"

info "Setting DEPLOYMENT_TRIGGER_TOKEN in all service repos..."
for PROJECT_ID in ${PROJ_CATALOG_ID} ${PROJ_ORDERS_ID} ${PROJ_AUDIT_ID} ${PROJ_FRONTEND_ID}; do
  upsert_var \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" \
    "DEPLOYMENT_TRIGGER_TOKEN" "${TRIGGER_TOKEN}" true true
done
success "DEPLOYMENT_TRIGGER_TOKEN set in all service repos"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo -e "${GREEN}  Bootstrap complete!${NC}"
echo "════════════════════════════════════════════════════════"
echo
echo "  IAM user:        ${IAM_USER}"
echo "  Access key ID:   ${DEPLOY_ACCESS_KEY_ID:-<existing key — not rotated>}"
echo "  OIDC role ARN:   ${OIDC_ROLE_ARN}"
echo "  S3 state bucket: ${STATE_BUCKET} (${AWS_REGION})"
echo "  ECR registry:    ${CONTAINER_REGISTRY_NAME}"
echo
echo "  GitLab group variables set:         $(curl -sf \
  --header "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
  "${GITLAB_URL}/api/v4/groups/${GROUP_ID}/variables" | jq 'length') variables"
echo
echo "  Next steps:"
echo "  1. Push to infrastructure repo main → validate+plan runs automatically"
echo "  2. Click ▶ apply_infrastructure in GitLab (~20 min)"
echo "  3. Trigger utilities pipeline manually (~15 min)"
echo "  4. Push to kubernetes-infrastructure repo main → click ▶ apply (~15 min)"
echo "  5. Push to service repos → pipelines run fully automatically"
echo
warn "The IAM access key secret was stored in GitLab and is not shown again."
warn "If you need to rotate it: aws iam create-access-key --user-name ${IAM_USER}"
echo
