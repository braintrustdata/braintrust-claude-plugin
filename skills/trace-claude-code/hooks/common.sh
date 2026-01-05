#!/bin/bash
###
# Common utilities for Braintrust Claude Code tracing hooks
###

# Config
export LOG_FILE="$HOME/.claude/state/braintrust_hook.log"
export STATE_FILE="$HOME/.claude/state/braintrust_state.json"
export SESSION_CONTEXT_FILE="${BRAINTRUST_SESSION_CONTEXT_FILE:-/tmp/braintrust_session.json}"
export DEBUG="${BRAINTRUST_CC_DEBUG:-false}"
export API_KEY="${BRAINTRUST_API_KEY}"
export PROJECT="${BRAINTRUST_CC_PROJECT:-claude-code}"
export APP_URL="${BRAINTRUST_APP_URL:-https://www.braintrust.dev}"

# Resolve API URL via login endpoint (with caching)
resolve_api_url() {
    # Check for explicit override first
    if [ -n "${BRAINTRUST_API_URL:-}" ]; then
        echo "$BRAINTRUST_API_URL"
        return 0
    fi

    # Check cache
    local cached_url
    cached_url=$(get_state_value "api_url")
    if [ -n "$cached_url" ]; then
        echo "$cached_url"
        return 0
    fi

    # Login to discover API URL
    if [ -z "$API_KEY" ]; then
        echo "https://api.braintrust.dev"
        return 0
    fi

    local resp
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" "$APP_URL/api/apikey/login" 2>/dev/null) || true

    local api_url
    local org_name="${BRAINTRUST_ORG_NAME:-}"

    if [ -n "$org_name" ]; then
        # Filter by org name if specified
        api_url=$(echo "$resp" | jq -r --arg name "$org_name" \
            '.org_info[] | select(.name == $name) | .api_url // empty' 2>/dev/null | head -1)
    else
        # Use first org
        api_url=$(echo "$resp" | jq -r '.org_info[0].api_url // empty' 2>/dev/null)
    fi

    if [ -n "$api_url" ]; then
        set_state_value "api_url" "$api_url"
        echo "$api_url"
        return 0
    fi

    # Fall back to default
    echo "https://api.braintrust.dev"
}

# Initialize API_URL (call resolve_api_url lazily when needed)
get_api_url() {
    if [ -z "${_RESOLVED_API_URL:-}" ]; then
        _RESOLVED_API_URL=$(resolve_api_url)
    fi
    echo "$_RESOLVED_API_URL"
}

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$STATE_FILE")"

# Logging
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }
debug() { [ "$(echo "$DEBUG" | tr '[:upper:]' '[:lower:]')" = "true" ] && log "DEBUG" "$1" || true; }

# Check if tracing is enabled
tracing_enabled() {
    [ "$(echo "$TRACE_TO_BRAINTRUST" | tr '[:upper:]' '[:lower:]')" = "true" ]
}

# Validate requirements
check_requirements() {
    for cmd in jq curl; do
        command -v "$cmd" &>/dev/null || { log "ERROR" "$cmd not installed"; return 1; }
    done
    [ -z "$API_KEY" ] && { log "ERROR" "BRAINTRUST_API_KEY not set"; return 1; }
    return 0
}

# Get or create project ID (cached)
get_project_id() {
    local name="$1"

    # Check cache first
    local cached_id
    cached_id=$(get_state_value "project_id")
    if [ -n "$cached_id" ]; then
        echo "$cached_id"
        return 0
    fi

    local encoded_name
    encoded_name=$(printf '%s' "$name" | jq -sRr @uri)

    # Try to get existing project
    local api_url
    api_url=$(get_api_url)
    local resp
    resp=$(curl -sf -H "Authorization: Bearer $API_KEY" "$api_url/v1/project?project_name=$encoded_name" 2>/dev/null) || true
    local pid
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_state_value "project_id" "$pid"
        echo "$pid"
        return 0
    fi

    # Create project
    debug "Creating project: $name"
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "{\"name\": \"$name\"}" "$api_url/v1/project" 2>/dev/null) || true
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_state_value "project_id" "$pid"
        echo "$pid"
        return 0
    fi

    return 1
}

# Insert a span to Braintrust
insert_span() {
    local project_id="$1"
    local event_json="$2"

    debug "Inserting span: $(echo "$event_json" | jq -c '.')"

    # Check if API_KEY is set
    if [ -z "$API_KEY" ]; then
        log "ERROR" "API_KEY is empty - check BRAINTRUST_API_KEY env var"
        return 1
    fi

    local api_url
    api_url=$(get_api_url)
    local resp http_code
    # Use -w to capture HTTP status, don't use -f so we can see error responses
    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"events\": [$event_json]}" \
        "$api_url/v1/project_logs/$project_id/insert" 2>&1)

    # Extract HTTP code from last line
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log "ERROR" "Insert failed (HTTP $http_code): $resp"
        return 1
    fi

    local row_id
    row_id=$(echo "$resp" | jq -r '.row_ids[0] // empty' 2>/dev/null)

    if [ -n "$row_id" ]; then
        echo "$row_id"
        return 0
    else
        log "WARN" "Insert returned empty row_ids: $resp"
        return 1
    fi
}

# State management
load_state() {
    [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "{}"
}

save_state() {
    echo "$1" > "$STATE_FILE"
}

get_state_value() {
    local key="$1"
    load_state | jq -r ".$key // empty"
}

set_state_value() {
    local key="$1"
    local value="$2"
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
    save_state "$state"
}

get_session_state() {
    local session_id="$1"
    local key="$2"
    load_state | jq -r ".sessions[\"$session_id\"].$key // empty"
}

set_session_state() {
    local session_id="$1"
    local key="$2"
    local value="$3"
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --arg s "$session_id" --arg k "$key" --arg v "$value" \
        '.sessions[$s] = (.sessions[$s] // {}) | .sessions[$s][$k] = $v')
    save_state "$state"
}

# Generate a UUID
generate_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# Get current ISO timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Get system info for metadata
get_hostname() {
    hostname 2>/dev/null || echo "unknown"
}

get_username() {
    whoami 2>/dev/null || echo "unknown"
}

get_os() {
    uname -s 2>/dev/null || echo "unknown"
}

# Parse span IDs from Braintrust SDK exported format (SpanComponentsV3)
# Format: version(1) + object_type(1) + num_uuids(1) + [field_id(1) + uuid(16)]... + JSON
# Field IDs: 1=OBJECT_ID, 2=ROW_ID, 3=SPAN_ID, 4=ROOT_SPAN_ID
# Output: span_id and root_span_id separated by space
parse_exported_span() {
    local exported="$1"
    [ -z "$exported" ] && return 1

    local result
    result=$(python3 -c "
import base64
import sys
from uuid import UUID

try:
    data = base64.b64decode('$exported')
    if len(data) < 3:
        sys.exit(1)

    num_uuids = data[2]
    uuids = {}
    offset = 3

    for _ in range(num_uuids):
        if offset + 17 > len(data):
            break
        field_id = data[offset]
        uuid_bytes = data[offset + 1:offset + 17]
        uuid_str = str(UUID(bytes=uuid_bytes))
        uuids[field_id] = uuid_str
        offset += 17

    span_id = uuids.get(3, '')      # SPAN_ID
    root_span_id = uuids.get(4, '') # ROOT_SPAN_ID

    if span_id and root_span_id:
        print(f'{span_id} {root_span_id}')
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null)

    [ -z "$result" ] && return 1
    echo "$result"
}

# Read session context from file for distributed tracing
# Sets: PARENT_SPAN_ID (for span_parents), TRACE_ROOT_ID (for root_span_id), CONTEXT_PROJECT
get_session_context() {
    PARENT_SPAN_ID=""
    TRACE_ROOT_ID=""
    CONTEXT_PROJECT=""

    if [ -f "$SESSION_CONTEXT_FILE" ]; then
        local exported project
        exported=$(jq -r '.parent_span // empty' "$SESSION_CONTEXT_FILE" 2>/dev/null)
        project=$(jq -r '.project // empty' "$SESSION_CONTEXT_FILE" 2>/dev/null)

        if [ -n "$exported" ]; then
            local parsed
            parsed=$(parse_exported_span "$exported")
            if [ -n "$parsed" ]; then
                PARENT_SPAN_ID=$(echo "$parsed" | cut -d' ' -f1)
                TRACE_ROOT_ID=$(echo "$parsed" | cut -d' ' -f2)
                debug "Parsed session context: parent=$PARENT_SPAN_ID root=$TRACE_ROOT_ID"
            fi
        fi

        [ -n "$project" ] && CONTEXT_PROJECT="$project"
    fi
}
