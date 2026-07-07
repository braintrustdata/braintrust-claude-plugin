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
describe "git metadata helpers"
# ---------------------------------------------------------------------------

_make_git_repo() {
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init >/dev/null 2>&1
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test User"
    printf "hello\n" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -m init >/dev/null 2>&1
    git -C "$dir" branch -M main
    git -C "$dir" remote add origin "https://token@github.com/acme/app.git"
    echo "$dir"
}

t_git_remote_redaction() {
    local redacted
    redacted=$(redact_git_remote_url "https://token:secret@github.com/acme/app.git")
    assert_eq "$redacted" "https://github.com/acme/app.git"

    local ssh
    ssh=$(redact_git_remote_url "git@github.com:acme/app.git")
    assert_eq "$ssh" "git@github.com:acme/app.git"
}

t_git_metadata_json() {
    local repo commit metadata
    repo=$(_make_git_repo)
    commit=$(git -C "$repo" rev-parse HEAD)
    metadata=$(git_metadata_json "$repo")

    assert_eq "$(echo "$metadata" | jq -r '.git_origin_url')" "https://github.com/acme/app.git"
    assert_eq "$(echo "$metadata" | jq -r '.git_branch')" "main"
    assert_eq "$(echo "$metadata" | jq -r '.git_commit_sha')" "$commit"

    rm -rf "$repo"
}

t_git_metadata_json_not_git() {
    local dir metadata
    dir=$(mktemp -d)
    metadata=$(git_metadata_json "$dir")
    assert_eq "$metadata" "{}"
    rm -rf "$dir"
}

it "redacts URL-style git remote credentials" t_git_remote_redaction
it "captures origin, branch, and commit"      t_git_metadata_json
it "omits fields outside a git repo"          t_git_metadata_json_not_git

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
    # its model calls) before Claude Code can clean it up.
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

# ---------------------------------------------------------------------------
describe "emit_llm_spans_from_transcript: per-request LLM spans"
# ---------------------------------------------------------------------------

# Write a tiny NDJSON transcript with two API requests. Request A spans two
# content-block lines sharing a requestId where output_tokens STREAMS (5 then
# 30) while input/cache stay constant - this exercises both the dedupe and the
# "take max output per request" logic.
_write_agent_transcript() {
    local path="$1"
    {
        # Request A, line 1: partial output (5).
        echo '{"type":"assistant","requestId":"reqA","timestamp":"2026-06-11T03:00:00.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000}}}'
        # Request A, line 2: final cumulative output (30); input/cache identical.
        echo '{"type":"assistant","requestId":"reqA","timestamp":"2026-06-11T03:00:00.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":5,"output_tokens":30,"cache_creation_input_tokens":100,"cache_read_input_tokens":2000}}}'
        # A user/tool_result line in between (must be ignored).
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
        # Request B: single line.
        echo '{"type":"assistant","requestId":"reqB","timestamp":"2026-06-11T03:00:05.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":2500}}}'
    } > "$path"
}

t_emit_dedupes_by_request_id() {
    local transcript="$HOME/agent.jsonl"
    _write_agent_transcript "$transcript"

    # Capture emitted spans instead of enqueuing them. Compact each span to
    # one line so the file is valid NDJSON regardless of jq pretty-printing.
    local out="$HOME/emitted.ndjson"
    : > "$out"
    enqueue_span() { echo "$3" | jq -c '.' >> "$out"; return 0; }

    local n
    n=$(emit_llm_spans_from_transcript "$transcript" "sess" "proj" "ROOT" "PARENT")

    # Return value counts LLM spans only: 2 unique requestIds -> 2 LLM spans.
    assert_eq "$n" "2" "return value counts LLM spans"

    # Structure: 2 LLM spans + 1 tool span (request A's Bash tool_use, which
    # has a matching tool_result). The third raw line is a tool_result, not a
    # separate LLM call.
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")]|length' "$out")"  "2" "two LLM spans"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="tool")]|length' "$out")" "1" "one tool span"

    # Output is the MAX per request: A=30 (not 5), B=20 -> 50.
    # Braintrust prompt_tokens are inclusive for Anthropic:
    # input 7 + cache_read 4500 + cache_creation 103 = 4610.
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")|.metrics.completion_tokens]|add' "$out")"             "50"   "completion uses max per request"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_tokens]|add' "$out")"                "4610" "prompt includes input and cache tokens"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")|.metrics.tokens]|add' "$out")"                       "4660" "total tokens includes inclusive prompt and completion"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_cached_tokens]|add' "$out")"         "4500" "cache_read deduped"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_cache_creation_tokens]|add' "$out")" "103"  "cache_creation deduped"
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm" and (.metrics | (has("cache_read_input_tokens") or has("cache_creation_input_tokens"))))]|length' "$out")" "0" "raw Anthropic cache metrics are not emitted"

    # All spans parented under PARENT.
    assert_eq "$(jq -s 'all(.[]; .span_parents[0] == "PARENT")' "$out")" "true" "all parented under PARENT"
    # LLM spans tagged with the model; tool span named after the tool.
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")]|all(.span_attributes.name == "claude-haiku-4-5")' "$out")" "true" "model name on LLM spans"
    assert_eq "$(jq -rs '[.[]|select(.span_attributes.type=="tool")][0].span_attributes.name' "$out")" "Terminal: command" "tool span named after the tool"

    # The second LLM span's input includes the prior assistant + tool history.
    local hist_roles
    hist_roles=$(jq -s '[.[]|select(.span_attributes.type=="llm")][1].input|map(.role)|join(",")' "$out")
    assert_eq "$hist_roles" '"assistant,tool"' "second LLM span input carries conversation history"
}

t_emit_missing_file_is_zero() {
    enqueue_span() { return 0; }
    local n
    n=$(emit_llm_spans_from_transcript "$HOME/does-not-exist.jsonl" "s" "p" "R" "P")
    assert_eq "$n" "0" "missing transcript emits nothing"
}

# Write a transcript whose chronological order is the REVERSE of the
# requestId sort order: the first request ("reqZ") happens at t=00, the
# second ("reqA") at t=05. group_by sorts by id, so without an explicit
# re-sort the directives come out reqA-then-reqZ, scrambling the threaded
# conversation history.
_write_out_of_id_order_transcript() {
    local path="$1"
    {
        # Chronologically FIRST (t=00) but sorts LAST by id.
        echo '{"type":"assistant","requestId":"reqZ","timestamp":"2026-06-11T03:00:00.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"first turn"}],"usage":{"input_tokens":5,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
        # Chronologically SECOND (t=05) but sorts FIRST by id.
        echo '{"type":"assistant","requestId":"reqA","timestamp":"2026-06-11T03:00:05.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"second turn"}],"usage":{"input_tokens":8,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
    } > "$path"
}

t_emit_preserves_chronological_order() {
    local transcript="$HOME/agent_order.jsonl"
    _write_out_of_id_order_transcript "$transcript"

    local out="$HOME/emitted_order.ndjson"
    : > "$out"
    enqueue_span() { echo "$3" | jq -c '.' >> "$out"; return 0; }

    emit_llm_spans_from_transcript "$transcript" "sess" "proj" "ROOT" "PARENT" >/dev/null

    # Spans must be emitted in chronological order: "first turn" then
    # "second turn", regardless of requestId sort order.
    local first_text second_text
    first_text=$(jq -rs '[.[]|select(.span_attributes.type=="llm")][0].output.content' "$out")
    second_text=$(jq -rs '[.[]|select(.span_attributes.type=="llm")][1].output.content' "$out")
    assert_eq "$first_text"  "first turn"  "first emitted LLM span is the chronologically-first turn"
    assert_eq "$second_text" "second turn" "second emitted LLM span is the chronologically-second turn"

    # History threading must follow chronological order: the first turn has
    # empty input history; the second turn carries the first turn's assistant
    # message as input.
    assert_eq "$(jq -s '[.[]|select(.span_attributes.type=="llm")][0].input|length' "$out")" "0" "first turn has empty input history"
    local second_input_text
    second_input_text=$(jq -rs '[.[]|select(.span_attributes.type=="llm")][1].input[0].content' "$out")
    assert_eq "$second_input_text" "first turn" "second turn input carries the first turn as history"
}

it "emits one LLM span per requestId (dedupes repeated usage)" t_emit_dedupes_by_request_id
it "emits nothing when the transcript file is missing"         t_emit_missing_file_is_zero
it "preserves chronological order when requestIds don't sort chronologically" t_emit_preserves_chronological_order
