#!/bin/bash
set -euo pipefail

INPUT=$(cat /dev/stdin)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
JQ="${JQ:-jq}"

COMMAND=$(
    printf '%s' "$INPUT" |
    "$JQ" -r '.tool_input.command // empty'
)

[ -z "$COMMAND" ] && exit 0

EVALUATOR="$PROJECT_DIR/policies/evaluate-command.py"

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

if [ ! -x "$EVALUATOR" ]; then
    deny_closed "Shared command-policy evaluator is unavailable: $EVALUATOR"
fi

if ! RESULT=$("$EVALUATOR" "$COMMAND"); then
    deny_closed "Shared command-policy evaluator failed."
fi

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
        deny_closed "Invalid decision returned by shared command-policy evaluator."
        ;;
esac
