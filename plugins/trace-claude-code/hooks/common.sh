#!/bin/bash
###
# Common utilities for Braintrust Claude Code tracing hooks
###

# Config
export LOG_FILE="$HOME/.claude/state/braintrust_hook.log"
export CACHE_FILE="$HOME/.claude/state/braintrust_cache.json"
export SESSION_STATE_DIR="$HOME/.claude/state/braintrust_sessions"
export DEBUG="${BRAINTRUST_CC_DEBUG:-false}"
export API_KEY="${BRAINTRUST_API_KEY}"
export PROJECT="${BRAINTRUST_CC_PROJECT:-claude-code}"
export APP_URL="${BRAINTRUST_APP_URL:-https://www.braintrust.dev}"

# Parent span configuration (for attaching to an existing trace)
# If either is set, we're attaching to an existing trace
# Each defaults to the other if not set
if [ -n "${CC_PARENT_SPAN_ID:-}" ] && [ -z "${CC_ROOT_SPAN_ID:-}" ]; then
    export CC_ROOT_SPAN_ID="$CC_PARENT_SPAN_ID"
elif [ -n "${CC_ROOT_SPAN_ID:-}" ] && [ -z "${CC_PARENT_SPAN_ID:-}" ]; then
    export CC_PARENT_SPAN_ID="$CC_ROOT_SPAN_ID"
fi
export CC_PARENT_SPAN_ID="${CC_PARENT_SPAN_ID:-}"
export CC_ROOT_SPAN_ID="${CC_ROOT_SPAN_ID:-}"

# Experiment mode configuration
# If CC_EXPERIMENT_ID is set, spans are inserted into the experiment instead of project_logs
export CC_EXPERIMENT_ID="${CC_EXPERIMENT_ID:-}"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$SESSION_STATE_DIR"

# Logging (defined early so other functions can use it)
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }

# Check if a value is truthy (true, 1, yes, on - case insensitive)
is_truthy() {
    local val="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" || "$val" == "on" ]]
}

debug() { is_truthy "$DEBUG" && log "DEBUG" "$1" || true; }

###
# Cache management (shared across sessions, used for API URL and project IDs)
# Uses simple file-based caching - minor races here are harmless (just extra API calls)
###

get_cache_value() {
    local key="$1"
    [ -f "$CACHE_FILE" ] && cat "$CACHE_FILE" | jq -r ".$key // empty" 2>/dev/null || echo ""
}

set_cache_value() {
    local key="$1"
    local value="$2"
    local cache
    cache=$([ -f "$CACHE_FILE" ] && cat "$CACHE_FILE" 2>/dev/null || echo '{}')
    cache=$(echo "$cache" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' 2>/dev/null) || return 0
    local tmp="$CACHE_FILE.tmp.$$"
    echo "$cache" > "$tmp" && mv "$tmp" "$CACHE_FILE"
}

# Resolve API URL via login endpoint (with caching)
resolve_api_url() {
    # Check for explicit override first
    if [ -n "${BRAINTRUST_API_URL:-}" ]; then
        echo "$BRAINTRUST_API_URL"
        return 0
    fi

    # Check cache
    local cached_url
    cached_url=$(get_cache_value "api_url")
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
        set_cache_value "api_url" "$api_url"
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

# Check if tracing is enabled
tracing_enabled() {
    is_truthy "$TRACE_TO_BRAINTRUST"
}

# Validate requirements
check_requirements() {
    for cmd in jq curl uuidgen; do
        command -v "$cmd" &>/dev/null || { log "ERROR" "$cmd not installed"; return 1; }
    done
    [ -z "$API_KEY" ] && { log "ERROR" "BRAINTRUST_API_KEY not set"; return 1; }
    return 0
}

# Get or create project ID (cached per project name)
get_project_id() {
    local name="$1"
    local cache_key="project_id_$name"

    # Check cache first
    local cached_id
    cached_id=$(get_cache_value "$cache_key")
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
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    # Create project
    debug "Creating project: $name"
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "{\"name\": \"$name\"}" "$api_url/v1/project" 2>/dev/null) || true
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    return 1
}

# Check if we're in experiment mode
is_experiment_mode() {
    [ -n "$CC_EXPERIMENT_ID" ]
}

# Get the insert endpoint URL based on mode (experiment vs project_logs)
get_insert_endpoint() {
    local object_id="$1"
    local api_url
    api_url=$(get_api_url)

    if is_experiment_mode; then
        echo "$api_url/v1/experiment/$CC_EXPERIMENT_ID/insert"
    else
        echo "$api_url/v1/project_logs/$object_id/insert"
    fi
}

# Insert a span to Braintrust
# In experiment mode, project_id is ignored and CC_EXPERIMENT_ID is used instead
insert_span() {
    local project_id="$1"
    local event_json="$2"

    debug "Inserting span: $(echo "$event_json" | jq -c '.')"

    # Check if API_KEY is set
    if [ -z "$API_KEY" ]; then
        log "ERROR" "API_KEY is empty - check BRAINTRUST_API_KEY env var"
        return 1
    fi

    local endpoint
    endpoint=$(get_insert_endpoint "$project_id")
    debug "Insert endpoint: $endpoint"

    local resp http_code
    # Use -w to capture HTTP status, don't use -f so we can see error responses
    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"events\": [$event_json]}" \
        "$endpoint" 2>&1)

    # Extract HTTP code from last line
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log "ERROR" "Insert failed (HTTP $http_code) to $endpoint: $resp"
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

###
# Per-session state management
# Each session has its own state file: $SESSION_STATE_DIR/{session_id}.json
# This eliminates race conditions between sessions entirely.
###

# Get the state file path for a session
get_session_state_file() {
    local session_id="$1"
    echo "$SESSION_STATE_DIR/${session_id}.json"
}

# Get a value from session state
get_session_state() {
    local session_id="$1"
    local key="$2"
    local state_file
    state_file=$(get_session_state_file "$session_id")
    [ -f "$state_file" ] && cat "$state_file" | jq -r ".$key // empty" 2>/dev/null || echo ""
}

# Set a value in session state
set_session_state() {
    local session_id="$1"
    local key="$2"
    local value="$3"
    local state_file state
    state_file=$(get_session_state_file "$session_id")
    state=$([ -f "$state_file" ] && cat "$state_file" || echo '{}')
    state=$(echo "$state" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
    echo "$state" > "$state_file"
}

# Atomic check-and-set for session state - returns 0 if set, 1 if already exists
# Uses mkdir as an atomic lock for the specific session
check_and_set_session_state() {
    local session_id="$1"
    local key="$2"
    local value="$3"
    local state_file lock_dir
    state_file=$(get_session_state_file "$session_id")
    lock_dir="${state_file}.lock"

    # Try to acquire lock for this specific session
    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Another process is initializing this session, wait briefly and check
        sleep 0.1
        local existing
        existing=$(get_session_state "$session_id" "$key")
        if [ -n "$existing" ]; then
            echo "$existing"
            return 1
        fi
        # Lock was released but key still not set - try again
        rmdir "$lock_dir" 2>/dev/null || true
        if ! mkdir "$lock_dir" 2>/dev/null; then
            # Still can't get lock, just check and return
            existing=$(get_session_state "$session_id" "$key")
            if [ -n "$existing" ]; then
                echo "$existing"
                return 1
            fi
        fi
    fi

    # We have the lock - check if key already exists
    local existing
    existing=$(get_session_state "$session_id" "$key")
    if [ -n "$existing" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
        echo "$existing"
        return 1
    fi

    # Set the value
    set_session_state "$session_id" "$key" "$value"
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
}

# Clean up old session state files (call periodically or from session_stop)
cleanup_old_sessions() {
    local max_age_hours="${1:-24}"
    local max_age_minutes=$((max_age_hours * 60))
    find "$SESSION_STATE_DIR" -name "*.json" -mmin "+$max_age_minutes" -delete 2>/dev/null || true
    find "$SESSION_STATE_DIR" -name "*.lock" -mmin "+5" -delete 2>/dev/null || true
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
