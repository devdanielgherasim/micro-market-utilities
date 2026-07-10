$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "scripts/bootstrap-github.sh"
$script = Get-Content -Raw $scriptPath

if ($script -notmatch 'INFRASTRUCTURE_REPOS=\(micro-market-infrastructure\)') {
    throw "bootstrap-github.sh must explicitly include micro-market-infrastructure for infrastructure Terraform credentials"
}

if ($script -notmatch 'set_provider_repo_variables\(\)') {
    throw "bootstrap-github.sh must route variables through a provider-specific setter"
}

if ($script -notmatch 'set_provider_repo_secrets\(\)') {
    throw "bootstrap-github.sh must route secrets through a provider-specific setter"
}

if ($script -match 'for repo in "\$\{ALL_APP_REPOS\[@\]\}"; do\s+set_repo_variable "\$\{repo\}" "CLOUD_PROVIDER"[\s\S]*?set_repo_variable "\$\{repo\}" "AWS_REGION"[\s\S]*?set_repo_variable "\$\{repo\}" "GCP_REGION"') {
    throw "common repo variable loop must not set AWS/GCP variables for every provider"
}

if ($script -match 'for repo in "\$\{ALL_APP_REPOS\[@\]\}"; do[\s\S]*?case "\$\{CLOUD_PROVIDER\}"[\s\S]*?AZURE_CLIENT_ID') {
    throw "app-only secret loop must be replaced by provider-specific repo secret routing"
}

foreach ($required in @(
    '"micro-market-infrastructure" "ARM_CLIENT_ID"',
    '"micro-market-infrastructure" "ARM_TENANT_ID"',
    '"micro-market-infrastructure" "ARM_SUBSCRIPTION_ID"',
    '"micro-market-infrastructure" "AZURE_TF_STATE_RESOURCE_GROUP"',
    '"micro-market-infrastructure" "AZURE_TF_STATE_STORAGE_ACCOUNT"',
    '"micro-market-infrastructure" "AZURE_TF_STATE_CONTAINER"',
    '"micro-market-infrastructure" "AWS_ROLE_ARN"',
    '"micro-market-infrastructure" "AWS_TF_STATE_BUCKET"',
    '"micro-market-infrastructure" "GCP_PROJECT_ID"',
    '"micro-market-infrastructure" "GCP_TF_STATE_BUCKET"'
)) {
    if ($script -notmatch [regex]::Escape($required)) {
        throw "bootstrap-github.sh missing provider-specific infrastructure setting: $required"
    }
}

if ($script -notmatch 'AWS_ACCOUNT_ID="\$\{AWS_ACCOUNT_ID:-\$\{account_id\}\}"') {
    throw "AWS OIDC trust setup must expose the discovered AWS account ID for later provider-specific repo settings"
}

if ($script -match '"micro-market-infrastructure" "ARM_CLIENT_ID" "\$\{AZURE_GITHUB_CI_CLIENT_ID') {
    throw "micro-market-infrastructure ARM_CLIENT_ID must use the Terraform ARM identity, not the app-only Azure GitHub CI identity"
}

if ($script -notmatch '"micro-market-infrastructure" "ARM_CLIENT_ID" "\$\{ARM_CLIENT_ID:-\}"') {
    throw "micro-market-infrastructure ARM_CLIENT_ID must be set from ARM_CLIENT_ID"
}

foreach ($required in @(
    'ensure_github_azure_infra_oidc_trust\(\)',
    'az ad app federated-credential',
    'repo:\$\{GITHUB_ORG\}/\$\{repo\}:ref:refs/heads/main',
    'repo:\$\{GITHUB_ORG\}/\$\{repo\}:environment:\$\{ENVIRONMENT\}',
    'api://AzureADTokenExchange'
)) {
    if ($script -notmatch $required) {
        throw "bootstrap-github.sh must configure Azure GitHub OIDC trust for the infrastructure ARM_CLIENT_ID app registration: $required"
    }
}

Write-Host "bootstrap-github provider-specific repository scoping is covered."
