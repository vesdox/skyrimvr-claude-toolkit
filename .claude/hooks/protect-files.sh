#!/bin/bash
set -euo pipefail

INPUT=$(cat /dev/stdin)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
JQ="${JQ:-jq}"

FILE_PATH=$(
    printf '%s' "$INPUT" |
    "$JQ" -r '.tool_input.file_path // empty'
)

[ -z "$FILE_PATH" ] && exit 0

EVALUATOR="$PROJECT_DIR/policies/evaluate-file.py"

if [ ! -x "$EVALUATOR" ]; then
    "$JQ" -n \
        --arg r "Shared file-policy evaluator is unavailable: $EVALUATOR" \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
          }
        }'
    exit 0
fi

RESULT=$("$EVALUATOR" "$FILE_PATH")
DECISION=$(printf '%s' "$RESULT" | "$JQ" -r '.decision')
REASON=$(printf '%s' "$RESULT" | "$JQ" -r '.reason')

case "$DECISION" in
    allow)
        exit 0
        ;;

    ask|deny)
        "$JQ" -n \
            --arg d "$DECISION" \
            --arg r "$REASON" \
            '{
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: $d,
                permissionDecisionReason: $r
              }
            }'
        exit 0
        ;;

    *)
        "$JQ" -n \
            --arg r "Invalid decision returned by shared file-policy evaluator." \
            '{
              hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: $r
              }
            }'
        exit 0
        ;;
esac
