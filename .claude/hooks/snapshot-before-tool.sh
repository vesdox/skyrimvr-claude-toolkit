#!/bin/bash
set -euo pipefail

INPUT=$(cat /dev/stdin)
JQ="${JQ:-jq}"

COMMAND=$(
    printf '%s' "$INPUT" |
    "$JQ" -r '.tool_input.command // empty'
)

[ -z "$COMMAND" ] && exit 0

# Purely observational commands do not need transactional snapshots.
printf '%s' "$COMMAND" |
    grep -qE '^\s*(ls|cat|head|tail|grep|rg|find|wc|file|stat|pwd|date|whoami|which|type|env|printenv)\b' &&
    exit 0

printf '%s' "$COMMAND" |
    grep -qE '^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)\b' &&
    exit 0

HOOK_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)"

TOOLKIT_ROOT="$(
    cd "$HOOK_DIR/../.." &&
    pwd
)"

SNAPSHOT_SETS="$TOOLKIT_ROOT/tools/skyrim-snapshot-set.py"

deny_closed() {
    "$JQ" -n \
        --arg r "$1" \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
          }
        }'
    exit 0
}

if [ ! -x "$SNAPSHOT_SETS" ]; then
    deny_closed "Shared snapshot-set service is unavailable: $SNAPSHOT_SETS"
fi

CONTEXT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if ! RESULT=$(
    "$SNAPSHOT_SETS" before-command \
        --context "$CONTEXT" \
        --reason "claude:Bash"
); then
    deny_closed "Shared pre-command snapshot service failed."
fi

STATUS=$(
    printf '%s' "$RESULT" |
    "$JQ" -r '.status'
)

case "$STATUS" in
    processed|skipped)
        exit 0
        ;;

    *)
        deny_closed "Unexpected result from shared snapshot-set service."
        ;;
esac
