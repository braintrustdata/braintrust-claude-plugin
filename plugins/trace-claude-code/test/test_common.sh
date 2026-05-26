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
