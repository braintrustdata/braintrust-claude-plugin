#!/bin/bash
###
# Unit tests for utility functions in hooks/common.sh
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

# ---------------------------------------------------------------------------
describe "is_truthy"
# ---------------------------------------------------------------------------

t_truthy_true()      { is_truthy "true";  assert_eq "$?" "0"; }
t_truthy_TRUE()      { is_truthy "TRUE";  assert_eq "$?" "0"; }
t_truthy_mixed()     { is_truthy "tRuE";  assert_eq "$?" "0"; }
t_truthy_one()       { is_truthy "1";     assert_eq "$?" "0"; }
t_truthy_yes()       { is_truthy "yes";   assert_eq "$?" "0"; }
t_truthy_on()        { is_truthy "on";    assert_eq "$?" "0"; }
t_truthy_false()     { is_truthy "false"; assert_failure "$?"; }
t_truthy_zero()      { is_truthy "0";     assert_failure "$?"; }
t_truthy_empty()     { is_truthy "";      assert_failure "$?"; }
t_truthy_arbitrary() { is_truthy "maybe"; assert_failure "$?"; }

it "returns 0 for 'true'"               t_truthy_true
it "returns 0 for 'TRUE' (uppercase)"   t_truthy_TRUE
it "returns 0 for 'tRuE' (mixed case)"  t_truthy_mixed
it "returns 0 for '1'"                  t_truthy_one
it "returns 0 for 'yes'"                t_truthy_yes
it "returns 0 for 'on'"                 t_truthy_on
it "returns non-zero for 'false'"       t_truthy_false
it "returns non-zero for '0'"           t_truthy_zero
it "returns non-zero for empty string"  t_truthy_empty
it "returns non-zero for arbitrary string" t_truthy_arbitrary

# ---------------------------------------------------------------------------
describe "tracing_enabled"
# ---------------------------------------------------------------------------

t_tracing_true() {
    TRACE_TO_BRAINTRUST=true
    tracing_enabled
    assert_eq "$?" "0"
}
t_tracing_false() {
    TRACE_TO_BRAINTRUST=false
    tracing_enabled
    assert_failure "$?"
}
t_tracing_unset() {
    unset TRACE_TO_BRAINTRUST
    tracing_enabled
    assert_failure "$?"
}

it "follows TRACE_TO_BRAINTRUST=true"  t_tracing_true
it "follows TRACE_TO_BRAINTRUST=false" t_tracing_false
it "returns non-zero when TRACE_TO_BRAINTRUST is unset" t_tracing_unset

# ---------------------------------------------------------------------------
describe "check_requirements"
# ---------------------------------------------------------------------------

t_check_req_ok() {
    API_KEY="some-key"
    check_requirements
    assert_eq "$?" "0"
}
t_check_req_missing_key() {
    API_KEY=""
    check_requirements
    assert_failure "$?"
    local log
    log=$(hook_log)
    assert_contains "$log" "BRAINTRUST_API_KEY not set"
}

it "passes when all binaries exist and API_KEY is set" t_check_req_ok
it "fails when API_KEY is empty"                       t_check_req_missing_key

# ---------------------------------------------------------------------------
describe "get_cache_value / set_cache_value"
# ---------------------------------------------------------------------------

t_cache_roundtrip() {
    set_cache_value "my_key" "my_value"
    local got
    got=$(get_cache_value "my_key")
    assert_eq "$got" "my_value"
}
t_cache_missing() {
    local got
    got=$(get_cache_value "never_set_key")
    assert_eq "$got" ""
}
t_cache_overwrite() {
    set_cache_value "k" "v1"
    set_cache_value "k" "v2"
    local got
    got=$(get_cache_value "k")
    assert_eq "$got" "v2"
}

it "round-trips a value"                    t_cache_roundtrip
it "returns empty string when key is unset" t_cache_missing
it "overwrites an existing value"           t_cache_overwrite

# ---------------------------------------------------------------------------
describe "set_session_state / get_session_state"
# ---------------------------------------------------------------------------

t_state_roundtrip() {
    set_session_state "sess1" "name" "value-A"
    local got
    got=$(get_session_state "sess1" "name")
    assert_eq "$got" "value-A"
}
t_state_isolation() {
    set_session_state "sessA" "k" "valueA"
    set_session_state "sessB" "k" "valueB"
    local got_a got_b
    got_a=$(get_session_state "sessA" "k")
    got_b=$(get_session_state "sessB" "k")
    assert_eq "$got_a" "valueA"
    assert_eq "$got_b" "valueB"
}
t_state_missing() {
    local got
    got=$(get_session_state "sess_missing" "missing_key")
    assert_eq "$got" ""
}
t_state_overwrite() {
    set_session_state "sess" "k" "old"
    set_session_state "sess" "k" "new"
    local got
    got=$(get_session_state "sess" "k")
    assert_eq "$got" "new"
}

it "round-trips a value within a single session"    t_state_roundtrip
it "isolates state across distinct sessions"        t_state_isolation
it "returns empty string for an unknown key"        t_state_missing
it "supports overwriting an existing key"           t_state_overwrite

# ---------------------------------------------------------------------------
describe "check_and_set_session_state"
# ---------------------------------------------------------------------------

t_check_set_new() {
    check_and_set_session_state "sess" "first" "v"
    local rc=$?
    assert_eq "$rc" "0"
    local got
    got=$(get_session_state "sess" "first")
    assert_eq "$got" "v"
}
t_check_set_existing() {
    set_session_state "sess" "claimed" "original"
    local out
    out=$(check_and_set_session_state "sess" "claimed" "new-value")
    local rc=$?
    assert_eq "$rc" "1"
    assert_eq "$out" "original"
    local got
    got=$(get_session_state "sess" "claimed")
    assert_eq "$got" "original"
}

it "sets and returns 0 when key is new"                          t_check_set_new
it "preserves existing value and returns 1 when key is already set" t_check_set_existing

# ---------------------------------------------------------------------------
describe "is_experiment_mode"
# ---------------------------------------------------------------------------

t_exp_set() {
    CC_EXPERIMENT_ID="exp_abc"
    is_experiment_mode
    assert_eq "$?" "0"
}
t_exp_empty() {
    CC_EXPERIMENT_ID=""
    is_experiment_mode
    assert_failure "$?"
}

it "is true when CC_EXPERIMENT_ID is set"      t_exp_set
it "is false when CC_EXPERIMENT_ID is empty"   t_exp_empty

# ---------------------------------------------------------------------------
describe "generate_uuid"
# ---------------------------------------------------------------------------

t_uuid_format() {
    local uuid
    uuid=$(generate_uuid)
    assert_match "$uuid" "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
}
t_uuid_unique() {
    local a b
    a=$(generate_uuid)
    b=$(generate_uuid)
    assert_ne "$a" "$b"
}

it "returns a non-empty lowercase UUID"        t_uuid_format
it "returns unique values on subsequent calls" t_uuid_unique

# ---------------------------------------------------------------------------
describe "record_hook_input: event labeling and transcript snapshots"
# ---------------------------------------------------------------------------

# Helper: point recording at a fresh dir under the test's isolated HOME.
_rec_dir() {
    echo "$HOME/recording"
}

t_record_labels_by_event_name() {
    # The recorded event should be labeled with the payload's
    # hook_event_name (CamelCase), regardless of the name passed in.
    export BRAINTRUST_RECORD_DIR="$(_rec_dir)"
    local payload='{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}'
    record_hook_input "ignored_arg" "$payload"

    local label
    label=$(jq -r '.hook' "$BRAINTRUST_RECORD_DIR/events.ndjson")
    assert_eq "$label" "PreToolUse" "event labeled by hook_event_name"
}

t_record_falls_back_to_arg_name() {
    # When the payload has no hook_event_name, fall back to the passed name.
    export BRAINTRUST_RECORD_DIR="$(_rec_dir)"
    record_hook_input "CwdChanged" '{"session_id":"s1"}'

    local label
    label=$(jq -r '.hook' "$BRAINTRUST_RECORD_DIR/events.ndjson")
    assert_eq "$label" "CwdChanged" "falls back to caller-supplied name"
}

t_record_copies_main_transcript_on_stop() {
    # Regression guard: a Stop event must snapshot the main transcript into
    # transcripts/. (This broke once when the copy guard still checked the
    # old snake_case name after we switched to CamelCase labels.)
    export BRAINTRUST_RECORD_DIR="$(_rec_dir)"
    local transcript="$HOME/main.jsonl"
    echo '{"type":"assistant"}' > "$transcript"

    local payload
    payload=$(jq -nc --arg t "$transcript" \
        '{session_id:"s1", hook_event_name:"Stop", transcript_path:$t}')
    record_hook_input "stop_hook" "$payload"

    assert_file_exists "$BRAINTRUST_RECORD_DIR/transcripts/main.jsonl" \
        "Stop should copy the main transcript"
}

t_record_copies_agent_transcript_on_subagent_stop() {
    # SubagentStop must snapshot the sub-agent's own transcript (which holds
    # its model calls, e.g. haiku) before Claude Code can clean it up.
    export BRAINTRUST_RECORD_DIR="$(_rec_dir)"
    local agent_t="$HOME/agent-abc123.jsonl"
    echo '{"type":"assistant"}' > "$agent_t"

    local payload
    payload=$(jq -nc --arg t "$agent_t" \
        '{session_id:"s1", hook_event_name:"SubagentStop", agent_id:"abc123", agent_transcript_path:$t}')
    record_hook_input "ignored" "$payload"

    assert_file_exists "$BRAINTRUST_RECORD_DIR/transcripts/agent-abc123.jsonl" \
        "SubagentStop should copy the agent transcript"
}

t_record_off_is_noop() {
    # With no BRAINTRUST_RECORD_DIR, recording must write nothing.
    unset BRAINTRUST_RECORD_DIR
    record_hook_input "Stop" '{"session_id":"s1","hook_event_name":"Stop"}'
    # Nothing to assert beyond "no crash"; the absence of a recording dir
    # means there is no file to inspect. Exit status should be success.
    assert_success "$?" "record_hook_input is a no-op when recording is off"
}

it "labels recorded events by hook_event_name"        t_record_labels_by_event_name
it "falls back to the caller-supplied name"           t_record_falls_back_to_arg_name
it "copies the main transcript on Stop"               t_record_copies_main_transcript_on_stop
it "copies the agent transcript on SubagentStop"      t_record_copies_agent_transcript_on_subagent_stop
it "is a no-op when recording is disabled"            t_record_off_is_noop
