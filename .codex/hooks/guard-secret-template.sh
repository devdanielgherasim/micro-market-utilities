#!/usr/bin/env bash
# Blocks Write/Edit on the tracked scripts/.env.bootstrap template if the new
# content fills in a real-looking value for any of its secret keys. This file
# is committed as an all-placeholder template for onboarding -- it must stay
# that way, since it's the canonical bootstrap script every other repo's
# .gitlab-ci.yml references.
set -euo pipefail

INPUT="$(cat)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' | tr -d '\r')"

case "$FILE_PATH" in
  *"/scripts/.env.bootstrap"|*"\\scripts\\.env.bootstrap") ;;
  *) echo '{"continue": true}'; exit 0 ;;
esac

while IFS= read -r line; do
  if [[ "$line" =~ ^(GITLAB_API_PAT|GITLAB_REPO_PAT|CLOUDFLARE_TOKEN|CLOUDFLARE_ZONE_ID)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    value="${value#\"}"
    case "$value" in
      ""|CHANGE_ME|CHANGEME|TODO|REPLACE_ME|xxx|XXX) ;;
      "<"*">") ;;
      *)
        reason="utilities/scripts/.env.bootstrap is a committed onboarding template -- every value must stay a placeholder. Writing a real-looking value for $key here risks committing a credential. Fill in the real value only in a local, untracked copy."
        jq -n --arg reason "$reason" '{"continue": false, "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": $reason}}'
        exit 0
        ;;
    esac
  fi
done <<< "$CONTENT"

echo '{"continue": true}'
