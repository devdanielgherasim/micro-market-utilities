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
      AWS_REGION="${AWS_REGION:-us-east-1}"
      CONTAINER_REGISTRY_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
      ;;
    azure)
      CONTAINER_REGISTRY_NAME="acr${PROJECT_NAMESPACE}${ENVIRONMENT}.azurecr.io"
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
    AWS_REGION="${AWS_REGION:-us-east-1}"
    aws ecr get-login-password --region "${AWS_REGION}" |
      docker login --username AWS --password-stdin "${CONTAINER_REGISTRY_NAME}"
    ;;
  azure)
    : "${ARM_CLIENT_ID:?Set ARM_CLIENT_ID for Azure Container Registry login}"
    : "${ARM_CLIENT_SECRET:?Set ARM_CLIENT_SECRET for Azure Container Registry login}"
    echo "${ARM_CLIENT_SECRET}" |
      docker login "${CONTAINER_REGISTRY_NAME}" -u "${ARM_CLIENT_ID}" --password-stdin
    ;;
esac

export CONTAINER_REGISTRY_NAME
export CI_COMMIT_SHA
export PROJECT_NAMESPACE
export CLOUD_PROVIDER

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
