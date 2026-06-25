#!/bin/bash
###
# PostToolUse Hook - Creates a tool span as child of current Turn
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PostToolUse hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
debug "PostToolUse input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
TOOL_OUTPUT=$(echo "$INPUT" | jq -c '.tool_response // .output // {}' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# Skip if no tool name
[ -z "$TOOL_NAME" ] && { debug "No tool name, skipping"; exit 0; }
[ -z "$SESSION_ID" ] && { debug "No session ID, skipping"; exit 0; }

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

# If no turn span exists, tools are orphaned - skip
if [ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    debug "No current turn for session $SESSION_ID, skipping tool trace"
    exit 0
fi

# Increment tool count for this turn
TOOL_COUNT=$(get_session_state "$SESSION_ID" "current_turn_tool_count")
TOOL_COUNT=${TOOL_COUNT:-0}
TOOL_COUNT=$((TOOL_COUNT + 1))
set_session_state "$SESSION_ID" "current_turn_tool_count" "$TOOL_COUNT"

# Generate span ID
SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
TOOL_TIME=$(date +%s)

# Determine span name based on tool
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

# Build the event - tool is child of Turn
EVENT=$(jq -n \
    --arg id "$SPAN_ID" \
    --arg span_id "$SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg parent "$TURN_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg tool "$TOOL_NAME" \
    --argjson input "$TOOL_INPUT" \
    --argjson output "$TOOL_OUTPUT" \
    --arg name "$SPAN_NAME" \
    --argjson start_time "$TOOL_TIME" \
    --argjson end_time "$TOOL_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$parent],
        created: $created,
        input: $input,
        output: $output,
        metrics: {
            start: $start_time,
            end: $end_time
        },
        metadata: {
            tool_name: $tool
        },
        span_attributes: {
            name: $name,
            type: "tool"
        }
    }')

ROW_ID=$(insert_span "$PROJECT_ID" "$EVENT") || { log "ERROR" "Failed to create tool span"; exit 0; }

log "INFO" "Tool: $SPAN_NAME (turn=$TURN_SPAN_ID)"

# --- Model-inferred skill capture (best-effort; must never abort the hook) ---
# When Claude invokes a skill itself (the "Skill" tool, no leading slash), stamp the
# same invoked_skill metadata onto the Turn span via a merge write, so skill-efficacy
# evals and audits see model-selected skills too -- not just user-typed slash commands.
# Uses the shared resolver in common.sh; source distinguishes the two paths. If a turn
# has several Skill calls, last-wins on the singular invoked_skill field.
if [ "$TOOL_NAME" = "Skill" ]; then
    SKILL_NAME=$(echo "$TOOL_INPUT" | jq -r '.skill // .name // .command // empty' 2>/dev/null) || SKILL_NAME=""
    if [ -n "$SKILL_NAME" ]; then
        CWD_FOR_SKILL=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD_FOR_SKILL=""
        INVOKED_SKILL_JSON=$(__bt_resolve_skill "$SKILL_NAME" "$CWD_FOR_SKILL" "model_inferred" 2>/dev/null) || INVOKED_SKILL_JSON=""
        echo "$INVOKED_SKILL_JSON" | jq empty >/dev/null 2>&1 || INVOKED_SKILL_JSON=""
        if [ -n "$INVOKED_SKILL_JSON" ]; then
            TURN_UPDATE=$(jq -n --arg id "$TURN_SPAN_ID" --argjson s "$INVOKED_SKILL_JSON" \
                '{id: $id, _is_merge: true, metadata: {invoked_skill: $s}}' 2>/dev/null) || TURN_UPDATE=""
            if [ -n "$TURN_UPDATE" ]; then
                insert_span "$PROJECT_ID" "$TURN_UPDATE" >/dev/null 2>&1 \
                    && log "INFO" "Model-inferred skill: $SKILL_NAME (turn=$TURN_SPAN_ID)" || true
            fi
        fi
    fi
fi
# --- end model-inferred skill capture ---

exit 0
