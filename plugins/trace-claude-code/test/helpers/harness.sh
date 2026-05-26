#!/bin/bash
###
# Test harness: provides a clean, isolated environment for each test.
#
# Each test gets:
#   - A fresh temp directory used as $HOME so common.sh writes to it
#   - Env vars set to defaults safe for testing (e.g. BRAINTRUST_API_KEY)
#   - common.sh sourced so its functions are available
#   - The stubbed `curl` function loaded so no real network calls are made
#   - A capture file ($CAPTURED_REQUESTS) recording every HTTP request
#
# Usage in a test file:
#   source helpers/assert.sh
#   source helpers/harness.sh
#
#   describe "my function"
#   it "does the thing"
#     setup_test_env
#     ... call functions ...
#     assert_eq "$got" "$want"
#   end_it
###

# Locate the plugin root and hooks directory based on this file's path
TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$TEST_HELPERS_DIR")"
PLUGIN_DIR="$(dirname "$TEST_DIR")"
HOOKS_DIR="$PLUGIN_DIR/hooks"

export TEST_HELPERS_DIR TEST_DIR PLUGIN_DIR HOOKS_DIR

# Source the curl stub - defines curl() as a shell function that overrides
# the binary. Tests can configure responses via stub_response_for.
source "$TEST_HELPERS_DIR/curl_stub.sh"

# Source fixture builders and span-tree helpers so tests don't have to
# source them individually. These are pure helpers; no state.
source "$TEST_HELPERS_DIR/fixtures.sh"
source "$TEST_HELPERS_DIR/span_tree.sh"
source "$TEST_HELPERS_DIR/replay.sh"

# Per-test temp dir; reset on every setup_test_env call.
TEST_TMP=""

setup_test_env() {
    # Fresh isolated home for this test
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/braintrust-test.XXXXXX")
    export HOME="$TEST_TMP"

    # Defaults that make common.sh happy
    export BRAINTRUST_API_KEY="test-api-key"
    export BRAINTRUST_APP_URL="https://app.test.invalid"
    export BRAINTRUST_API_URL="https://api.test.invalid"
    export TRACE_TO_BRAINTRUST=true
    export DEBUG=false
    # Run the span queue inline so tests are deterministic - we don't
    # want to spawn background workers or wait on file watchers.
    export BRAINTRUST_SYNC_QUEUE=true
    # If a test opts into async mode and a worker is left behind, make
    # sure drain_queue calls don't block tests for the full default.
    export BRAINTRUST_DRAIN_TIMEOUT=5

    # Capture file for HTTP requests
    export CAPTURED_REQUESTS="$TEST_TMP/captured_requests.ndjson"
    : > "$CAPTURED_REQUESTS"

    # Reset stub response configuration
    _curl_stub_reset

    # Clear cached state from a previous test in the same shell.
    # common.sh caches API URL in _RESOLVED_API_URL; clearing avoids
    # cross-test pollution.
    unset _RESOLVED_API_URL

    # Source common.sh so its functions are available in this shell.
    # common.sh uses $HOME, so this must happen AFTER setting HOME.
    # shellcheck source=/dev/null
    source "$HOOKS_DIR/common.sh"

    # After sourcing common.sh, re-export the stub curl so it shadows the
    # binary for any subprocesses spawned by hook scripts.
    export -f curl
}

teardown_test_env() {
    if [ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ]; then
        rm -rf "$TEST_TMP"
    fi
    TEST_TMP=""
}

# Run a hook script as a subprocess with the given stdin payload.
# Returns the exit code; stdout/stderr are captured into the named variables.
#
# Usage:
#   run_hook session_start.sh "$payload"
#   echo "$HOOK_STDOUT" "$HOOK_STDERR" "$HOOK_STATUS"
run_hook() {
    local hook="$1"
    local payload="$2"
    local out err
    local tmpout tmperr
    tmpout=$(mktemp)
    tmperr=$(mktemp)

    # Pass the env explicitly so the subprocess sees our stub curl
    # (export -f propagates over `env` invocations in bash).
    echo "$payload" | bash "$HOOKS_DIR/$hook" >"$tmpout" 2>"$tmperr"
    HOOK_STATUS=$?
    HOOK_STDOUT=$(cat "$tmpout")
    HOOK_STDERR=$(cat "$tmperr")
    rm -f "$tmpout" "$tmperr"
    return $HOOK_STATUS
}

# Convenience: print the contents of the hook log file (common.sh writes
# to $HOME/.claude/state/braintrust_hook.log when sourced).
hook_log() {
    local f="$HOME/.claude/state/braintrust_hook.log"
    [ -f "$f" ] && cat "$f" || true
}
