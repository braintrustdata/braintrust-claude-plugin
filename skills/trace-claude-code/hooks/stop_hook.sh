#!/bin/bash
###
# Stop Hook - Creates LLM spans for each model call within the Turn
#
# Structure:
#   Session (task)
#   ├── Turn 1 (task) - created by UserPromptSubmit
#   │   ├── claude-sonnet... (llm) - first model call (plan + tool_use)
#   │   ├── Tool 1 (tool) - created by PostToolUse
#   │   ├── Tool 2 (tool) - created by PostToolUse
#   │   └── claude-sonnet... (llm) - second model call (after tools)
#   └── Turn 2 (task)
#       └── ...
#
# Each assistant message block = one LLM call
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "Stop hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
debug "Stop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Get session ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    if [ -n "$TRANSCRIPT_PATH" ]; then
        SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
    fi
fi

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Get session state
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")
TURN_START=$(get_session_state "$SESSION_ID" "current_turn_start")

if [ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    debug "No current turn to finalize"
    exit 0
fi

# Find the conversation file
CONV_FILE=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ]; then
    SESSIONS_DIR="$HOME/.claude/projects"
    CONV_FILE=$(find "$SESSIONS_DIR" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
fi

[ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ] && { debug "No conversation file"; exit 0; }

debug "Processing transcript: $CONV_FILE"

# Get last processed line for this turn
TURN_LAST_LINE=$(get_session_state "$SESSION_ID" "turn_last_line")
TURN_LAST_LINE=${TURN_LAST_LINE:-0}

TOTAL_LINES=$(wc -l < "$CONV_FILE" | tr -d ' ')

# Process the transcript to find LLM calls
# An LLM call = assistant message(s) that follow a user message or tool_result
LLM_CALLS_CREATED=0
CURRENT_INPUT=""
CURRENT_INPUT_TYPE=""  # "user" or "tool_result"
CURRENT_OUTPUT=""
CURRENT_MODEL=""
CURRENT_PROMPT_TOKENS=0
CURRENT_COMPLETION_TOKENS=0
CURRENT_TIMESTAMP=""
LINE_NUM=0

create_llm_span() {
    local input_content="$1"
    local output_content="$2"
    local model="$3"
    local prompt_tokens="$4"
    local completion_tokens="$5"
    local timestamp="$6"
    local input_type="$7"

    [ -z "$output_content" ] && return

    local span_id=$(generate_uuid)
    local total_tokens=$((prompt_tokens + completion_tokens))
    local end_time=$(date +%s)
    local start_time=${TURN_START:-$end_time}

    # Format input based on type
    local input_json
    if [ "$input_type" = "tool_result" ]; then
        input_json=$(jq -n --arg content "$input_content" '[{"role": "user", "content": [{"type": "tool_result", "content": $content}]}]')
    else
        input_json=$(jq -n --arg content "$input_content" '[{"role": "user", "content": $content}]')
    fi

    local event=$(jq -n \
        --arg id "$span_id" \
        --arg span_id "$span_id" \
        --arg root_span_id "$ROOT_SPAN_ID" \
        --arg parent "$TURN_SPAN_ID" \
        --arg created "${timestamp:-$(get_timestamp)}" \
        --argjson input "$input_json" \
        --arg output "$output_content" \
        --arg model "${model:-claude}" \
        --argjson prompt_tokens "$prompt_tokens" \
        --argjson completion_tokens "$completion_tokens" \
        --argjson tokens "$total_tokens" \
        --argjson start_time "$start_time" \
        --argjson end_time "$end_time" \
        '{
            id: $id,
            span_id: $span_id,
            root_span_id: $root_span_id,
            span_parents: [$parent],
            created: $created,
            input: $input,
            output: {
                "role": "assistant",
                "content": $output
            },
            metrics: {
                start: $start_time,
                end: $end_time,
                prompt_tokens: $prompt_tokens,
                completion_tokens: $completion_tokens,
                tokens: $tokens
            },
            metadata: {
                model: $model
            },
            span_attributes: {
                name: $model,
                type: "llm"
            }
        }')

    insert_span "$PROJECT_ID" "$event" >/dev/null && {
        LLM_CALLS_CREATED=$((LLM_CALLS_CREATED + 1))
        log "INFO" "LLM span: $model tokens=$total_tokens (turn=$TURN_SPAN_ID)"
    } || true
}

while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    [ "$LINE_NUM" -le "$TURN_LAST_LINE" ] && continue
    [ -z "$line" ] && continue

    MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    MSG_TIMESTAMP=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)

    if [ "$MSG_TYPE" = "user" ]; then
        # Check if tool_result or real user message
        CONTENT=$(echo "$line" | jq -r '.message.content // empty' 2>/dev/null)
        IS_TOOL_RESULT=$(echo "$CONTENT" | jq -e '.[0].type == "tool_result"' >/dev/null 2>&1 && echo "true" || echo "false")

        if [ "$IS_TOOL_RESULT" = "true" ]; then
            # Tool result - if we have pending output, save it first
            if [ -n "$CURRENT_OUTPUT" ]; then
                create_llm_span "$CURRENT_INPUT" "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_TIMESTAMP" "$CURRENT_INPUT_TYPE"
            fi

            # Extract tool result content for next LLM call's input
            TOOL_RESULT_CONTENT=$(echo "$CONTENT" | jq -r '.[0].content // "tool result"' 2>/dev/null)
            CURRENT_INPUT="$TOOL_RESULT_CONTENT"
            CURRENT_INPUT_TYPE="tool_result"
            CURRENT_OUTPUT=""
            CURRENT_MODEL=""
            CURRENT_PROMPT_TOKENS=0
            CURRENT_COMPLETION_TOKENS=0
            CURRENT_TIMESTAMP="$MSG_TIMESTAMP"
        else
            # Real user message - if we have pending output, save it
            if [ -n "$CURRENT_OUTPUT" ]; then
                create_llm_span "$CURRENT_INPUT" "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_TIMESTAMP" "$CURRENT_INPUT_TYPE"
            fi

            # Start tracking new LLM call
            CURRENT_INPUT="$CONTENT"
            CURRENT_INPUT_TYPE="user"
            CURRENT_OUTPUT=""
            CURRENT_MODEL=""
            CURRENT_PROMPT_TOKENS=0
            CURRENT_COMPLETION_TOKENS=0
            CURRENT_TIMESTAMP="$MSG_TIMESTAMP"
        fi

    elif [ "$MSG_TYPE" = "assistant" ]; then
        # Extract text content (skip tool_use blocks)
        TEXT=$(echo "$line" | jq -r '
            .message.content
            | if type == "array" then
                [.[] | select(.type == "text") | .text] | join("\n")
              elif type == "string" then
                .
              else
                empty
              end
        ' 2>/dev/null)

        if [ -n "$TEXT" ]; then
            if [ -n "$CURRENT_OUTPUT" ]; then
                CURRENT_OUTPUT="$CURRENT_OUTPUT"$'\n'"$TEXT"
            else
                CURRENT_OUTPUT="$TEXT"
            fi
        fi

        # Extract model
        MODEL=$(echo "$line" | jq -r '.message.model // empty' 2>/dev/null)
        [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"

        # Extract tokens
        USAGE=$(echo "$line" | jq -c '.message.usage // {}' 2>/dev/null)
        if [ "$USAGE" != "{}" ] && [ -n "$USAGE" ]; then
            INPUT_TOKENS=$(echo "$USAGE" | jq -r '.input_tokens // 0' 2>/dev/null)
            OUTPUT_TOKENS=$(echo "$USAGE" | jq -r '.output_tokens // 0' 2>/dev/null)
            [ "$INPUT_TOKENS" != "null" ] && [ "$INPUT_TOKENS" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$((CURRENT_PROMPT_TOKENS + INPUT_TOKENS))
            [ "$OUTPUT_TOKENS" != "null" ] && [ "$OUTPUT_TOKENS" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$((CURRENT_COMPLETION_TOKENS + OUTPUT_TOKENS))
        fi
    fi
done < "$CONV_FILE"

# Save final LLM call
if [ -n "$CURRENT_OUTPUT" ]; then
    create_llm_span "$CURRENT_INPUT" "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_TIMESTAMP" "$CURRENT_INPUT_TYPE"
fi

# Update state
set_session_state "$SESSION_ID" "turn_last_line" "$TOTAL_LINES"
set_session_state "$SESSION_ID" "current_turn_span_id" ""

[ "$LLM_CALLS_CREATED" -gt 0 ] && log "INFO" "Created $LLM_CALLS_CREATED LLM spans for turn"
log "INFO" "Turn finalized"

exit 0
