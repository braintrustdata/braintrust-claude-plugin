#!/bin/bash
###
# UserPromptExpansion Hook - Captures explicit Claude slash skill requests.
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
record_hook_input "UserPromptExpansion" "$INPUT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

EXPANSION_TYPE=$(echo "$INPUT" | jq -r '.expansion_type // .type // empty' 2>/dev/null)
if [ -n "$EXPANSION_TYPE" ] && [ "$EXPANSION_TYPE" != "slash_command" ]; then
    exit 0
fi

_normalize_skill_name() {
    echo "$1" | sed 's#^/##' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/[),.;:]*$//'
}

_skill_listing_contains() {
    local transcript="$1"
    local name="$2"
    [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
    jq -e --arg name "$name" '
        select(.attachment.type == "skill_listing")
        | .attachment.names[]?
        | select(. == $name)
    ' "$transcript" >/dev/null 2>&1
}

SKILL_NAME=$(echo "$INPUT" | jq -r '
    .skill_name
    // .skillName
    // .skill.name
    // .skill
    // empty
' 2>/dev/null)

if [ -z "$SKILL_NAME" ]; then
    COMMAND_NAME=$(echo "$INPUT" | jq -r '.command_name // .command // .slash_command // .name // empty' 2>/dev/null)
    COMMAND_NAME=$(_normalize_skill_name "$COMMAND_NAME")
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    if [ -n "$COMMAND_NAME" ] && _skill_listing_contains "$TRANSCRIPT_PATH" "$COMMAND_NAME"; then
        SKILL_NAME="$COMMAND_NAME"
    fi
fi

SKILL_NAME=$(_normalize_skill_name "$SKILL_NAME")
[ -z "$SKILL_NAME" ] && exit 0

EXISTING=$(get_session_state "$SESSION_ID" "current_turn_explicit_skill_names")
[ -z "$EXISTING" ] && EXISTING="[]"

NAMES_JSON=$(jq -nc --argjson existing "$EXISTING" --arg name "$SKILL_NAME" '
    ($existing + [$name])
    | reduce .[] as $name ([]; if index($name) then . else . + [$name] end)
' 2>/dev/null || jq -nc --arg name "$SKILL_NAME" '[$name]')

set_session_state "$SESSION_ID" "current_turn_explicit_skill_names" "$NAMES_JSON"

TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -n "$TURN_SPAN_ID" ] && [ -n "$PROJECT_ID" ] || exit 0

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")

EVENT=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --argjson names "$NAMES_JSON" \
    '{
        id: $id,
        _is_merge: true,
        metadata: {
            loaded_skill_names: $names,
            loaded_skills: ($names | map({name: .}))
        }
    }')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || true

log "INFO" "Explicit skill request: $SKILL_NAME (turn=$TURN_SPAN_ID root=$ROOT_SPAN_ID)"

exit 0
