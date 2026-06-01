#!/bin/bash
###
# Tests for _http_insert_span() and get_project_id() HTTP status handling.
#
# Exercises the curl_stub by configuring canned responses and asserting on
# the captured requests and the function's stdout/exit codes.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

# A minimal valid span event JSON (matching the shape common.sh builds).
_test_event() {
    jq -nc \
        --arg id "span-test-1" \
        --arg root "root-1" \
        '{
            id: $id,
            span_id: $id,
            root_span_id: $root,
            input: "test input",
            span_attributes: { name: "test span", type: "task" }
        }'
}

# ---------------------------------------------------------------------------
describe "_http_insert_span: success"
# ---------------------------------------------------------------------------

t_insert_success_returns_row_id() {
    stub_response_for "*/v1/project_logs/*/insert" 200 '{"row_ids":["row_abc"]}'

    local event row_id rc
    event=$(_test_event)
    row_id=$(_http_insert_span "proj_123" "$event")
    rc=$?

    assert_success "$rc"
    assert_eq "$row_id" "row_abc"

    local count
    count=$(captured_request_count '/insert$')
    assert_eq "$count" "1"
}

t_insert_request_body_shape() {
    stub_response_for "*/insert" 200 '{"row_ids":["row_xyz"]}'

    local event
    event=$(_test_event)
    _http_insert_span "proj_456" "$event" >/dev/null

    local body_events_len
    body_events_len=$(jq -s '.[0].body.events | length' "$CAPTURED_REQUESTS")
    assert_eq "$body_events_len" "1"

    local body_span_id
    body_span_id=$(jq -s -r '.[0].body.events[0].span_id' "$CAPTURED_REQUESTS")
    assert_eq "$body_span_id" "span-test-1"
}

it "POSTs to the project_logs insert endpoint and returns the row id" t_insert_success_returns_row_id
it "includes the event in the request body wrapped under .events"     t_insert_request_body_shape

# ---------------------------------------------------------------------------
describe "_http_insert_span: failure modes"
# ---------------------------------------------------------------------------

t_insert_401() {
    stub_response_for "*/insert" 401 "Invalid API Key"

    local event rc
    event=$(_test_event)
    _http_insert_span "proj_123" "$event" >/dev/null
    rc=$?

    assert_failure "$rc"
    local log
    log=$(hook_log)
    assert_contains "$log" "Insert failed (HTTP 401)"
}

t_insert_500() {
    stub_response_for "*/insert" 500 "Internal Server Error"

    local event rc
    event=$(_test_event)
    _http_insert_span "proj_123" "$event" >/dev/null
    rc=$?

    assert_failure "$rc"
    local log
    log=$(hook_log)
    assert_contains "$log" "Insert failed (HTTP 500)"
}

t_insert_no_api_key() {
    API_KEY=""

    local event rc
    event=$(_test_event)
    _http_insert_span "proj_123" "$event" >/dev/null
    rc=$?

    assert_failure "$rc"
    local log
    log=$(hook_log)
    assert_contains "$log" "API_KEY is empty"
}

t_insert_empty_row_ids() {
    stub_response_for "*/insert" 200 '{"row_ids":[]}'

    local event rc
    event=$(_test_event)
    _http_insert_span "proj_123" "$event" >/dev/null
    rc=$?

    assert_failure "$rc"
}

it "returns non-zero on HTTP 401 and logs an error" t_insert_401
it "returns non-zero on HTTP 500"                   t_insert_500
it "returns non-zero when API_KEY is empty"         t_insert_no_api_key
it "returns non-zero when the response has no row_ids" t_insert_empty_row_ids

# ---------------------------------------------------------------------------
describe "_http_insert_span: experiment mode"
# ---------------------------------------------------------------------------

t_insert_experiment_mode() {
    stub_response_for "*/v1/experiment/exp_42/insert" 200 '{"row_ids":["row_e1"]}'

    CC_EXPERIMENT_ID="exp_42"

    local event row_id rc
    event=$(_test_event)
    row_id=$(_http_insert_span "proj_irrelevant" "$event")
    rc=$?

    assert_success "$rc"
    assert_eq "$row_id" "row_e1"

    local pl_count
    pl_count=$(captured_request_count '/project_logs/')
    assert_eq "$pl_count" "0"

    local exp_count
    exp_count=$(captured_request_count '/v1/experiment/exp_42/insert')
    assert_eq "$exp_count" "1"
}

it "POSTs to /v1/experiment/<id>/insert when CC_EXPERIMENT_ID is set" t_insert_experiment_mode

# ---------------------------------------------------------------------------
describe "get_project_id"
# ---------------------------------------------------------------------------

t_get_project_existing() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_existing"}'

    local pid rc
    pid=$(get_project_id "my-project")
    rc=$?

    assert_success "$rc"
    assert_eq "$pid" "proj_existing"
}

t_get_project_create() {
    stub_response_for "*/v1/project?project_name=*" 200 '{}'
    stub_response_for "*/v1/project" 200 '{"id":"proj_created"}'

    local pid rc
    pid=$(get_project_id "brand-new-project")
    rc=$?

    assert_success "$rc"
    assert_eq "$pid" "proj_created"
}

t_get_project_cached() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_cached"}'

    get_project_id "cached-project" >/dev/null
    local before
    before=$(captured_request_count '.')

    local pid
    pid=$(get_project_id "cached-project")
    local after
    after=$(captured_request_count '.')

    assert_eq "$pid" "proj_cached"
    assert_eq "$before" "$after"
}

t_get_project_401() {
    stub_response_for "*/v1/project*" 401 "Invalid API Key"

    local pid rc
    pid=$(get_project_id "doomed-project")
    rc=$?

    assert_failure "$rc"
    assert_eq "$pid" ""

    local log
    log=$(hook_log)
    assert_contains "$log" "authentication failed"
    assert_contains "$log" "BRAINTRUST_API_KEY"
}

t_get_project_403() {
    stub_response_for "*/v1/project*" 403 "Forbidden"

    local pid rc
    pid=$(get_project_id "forbidden-project")
    rc=$?

    assert_failure "$rc"
    assert_eq "$pid" ""

    local log
    log=$(hook_log)
    assert_contains "$log" "authentication failed"
}

t_get_project_create_escapes_special_chars() {
    # Project names can contain characters that would break a hand-rolled
    # JSON literal: double quotes, backslashes, newlines. The create body
    # must escape these correctly via jq.
    stub_response_for "*/v1/project?project_name=*" 200 '{}'
    stub_response_for "*/v1/project" 200 '{"id":"proj_created"}'

    local weird_name='my "quoted" \backslash project'
    local pid rc
    pid=$(get_project_id "$weird_name")
    rc=$?

    assert_success "$rc"
    assert_eq "$pid" "proj_created"

    # The POST body must be parseable JSON and the name field must round
    # trip cleanly (including the embedded quotes and backslash).
    local sent_name
    sent_name=$(jq -s --arg url "/v1/project" -r '
        [.[] | select(.method == "POST") | select(.url | endswith($url))]
        | .[-1].body.name
    ' "$CAPTURED_REQUESTS")
    assert_eq "$sent_name" "$weird_name"
}

it "returns the existing project id on successful lookup"             t_get_project_existing
it "creates a new project when lookup returns no id"                  t_get_project_create
it "escapes special characters in the project create body"            t_get_project_create_escapes_special_chars
it "caches the project id so the second call makes no HTTP request"   t_get_project_cached
it "returns non-zero and logs an auth error on HTTP 401"              t_get_project_401
it "returns non-zero and logs an auth error on HTTP 403"              t_get_project_403
