#!/bin/bash
###
# Full pipeline end-to-end tests.
#
# These tests chain together SessionStart → UserPromptSubmit → PostToolUse...
# to assert that the resulting span tree has the expected structure. They
# are the bash equivalent of opencode-plugin's `assertEventsProduceTree`
# integration tests.
#
# These are the tests most likely to catch regressions like the missing-
# spans bug (where async hooks dropped spans due to state-file races or
# killed curl processes).
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

# ---------------------------------------------------------------------------
describe "full pipeline: simple session with one turn and two tools"
# ---------------------------------------------------------------------------

t_e2e_simple_session() {
    _setup_default_stubs
    local sid="e2e-sess-1"

    run_hook session_start.sh    "$(fixture_session_start "$sid" "/tmp/proj-x")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$sid" "List files")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Bash" \
        "$(fixture_tool_input_bash 'ls')" \
        "$(fixture_tool_response_text 'a.txt')")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Read" \
        "$(fixture_tool_input_read /tmp/a.txt)" \
        "$(fixture_tool_response_text 'hello')")"

    # Expected total: 1 session + 1 turn + 2 tools = 4 spans
    local total
    total=$(span_count)
    assert_eq "$total" "4"

    # Count by type
    local task_count tool_count
    task_count=$(span_count_by_type "task")
    tool_count=$(span_count_by_type "tool")
    assert_eq "$task_count" "2" "expected 2 task spans (session + turn)"
    assert_eq "$tool_count" "2" "expected 2 tool spans"
}

t_e2e_span_hierarchy() {
    _setup_default_stubs
    local sid="e2e-hier-1"

    run_hook session_start.sh "$(fixture_session_start "$sid" "/tmp/proj")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$sid" "go")"
    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Bash" \
        "$(fixture_tool_input_bash 'echo hi')" \
        "$(fixture_tool_response_text 'hi')")"

    # Session span: span_id == session_id, no parents
    local session_span
    session_span=$(span_by_name "^Claude Code: ")
    local session_id_value
    session_id_value=$(echo "$session_span" | jq -r '.span_id')
    assert_eq "$session_id_value" "$sid"

    # Turn span: parent is session
    local turn_span turn_id turn_parent
    turn_span=$(span_by_name "^Turn 1$")
    turn_id=$(echo "$turn_span" | jq -r '.span_id')
    turn_parent=$(echo "$turn_span" | jq -r '.span_parents[0]')
    assert_eq "$turn_parent" "$sid"

    # Tool span: parent is turn
    local tool_span tool_parent
    tool_span=$(span_by_type "tool")
    tool_parent=$(echo "$tool_span" | jq -r '.span_parents[0]')
    assert_eq "$tool_parent" "$turn_id"

    # All three share the same root_span_id (the session id)
    local turn_root tool_root
    turn_root=$(echo "$turn_span" | jq -r '.root_span_id')
    tool_root=$(echo "$tool_span" | jq -r '.root_span_id')
    assert_eq "$turn_root" "$sid"
    assert_eq "$tool_root" "$sid"
}

t_e2e_multi_turn() {
    _setup_default_stubs
    local sid="e2e-multi-1"

    run_hook session_start.sh "$(fixture_session_start "$sid" "/tmp/proj")"

    # Turn 1: one tool
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$sid" "turn 1")"
    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Bash" \
        "$(fixture_tool_input_bash 'echo 1')" \
        "$(fixture_tool_response_text '1')")"

    # Turn 2: two tools
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$sid" "turn 2")"
    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Read" \
        "$(fixture_tool_input_read /tmp/a)" \
        "$(fixture_tool_response_text 'a')")"
    run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Read" \
        "$(fixture_tool_input_read /tmp/b)" \
        "$(fixture_tool_response_text 'b')")"

    # Total: 1 session + 2 turns + 3 tools = 6 spans
    local total
    total=$(span_count)
    assert_eq "$total" "6"

    # Two turn spans
    local turns
    turns=$(spans_named "^Turn ")
    local turn_count
    turn_count=$(echo "$turns" | jq 'length')
    assert_eq "$turn_count" "2"

    # Tool spans are split across turns
    local turn1_id turn2_id
    turn1_id=$(echo "$turns" | jq -r '.[0].span_id')
    turn2_id=$(echo "$turns" | jq -r '.[1].span_id')

    local children_t1 children_t2
    children_t1=$(children_of "$turn1_id" | jq 'length')
    children_t2=$(children_of "$turn2_id" | jq 'length')

    assert_eq "$children_t1" "1" "turn 1 should have 1 tool child"
    assert_eq "$children_t2" "2" "turn 2 should have 2 tool children"
}

it "produces session + turn + 2 tool spans (4 total)" t_e2e_simple_session
it "spans form correct session > turn > tool hierarchy" t_e2e_span_hierarchy
it "multiple turns produce correctly-parented spans"    t_e2e_multi_turn

# ---------------------------------------------------------------------------
describe "full pipeline: no tool spans dropped under sequential PostToolUse"
# ---------------------------------------------------------------------------

# This is the regression test for the missing-spans class of bugs. We fire
# many PostToolUse hooks in rapid succession and assert that every one
# produced a tool span. With the previous async config, some of these
# would be silently dropped; with sync hooks they should all land.
t_e2e_no_drops_sequential() {
    _setup_default_stubs
    local sid="e2e-no-drops"
    local N=20

    run_hook session_start.sh "$(fixture_session_start "$sid" "/tmp/proj")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$sid" "many tools")"

    local i
    for i in $(seq 1 $N); do
        run_hook post_tool_use.sh "$(fixture_post_tool_use "$sid" "Bash" \
            "$(fixture_tool_input_bash "echo $i")" \
            "$(fixture_tool_response_text "$i")")"
    done

    local tool_count
    tool_count=$(span_count_by_type "tool")
    assert_eq "$tool_count" "$N" "expected $N tool spans, none dropped"
}

it "20 sequential PostToolUse hooks produce 20 tool spans" t_e2e_no_drops_sequential
