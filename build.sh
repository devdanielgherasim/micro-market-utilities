#!/bin/bash

CONTAINER_REGISTRY_NAME=""
ARM_CLIENT_ID=""
ARM_CLIENT_SECRET=""

CI_COMMIT_SHA="1.0.0"
PROJECT_NAMESPACE="microservices1691711"

#SERVICES=("audit" "catalog" "orders" "micro-market-frontend")
SERVICES=("audit" "catalog" "orders" "micro-market-frontend")

export CONTAINER_REGISTRY_NAME
export ARM_CLIENT_ID
export ARM_CLIENT_SECRET
export CI_COMMIT_SHA
export PROJECT_NAMESPACE

if [ -z "$CONTAINER_REGISTRY_NAME" ]; then
  echo "Error: CONTAINER_REGISTRY_NAME environment variable is not set"
  exit 1
fi

if [ ! -z "$ARM_CLIENT_ID" ] && [ ! -z "$ARM_CLIENT_SECRET" ]; then
  echo "===== Logging in to Container Registry ====="
  echo "$ARM_CLIENT_SECRET" | docker login $CONTAINER_REGISTRY_NAME -u "$ARM_CLIENT_ID" --password-stdin
  if [ $? -ne 0 ]; then
    echo "Error: Failed to log in to Container Registry"
    exit 1
  fi
else
  echo "Warning: ARM_CLIENT_ID or ARM_CLIENT_SECRET not set. You may need to log in to ACR manually."
fi

cd ..

for SERVICE in "${SERVICES[@]}"; do
  echo "===== Building $SERVICE service ====="
  
  export CI_PROJECT_NAME="$SERVICE"
  
  if [ -d "./$SERVICE" ]; then
    (cd ./$SERVICE && ./build.sh)
    
    if [ $? -ne 0 ]; then
      echo "Error: Failed to build $SERVICE service"
      exit 1
    fi
  else
    echo "Warning: Directory for $SERVICE not found"
  fi
done

echo "===== All builds completed successfully ====="