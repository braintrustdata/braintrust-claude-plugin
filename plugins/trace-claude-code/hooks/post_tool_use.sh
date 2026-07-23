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
record_hook_input "post_tool_use" "$INPUT"
debug "PostToolUse input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
TOOL_OUTPUT=$(echo "$INPUT" | jq -c '.tool_response // .output // {}' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_CALL_ID=$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null)
TOOL_FAILED=$(echo "$INPUT" | jq -r '
    if ((.tool_response.interrupted // false) == true
        or (.tool_response.is_error // false) == true
        or (.tool_response.isError // false) == true
        or (.tool_response.status // "") == "error"
        or (.tool_response.status // "") == "failed"
        or (.tool_response.error != null)) then
        true
    else
        false
    end
' 2>/dev/null)
if [ "$TOOL_FAILED" != "true" ]; then
    TOOL_FAILED=false
fi
TOOL_ERROR=$(echo "$INPUT" | jq -r '
    .tool_response.error
    // .tool_response.stderr
    // .tool_response.message
    // .tool_response.output
    // "Tool execution failed"
' 2>/dev/null | head -n 1)

# Skip if no tool name
[ -z "$TOOL_NAME" ] && { debug "No tool name, skipping"; exit 0; }
[ -z "$SESSION_ID" ] && { debug "No session ID, skipping"; exit 0; }

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")

# Load experiment_id from session state if not already set
if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

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
METADATA_TOOL_NAME="$TOOL_NAME"
IS_SKILL_TOOL=false
SKILL_NAME=""
SKILL_LOAD_TRIGGER=""
case "$TOOL_NAME" in
    Skill)
        IS_SKILL_TOOL=true
        SKILL_NAME=$(echo "$TOOL_INPUT" | jq -r '.name // .skill // .skill_name // .skillName // empty' 2>/dev/null)
        EXPLICIT_SKILL_NAMES=$(get_session_state "$SESSION_ID" "current_turn_explicit_skill_names")
        if [ -n "$SKILL_NAME" ] && [ -n "$EXPLICIT_SKILL_NAMES" ] && \
            echo "$EXPLICIT_SKILL_NAMES" | jq -e --arg name "$SKILL_NAME" 'index($name) != null' >/dev/null 2>&1; then
            SKILL_LOAD_TRIGGER="explicit"
        fi
        if [ -n "$SKILL_NAME" ]; then
            SPAN_NAME="skill: $SKILL_NAME"
        else
            SPAN_NAME="skill"
        fi
        ;;
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
    --arg metadata_tool "$METADATA_TOOL_NAME" \
    --arg tool_call_id "$TOOL_CALL_ID" \
    --arg tool_error "$TOOL_ERROR" \
    --argjson tool_failed "$TOOL_FAILED" \
    --arg skill_name "$SKILL_NAME" \
    --arg skill_load_trigger "$SKILL_LOAD_TRIGGER" \
    --argjson is_skill_tool "$IS_SKILL_TOOL" \
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
        metadata: ({
            tool_name: $metadata_tool,
            tool_approval: "approved"
        }
        + (if $tool_call_id != "" then {tool_call_id: $tool_call_id} else {} end)
        + (if $is_skill_tool then {
            tool_kind: "skill",
            skill_name: (if $skill_name != "" then $skill_name else null end)
        } else {} end)
        + (if $skill_load_trigger != "" then {skill_load_trigger: $skill_load_trigger} else {} end)),
        span_attributes: {
            name: $name,
            type: "tool"
        }
    }
    + (if $tool_failed then {error: $tool_error} else {} end)')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || { log "ERROR" "Failed to enqueue tool span"; exit 0; }

log "INFO" "Tool: $SPAN_NAME (turn=$TURN_SPAN_ID)"

# For Agent (sub-agent) tool calls, surface the sub-agent's own model calls
# (e.g. claude-haiku-4-5) as LLM spans nested under this Agent tool span.
# Claude Code writes each sub-agent's conversation to its own transcript at
#   <projects_dir>/<session_id>/subagents/agent-<agentId>.jsonl
# which we derive from the main transcript_path + the agentId in the tool
# response. We do this in PostToolUse (not SubagentStop) because SubagentStop
# fires *before* PostToolUse, so the Agent tool span does not exist yet then.
if [ "$TOOL_NAME" = "Agent" ]; then
    AGENT_ID=$(echo "$TOOL_OUTPUT" | jq -r '.agentId // .agent_id // empty' 2>/dev/null)
    MAIN_TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

    if [ -n "$AGENT_ID" ] && [ -n "$MAIN_TRANSCRIPT" ]; then
        TRANSCRIPT_DIR=$(dirname "$MAIN_TRANSCRIPT")
        SESSION_BASENAME=$(basename "$MAIN_TRANSCRIPT" .jsonl)
        AGENT_FILE_NAME="agent-${AGENT_ID}.jsonl"

        # Candidate locations, in priority order:
        #   1. Live layout: <dir>/<session>/subagents/agent-<id>.jsonl
        #   2. Replay/flat layout: <dir>/agent-<id>.jsonl  (record_hook_input
        #      snapshots agent transcripts flat next to the main one, and
        #      replay rewrites transcript_path into that flat transcripts/ dir)
        AGENT_TRANSCRIPT=""
        for candidate in \
            "$TRANSCRIPT_DIR/$SESSION_BASENAME/subagents/$AGENT_FILE_NAME" \
            "$TRANSCRIPT_DIR/$AGENT_FILE_NAME"; do
            if [ -f "$candidate" ]; then
                AGENT_TRANSCRIPT="$candidate"
                break
            fi
        done

        if [ -n "$AGENT_TRANSCRIPT" ]; then
            N_LLM=$(emit_llm_spans_from_transcript \
                "$AGENT_TRANSCRIPT" "$SESSION_ID" "$PROJECT_ID" \
                "$ROOT_SPAN_ID" "$SPAN_ID")
            log "INFO" "Sub-agent $AGENT_ID: emitted ${N_LLM:-0} LLM spans under $SPAN_NAME"
        else
            debug "Agent transcript not found for agent_id=$AGENT_ID (looked under $TRANSCRIPT_DIR)"
        fi
    fi
fi

exit 0
