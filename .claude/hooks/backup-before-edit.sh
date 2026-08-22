#!/bin/bash
set -euo pipefail

INPUT=$(cat /dev/stdin)

JQ="${JQ:-jq}"

TOOL_NAME=$(
    printf '%s' "$INPUT" |
    "$JQ" -r '.tool_name // "unknown"'
)

FILE_PATH=$(
    printf '%s' "$INPUT" |
    "$JQ" -r '.tool_input.file_path // empty'
)

# Nothing to snapshot for a new/nonexistent file.
[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

# Do not recursively snapshot transient agent/tooling material.
printf '%s' "$FILE_PATH" |
    grep -qiE '(\.claude/backups/|\.claude/hooks/|\.claude/plans/|node_modules/)' &&
    exit 0

HOOK_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)"

TOOLKIT_ROOT="$(
    cd "$HOOK_DIR/../.." &&
    pwd
)"

SNAPSHOT="$TOOLKIT_ROOT/tools/skyrim-snapshot.py"

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

if [ ! -x "$SNAPSHOT" ]; then
    deny_closed "Shared snapshot service is unavailable: $SNAPSHOT"
fi

if ! RESULT=$(
    "$SNAPSHOT" file "$FILE_PATH" \
        --if-registered \
        --reason "claude:$TOOL_NAME"
); then
    deny_closed "Shared snapshot service failed before editing: $FILE_PATH"
fi

STATUS=$(
    printf '%s' "$RESULT" |
    "$JQ" -r '.status'
)

case "$STATUS" in
    snapshotted|skipped)
        exit 0
        ;;

    *)
        deny_closed "Unexpected result from shared snapshot service."
        ;;
esac
