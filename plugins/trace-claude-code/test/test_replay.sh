#!/bin/bash
###
# Tests for the replay helper.
#
# Replay-based tests are how you turn a real Claude Code session into a
# regression test:
#
#   1. Capture: set BRAINTRUST_RECORD_DIR to a fresh directory, run claude,
#      let the session play out. Every hook invocation gets appended to
#      $BRAINTRUST_RECORD_DIR/events.ndjson and any stop_hook transcripts
#      are copied to $BRAINTRUST_RECORD_DIR/transcripts/.
#
#   2. Move: drop the captured directory under
#      test/fixtures/sessions/<name>/
#
#   3. Replay: in a test, call replay_session "$FIXTURE_DIR" then assert
#      on the resulting span tree using span_count_by_type, span_by_name,
#      etc.
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
describe "replay_session: example-simple fixture"
# ---------------------------------------------------------------------------

t_replay_runs_all_events() {
    _setup_default_stubs

    local n
    n=$(replay_session "$SCRIPT_DIR/fixtures/sessions/example-simple")
    assert_success "$?" "replay_session should succeed"
    assert_eq "$n" "5" "expected 5 events replayed"
}

t_replay_produces_expected_spans() {
    _setup_default_stubs

    replay_session "$SCRIPT_DIR/fixtures/sessions/example-simple" >/dev/null
    assert_success "$?"

    # The fixture has: session_start, user_prompt_submit, 2x post_tool_use,
    # session_end. That should result in:
    #   - 1 session span (type=task, "Claude Code: ...")
    #   - 1 turn span    (type=task, "Turn 1")
    #   - 2 tool spans   (type=tool, "Terminal: ...", "Read: a.txt")
    local task_count tool_count llm_count total
    task_count=$(span_count_by_type "task")
    tool_count=$(span_count_by_type "tool")
    llm_count=$(span_count_by_type "llm")
    total=$(span_count)

    assert_eq "$task_count" "2" "expected 2 task spans (session + turn)"
    assert_eq "$tool_count" "2" "expected 2 tool spans"
    assert_eq "$llm_count"  "0" "no llm spans without a stop_hook"
    assert_eq "$total"      "4"
}

t_replay_preserves_hierarchy() {
    _setup_default_stubs

    replay_session "$SCRIPT_DIR/fixtures/sessions/example-simple" >/dev/null

    # Session id from the fixture
    local sid="example-sess-001"

    # The session span's id is the session id
    local session_span
    session_span=$(span_by_id "$sid")
    assert_ne "$session_span" "null" "expected session span to exist"

    # The turn span's parent is the session
    local turn_span turn_parent
    turn_span=$(span_by_name "^Turn 1$")
    turn_parent=$(echo "$turn_span" | jq -r '.span_parents[0]')
    assert_eq "$turn_parent" "$sid"

    # Each tool span's parent is the turn
    local turn_id
    turn_id=$(echo "$turn_span" | jq -r '.span_id')
    local tool_children
    tool_children=$(children_of "$turn_id" | jq 'length')
    assert_eq "$tool_children" "2" "turn should have 2 tool children"
}

it "replays all 5 hook events"                t_replay_runs_all_events
it "produces session + turn + 2 tool spans"   t_replay_produces_expected_spans
it "preserves session > turn > tool hierarchy" t_replay_preserves_hierarchy

# ---------------------------------------------------------------------------
describe "replay_session: error handling"
# ---------------------------------------------------------------------------

t_replay_missing_fixture() {
    _setup_default_stubs
    replay_session "/nonexistent/fixture/path" >/dev/null 2>&1
    assert_failure "$?" "replay_session should fail when fixture is missing"
}

it "returns non-zero when the fixture directory does not exist" t_replay_missing_fixture

# ---------------------------------------------------------------------------
describe "replay_session: record-only events run their no-op handler"
# ---------------------------------------------------------------------------

# Replay is hooks.json-driven: every event runs whatever is registered for
# it. Record-only events (PreToolUse, PreCompact, InstructionsLoaded, ...)
# are registered to record_event.sh, which no-ops when recording is off.
# So they replay successfully and produce no spans, while the acting hooks
# create their spans. Replay must never fail just because an event is
# observability-only.
t_replay_runs_record_only_handlers() {
    _setup_default_stubs

    # Build a fixture that interleaves record-only events among the acting
    # hooks. All names are Claude Code's CamelCase event names.
    local dir="$TEST_TMP/mixed-fixture"
    mkdir -p "$dir/transcripts"
    {
        echo '{"ts":"t0","hook":"SessionStart","payload":{"session_id":"mix-1","cwd":"/tmp","hook_event_name":"SessionStart"}}'
        echo '{"ts":"t1","hook":"InstructionsLoaded","payload":{"session_id":"mix-1","hook_event_name":"InstructionsLoaded"}}'
        echo '{"ts":"t2","hook":"UserPromptSubmit","payload":{"session_id":"mix-1","prompt":"hi","cwd":"/tmp","hook_event_name":"UserPromptSubmit"}}'
        echo '{"ts":"t3","hook":"PreToolUse","payload":{"session_id":"mix-1","tool_name":"Bash","hook_event_name":"PreToolUse"}}'
        echo '{"ts":"t4","hook":"PostToolUse","payload":{"session_id":"mix-1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"output":"x"},"hook_event_name":"PostToolUse"}}'
        echo '{"ts":"t5","hook":"PreCompact","payload":{"session_id":"mix-1","trigger":"auto","hook_event_name":"PreCompact"}}'
        echo '{"ts":"t6","hook":"SessionEnd","payload":{"session_id":"mix-1","hook_event_name":"SessionEnd"}}'
    } > "$dir/events.ndjson"

    # Every event has a registered handler in hooks.json, so all 7 run.
    local n
    n=$(replay_session "$dir")
    assert_success "$?" "replay should not fail on record-only events"
    assert_eq "$n" "7" "all 7 events have a handler and should replay"

    # Only the acting hooks produce spans (session + turn + tool). The
    # record-only events no-op, contributing nothing.
    assert_eq "$(span_count_by_type task)" "2" "session + turn task spans"
    assert_eq "$(span_count_by_type tool)" "1" "one tool span from PostToolUse"
}

it "runs record-only event handlers as no-ops without failing" t_replay_runs_record_only_handlers
