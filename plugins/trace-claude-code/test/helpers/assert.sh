#!/bin/bash
###
# Assertion utilities for trace-claude-code tests.
#
# Test structure:
#   describe "thing under test"
#   it "behaves like X"
#     <commands>
#     assert_eq "$got" "$want"
#   end_it
#
# Each test file should source this and helpers/harness.sh, then declare
# its tests. The runner aggregates pass/fail counts in environment vars
# so multiple test files share a single tally.
###

# Color codes (disable if NO_COLOR or non-tty stdout)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BOLD=""
    C_DIM=""
    C_RESET=""
fi

# Test state - exported so subshells inherit, but counters are only meaningful
# at the top-level shell (we manage them via files for cross-process aggregation).
export TESTS_RUN_FILE="${TESTS_RUN_FILE:-/tmp/braintrust_test_run_$$}"
export TESTS_FAIL_FILE="${TESTS_FAIL_FILE:-/tmp/braintrust_test_fail_$$}"

# Per-test ephemeral state (not exported across processes)
CURRENT_DESCRIBE=""
CURRENT_IT=""
CURRENT_TEST_FAILED=0
CURRENT_TEST_FAILURES=()

_init_counters() {
    : > "$TESTS_RUN_FILE"
    : > "$TESTS_FAIL_FILE"
}

_incr_run() {
    echo "x" >> "$TESTS_RUN_FILE"
}

_incr_fail() {
    echo "x" >> "$TESTS_FAIL_FILE"
}

tests_total() {
    [ -f "$TESTS_RUN_FILE" ] && wc -l < "$TESTS_RUN_FILE" | tr -d ' ' || echo 0
}

tests_failed() {
    [ -f "$TESTS_FAIL_FILE" ] && wc -l < "$TESTS_FAIL_FILE" | tr -d ' ' || echo 0
}

describe() {
    CURRENT_DESCRIBE="$1"
    printf '\n%s%s%s\n' "$C_BOLD" "$CURRENT_DESCRIBE" "$C_RESET"
}

# Run a single test case.
#
# Usage:
#   it "does the thing" test_body_function_name
#
# The body function is invoked between setup_test_env and teardown_test_env
# (when those functions are defined). Inside the body you may use `local`
# variables freely. Use assert_* helpers to record failures; the test only
# fails if at least one assertion failed.
it() {
    CURRENT_IT="$1"
    local body_fn="$2"
    CURRENT_TEST_FAILED=0
    CURRENT_TEST_FAILURES=()
    _incr_run

    if declare -F setup_test_env >/dev/null; then
        setup_test_env
    fi

    # Run the test body in this shell so failures from assert_* propagate
    # into our CURRENT_TEST_FAILURES array. Suppress `set -e` style aborts
    # by using `|| true` if the body returns non-zero - we don't want the
    # whole test file to exit just because one assertion failed.
    "$body_fn" || true

    if [ "$CURRENT_TEST_FAILED" -eq 0 ]; then
        printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$CURRENT_IT"
    else
        _incr_fail
        printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$CURRENT_IT"
        for msg in "${CURRENT_TEST_FAILURES[@]}"; do
            printf '      %s%s%s\n' "$C_RED" "$msg" "$C_RESET"
        done
    fi

    if declare -F teardown_test_env >/dev/null; then
        teardown_test_env
    fi

    CURRENT_IT=""
    CURRENT_TEST_FAILED=0
    CURRENT_TEST_FAILURES=()
}

# Mark current test as failed and append a message
_fail() {
    CURRENT_TEST_FAILED=1
    CURRENT_TEST_FAILURES+=("$1")
}

assert_eq() {
    local got="$1" want="$2" msg="${3:-}"
    if [ "$got" != "$want" ]; then
        _fail "${msg:-assert_eq}: expected '$want', got '$got'"
        return 1
    fi
    return 0
}

assert_ne() {
    local got="$1" not_want="$2" msg="${3:-}"
    if [ "$got" = "$not_want" ]; then
        _fail "${msg:-assert_ne}: expected NOT '$not_want', got '$got'"
        return 1
    fi
    return 0
}

assert_match() {
    local got="$1" pattern="$2" msg="${3:-}"
    if ! [[ "$got" =~ $pattern ]]; then
        _fail "${msg:-assert_match}: '$got' does not match /$pattern/"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _fail "${msg:-assert_contains}: '$haystack' does not contain '$needle'"
        return 1
    fi
    return 0
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _fail "${msg:-assert_not_contains}: '$haystack' unexpectedly contains '$needle'"
        return 1
    fi
    return 0
}

assert_success() {
    local status="$1" msg="${2:-}"
    if [ "$status" -ne 0 ]; then
        _fail "${msg:-assert_success}: expected exit 0, got $status"
        return 1
    fi
    return 0
}

assert_failure() {
    local status="$1" msg="${2:-}"
    if [ "$status" -eq 0 ]; then
        _fail "${msg:-assert_failure}: expected non-zero exit, got 0"
        return 1
    fi
    return 0
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [ ! -f "$path" ]; then
        _fail "${msg:-assert_file_exists}: file '$path' does not exist"
        return 1
    fi
    return 0
}

# Explicit failure
fail() {
    _fail "${1:-explicit fail}"
    return 1
}

# Skip the current test without failing it. Prints a note; the test body
# should `return 0` immediately after calling this. The test still counts as
# run/passed (it makes no assertions), which keeps the suite green when an
# optional fixture is absent.
skip() {
    printf '      %s(skipped) %s%s\n' "$C_YELLOW" "${1:-no reason given}" "$C_RESET"
    return 0
}
