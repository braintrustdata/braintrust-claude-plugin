#!/bin/bash
###
# End-to-end tests for the UserPromptSubmit hook.
#
# UserPromptSubmit is fired each time the user submits a prompt. It creates
# a "Turn N" child span under the session span. If the session root doesn't
# exist yet (e.g. session_start was missed), it back-fills one.
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

# Helper: run session_start first, ignoring its inserts.
_with_started_session() {
    local session_id="$1"
    _setup_default_stubs
    run_hook session_start.sh "$(fixture_session_start "$session_id" "/tmp/x")"
    # Clear capture so subsequent tests see only the new hook's requests
    : > "$CAPTURED_REQUESTS"
}

# ---------------------------------------------------------------------------
describe "user_prompt_submit.sh: with existing session"
# ---------------------------------------------------------------------------

t_prompt_creates_turn_span() {
    _with_started_session "sess-turn-1"

    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-turn-1" "Hello!")"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "1" "expected exactly one new span (the turn)"

    local turn
    turn=$(span_by_type "task")
    assert_ne "$turn" "null"

    local name
    name=$(echo "$turn" | jq -r '.span_attributes.name')
    assert_eq "$name" "Turn 1"

    local input
    input=$(echo "$turn" | jq -r '.input')
    assert_eq "$input" "Hello!"
}

t_turn_is_child_of_session() {
    _with_started_session "sess-parent"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-parent" "Hi")"

    local turn
    turn=$(span_by_name "^Turn 1$")
    local parent root
    parent=$(echo "$turn" | jq -r '.span_parents[0]')
    root=$(echo "$turn" | jq -r '.root_span_id')

    # Turn's parent is the session span; its root is the same session id.
    assert_eq "$parent" "sess-parent"
    assert_eq "$root" "sess-parent"
}

t_subsequent_prompts_increment_turn_number() {
    _with_started_session "sess-multi"

    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-multi" "first")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-multi" "second")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-multi" "third")"

    local count
    count=$(span_count)
    assert_eq "$count" "3"

    # Verify each turn got the right name
    local t1 t2 t3
    t1=$(all_spans | jq -r '.[0].span_attributes.name')
    t2=$(all_spans | jq -r '.[1].span_attributes.name')
    t3=$(all_spans | jq -r '.[2].span_attributes.name')
    assert_eq "$t1" "Turn 1"
    assert_eq "$t2" "Turn 2"
    assert_eq "$t3" "Turn 3"
}

t_turn_state_stored() {
    _with_started_session "sess-state-turn"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-state-turn" "X")"

    local turn_span_id
    turn_span_id=$(get_session_state "sess-state-turn" "current_turn_span_id")
    assert_ne "$turn_span_id" "" "current_turn_span_id should be persisted"

    local turn_count
    turn_count=$(get_session_state "sess-state-turn" "turn_count")
    assert_eq "$turn_count" "1"
}

it "creates a Turn span on prompt submit"          t_prompt_creates_turn_span
it "Turn span is a child of the session span"      t_turn_is_child_of_session
it "subsequent prompts increment the turn number"  t_subsequent_prompts_increment_turn_number
it "persists current_turn_span_id to state"        t_turn_state_stored

# ---------------------------------------------------------------------------
describe "user_prompt_submit.sh: without prior session_start"
# ---------------------------------------------------------------------------

t_prompt_backfills_session_root() {
    # No session_start ran first. The hook should create both the session
    # root span AND the Turn span.
    _setup_default_stubs

    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-orphan" "Hello")"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "2" "expected session root + turn (2 spans)"

    # We should have at least one span with type=task named "Claude Code: *"
    local session_span
    session_span=$(span_by_name "^Claude Code: ")
    assert_ne "$session_span" "null"

    local turn_span
    turn_span=$(span_by_name "^Turn 1$")
    assert_ne "$turn_span" "null"
}

it "back-fills a session root span if session_start was missed" t_prompt_backfills_session_root

# ---------------------------------------------------------------------------
describe "user_prompt_submit.sh: tracing disabled"
# ---------------------------------------------------------------------------

t_prompt_disabled() {
    _setup_default_stubs
    export TRACE_TO_BRAINTRUST=false

    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-off" "x")"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "is a no-op when TRACE_TO_BRAINTRUST is false" t_prompt_disabled
