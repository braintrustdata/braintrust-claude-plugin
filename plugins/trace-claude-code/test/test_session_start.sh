#!/bin/bash
###
# End-to-end tests for the SessionStart hook.
#
# Each test:
#   1. Configures canned curl responses
#   2. Builds a hook payload using fixture_session_start()
#   3. Invokes the hook via run_hook
#   4. Asserts on the captured POST requests / resulting span data
#
# These tests are the bash equivalent of opencode-plugin's
# `assertEventsProduceTree` pattern.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

# Canned response setup used by most tests.
_setup_default_stubs() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_test"}'
    stub_response_for "*/v1/project_logs/*/insert"  200 '{"row_ids":["row_1"]}'
}

# ---------------------------------------------------------------------------
describe "session_start.sh: happy path"
# ---------------------------------------------------------------------------

t_session_start_creates_one_span() {
    _setup_default_stubs

    local payload
    payload=$(fixture_session_start "sess-001" "/tmp/my-workspace")

    run_hook session_start.sh "$payload"
    assert_success "$HOOK_STATUS" "hook should exit 0"

    local count
    count=$(span_count)
    assert_eq "$count" "1" "expected exactly one span inserted"
}

t_session_start_span_shape() {
    _setup_default_stubs

    local payload
    payload=$(fixture_session_start "sess-002" "/tmp/cool-project")
    run_hook session_start.sh "$payload"

    local span
    span=$(span_by_type "task")
    assert_ne "$span" "null" "expected a task span to exist"

    local name
    name=$(echo "$span" | jq -r '.span_attributes.name')
    assert_eq "$name" "Claude Code: cool-project"

    # span_id should equal the session_id; root_span_id should too
    local span_id root_span_id
    span_id=$(echo "$span" | jq -r '.span_id')
    root_span_id=$(echo "$span" | jq -r '.root_span_id')
    assert_eq "$span_id" "sess-002"
    assert_eq "$root_span_id" "sess-002"
}

t_session_start_metadata() {
    _setup_default_stubs

    run_hook session_start.sh "$(fixture_session_start "sess-meta" "/tmp/x")"

    local span
    span=$(span_by_type "task")

    local source
    source=$(echo "$span" | jq -r '.metadata.source')
    assert_eq "$source" "claude-code"

    local session_id
    session_id=$(echo "$span" | jq -r '.metadata.session_id')
    assert_eq "$session_id" "sess-meta"

    # Version attributes are present and non-empty. trace_claude_code_version
    # comes from plugin.json; claude_code_version from the transcript or
    # `claude --version` (falls back to "unknown" but must always be set).
    local trace_version cc_version
    trace_version=$(echo "$span" | jq -r '.metadata.trace_claude_code_version')
    cc_version=$(echo "$span" | jq -r '.metadata.claude_code_version')
    assert_ne "$trace_version" "null" "trace_claude_code_version should be set"
    assert_ne "$trace_version" "" "trace_claude_code_version should be non-empty"
    # It should match the manifest (e.g. a semver-ish string).
    assert_match "$trace_version" "^[0-9]+\.[0-9]+\.[0-9]+" "trace_claude_code_version looks like a version"
    assert_ne "$cc_version" "null" "claude_code_version should be set"
    assert_ne "$cc_version" "" "claude_code_version should be non-empty"
}

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

t_session_start_git_metadata() {
    _setup_default_stubs

    local repo commit
    repo=$(_make_git_repo)
    commit=$(git -C "$repo" rev-parse HEAD)

    run_hook session_start.sh "$(fixture_session_start "sess-git" "$repo")"

    local span
    span=$(span_by_type "task")

    assert_eq "$(echo "$span" | jq -r '.metadata.git_origin_url')" "https://github.com/acme/app.git"
    assert_eq "$(echo "$span" | jq -r '.metadata.git_branch')" "main"
    assert_eq "$(echo "$span" | jq -r '.metadata.git_commit_sha')" "$commit"

    rm -rf "$repo"
}

t_session_start_writes_state() {
    _setup_default_stubs

    run_hook session_start.sh "$(fixture_session_start "sess-state" "/tmp/x")"

    # The hook should persist root_span_id, session_span_id, project_id, etc.
    # These are written by the parent shell of session_start via
    # set_session_state. Reading them back is best done via the same helper
    # so paths agree.
    local root_id project_id turn_count
    root_id=$(get_session_state "sess-state" "root_span_id")
    project_id=$(get_session_state "sess-state" "project_id")
    turn_count=$(get_session_state "sess-state" "turn_count")

    assert_eq "$root_id" "sess-state"
    assert_eq "$project_id" "proj_test"
    assert_eq "$turn_count" "0"
}

it "creates exactly one root session span"  t_session_start_creates_one_span
it "span has correct name, id, and type"    t_session_start_span_shape
it "span includes claude-code metadata"     t_session_start_metadata
it "span includes minimal git metadata"     t_session_start_git_metadata
it "persists session state for later hooks" t_session_start_writes_state

# ---------------------------------------------------------------------------
describe "session_start.sh: tracing disabled"
# ---------------------------------------------------------------------------

t_session_start_disabled() {
    _setup_default_stubs
    export TRACE_TO_BRAINTRUST=false

    run_hook session_start.sh "$(fixture_session_start "sess-off" "/tmp/x")"
    assert_success "$HOOK_STATUS"

    # No spans should have been inserted
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "is a no-op when TRACE_TO_BRAINTRUST is false" t_session_start_disabled

# ---------------------------------------------------------------------------
describe "session_start.sh: missing API key"
# ---------------------------------------------------------------------------

t_session_start_no_api_key() {
    _setup_default_stubs
    export BRAINTRUST_API_KEY=""

    run_hook session_start.sh "$(fixture_session_start "sess-noauth" "/tmp/x")"
    # Hook exits 0 (graceful failure) - it should never block Claude Code.
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "0"

    local log
    log=$(hook_log)
    assert_contains "$log" "BRAINTRUST_API_KEY not set"
}

it "exits gracefully and logs when BRAINTRUST_API_KEY is unset" t_session_start_no_api_key

# ---------------------------------------------------------------------------
describe "session_start.sh: invalid API key"
# ---------------------------------------------------------------------------

t_session_start_invalid_key() {
    stub_response_for "*/v1/project?project_name=*" 401 "Invalid API Key"

    run_hook session_start.sh "$(fixture_session_start "sess-bad" "/tmp/x")"
    # Hook exits 0 so Claude Code keeps running
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "0" "no spans should be sent when project lookup fails"

    local log
    log=$(hook_log)
    assert_contains "$log" "authentication failed"
}

it "exits gracefully and logs an auth error on HTTP 401" t_session_start_invalid_key

# ---------------------------------------------------------------------------
describe "session_start.sh: race protection"
# ---------------------------------------------------------------------------

t_session_start_idempotent() {
    _setup_default_stubs

    # Two SessionStart hooks for the same session should produce one span.
    # The second invocation should detect the existing root_span_id via
    # check_and_set_session_state and exit without inserting.
    local payload
    payload=$(fixture_session_start "sess-dup" "/tmp/x")

    run_hook session_start.sh "$payload"
    assert_success "$HOOK_STATUS"

    run_hook session_start.sh "$payload"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "1" "duplicate session_start should not double-insert"
}

it "does not double-insert when called twice for the same session" t_session_start_idempotent
