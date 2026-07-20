#!/bin/bash
###
# PermissionDenied Hook - Creates a denied tool span when tied to a tool request
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PermissionDenied hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
record_hook_input "permission_denied" "$INPUT"
debug "PermissionDenied input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // .input // {}' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_CALL_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
PERMISSION_ID=$(echo "$INPUT" | jq -r '.permission_id // .permission.id // empty' 2>/dev/null)
PERMISSION_TYPE=$(echo "$INPUT" | jq -r '.permission_type // .permission.type // empty' 2>/dev/null)
PERMISSION_TITLE=$(echo "$INPUT" | jq -r '.permission_title // .permission.title // empty' 2>/dev/null)

[ -z "$TOOL_NAME" ] && { debug "No tool name, skipping"; exit 0; }
[ -z "$SESSION_ID" ] && { debug "No session ID, skipping"; exit 0; }

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

if [ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    debug "No current turn for session $SESSION_ID, skipping denied tool trace"
    exit 0
fi

SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
TOOL_TIME=$(date +%s)

case "$TOOL_NAME" in
    Bash|Terminal)
        CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null | head -c 50)
        SPAN_NAME="Terminal: ${CMD:-command}"
        ;;
    *)
        SPAN_NAME="$TOOL_NAME"
        ;;
esac

EVENT=$(jq -n \
    --arg id "$SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg parent "$TURN_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --argjson input "$TOOL_INPUT" \
    --arg name "$SPAN_NAME" \
    --arg tool "$TOOL_NAME" \
    --arg tool_call_id "$TOOL_CALL_ID" \
    --arg permission_id "$PERMISSION_ID" \
    --arg permission_type "$PERMISSION_TYPE" \
    --arg permission_title "$PERMISSION_TITLE" \
    --argjson start_time "$TOOL_TIME" \
    --argjson end_time "$TOOL_TIME" \
    '{
        id: $id,
        span_id: $id,
        root_span_id: $root_span_id,
        span_parents: [$parent],
        created: $created,
        input: $input,
        metrics: {start: $start_time, end: $end_time},
        metadata: ({
            tool_name: $tool,
            tool_approval: "denied"
        }
        + (if $tool_call_id != "" then {tool_call_id: $tool_call_id} else {} end)
        + (if $permission_id != "" then {permission_id: $permission_id} else {} end)
        + (if $permission_type != "" then {permission_type: $permission_type} else {} end)
        + (if $permission_title != "" then {permission_title: $permission_title} else {} end)),
        span_attributes: {name: $name, type: "tool"}
    }')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || { log "ERROR" "Failed to enqueue denied tool span"; exit 0; }

log "INFO" "Denied tool: $SPAN_NAME (turn=$TURN_SPAN_ID)"
exit 0
