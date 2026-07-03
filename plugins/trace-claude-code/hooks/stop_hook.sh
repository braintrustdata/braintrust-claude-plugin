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
#
# Token accounting note / known ceiling:
#   Token counts are derived entirely from the transcript. For every request
#   that the transcript records, our totals match Claude Code's /usage exactly.
#   The exception is Claude Code's *internal background* model calls - chiefly
#   automatic session-title generation (and conversation summarization). These
#   are billed in /usage but the transcript stores only their result (e.g. an
#   `ai-title` line) with NO requestId, model, or usage, and no hook payload
#   carries their tokens. They are therefore unrecoverable, so an interactive
#   session's traced totals can read slightly below /usage (a small amount of
#   opus cache-read tokens). Non-interactive (-p) runs don't make these calls
#   and reconcile exactly. See README "token accounting".
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "Stop hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
record_hook_input "stop_hook" "$INPUT"
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

# The Stop event includes Claude's final assistant message directly in the
# payload, so we don't have to reconstruct it from the transcript.
# (See https://docs.claude.com/en/docs/claude-code/hooks -> Stop input)
LAST_ASSISTANT_MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)

# Get session state
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")
TURN_START=$(get_session_state "$SESSION_ID" "current_turn_start")

# Load experiment_id from session state if not already set
if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

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
CURRENT_OUTPUT_TEXT=""
CURRENT_TOOL_CALLS="[]"
CURRENT_MODEL=""
CURRENT_PROMPT_TOKENS=0
CURRENT_COMPLETION_TOKENS=0
CURRENT_CACHE_CREATION_TOKENS=0
CURRENT_CACHE_CREATION_5M_TOKENS=0
CURRENT_CACHE_CREATION_1H_TOKENS=0
CURRENT_CACHE_CREATION_MISSING_SPLIT=false
CURRENT_CACHE_READ_TOKENS=0
CURRENT_START_TIMESTAMP=""  # ISO timestamp when this LLM call started
CURRENT_END_TIMESTAMP=""    # ISO timestamp when this LLM call ended
LINE_NUM=0

# Claude Code writes one transcript line per content block (thinking, text,
# each tool_use) tagged with the same `requestId` for a single API response.
# Within a response, input/cache usage is repeated identically on every line,
# but `output_tokens` is reported CUMULATIVELY as the response streams (early
# lines hold partials, the final line holds the true total). A response can
# also straddle a tool_result boundary (the same requestId reappears after
# tool output).
#
# To count each response correctly we therefore:
#   - add input/cache exactly once per requestId (first sighting), and
#   - track the running MAX output per requestId, adding only the delta when a
#     larger value appears, so the total reflects the final (max) output.
#
# SEEN_REQUEST_IDS holds requestIds whose input/cache have been counted.
# REQUEST_OUTPUT_MAX maps "<rid>=<max_output_so_far>" so we can add deltas.
SEEN_REQUEST_IDS=" "
REQUEST_OUTPUT_MAX=" "

# Note: we deliberately do NOT write aggregate token metrics onto the Turn
# span. Token metrics live only on the leaf LLM spans (main-conversation and
# sub-agent), and Braintrust rolls those up to parent spans for display.
# Writing our own Turn-level sums here would be both redundant and incomplete
# (it would miss sub-agent tokens, which are emitted outside this loop).

# Accumulated conversation history (JSON array of messages)
CONVERSATION_HISTORY="[]"

# Add message to conversation history
add_to_history() {
    local role="$1"
    local content="$2"
    local tool_call_id="$3"
    local tool_calls="$4"

    if [ "$role" = "tool" ]; then
        CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg role "$role" --arg content "$content" --arg id "$tool_call_id" \
            '. += [{role: $role, tool_call_id: $id, content: $content}]')
    elif [ -n "$tool_calls" ] && [ "$tool_calls" != "[]" ]; then
        CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg role "$role" --arg content "$content" --argjson tc "$tool_calls" \
            '. += [{role: $role, content: $content, tool_calls: $tc}]')
    else
        CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg role "$role" --arg content "$content" \
            '. += [{role: $role, content: $content}]')
    fi
}

create_llm_span() {
    local output_text="$1"
    local model="$2"
    local prompt_tokens="$3"
    local completion_tokens="$4"
    local start_ts="$5"   # ISO timestamp
    local end_ts="$6"     # ISO timestamp
    local tool_calls_json="${7:-[]}"
    local input_history="$8"  # JSON array of conversation history
    local cache_creation_tokens="${9:-0}"
    local cache_read_tokens="${10:-0}"
    local cache_creation_5m_tokens="${11:-0}"
    local cache_creation_1h_tokens="${12:-0}"
    local cache_creation_missing_split="${13:-false}"

    # Need either text or tool_calls
    [ -z "$output_text" ] && [ "$tool_calls_json" = "[]" ] && return

    local span_id=$(generate_uuid)
    local use_cache_creation_split=false
    if [ "$cache_creation_missing_split" != "true" ]; then
        if [ "$cache_creation_5m_tokens" -gt 0 ] 2>/dev/null \
            || [ "$cache_creation_1h_tokens" -gt 0 ] 2>/dev/null; then
            use_cache_creation_split=true
        fi
    fi

    local effective_cache_creation_tokens="$cache_creation_tokens"
    if [ "$use_cache_creation_split" = "true" ]; then
        effective_cache_creation_tokens=$((cache_creation_5m_tokens + cache_creation_1h_tokens))
    fi
    local bt_prompt_tokens=$((prompt_tokens + cache_read_tokens + effective_cache_creation_tokens))
    local total_tokens=$((bt_prompt_tokens + completion_tokens))
    local start_time=$(_iso_to_epoch "$start_ts")
    local end_time=$(_iso_to_epoch "$end_ts")

    # Input is the conversation history up to this point
    local input_json="$input_history"

    # Format output - include tool_calls if present
    local output_json
    local has_tool_calls=$(echo "$tool_calls_json" | jq 'length > 0' 2>/dev/null)
    if [ "$has_tool_calls" = "true" ]; then
        output_json=$(jq -n \
            --arg content "${output_text:-}" \
            --argjson tool_calls "$tool_calls_json" \
            '{role: "assistant", content: $content, tool_calls: $tool_calls}')
    else
        output_json=$(jq -n --arg content "$output_text" '{role: "assistant", content: $content}')
    fi

    local event=$(jq -n \
        --arg id "$span_id" \
        --arg span_id "$span_id" \
        --arg root_span_id "$ROOT_SPAN_ID" \
        --arg parent "$TURN_SPAN_ID" \
        --arg created "${start_ts:-$(get_timestamp)}" \
        --argjson input "$input_json" \
        --argjson output "$output_json" \
        --arg model "${model:-claude}" \
        --argjson prompt_tokens "$prompt_tokens" \
        --argjson bt_prompt_tokens "$bt_prompt_tokens" \
        --argjson completion_tokens "$completion_tokens" \
        --argjson tokens "$total_tokens" \
        --argjson cache_creation_tokens "$cache_creation_tokens" \
        --argjson cache_read_tokens "$cache_read_tokens" \
        --argjson cache_creation_5m_tokens "$cache_creation_5m_tokens" \
        --argjson cache_creation_1h_tokens "$cache_creation_1h_tokens" \
        --argjson use_cache_creation_split "$use_cache_creation_split" \
        --argjson start_time "$start_time" \
        --argjson end_time "$end_time" \
        '{
            id: $id,
            span_id: $span_id,
            root_span_id: $root_span_id,
            span_parents: [$parent],
            created: $created,
            input: $input,
            output: $output,
            metrics: ({
                start: $start_time,
                end: $end_time,
                prompt_tokens: $bt_prompt_tokens,
                completion_tokens: $completion_tokens,
                tokens: $tokens,
                prompt_cached_tokens: $cache_read_tokens
            } + (
                if $use_cache_creation_split then
                    {
                        prompt_cache_creation_5m_tokens: $cache_creation_5m_tokens,
                        prompt_cache_creation_1h_tokens: $cache_creation_1h_tokens
                    }
                else
                    {prompt_cache_creation_tokens: $cache_creation_tokens}
                end
            )),
            metadata: {
                model: $model
            },
            span_attributes: {
                name: $model,
                type: "llm"
            }
        }')

    if enqueue_span "$SESSION_ID" "$PROJECT_ID" "$event"; then
        LLM_CALLS_CREATED=$((LLM_CALLS_CREATED + 1))
        log "INFO" "LLM span: $model tokens=$total_tokens (turn=$TURN_SPAN_ID)"
    fi
}

# Flush the pending assistant segment at a boundary (tool_result, real user
# message, or end of transcript).
#
# A single API response (one requestId) can span multiple tool_result
# boundaries: it emits a tool_use, gets a tool_result, then emits MORE
# tool_use blocks under the SAME requestId. Input/cache for that requestId
# are counted once and output is tracked as a running max, so every segment
# AFTER the first carries zero new tokens. Emitting a span for those
# continuation segments would create misleading all-zero-token LLM spans and
# split one logical response across several spans.
#
# To match the per-requestId grouping the sub-agent path uses, we only emit
# an LLM span when the pending segment actually accrued token metrics (its
# first sighting). Continuation segments are still recorded into the
# conversation history (so tool calls keep their context) but do not produce
# their own span.
flush_pending_llm() {
    [ -n "$CURRENT_OUTPUT_TEXT" ] || [ "$CURRENT_TOOL_CALLS" != "[]" ] || return 0

    if [ "$CURRENT_PROMPT_TOKENS" -gt 0 ] 2>/dev/null \
        || [ "$CURRENT_COMPLETION_TOKENS" -gt 0 ] 2>/dev/null \
        || [ "$CURRENT_CACHE_CREATION_TOKENS" -gt 0 ] 2>/dev/null \
        || [ "$CURRENT_CACHE_CREATION_5M_TOKENS" -gt 0 ] 2>/dev/null \
        || [ "$CURRENT_CACHE_CREATION_1H_TOKENS" -gt 0 ] 2>/dev/null \
        || [ "$CURRENT_CACHE_READ_TOKENS" -gt 0 ] 2>/dev/null; then
        create_llm_span "$CURRENT_OUTPUT_TEXT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_START_TIMESTAMP" "$CURRENT_END_TIMESTAMP" "$CURRENT_TOOL_CALLS" "$CONVERSATION_HISTORY" "$CURRENT_CACHE_CREATION_TOKENS" "$CURRENT_CACHE_READ_TOKENS" "$CURRENT_CACHE_CREATION_5M_TOKENS" "$CURRENT_CACHE_CREATION_1H_TOKENS" "$CURRENT_CACHE_CREATION_MISSING_SPLIT"
    fi

    # Always thread the assistant turn into history, whether or not a span
    # was emitted, so subsequent tool results / messages keep their context.
    add_to_history "assistant" "$CURRENT_OUTPUT_TEXT" "" "$CURRENT_TOOL_CALLS"
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
            # Tool result - flush any pending assistant segment first. This
            # emits an LLM span only if the segment accrued tokens (a fresh
            # requestId); continuation segments of an already-counted
            # requestId are folded into history without a separate span.
            flush_pending_llm

            # Extract tool result content and tool_use_id
            TOOL_RESULT_CONTENT=$(echo "$CONTENT" | jq -r '.[0].content // "tool result"' 2>/dev/null)
            TOOL_USE_ID=$(echo "$CONTENT" | jq -r '.[0].tool_use_id // ""' 2>/dev/null)

            # Add tool result to conversation history
            add_to_history "tool" "$TOOL_RESULT_CONTENT" "$TOOL_USE_ID" ""

            # Reset for next LLM call - DON'T set start timestamp yet
            # The next assistant message timestamp will be the actual LLM start
            CURRENT_OUTPUT_TEXT=""
            CURRENT_TOOL_CALLS="[]"
            CURRENT_MODEL=""
            CURRENT_PROMPT_TOKENS=0
            CURRENT_COMPLETION_TOKENS=0
            CURRENT_CACHE_CREATION_TOKENS=0
            CURRENT_CACHE_CREATION_5M_TOKENS=0
            CURRENT_CACHE_CREATION_1H_TOKENS=0
            CURRENT_CACHE_CREATION_MISSING_SPLIT=false
            CURRENT_CACHE_READ_TOKENS=0
            CURRENT_START_TIMESTAMP=""  # Will be set from first assistant message
            CURRENT_END_TIMESTAMP=""
        else
            # Real user message - flush any pending assistant segment first.
            flush_pending_llm

            # Add user message to conversation history
            add_to_history "user" "$CONTENT" "" ""

            # Reset for next LLM call
            CURRENT_OUTPUT_TEXT=""
            CURRENT_TOOL_CALLS="[]"
            CURRENT_MODEL=""
            CURRENT_PROMPT_TOKENS=0
            CURRENT_COMPLETION_TOKENS=0
            CURRENT_CACHE_CREATION_TOKENS=0
            CURRENT_CACHE_CREATION_5M_TOKENS=0
            CURRENT_CACHE_CREATION_1H_TOKENS=0
            CURRENT_CACHE_CREATION_MISSING_SPLIT=false
            CURRENT_CACHE_READ_TOKENS=0
            CURRENT_START_TIMESTAMP="$MSG_TIMESTAMP"
            CURRENT_END_TIMESTAMP=""
        fi

    elif [ "$MSG_TYPE" = "assistant" ]; then
        # Extract text content
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

        # Extract full tool_use objects for tool_calls
        TOOL_CALLS_JSON=$(echo "$line" | jq -c '
            .message.content
            | if type == "array" then
                [.[] | select(.type == "tool_use") | {
                    id: .id,
                    type: "function",
                    function: {
                        name: .name,
                        arguments: (.input | tojson)
                    }
                }]
              else
                []
              end
        ' 2>/dev/null)

        # Check if we have tool calls
        HAS_TOOL_CALLS=$(echo "$TOOL_CALLS_JSON" | jq 'length > 0' 2>/dev/null)

        # Set start timestamp from first assistant message of this LLM call
        [ -z "$CURRENT_START_TIMESTAMP" ] && CURRENT_START_TIMESTAMP="$MSG_TIMESTAMP"

        if [ -n "$TEXT" ]; then
            if [ -n "$CURRENT_OUTPUT_TEXT" ]; then
                CURRENT_OUTPUT_TEXT="$CURRENT_OUTPUT_TEXT"$'\n'"$TEXT"
            else
                CURRENT_OUTPUT_TEXT="$TEXT"
            fi
            CURRENT_END_TIMESTAMP="$MSG_TIMESTAMP"
        fi

        if [ "$HAS_TOOL_CALLS" = "true" ]; then
            CURRENT_TOOL_CALLS="$TOOL_CALLS_JSON"
            CURRENT_END_TIMESTAMP="$MSG_TIMESTAMP"
        fi

        # Extract model
        MODEL=$(echo "$line" | jq -r '.message.model // empty' 2>/dev/null)
        [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"

        # Extract tokens. A single API response repeats across multiple
        # content-block lines sharing one requestId. Input/cache are identical
        # on every line (count once); output_tokens streams cumulatively
        # (track the running max and add only deltas). Lines without a
        # requestId (rare) fall back to message id; if neither is present we
        # treat each line as its own request.
        REQUEST_ID=$(echo "$line" | jq -r '.requestId // .message.id // empty' 2>/dev/null)

        USAGE=$(echo "$line" | jq -c '.message.usage // {}' 2>/dev/null)
        if [ "$USAGE" != "{}" ] && [ -n "$USAGE" ]; then
            INPUT_TOKENS=$(echo "$USAGE" | jq -r '.input_tokens // 0' 2>/dev/null)
            OUTPUT_TOKENS=$(echo "$USAGE" | jq -r '.output_tokens // 0' 2>/dev/null)
            CACHE_CREATION=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
            CACHE_READ=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
            CACHE_CREATION_5M=$(echo "$USAGE" | jq -r '.cache_creation.ephemeral_5m_input_tokens // 0' 2>/dev/null)
            CACHE_CREATION_1H=$(echo "$USAGE" | jq -r '.cache_creation.ephemeral_1h_input_tokens // 0' 2>/dev/null)
            HAS_CACHE_CREATION_SPLIT=$(echo "$USAGE" | jq -r 'if ((.cache_creation? // null) | type) == "object" then "true" else "false" end' 2>/dev/null)
            [ "$INPUT_TOKENS" = "null" ] && INPUT_TOKENS=0
            [ "$OUTPUT_TOKENS" = "null" ] && OUTPUT_TOKENS=0
            [ "$CACHE_CREATION" = "null" ] && CACHE_CREATION=0
            [ "$CACHE_READ" = "null" ] && CACHE_READ=0
            [ "$CACHE_CREATION_5M" = "null" ] && CACHE_CREATION_5M=0
            [ "$CACHE_CREATION_1H" = "null" ] && CACHE_CREATION_1H=0
            [ "$HAS_CACHE_CREATION_SPLIT" = "null" ] && HAS_CACHE_CREATION_SPLIT=false

            # Determine whether input/cache for this requestId were already
            # counted, and fetch the prior max output for delta accounting.
            local_first_sighting=true
            prior_output=0
            if [ -n "$REQUEST_ID" ]; then
                case "$SEEN_REQUEST_IDS" in
                    *" $REQUEST_ID "*) local_first_sighting=false ;;
                    *) SEEN_REQUEST_IDS="${SEEN_REQUEST_IDS}${REQUEST_ID} " ;;
                esac
                # Look up the prior max output recorded for this requestId.
                case "$REQUEST_OUTPUT_MAX" in
                    *" ${REQUEST_ID}="*)
                        prior_output=${REQUEST_OUTPUT_MAX#*" ${REQUEST_ID}="}
                        prior_output=${prior_output%% *}
                        ;;
                esac
            fi

            # Input + cache: count once per requestId (constant across lines).
            if [ "$local_first_sighting" = "true" ]; then
                [ "$INPUT_TOKENS" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$((CURRENT_PROMPT_TOKENS + INPUT_TOKENS))
                [ "$CACHE_CREATION" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION_TOKENS=$((CURRENT_CACHE_CREATION_TOKENS + CACHE_CREATION))
                [ "$CACHE_READ" -gt 0 ] 2>/dev/null && CURRENT_CACHE_READ_TOKENS=$((CURRENT_CACHE_READ_TOKENS + CACHE_READ))
                [ "$CACHE_CREATION_5M" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION_5M_TOKENS=$((CURRENT_CACHE_CREATION_5M_TOKENS + CACHE_CREATION_5M))
                [ "$CACHE_CREATION_1H" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION_1H_TOKENS=$((CURRENT_CACHE_CREATION_1H_TOKENS + CACHE_CREATION_1H))
                if [ "$CACHE_CREATION" -gt 0 ] 2>/dev/null && [ "$HAS_CACHE_CREATION_SPLIT" != "true" ]; then
                    CURRENT_CACHE_CREATION_MISSING_SPLIT=true
                fi
            fi

            # Output: add only the increase over this requestId's prior max,
            # so the running total converges on the final (largest) value.
            if [ -z "$REQUEST_ID" ]; then
                # No requestId: treat as a standalone response.
                [ "$OUTPUT_TOKENS" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$((CURRENT_COMPLETION_TOKENS + OUTPUT_TOKENS))
            elif [ "$OUTPUT_TOKENS" -gt "$prior_output" ] 2>/dev/null; then
                CURRENT_COMPLETION_TOKENS=$((CURRENT_COMPLETION_TOKENS + OUTPUT_TOKENS - prior_output))
                # Record the new max for this requestId. Use an intermediate
                # variable for the pattern: nesting double-quotes inside the
                # ${var//pat/repl} expansion does NOT produce the intended
                # pattern and instead corrupts REQUEST_OUTPUT_MAX, so on the
                # next sighting the prior max can't be found and the full
                # output gets re-added as a bogus delta.
                _rom_pat=" ${REQUEST_ID}=${prior_output} "
                REQUEST_OUTPUT_MAX="${REQUEST_OUTPUT_MAX//$_rom_pat/ }"
                REQUEST_OUTPUT_MAX="${REQUEST_OUTPUT_MAX}${REQUEST_ID}=${OUTPUT_TOKENS} "
            fi
        fi
    fi
done < "$CONV_FILE"

# Save final LLM call (same zero-token suppression as the boundary flushes).
flush_pending_llm

# Update the Turn span with its end time and Claude's final response via a
# merge write. The merge keeps the existing fields (input, name, type) set
# when user_prompt_submit.sh created the Turn span. We intentionally do NOT
# write token metrics here: token metrics live only on the leaf LLM spans,
# and Braintrust aggregates them onto parents (Turn, session) for display.
END_TIME=$(date +%s)

TURN_UPDATE=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --arg output "$LAST_ASSISTANT_MESSAGE" \
    --argjson end_time "$END_TIME" \
    '{
        id: $id,
        _is_merge: true,
        output: $output,
        metrics: {
            end: $end_time
        }
    }')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$TURN_UPDATE" || true

# Update state
set_session_state "$SESSION_ID" "turn_last_line" "$TOTAL_LINES"
set_session_state "$SESSION_ID" "current_turn_span_id" ""
set_session_state "$SESSION_ID" "current_turn_explicit_skill_names" "[]"

[ "$LLM_CALLS_CREATED" -gt 0 ] && log "INFO" "Created $LLM_CALLS_CREATED LLM spans for turn"
log "INFO" "Turn finalized (end=$END_TIME)"

exit 0
