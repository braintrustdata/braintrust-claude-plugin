#!/bin/bash
###
# PostToolUseFailure Hook - Creates a failed tool span as child of current Turn
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PostToolUseFailure hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
record_hook_input "post_tool_use_failure" "$INPUT"
debug "PostToolUseFailure input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // .input // {}' 2>/dev/null)
TOOL_OUTPUT=$(echo "$INPUT" | jq -c '.tool_response // .output // {}' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_CALL_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
TOOL_ERROR=$(echo "$INPUT" | jq -r '
    .error
    // .message
    // .tool_response.error
    // .tool_response.stderr
    // .tool_response.message
    // "Tool execution failed"
' 2>/dev/null | head -n 1)

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
    debug "No current turn for session $SESSION_ID, skipping failed tool trace"
    exit 0
fi

TOOL_COUNT=$(get_session_state "$SESSION_ID" "current_turn_tool_count")
TOOL_COUNT=${TOOL_COUNT:-0}
TOOL_COUNT=$((TOOL_COUNT + 1))
set_session_state "$SESSION_ID" "current_turn_tool_count" "$TOOL_COUNT"

SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
TOOL_TIME=$(date +%s)

case "$TOOL_NAME" in
    Read|Write|Edit|MultiEdit)
        FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
        if [ -n "$FILE_PATH" ]; then
            SPAN_NAME="$TOOL_NAME: $(basename "$FILE_PATH")"
        else
            SPAN_NAME="$TOOL_NAME"
        fi
        ;;
    Bash|Terminal)
        CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null | head -c 50)
        SPAN_NAME="Terminal: ${CMD:-command}"
        ;;
    mcp__*)
        SPAN_NAME=$(echo "$TOOL_NAME" | sed 's/mcp__/MCP: /' | sed 's/__/ - /')
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
    --argjson output "$TOOL_OUTPUT" \
    --arg name "$SPAN_NAME" \
    --arg tool "$TOOL_NAME" \
    --arg tool_call_id "$TOOL_CALL_ID" \
    --arg tool_error "$TOOL_ERROR" \
    --argjson start_time "$TOOL_TIME" \
    --argjson end_time "$TOOL_TIME" \
    '{
        id: $id,
        span_id: $id,
        root_span_id: $root_span_id,
        span_parents: [$parent],
        created: $created,
        input: $input,
        output: $output,
        error: $tool_error,
        metrics: {start: $start_time, end: $end_time},
        metadata: ({
            tool_name: $tool,
            tool_approval: "approved"
        } + (if $tool_call_id != "" then {tool_call_id: $tool_call_id} else {} end)),
        span_attributes: {name: $name, type: "tool"}
    }')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || { log "ERROR" "Failed to enqueue failed tool span"; exit 0; }

log "INFO" "Failed tool: $SPAN_NAME (turn=$TURN_SPAN_ID)"
exit 0
