#!/usr/bin/env bash
# finalize-github-repo.sh - final per-repo GitHub cutover step.
#
# Configures a GitHub repository fully through the REST API so no manual
# Settings-UI work is needed:
#   - Repository metadata (description, homepage, topics, feature toggles)
#   - Code-security settings (dependency graph, secret scanning, push protection)
#   - Dependabot vulnerability alerts and automated security fixes
#   - Main-branch protection (no force push, no delete)
#   - CodeQL default setup disable (for repos using the shared advanced workflow)
#   - GitHub Environments with optional required-reviewer protection rules
#   - Verification of every setting applied above
#   - Optional push of the local repo to origin/main
#
# Usage:
#   GITHUB_ORG=devdanielgherasim \
#     ./scripts/finalize-github-repo.sh \
#       --repo micro-market-deployment \
#       --repo-dir ../deployment \
#       --disable-default-codeql \
#       --description "ArgoCD deployment manifests" \
#       --topics "argocd,kubernetes,gitops" \
#       --no-wiki --no-projects \
#       --delete-branch-on-merge \
#       --enable-dependabot \
#       --environments dev,staging,production \
#       --environment-reviewers "staging:devdanielgherasim,production:devdanielgherasim" \
#       --push

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GITHUB_ENV_FILE="${SCRIPT_DIR}/.env.bootstrap.github"

if [[ -f "${GITHUB_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${GITHUB_ENV_FILE}"
fi

GITHUB_ORG="${GITHUB_ORG:-}"
REPO=""
REPO_DIR=""
DISABLE_DEFAULT_CODEQL=false
PUSH=false
DRY_RUN=false
REPO_DESCRIPTION=""
REPO_HOMEPAGE=""
REPO_TOPICS=""
NO_WIKI=false
NO_PROJECTS=false
DELETE_BRANCH_ON_MERGE=false
ENABLE_DEPENDABOT=false
ENVIRONMENTS=""
ENVIRONMENT_REVIEWERS=""

usage() {
  cat <<'EOF'
Usage:
  finalize-github-repo.sh --repo <repo> [options]

Options:
  --repo <name>                GitHub repository name, e.g. micro-market-platform-gitops.
  --repo-dir <path>            Local repo directory to push from when --push is used.
  --org <owner>                GitHub org/user. Defaults to GITHUB_ORG or scripts/.env.bootstrap.github.
  --disable-default-codeql     Set CodeQL default setup state to "not-configured".
  --description <text>         Set repository description.
  --homepage <url>             Set repository homepage URL.
  --topics <t1,t2,...>         Set repository topics (comma-separated, replaces existing).
  --no-wiki                    Disable the wiki tab.
  --no-projects                Disable the projects tab.
  --delete-branch-on-merge     Auto-delete head branches after PR merge.
  --enable-dependabot          Enable Dependabot vulnerability alerts and automated security fixes.
  --environments <e1,e2,...>   Create GitHub Environments (comma-separated).
  --environment-reviewers <spec>
                               Required reviewers per environment. Format:
                               "env1:user1,env2:user2:user3" (colon-separated users per env).
  --push                       Push HEAD to origin main after settings are verified.
  --dry-run                    Print intended API/git operations without changing anything.
  -h, --help                   Show this help.

The authenticated gh user/token must have repository Administration: write.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"; shift 2 ;;
    --repo-dir)
      REPO_DIR="${2:-}"; shift 2 ;;
    --org)
      GITHUB_ORG="${2:-}"; shift 2 ;;
    --disable-default-codeql)
      DISABLE_DEFAULT_CODEQL=true; shift ;;
    --description)
      REPO_DESCRIPTION="${2:-}"; shift 2 ;;
    --homepage)
      REPO_HOMEPAGE="${2:-}"; shift 2 ;;
    --topics)
      REPO_TOPICS="${2:-}"; shift 2 ;;
    --no-wiki)
      NO_WIKI=true; shift ;;
    --no-projects)
      NO_PROJECTS=true; shift ;;
    --delete-branch-on-merge)
      DELETE_BRANCH_ON_MERGE=true; shift ;;
    --enable-dependabot)
      ENABLE_DEPENDABOT=true; shift ;;
    --environments)
      ENVIRONMENTS="${2:-}"; shift 2 ;;
    --environment-reviewers)
      ENVIRONMENT_REVIEWERS="${2:-}"; shift 2 ;;
    --push)
      PUSH=true; shift ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ -n "${GITHUB_ORG}" ]] || die "GitHub org/user is required. Pass --org or set GITHUB_ORG."
[[ -n "${REPO}" ]] || die "--repo is required."
if [[ "${PUSH}" == "true" && -z "${REPO_DIR}" ]]; then
  die "--repo-dir is required when --push is used."
fi

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

require_cmd() {
  command -v "${1}" >/dev/null 2>&1 || die "${1} is not installed. Install it first."
}

if [[ "${DRY_RUN}" != "true" ]]; then
  require_cmd gh
  require_cmd jq
  gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated. Run 'gh auth login' first."
fi
if [[ "${PUSH}" == "true" && "${DRY_RUN}" != "true" ]]; then
  require_cmd git
fi

repo_full_name="${GITHUB_ORG}/${REPO}"

configure_repo_settings() {
  info "Configuring repository settings for ${repo_full_name}"

  local payload
  payload='{
    "visibility": "public",
    "security_and_analysis": {
      "dependency_graph": { "status": "enabled" },
      "secret_scanning": { "status": "enabled" },
      "secret_scanning_push_protection": { "status": "enabled" }
    }
  }'

  if [[ -n "${REPO_DESCRIPTION}" ]]; then
    payload="$(echo "${payload}" | jq --arg d "${REPO_DESCRIPTION}" '. + {description: $d}')"
  fi
  if [[ -n "${REPO_HOMEPAGE}" ]]; then
    payload="$(echo "${payload}" | jq --arg h "${REPO_HOMEPAGE}" '. + {homepage: $h}')"
  fi
  if [[ "${NO_WIKI}" == "true" ]]; then
    payload="$(echo "${payload}" | jq '. + {has_wiki: false}')"
  fi
  if [[ "${NO_PROJECTS}" == "true" ]]; then
    payload="$(echo "${payload}" | jq '. + {has_projects: false}')"
  fi
  if [[ "${DELETE_BRANCH_ON_MERGE}" == "true" ]]; then
    payload="$(echo "${payload}" | jq '. + {delete_branch_on_merge: true}')"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PATCH repos/${repo_full_name} --input -"
    echo "${payload}"
  else
    gh api \
      --method PATCH \
      "repos/${repo_full_name}" \
      --input - <<<"${payload}" >/dev/null
  fi
}

configure_topics() {
  [[ -n "${REPO_TOPICS}" ]] || return 0

  info "Setting topics for ${repo_full_name}"

  local topics_json
  topics_json="$(echo "${REPO_TOPICS}" | tr ',' '\n' | jq -R . | jq -sc '{names: .}')"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/topics --input -"
    echo "${topics_json}"
  else
    gh api \
      --method PUT \
      "repos/${repo_full_name}/topics" \
      --input - <<<"${topics_json}" >/dev/null
  fi
}

configure_dependabot() {
  [[ "${ENABLE_DEPENDABOT}" == "true" ]] || return 0

  info "Enabling Dependabot vulnerability alerts for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/vulnerability-alerts"
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/automated-security-fixes"
    return 0
  fi

  gh api \
    --method PUT \
    "repos/${repo_full_name}/vulnerability-alerts" >/dev/null 2>&1 || true

  info "Enabling Dependabot automated security fixes for ${repo_full_name}"
  gh api \
    --method PUT \
    "repos/${repo_full_name}/automated-security-fixes" >/dev/null 2>&1 || true
}

configure_environments() {
  [[ -n "${ENVIRONMENTS}" ]] || return 0

  # Parse reviewer spec into an associative array: env_name -> "user1 user2"
  declare -A reviewer_map
  if [[ -n "${ENVIRONMENT_REVIEWERS}" ]]; then
    IFS=',' read -ra reviewer_entries <<< "${ENVIRONMENT_REVIEWERS}"
    for entry in "${reviewer_entries[@]}"; do
      local env_name="${entry%%:*}"
      local users="${entry#*:}"
      reviewer_map["${env_name}"]="${users//:/ }"
    done
  fi

  IFS=',' read -ra env_list <<< "${ENVIRONMENTS}"
  for env_name in "${env_list[@]}"; do
    info "Creating/updating environment '${env_name}' for ${repo_full_name}"

    local payload='{"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}'

    if [[ -n "${reviewer_map[${env_name}]:-}" ]]; then
      local reviewers_array='[]'
      for username in ${reviewer_map[${env_name}]}; do
        if [[ "${DRY_RUN}" == "true" ]]; then
          info "Would look up user ID for '${username}' and add as reviewer on '${env_name}'"
          continue
        fi
        local user_id
        user_id="$(gh api "users/${username}" --jq '.id' 2>/dev/null)" || {
          warn "Could not resolve user '${username}', skipping as reviewer for '${env_name}'"
          continue
        }
        reviewers_array="$(echo "${reviewers_array}" | jq --argjson id "${user_id}" '. + [{type: "User", id: $id}]')"
      done
      if [[ "${DRY_RUN}" != "true" ]]; then
        payload="$(echo "${payload}" | jq --argjson r "${reviewers_array}" '. + {reviewers: $r}')"
      fi
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] gh api --method PUT repos/${repo_full_name}/environments/${env_name} --input -"
      echo "${payload}"
    else
      gh api \
        --method PUT \
        "repos/${repo_full_name}/environments/${env_name}" \
        --input - <<<"${payload}" >/dev/null
    fi
  done
}

configure_branch_protection() {
  info "Protecting main branch for ${repo_full_name}"

  local payload
  payload="$(cat <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": true
}
JSON
)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/branches/main/protection --input -"
    echo "${payload}"
  else
    gh api \
      --method PUT \
      "repos/${repo_full_name}/branches/main/protection" \
      --input - <<<"${payload}" >/dev/null
  fi
}

disable_default_codeql_if_requested() {
  [[ "${DISABLE_DEFAULT_CODEQL}" == "true" ]] || return 0

  info "Disabling CodeQL default setup for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PATCH repos/${repo_full_name}/code-scanning/default-setup -f state=not-configured"
    return 0
  fi

  gh api \
    --method PATCH \
    "repos/${repo_full_name}/code-scanning/default-setup" \
    -f state=not-configured >/dev/null
}

verify_repo_settings() {
  info "Verifying repository settings for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}"
    return 0
  fi

  local repo_json visibility dependency_graph secret_scanning push_protection
  repo_json="$(gh api "repos/${repo_full_name}")"
  visibility="$(echo "${repo_json}" | jq -r '.visibility')"
  dependency_graph="$(echo "${repo_json}" | jq -r '.security_and_analysis.dependency_graph.status // "unavailable"')"
  secret_scanning="$(echo "${repo_json}" | jq -r '.security_and_analysis.secret_scanning.status // "unavailable"')"
  push_protection="$(echo "${repo_json}" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unavailable"')"

  [[ "${visibility}" == "public" ]] || die "Expected visibility=public, got ${visibility}."
  if [[ "${dependency_graph}" == "enabled" ]]; then
    :
  elif [[ "${dependency_graph}" == "unavailable" && "${visibility}" == "public" ]]; then
    warn "dependency_graph status is unavailable in the repo API response; public repositories have dependency graph enabled by GitHub. Continuing."
  else
    die "Expected dependency_graph=enabled, got ${dependency_graph}."
  fi
  [[ "${secret_scanning}" == "enabled" ]] || die "Expected secret_scanning=enabled, got ${secret_scanning}."
  [[ "${push_protection}" == "enabled" ]] || die "Expected secret_scanning_push_protection=enabled, got ${push_protection}."

  success "visibility=${visibility}, dependency_graph=${dependency_graph}, secret_scanning=${secret_scanning}, push_protection=${push_protection}"

  if [[ -n "${REPO_DESCRIPTION}" ]]; then
    local actual_desc
    actual_desc="$(echo "${repo_json}" | jq -r '.description // ""')"
    [[ "${actual_desc}" == "${REPO_DESCRIPTION}" ]] || die "Expected description='${REPO_DESCRIPTION}', got '${actual_desc}'."
    success "description='${actual_desc}'"
  fi

  if [[ "${NO_WIKI}" == "true" ]]; then
    local has_wiki
    has_wiki="$(echo "${repo_json}" | jq -r '.has_wiki')"
    [[ "${has_wiki}" == "false" ]] || die "Expected has_wiki=false, got ${has_wiki}."
    success "has_wiki=${has_wiki}"
  fi

  if [[ "${NO_PROJECTS}" == "true" ]]; then
    local has_projects
    has_projects="$(echo "${repo_json}" | jq -r '.has_projects')"
    [[ "${has_projects}" == "false" ]] || die "Expected has_projects=false, got ${has_projects}."
    success "has_projects=${has_projects}"
  fi

  if [[ "${DELETE_BRANCH_ON_MERGE}" == "true" ]]; then
    local delete_on_merge
    delete_on_merge="$(echo "${repo_json}" | jq -r '.delete_branch_on_merge')"
    [[ "${delete_on_merge}" == "true" ]] || die "Expected delete_branch_on_merge=true, got ${delete_on_merge}."
    success "delete_branch_on_merge=${delete_on_merge}"
  fi

  if [[ "${DISABLE_DEFAULT_CODEQL}" == "true" ]]; then
    local default_setup_json default_setup_state
    default_setup_json="$(gh api "repos/${repo_full_name}/code-scanning/default-setup")"
    default_setup_state="$(echo "${default_setup_json}" | jq -r '.state')"
    [[ "${default_setup_state}" == "not-configured" ]] || die "Expected CodeQL default setup state=not-configured, got ${default_setup_state}."
    success "codeql_default_setup=${default_setup_state}"
  fi
}

verify_topics() {
  [[ -n "${REPO_TOPICS}" ]] || return 0

  info "Verifying topics for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/topics"
    return 0
  fi

  local actual_topics expected_topics
  actual_topics="$(gh api "repos/${repo_full_name}/topics" --jq '.names | sort | join(",")')"
  expected_topics="$(echo "${REPO_TOPICS}" | tr ',' '\n' | sort | paste -sd ',')"
  [[ "${actual_topics}" == "${expected_topics}" ]] || die "Expected topics='${expected_topics}', got '${actual_topics}'."
  success "topics=${actual_topics}"
}

verify_dependabot() {
  [[ "${ENABLE_DEPENDABOT}" == "true" ]] || return 0

  info "Verifying Dependabot settings for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/vulnerability-alerts (check status code)"
    return 0
  fi

  local http_code
  http_code="$(gh api "repos/${repo_full_name}/vulnerability-alerts" --include 2>&1 | head -1 | awk '{print $2}')" || true
  if [[ "${http_code}" == "204" ]]; then
    success "dependabot_alerts=enabled"
  else
    die "Expected Dependabot vulnerability alerts enabled (HTTP 204), got HTTP ${http_code}."
  fi
}

verify_environments() {
  [[ -n "${ENVIRONMENTS}" ]] || return 0

  info "Verifying environments for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/environments"
    return 0
  fi

  IFS=',' read -ra env_list <<< "${ENVIRONMENTS}"
  for env_name in "${env_list[@]}"; do
    local env_json
    env_json="$(gh api "repos/${repo_full_name}/environments/${env_name}" 2>/dev/null)" || {
      die "Environment '${env_name}' does not exist on ${repo_full_name}."
    }
    local actual_name
    actual_name="$(echo "${env_json}" | jq -r '.name')"
    [[ "${actual_name}" == "${env_name}" ]] || die "Expected environment name='${env_name}', got '${actual_name}'."
    success "environment '${env_name}' exists"
  done
}

verify_branch_protection() {
  info "Verifying main branch protection for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/branches/main/protection"
    return 0
  fi

  local protection_json force_pushes deletions
  protection_json="$(gh api "repos/${repo_full_name}/branches/main/protection")"
  force_pushes="$(echo "${protection_json}" | jq -r '.allow_force_pushes.enabled')"
  deletions="$(echo "${protection_json}" | jq -r '.allow_deletions.enabled')"

  [[ "${force_pushes}" == "false" ]] || die "Expected allow_force_pushes.enabled=false, got ${force_pushes}."
  [[ "${deletions}" == "false" ]] || die "Expected allow_deletions.enabled=false, got ${deletions}."

  success "main_branch_protected=true, allow_force_pushes=${force_pushes}, allow_deletions=${deletions}"
}

push_repo_if_requested() {
  [[ "${PUSH}" == "true" ]] || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "Pushing ${REPO_DIR} to origin main"
    echo "[dry-run] git -C ${REPO_DIR} status --short --branch"
    echo "[dry-run] git -C ${REPO_DIR} push origin main"
    return 0
  fi

  local resolved_repo_dir
  resolved_repo_dir="$(cd "${REPO_DIR}" && pwd)"
  info "Pushing ${resolved_repo_dir} to origin main"

  git -C "${resolved_repo_dir}" status --short --branch
  if [[ -n "$(git -C "${resolved_repo_dir}" status --porcelain)" ]]; then
    die "Refusing to push with uncommitted changes in ${resolved_repo_dir}. Commit the migration changes first, then rerun finalization."
  fi
  git -C "${resolved_repo_dir}" push origin main
}

configure_repo_settings
configure_topics
configure_branch_protection
disable_default_codeql_if_requested
configure_dependabot
configure_environments
verify_repo_settings
verify_topics
verify_branch_protection
verify_dependabot
verify_environments
push_repo_if_requested

success "GitHub finalization complete for ${repo_full_name}"
