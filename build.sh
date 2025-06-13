#!/bin/bash
# main-build.sh - Main script to configure environment variables and build all services

# Configuration section - modify these values
AZURE_REGISTRY_NAME=""  # Replace with your registry
ARM_CLIENT_ID=""                                             # Replace with your client ID
ARM_CLIENT_SECRET=""                                         # Replace with your client secret

CI_COMMIT_SHA="test"                                         # Or use git rev-parse HEAD to get actual commit
CI_PROJECT_NAMESPACE="microservices1691717"

# Array of services to build
#SERVICES=("audit" "catalog" "orders" "micro-market-frontend")
SERVICES=("orders")

# Export all variables so they're available to child processes
export AZURE_REGISTRY_NAME
export ARM_CLIENT_ID
export ARM_CLIENT_SECRET
export CI_COMMIT_SHA
export CI_PROJECT_NAMESPACE

# Check if required variables are set
if [ -z "$AZURE_REGISTRY_NAME" ]; then
  echo "Error: AZURE_REGISTRY_NAME environment variable is not set"
  exit 1
fi

# Perform Azure Container Registry login once
if [ ! -z "$ARM_CLIENT_ID" ] && [ ! -z "$ARM_CLIENT_SECRET" ]; then
  echo "===== Logging in to Container Registry ====="
  echo "$ARM_CLIENT_SECRET" | docker login $AZURE_REGISTRY_NAME -u "$ARM_CLIENT_ID" --password-stdin
  if [ $? -ne 0 ]; then
    echo "Error: Failed to log in to Container Registry"
    exit 1
  fi
else
  echo "Warning: ARM_CLIENT_ID or ARM_CLIENT_SECRET not set. You may need to log in to ACR manually."
fi

cd ..

# Build each service
for SERVICE in "${SERVICES[@]}"; do
  echo "===== Building $SERVICE service ====="
  
  # Export service-specific variables
  export CI_PROJECT_NAME="$SERVICE"
  
  # Check if the service directory exists
  if [ -d "./$SERVICE" ]; then
    # Change to the service directory and run its build script
    (cd ./$SERVICE && ./build.sh)
    
    # Check if build was successful
    if [ $? -ne 0 ]; then
      echo "Error: Failed to build $SERVICE service"
      exit 1
    fi
  else
    echo "Warning: Directory for $SERVICE not found"
  fi
done

echo "===== All builds completed successfully ====="