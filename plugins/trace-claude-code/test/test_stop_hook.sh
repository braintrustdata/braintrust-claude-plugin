#!/bin/bash
###
# End-to-end tests for the Stop hook.
#
# Stop fires when Claude finishes responding to a user turn. It:
#   - Reads $LAST_ASSISTANT_MESSAGE from the hook input (Claude's final
#     response text) and uses it as the Turn span's `output` field
#   - Parses the conversation transcript to emit per-LLM-call spans and
#     to aggregate turn-level token totals
#   - Emits a TURN_UPDATE merge to populate the Turn span's output and
#     metrics fields, finalizing the turn
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

_setup_default_stubs() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_test"}'
    stub_response_for "*/v1/project_logs/*/insert"  200 '{"row_ids":["row_1"]}'
}

# Set up session + turn so stop_hook has a current turn to finalize.
_with_turn_started() {
    local session_id="$1"
    _setup_default_stubs
    run_hook session_start.sh "$(fixture_session_start "$session_id" "/tmp/x")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$session_id" "do something")"
    : > "$CAPTURED_REQUESTS"
}

# Write a minimal empty transcript file. The hook will read it, find no
# assistant messages, and skip straight to emitting the TURN_UPDATE merge.
_empty_transcript() {
    local path="$1"
    : > "$path"
    echo "$path"
}

# ---------------------------------------------------------------------------
describe "stop_hook.sh: populates Turn output from last_assistant_message"
# ---------------------------------------------------------------------------

t_stop_sets_turn_output() {
    _with_turn_started "stop-out-1"
    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")

    local payload
    payload=$(fixture_stop "stop-out-1" "$transcript" "Here is my answer.")
    run_hook stop_hook.sh "$payload"
    assert_success "$HOOK_STATUS"

    # The hook should have emitted one TURN_UPDATE merge span. Find it.
    local span
    span=$(all_spans | jq '.[] | select(._is_merge == true)' | jq -s '.[0]')
    assert_ne "$span" "null" "expected a merge span to be emitted"

    local output
    output=$(echo "$span" | jq -r '.output')
    assert_eq "$output" "Here is my answer."
}

t_stop_output_empty_when_message_missing() {
    # If Claude Code doesn't supply last_assistant_message, the output
    # field should be empty (rather than e.g. "null" or undefined).
    _with_turn_started "stop-out-2"
    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")

    # Build a payload without last_assistant_message
    local payload
    payload=$(jq -nc --arg s "stop-out-2" --arg t "$transcript" \
        '{session_id: $s, transcript_path: $t}')
    run_hook stop_hook.sh "$payload"
    assert_success "$HOOK_STATUS"

    local span
    span=$(all_spans | jq '.[] | select(._is_merge == true)' | jq -s '.[0]')
    local output
    output=$(echo "$span" | jq -r '.output')
    assert_eq "$output" ""
}

t_stop_turn_update_has_correct_id() {
    # The merge should target the current_turn_span_id stored at
    # user_prompt_submit time, not a freshly-generated id.
    _with_turn_started "stop-id-1"
    local turn_id
    turn_id=$(get_session_state "stop-id-1" "current_turn_span_id")
    assert_ne "$turn_id" ""

    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")
    run_hook stop_hook.sh "$(fixture_stop "stop-id-1" "$transcript" "msg")"

    local span
    span=$(all_spans | jq '.[] | select(._is_merge == true)' | jq -s '.[0]')
    local span_id
    span_id=$(echo "$span" | jq -r '.id')
    assert_eq "$span_id" "$turn_id"
}

t_stop_merge_flag_is_set() {
    # Sanity check that we send `_is_merge: true` so Braintrust doesn't
    # try to create a brand-new span (which would orphan the original
    # Turn span's children).
    _with_turn_started "stop-merge-1"
    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")
    run_hook stop_hook.sh "$(fixture_stop "stop-merge-1" "$transcript" "msg")"

    local merges
    merges=$(all_spans | jq '[.[] | select(._is_merge == true)] | length')
    assert_eq "$merges" "1"
}

t_stop_merge_has_end_time_no_tokens() {
    # The Turn merge should carry an end time but NO token metrics: token
    # metrics live only on the leaf LLM spans, and Braintrust aggregates
    # them onto parent spans for display. Writing Turn-level token sums here
    # would be redundant and would miss sub-agent tokens.
    _with_turn_started "stop-metrics-1"
    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")
    run_hook stop_hook.sh "$(fixture_stop "stop-metrics-1" "$transcript" "ok")"

    local span
    span=$(all_spans | jq '.[] | select(._is_merge == true)' | jq -s '.[0]')

    # end is a unix timestamp - should be a positive integer
    local end_time
    end_time=$(echo "$span" | jq -r '.metrics.end')
    if [ "$end_time" -le 0 ] 2>/dev/null; then
        fail "expected positive end time, got $end_time"
    fi

    # No token metrics should be present on the merge.
    assert_eq "$(echo "$span" | jq -r '.metrics.prompt_tokens // "absent"')"     "absent" "no prompt_tokens on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.completion_tokens // "absent"')" "absent" "no completion_tokens on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.tokens // "absent"')"            "absent" "no tokens on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.prompt_cached_tokens // "absent"')" "absent" "no cache_read on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.prompt_cache_creation_tokens // "absent"')" "absent" "no cache_creation on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.prompt_cache_creation_5m_tokens // "absent"')" "absent" "no cache_creation_5m on Turn merge"
    assert_eq "$(echo "$span" | jq -r '.metrics.prompt_cache_creation_1h_tokens // "absent"')" "absent" "no cache_creation_1h on Turn merge"
}

# ---------------------------------------------------------------------------
describe "stop_hook.sh: streaming output_tokens are not double-counted"
# ---------------------------------------------------------------------------

# Build a single assistant transcript line for one requestId, carrying the
# given cumulative output_tokens in message.usage. input/cache are held
# constant across lines (as Claude Code reports them) so only the output
# delta logic is exercised.
_assistant_line() {
    local request_id="$1"
    local output_tokens="$2"
    local text="$3"
    jq -nc \
        --arg rid "$request_id" \
        --arg text "$text" \
        --argjson out "$output_tokens" \
        '{
            type: "assistant",
            requestId: $rid,
            timestamp: "2024-01-01T00:00:00.000Z",
            message: {
                model: "claude-test",
                content: [{type: "text", text: $text}],
                usage: {
                    input_tokens: 10,
                    cache_creation_input_tokens: 0,
                    cache_read_input_tokens: 0,
                    output_tokens: $out
                }
            }
        }'
}

t_stop_streaming_output_not_double_counted() {
    # A single API response streams output_tokens cumulatively across its
    # transcript lines (e.g. 5 -> 30 -> 40). The hook tracks the running max
    # per requestId and should add only deltas, so the emitted LLM span's
    # completion_tokens must equal the FINAL value (40), not the sum of all
    # reported values (5 + 30 + 40 = 75) nor a partial double-count (70).
    #
    # This requires THREE OR MORE increasing lines on one requestId: the
    # two-line case happens to be correct, which is why earlier fixtures
    # (constant output_tokens per requestId) did not catch this.
    _with_turn_started "stop-stream-1"

    local transcript="$TEST_TMP/transcript.jsonl"
    {
        _assistant_line "req_stream" 5  "partial one"
        _assistant_line "req_stream" 30 "partial two"
        _assistant_line "req_stream" 40 "final answer"
    } > "$transcript"

    run_hook stop_hook.sh "$(fixture_stop "stop-stream-1" "$transcript" "final answer")"
    assert_success "$HOOK_STATUS"

    # Exactly one LLM span should be emitted for this single response.
    local llm_spans
    llm_spans=$(all_spans | jq '[.[] | select(.span_attributes.type == "llm")]')
    assert_eq "$(echo "$llm_spans" | jq 'length')" "1" "expected exactly one LLM span"

    local completion
    completion=$(echo "$llm_spans" | jq -r '.[0].metrics.completion_tokens')
    assert_eq "$completion" "40" "completion_tokens should be the final max, not a re-added full output"

    # Input is counted once per requestId, so prompt_tokens stays at 10.
    local prompt
    prompt=$(echo "$llm_spans" | jq -r '.[0].metrics.prompt_tokens')
    assert_eq "$prompt" "10" "prompt_tokens should be counted once per requestId"
}

# ---------------------------------------------------------------------------
describe "stop_hook.sh: one LLM span per requestId across tool_result boundaries"
# ---------------------------------------------------------------------------

# Assistant line carrying a single tool_use block plus usage, for the given
# requestId. Output/input tokens are held constant across the requestId's
# lines (as Claude Code reports them for non-streamed usage).
_assistant_tool_use_line() {
    local request_id="$1"
    local tool_use_id="$2"
    local tool_name="$3"
    local output_tokens="$4"
    jq -nc \
        --arg rid "$request_id" \
        --arg tuid "$tool_use_id" \
        --arg name "$tool_name" \
        --argjson out "$output_tokens" \
        '{
            type: "assistant",
            requestId: $rid,
            timestamp: "2024-01-01T00:00:00.000Z",
            message: {
                model: "claude-test",
                content: [{type: "tool_use", id: $tuid, name: $name, input: {}}],
                usage: {
                    input_tokens: 10,
                    cache_creation_input_tokens: 0,
                    cache_read_input_tokens: 0,
                    output_tokens: $out
                }
            }
        }'
}

# A user/tool_result line answering the given tool_use_id.
_tool_result_line() {
    local tool_use_id="$1"
    local result="$2"
    jq -nc \
        --arg tuid "$tool_use_id" \
        --arg result "$result" \
        '{
            type: "user",
            timestamp: "2024-01-01T00:00:00.000Z",
            message: {
                content: [{type: "tool_result", tool_use_id: $tuid, content: $result}]
            }
        }'
}

t_stop_same_request_not_split_into_zero_token_spans() {
    # A single API response (one requestId) can emit a tool_use, receive a
    # tool_result, then emit MORE tool_use blocks under the SAME requestId
    # before the next tool_result. The per-boundary span logic would emit a
    # second LLM span for the continuation segment, but its input/cache were
    # already counted and its output delta is zero - so that span carries
    # all-zero token metrics and misattributes the response.
    #
    # Expectation: exactly one LLM span per requestId, and no LLM span with
    # entirely zero token metrics.
    _with_turn_started "stop-split-1"

    local transcript="$TEST_TMP/transcript.jsonl"
    {
        # First segment of req_A: tool_use #1
        _assistant_tool_use_line "req_A" "tool_1" "Bash" 20
        _tool_result_line "tool_1" "ok"
        # Continuation of req_A after the tool_result: more tool_use blocks,
        # same requestId, same (constant) usage.
        _assistant_tool_use_line "req_A" "tool_2" "Bash" 20
        _tool_result_line "tool_2" "ok"
        # A distinct follow-up response.
        _assistant_line "req_B" 15 "all done"
    } > "$transcript"

    run_hook stop_hook.sh "$(fixture_stop "stop-split-1" "$transcript" "all done")"
    assert_success "$HOOK_STATUS"

    local llm_spans
    llm_spans=$(all_spans | jq '[.[] | select(.span_attributes.type == "llm")]')

    # No LLM span should have all-zero token metrics.
    local zero_token_spans
    zero_token_spans=$(echo "$llm_spans" | jq '[
        .[] | select(
            (.metrics.prompt_tokens // 0) == 0
            and (.metrics.completion_tokens // 0) == 0
            and (.metrics.prompt_cache_creation_tokens // 0) == 0
            and (.metrics.prompt_cache_creation_5m_tokens // 0) == 0
            and (.metrics.prompt_cache_creation_1h_tokens // 0) == 0
            and (.metrics.prompt_cached_tokens // 0) == 0
        )
    ] | length')
    assert_eq "$zero_token_spans" "0" "no LLM span should carry all-zero token metrics"

    # Exactly two distinct LLM responses (req_A and req_B) -> two LLM spans.
    assert_eq "$(echo "$llm_spans" | jq 'length')" "2" \
        "expected one LLM span per requestId (req_A, req_B)"

    # Session-level token totals must be preserved: req_A=10 in / 20 out,
    # req_B=10 in / 15 out  ->  prompt 20, completion 35.
    local total_prompt total_completion
    total_prompt=$(echo "$llm_spans" | jq '[.[].metrics.prompt_tokens // 0] | add')
    total_completion=$(echo "$llm_spans" | jq '[.[].metrics.completion_tokens // 0] | add')
    assert_eq "$total_prompt" "20" "total prompt_tokens preserved across spans"
    assert_eq "$total_completion" "35" "total completion_tokens preserved across spans"
}

t_stop_emits_split_cache_metrics() {
    _with_turn_started "stop-cache-split-1"

    local transcript="$TEST_TMP/transcript.jsonl"
    jq -nc '{
        type: "assistant",
        requestId: "req_cache",
        timestamp: "2024-01-01T00:00:00.000Z",
        message: {
            model: "claude-test",
            content: [{type: "text", text: "cached answer"}],
            usage: {
                input_tokens: 7,
                cache_creation_input_tokens: 30,
                cache_read_input_tokens: 100,
                cache_creation: {
                    ephemeral_5m_input_tokens: 10,
                    ephemeral_1h_input_tokens: 20
                },
                output_tokens: 5
            }
        }
    }' > "$transcript"

    run_hook stop_hook.sh "$(fixture_stop "stop-cache-split-1" "$transcript" "cached answer")"
    assert_success "$HOOK_STATUS"

    local llm
    llm=$(all_spans | jq '[.[] | select(.span_attributes.type == "llm")][0]')

    assert_eq "$(echo "$llm" | jq -r '.metrics.prompt_tokens')" "137" "prompt includes input, cache read, and cache write"
    assert_eq "$(echo "$llm" | jq -r '.metrics.tokens')" "142" "tokens includes inclusive prompt and completion"
    assert_eq "$(echo "$llm" | jq -r '.metrics.prompt_cached_tokens')" "100" "cache read uses canonical metric"
    assert_eq "$(echo "$llm" | jq -r '.metrics.prompt_cache_creation_5m_tokens')" "10" "5m cache write uses canonical metric"
    assert_eq "$(echo "$llm" | jq -r '.metrics.prompt_cache_creation_1h_tokens')" "20" "1h cache write uses canonical metric"
    assert_eq "$(echo "$llm" | jq -r '.metrics.prompt_cache_creation_tokens // "absent"')" "absent" "aggregate cache write omitted when split is present"
    assert_eq "$(echo "$llm" | jq -r '.metrics.cache_creation_input_tokens // "absent"')" "absent" "raw cache creation omitted"
    assert_eq "$(echo "$llm" | jq -r '.metrics.cache_read_input_tokens // "absent"')" "absent" "raw cache read omitted"
}

it "writes last_assistant_message into the Turn span output"  t_stop_sets_turn_output
it "leaves output empty when last_assistant_message missing"  t_stop_output_empty_when_message_missing
it "targets the existing Turn span id via merge"              t_stop_turn_update_has_correct_id
it "sets _is_merge=true on the update"                        t_stop_merge_flag_is_set
it "merge carries end time but no token metrics"              t_stop_merge_has_end_time_no_tokens
it "does not double-count streaming output across 3+ lines"   t_stop_streaming_output_not_double_counted
it "emits one LLM span per requestId across tool_result splits" t_stop_same_request_not_split_into_zero_token_spans
it "emits canonical split cache metrics"                      t_stop_emits_split_cache_metrics
