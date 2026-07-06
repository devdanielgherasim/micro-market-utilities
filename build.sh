#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-prod}"
PROJECT_NAMESPACE="${PROJECT_NAMESPACE:-danielgherasim-microservices}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
CI_COMMIT_SHA="${CI_COMMIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
SERVICES_RAW="${SERVICES:-audit catalog orders micro-market-frontend}"

if [[ -z "${CONTAINER_REGISTRY_NAME:-}" ]]; then
  case "${CLOUD_PROVIDER}" in
    aws)
      : "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID or CONTAINER_REGISTRY_NAME for AWS image builds}"
      AWS_REGION="${AWS_REGION:-eu-central-1}"
      CONTAINER_REGISTRY_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
      ;;
    azure)
      AZURE_ACR_PROJECT="${PROJECT_NAMESPACE//-/}"
      CONTAINER_REGISTRY_NAME="acr${AZURE_ACR_PROJECT}${ENVIRONMENT}.azurecr.io"
      ;;
    gcp)
      : "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID or CONTAINER_REGISTRY_NAME for GCP image builds}"
      GCP_REGION="${GCP_REGION:-europe-west3}"
      CONTAINER_REGISTRY_NAME="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}"
      ;;
    *)
      echo "Unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER}'. Set CONTAINER_REGISTRY_NAME explicitly." >&2
      exit 1
      ;;
  esac
fi

echo "===== Logging in to ${CLOUD_PROVIDER} container registry: ${CONTAINER_REGISTRY_NAME} ====="
case "${CLOUD_PROVIDER}" in
  aws)
    AWS_REGION="${AWS_REGION:-eu-central-1}"
    if [[ -n "${AWS_ROLE_ARN:-}" && -n "${GITLAB_OIDC_TOKEN:-}" ]]; then
      CREDS="$(aws sts assume-role-with-web-identity \
        --role-arn "${AWS_ROLE_ARN}" \
        --role-session-name "gitlab-${CI_PROJECT_ID:-local}-${CI_PIPELINE_ID:-local}" \
        --web-identity-token "${GITLAB_OIDC_TOKEN}" \
        --duration-seconds 3600)"
      export AWS_ACCESS_KEY_ID="$(echo "${CREDS}" | jq -r '.Credentials.AccessKeyId')"
      export AWS_SECRET_ACCESS_KEY="$(echo "${CREDS}" | jq -r '.Credentials.SecretAccessKey')"
      export AWS_SESSION_TOKEN="$(echo "${CREDS}" | jq -r '.Credentials.SessionToken')"
    fi
    aws ecr get-login-password --region "${AWS_REGION}" |
      docker login --username AWS --password-stdin "${CONTAINER_REGISTRY_NAME}"
    ;;
  azure)
    : "${ARM_CLIENT_ID:?Set ARM_CLIENT_ID for Azure Container Registry login}"
    if [[ "${ARM_USE_OIDC:-false}" == "true" ]]; then
      : "${ARM_TENANT_ID:?Set ARM_TENANT_ID for Azure OIDC login}"
      : "${GITLAB_OIDC_TOKEN:?Set GITLAB_OIDC_TOKEN for Azure OIDC login}"
      az login --service-principal \
        --username "${ARM_CLIENT_ID}" \
        --tenant "${ARM_TENANT_ID}" \
        --federated-token "${GITLAB_OIDC_TOKEN}" >/dev/null
      az acr login --name "${CONTAINER_REGISTRY_NAME%%.azurecr.io}"
    else
      : "${ARM_CLIENT_SECRET:?Set ARM_CLIENT_SECRET for Azure Container Registry login}"
      echo "${ARM_CLIENT_SECRET}" |
        docker login "${CONTAINER_REGISTRY_NAME}" -u "${ARM_CLIENT_ID}" --password-stdin
    fi
    ;;
  gcp)
    GCP_REGION="${GCP_REGION:-europe-west3}"
    if [[ -n "${GCP_WORKLOAD_IDENTITY_PROVIDER:-}" && -n "${GCP_SERVICE_ACCOUNT_EMAIL:-}" && -n "${GITLAB_OIDC_TOKEN:-}" ]]; then
      OIDC_TOKEN_FILE="${CI_PROJECT_DIR:-.}/gitlab-oidc-token"
      WIF_CREDENTIALS_FILE="${CI_PROJECT_DIR:-.}/gcp-wif-credentials.json"
      printf '%s' "${GITLAB_OIDC_TOKEN}" > "${OIDC_TOKEN_FILE}"
      cat > "${WIF_CREDENTIALS_FILE}" <<EOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/${GCP_WORKLOAD_IDENTITY_PROVIDER}",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "${OIDC_TOKEN_FILE}"
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${GCP_SERVICE_ACCOUNT_EMAIL}:generateAccessToken"
}
EOF
      gcloud auth login --cred-file="${WIF_CREDENTIALS_FILE}" --quiet
    fi
    gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
    ;;
esac

export CONTAINER_REGISTRY_NAME
export CI_COMMIT_SHA
export PROJECT_NAMESPACE
export CLOUD_PROVIDER
export ENVIRONMENT
export MAIN_SCRIPT_LOGIN=1

cd ..

for SERVICE in ${SERVICES_RAW}; do
  echo "===== Building ${SERVICE} service ====="
  export CI_PROJECT_NAME="${SERVICE}"

  if [[ ! -d "./${SERVICE}" ]]; then
    echo "Service directory not found: ${SERVICE}" >&2
    exit 1
  fi

  (cd "./${SERVICE}" && ./build.sh)
done

echo "===== All builds completed successfully ====="
