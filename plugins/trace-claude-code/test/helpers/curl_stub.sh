#!/bin/bash
###
# curl stub for tests.
#
# Defines a shell function `curl` that overrides the binary in any code
# sourced/exec'd after this file is loaded. The stub:
#   1. Parses curl args to extract METHOD, URL, and the -d/--data body.
#   2. Appends a single NDJSON line to $CAPTURED_REQUESTS describing the call.
#   3. Looks up a canned response based on URL pattern matching.
#   4. Emits the response body to stdout, followed by a newline + status code
#      if the call included -w "%{http_code}" (matching real curl behavior).
#
# Configuring responses in a test:
#
#   stub_response_for "*/api/apikey/login" 200 '{"org_info":[{"api_url":"https://api.test.invalid"}]}'
#   stub_response_for "*/v1/project*"      200 '{"id":"proj_abc"}'
#   stub_response_for "*/insert"           200 '{"row_ids":["row_xyz"]}'
#
# Patterns are bash glob patterns (case-style matching). The first matching
# pattern wins. If no pattern matches, the stub returns 200 with an empty
# JSON object; the failing test will surface that as a missing expectation.
#
# To simulate auth failure:
#   stub_response_for "*" 401 "Invalid API Key"
###

# Arrays storing (pattern, status, body) triplets in parallel.
# Bash 3 (default on macOS) lacks associative arrays for this, so we use
# parallel indexed arrays.
_CURL_STUB_PATTERNS=()
_CURL_STUB_STATUSES=()
_CURL_STUB_BODIES=()

_curl_stub_reset() {
    _CURL_STUB_PATTERNS=()
    _CURL_STUB_STATUSES=()
    _CURL_STUB_BODIES=()
    # Re-export so subprocesses see the cleared state (they get a copy at exec).
    _curl_stub_export
}

stub_response_for() {
    local pattern="$1"
    local status="$2"
    local body="$3"
    _CURL_STUB_PATTERNS+=("$pattern")
    _CURL_STUB_STATUSES+=("$status")
    _CURL_STUB_BODIES+=("$body")
    _curl_stub_export
}

# Encode the stub config into a single env var so child processes can rebuild
# the lookup. Format: NDJSON, one line per stub.
_curl_stub_export() {
    local i out=""
    for i in "${!_CURL_STUB_PATTERNS[@]}"; do
        out+=$(printf '%s\t%s\t%s\n' "${_CURL_STUB_PATTERNS[i]}" "${_CURL_STUB_STATUSES[i]}" "${_CURL_STUB_BODIES[i]}")
        out+=$'\n'
    done
    export _CURL_STUB_CONFIG="$out"
}

# Rebuild local arrays from the env var (used in subprocesses that inherit
# the env but not the bash arrays).
_curl_stub_import() {
    _CURL_STUB_PATTERNS=()
    _CURL_STUB_STATUSES=()
    _CURL_STUB_BODIES=()
    [ -z "${_CURL_STUB_CONFIG:-}" ] && return 0
    local line pattern status body
    while IFS=$'\t' read -r pattern status body; do
        [ -z "$pattern" ] && continue
        _CURL_STUB_PATTERNS+=("$pattern")
        _CURL_STUB_STATUSES+=("$status")
        _CURL_STUB_BODIES+=("$body")
    done <<< "$_CURL_STUB_CONFIG"
}

# The curl stub itself. Designed to handle the curl invocation patterns
# used in common.sh (see top of file for the catalogue).
curl() {
    # Rebuild stub config in case we're in a subprocess that inherited only env.
    _curl_stub_import

    local method="GET"
    local url=""
    local data=""
    local want_http_code=0
    local arg

    # Parse args. We handle the flags actually used by common.sh:
    #   -s          silent (ignore)
    #   -f          fail on error (ignore - we control status)
    #   -X METHOD   method
    #   -H HEADER   header (ignore - we don't assert on headers)
    #   -d DATA     request body
    #   -w FORMAT   write-out format; we check for %{http_code}
    #   URL         positional
    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            -s|--silent) shift ;;
            -f|--fail) shift ;;
            -X|--request) method="$2"; shift 2 ;;
            -H|--header) shift 2 ;;
            -d|--data|--data-raw|--data-binary) data="$2"; shift 2 ;;
            -w|--write-out)
                if [[ "$2" == *"%{http_code}"* ]]; then
                    want_http_code=1
                fi
                shift 2
                ;;
            -o|--output) shift 2 ;;
            -L|--location) shift ;;
            --) shift; break ;;
            -*)
                # Unknown flag — try to skip it without consuming the next arg.
                # This is best-effort; if it requires a value we may misparse.
                shift
                ;;
            *)
                # Treat as URL if we don't have one yet
                if [ -z "$url" ]; then
                    url="$arg"
                fi
                shift
                ;;
        esac
    done

    # Default to POST if -d was provided but -X wasn't (matches curl behavior)
    if [ -n "$data" ] && [ "$method" = "GET" ]; then
        method="POST"
    fi

    # Record the request to the capture file as NDJSON.
    if [ -n "${CAPTURED_REQUESTS:-}" ]; then
        # Try to record data as parsed JSON when possible, otherwise as a string.
        local data_field
        if [ -z "$data" ]; then
            data_field='null'
        elif echo "$data" | jq -e . >/dev/null 2>&1; then
            data_field=$(echo "$data" | jq -c .)
        else
            data_field=$(jq -nc --arg d "$data" '$d')
        fi
        jq -nc \
            --arg method "$method" \
            --arg url "$url" \
            --argjson data "$data_field" \
            '{method: $method, url: $url, body: $data}' >> "$CAPTURED_REQUESTS"
    fi

    # Find a matching response
    local status=200
    local body='{}'
    local i matched=0
    for i in "${!_CURL_STUB_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        case "$url" in
            ${_CURL_STUB_PATTERNS[i]})
                status="${_CURL_STUB_STATUSES[i]}"
                body="${_CURL_STUB_BODIES[i]}"
                matched=1
                break
                ;;
        esac
    done

    # Default behavior on no match: 200 with empty object body.
    # Tests that care should configure stubs.

    # Emit response.
    printf '%s' "$body"
    if [ "$want_http_code" -eq 1 ]; then
        printf '\n%s' "$status"
    fi

    # Exit status: real curl returns non-zero on connection errors etc.
    # We always return 0 - the HTTP status code communicates HTTP errors.
    return 0
}

# Inspection helpers for tests.

# Print all captured requests as pretty JSON (one object per request, joined).
captured_requests() {
    [ -f "${CAPTURED_REQUESTS:-/dev/null}" ] || return 0
    jq -s . "$CAPTURED_REQUESTS"
}

# Print all captured requests that match a URL glob, as a JSON array.
captured_requests_matching() {
    local pattern="$1"
    [ -f "${CAPTURED_REQUESTS:-/dev/null}" ] || { echo '[]'; return 0; }
    jq -s --arg p "$pattern" '
        [ .[] | select(.url | test($p)) ]
    ' "$CAPTURED_REQUESTS"
}

# Count captured requests matching a URL glob.
captured_request_count() {
    local pattern="${1:-.*}"
    [ -f "${CAPTURED_REQUESTS:-/dev/null}" ] || { echo 0; return 0; }
    jq -s --arg p "$pattern" '
        [ .[] | select(.url | test($p)) ] | length
    ' "$CAPTURED_REQUESTS"
}

# Extract all spans from /insert calls as a flat JSON array.
captured_spans() {
    [ -f "${CAPTURED_REQUESTS:-/dev/null}" ] || { echo '[]'; return 0; }
    jq -s '
        [ .[] | select(.url | test("/insert$")) | .body.events[]? ]
    ' "$CAPTURED_REQUESTS"
}

# Export helper functions so subprocesses (hook scripts run via run_hook)
# inherit them - the stubbed curl() function calls _curl_stub_import on
# every invocation to rebuild its lookup table from $_CURL_STUB_CONFIG.
export -f _curl_stub_reset
export -f _curl_stub_export
export -f _curl_stub_import
export -f curl
