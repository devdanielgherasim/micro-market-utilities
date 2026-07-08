#!/usr/bin/env bash
# finalize-github-repo.sh - final per-repo GitHub cutover step.
#
# This script is intentionally narrow: it configures GitHub repository
# code-security settings through the GitHub REST API, optionally disables
# CodeQL default setup for repos that use the shared advanced CodeQL workflow,
# verifies the settings, and can then push the local repo to origin/main.
#
# Usage:
#   GITHUB_ORG=devdanielgherasim \
#     ./scripts/finalize-github-repo.sh \
#       --repo micro-market-platform-gitops \
#       --repo-dir ../platform-gitops \
#       --disable-default-codeql \
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

usage() {
  cat <<'EOF'
Usage:
  finalize-github-repo.sh --repo <repo> [options]

Options:
  --repo <name>                GitHub repository name, e.g. micro-market-platform-gitops.
  --repo-dir <path>            Local repo directory to push from when --push is used.
  --org <owner>                GitHub org/user. Defaults to GITHUB_ORG or scripts/.env.bootstrap.github.
  --disable-default-codeql     Set CodeQL default setup state to "not-configured".
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

configure_security_settings() {
  info "Enabling GitHub security settings for ${repo_full_name}"

  local payload
  payload="$(cat <<'JSON'
{
  "visibility": "public",
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
JSON
)"

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

verify_security_settings() {
  info "Verifying GitHub security settings for ${repo_full_name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}"
    return 0
  fi

  local repo_json visibility secret_scanning push_protection
  repo_json="$(gh api "repos/${repo_full_name}")"
  visibility="$(echo "${repo_json}" | jq -r '.visibility')"
  secret_scanning="$(echo "${repo_json}" | jq -r '.security_and_analysis.secret_scanning.status // "unavailable"')"
  push_protection="$(echo "${repo_json}" | jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unavailable"')"

  [[ "${visibility}" == "public" ]] || die "Expected visibility=public, got ${visibility}."
  [[ "${secret_scanning}" == "enabled" ]] || die "Expected secret_scanning=enabled, got ${secret_scanning}."
  [[ "${push_protection}" == "enabled" ]] || die "Expected secret_scanning_push_protection=enabled, got ${push_protection}."

  success "visibility=${visibility}, secret_scanning=${secret_scanning}, push_protection=${push_protection}"

  if [[ "${DISABLE_DEFAULT_CODEQL}" == "true" ]]; then
    local default_setup_json default_setup_state
    default_setup_json="$(gh api "repos/${repo_full_name}/code-scanning/default-setup")"
    default_setup_state="$(echo "${default_setup_json}" | jq -r '.state')"
    [[ "${default_setup_state}" == "not-configured" ]] || die "Expected CodeQL default setup state=not-configured, got ${default_setup_state}."
    success "codeql_default_setup=${default_setup_state}"
  fi
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

configure_security_settings
disable_default_codeql_if_requested
verify_security_settings
push_repo_if_requested

success "GitHub finalization complete for ${repo_full_name}"
