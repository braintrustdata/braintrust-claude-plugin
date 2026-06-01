#!/bin/bash
###
# End-to-end tests for the PostToolUse hook.
#
# PostToolUse fires after each tool invocation by the assistant. It creates
# a "tool" span as a child of the current Turn span. If no current Turn is
# active (no UserPromptSubmit since last Stop), the tool span is skipped.
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

# Setup helper: run session_start + user_prompt_submit, then clear capture.
_with_turn_started() {
    local session_id="$1"
    _setup_default_stubs
    run_hook session_start.sh "$(fixture_session_start "$session_id" "/tmp/x")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$session_id" "do something")"
    : > "$CAPTURED_REQUESTS"
}

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: with active turn"
# ---------------------------------------------------------------------------

t_post_tool_creates_tool_span() {
    _with_turn_started "sess-pt-1"

    local payload
    payload=$(fixture_post_tool_use "sess-pt-1" "Bash" \
        "$(fixture_tool_input_bash 'ls -la')" \
        "$(fixture_tool_response_text 'a.txt\nb.txt')")

    run_hook post_tool_use.sh "$payload"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "1"

    local tool_span
    tool_span=$(span_by_type "tool")
    assert_ne "$tool_span" "null"

    local name
    name=$(echo "$tool_span" | jq -r '.span_attributes.name')
    # Bash spans become "Terminal: <cmd>"
    assert_contains "$name" "Terminal"
    assert_contains "$name" "ls -la"
}

t_tool_span_is_child_of_turn() {
    _with_turn_started "sess-pt-child"

    # Capture the current turn id from state
    local turn_id
    turn_id=$(get_session_state "sess-pt-child" "current_turn_span_id")
    assert_ne "$turn_id" "" "expected a current turn span"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-child" "Read" \
        "$(fixture_tool_input_read /tmp/a.txt)" \
        "$(fixture_tool_response_text 'hello')")"

    local tool_span
    tool_span=$(span_by_type "tool")
    local parent
    parent=$(echo "$tool_span" | jq -r '.span_parents[0]')

    assert_eq "$parent" "$turn_id"
}

t_read_tool_span_name_includes_basename() {
    _with_turn_started "sess-pt-read"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-read" "Read" \
        "$(fixture_tool_input_read /tmp/some/long/path/file.txt)" \
        "$(fixture_tool_response_text 'content')")"

    local tool_span name
    tool_span=$(span_by_type "tool")
    name=$(echo "$tool_span" | jq -r '.span_attributes.name')
    assert_eq "$name" "Read: file.txt"
}

t_multiple_tools_in_turn() {
    _with_turn_started "sess-pt-multi"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Bash" \
        "$(fixture_tool_input_bash 'echo 1')" \
        "$(fixture_tool_response_text '1')")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Bash" \
        "$(fixture_tool_input_bash 'echo 2')" \
        "$(fixture_tool_response_text '2')")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Read" \
        "$(fixture_tool_input_read /tmp/x)" \
        "$(fixture_tool_response_text 'x')")"

    local tool_count
    tool_count=$(span_count_by_type "tool")
    assert_eq "$tool_count" "3"
}

it "creates a tool span on PostToolUse"             t_post_tool_creates_tool_span
it "tool span is a child of the current Turn span"  t_tool_span_is_child_of_turn
it "Read tool span name includes file basename"     t_read_tool_span_name_includes_basename
it "all tools in a turn produce distinct spans"     t_multiple_tools_in_turn

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: without active turn"
# ---------------------------------------------------------------------------

t_post_tool_skipped_without_turn() {
    # No session_start or user_prompt_submit ran. The hook should bail out
    # without creating any span (and without erroring).
    _setup_default_stubs

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-no-turn" "Bash" \
        "$(fixture_tool_input_bash 'ls')" \
        "$(fixture_tool_response_text 'output')")"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "skips silently when no current turn is active" t_post_tool_skipped_without_turn

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: input validation"
# ---------------------------------------------------------------------------

t_post_tool_no_tool_name() {
    _with_turn_started "sess-no-name"

    # Payload without tool_name
    local payload
    payload=$(jq -nc --arg s "sess-no-name" '{session_id: $s}')
    run_hook post_tool_use.sh "$payload"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

t_post_tool_no_session_id() {
    _setup_default_stubs

    local payload
    payload=$(jq -nc --arg t "Bash" '{tool_name: $t, tool_input: {}, tool_response: {}}')
    run_hook post_tool_use.sh "$payload"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "skips silently when payload has no tool_name"   t_post_tool_no_tool_name
it "skips silently when payload has no session_id"  t_post_tool_no_session_id
