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

t_stop_includes_metrics_in_merge() {
    # Even with an empty transcript (no LLM calls), the merge should
    # carry zero-valued token totals so the schema is consistent.
    _with_turn_started "stop-metrics-1"
    local transcript
    transcript=$(_empty_transcript "$TEST_TMP/transcript.jsonl")
    run_hook stop_hook.sh "$(fixture_stop "stop-metrics-1" "$transcript" "ok")"

    local span
    span=$(all_spans | jq '.[] | select(._is_merge == true)' | jq -s '.[0]')

    local end_time prompt_tokens completion_tokens tokens
    end_time=$(echo "$span" | jq -r '.metrics.end')
    prompt_tokens=$(echo "$span" | jq -r '.metrics.prompt_tokens')
    completion_tokens=$(echo "$span" | jq -r '.metrics.completion_tokens')
    tokens=$(echo "$span" | jq -r '.metrics.tokens')

    # end is a unix timestamp - should be a positive integer
    if [ "$end_time" -le 0 ] 2>/dev/null; then
        fail "expected positive end time, got $end_time"
    fi
    assert_eq "$prompt_tokens" "0"
    assert_eq "$completion_tokens" "0"
    assert_eq "$tokens" "0"
}

it "writes last_assistant_message into the Turn span output"  t_stop_sets_turn_output
it "leaves output empty when last_assistant_message missing"  t_stop_output_empty_when_message_missing
it "targets the existing Turn span id via merge"              t_stop_turn_update_has_correct_id
it "sets _is_merge=true on the update"                        t_stop_merge_flag_is_set
it "includes end-time and token-total metrics on the merge"   t_stop_includes_metrics_in_merge
