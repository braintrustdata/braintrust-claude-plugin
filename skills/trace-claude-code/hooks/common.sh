#!/bin/bash
###
# Common utilities for Braintrust Claude Code tracing hooks
###

# Config
export LOG_FILE="$HOME/.claude/state/braintrust_hook.log"
export STATE_FILE="$HOME/.claude/state/braintrust_state.json"
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

# Secret redaction configuration
export REDACT_ENABLED="${BRAINTRUST_REDACT_ENABLED:-true}"
export REDACT_PATTERNS="${BRAINTRUST_REDACT_PATTERNS:-}"
export SKIP_FILES="${BRAINTRUST_SKIP_FILES:-}"

# Default patterns to redact (common API keys and secrets)
DEFAULT_REDACT_PATTERNS=(
    'sk-[a-zA-Z0-9]{20,}'                    # OpenAI/Anthropic API keys
    'sk-proj-[a-zA-Z0-9]{20,}'               # OpenAI project keys
    'ghp_[a-zA-Z0-9]{36,}'                   # GitHub personal access tokens
    'gho_[a-zA-Z0-9]{36,}'                   # GitHub OAuth tokens
    'github_pat_[a-zA-Z0-9_]{22,}'           # GitHub fine-grained PATs
    'xoxb-[a-zA-Z0-9-]+'                     # Slack bot tokens
    'xoxp-[a-zA-Z0-9-]+'                     # Slack user tokens
    'AKIA[A-Z0-9]{16}'                       # AWS access key IDs
    'eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*'   # JWT tokens
    'npm_[a-zA-Z0-9]{36}'                    # npm tokens
    'pypi-[a-zA-Z0-9]{36,}'                  # PyPI tokens
)

# Default file patterns to skip content for
DEFAULT_SKIP_FILE_PATTERNS=(
    '*.env'
    '*.env.*'
    '.env.local'
    '.env.production'
    '.env.development'
    '*credentials*'
    '*secrets*'
    '*.pem'
    '*.key'
    '*.p12'
    '*.pfx'
    'id_rsa*'
    'id_ed25519*'
    '*.asc'
)

# Check if redaction is enabled
redaction_enabled() {
    [ "$(echo "$REDACT_ENABLED" | tr '[:upper:]' '[:lower:]')" = "true" ]
}

# Check if a file path matches skip patterns
should_skip_file_content() {
    local file_path="$1"
    [ -z "$file_path" ] && return 1
    
    local filename
    filename=$(basename "$file_path")
    
    # Check user-defined patterns first
    if [ -n "$SKIP_FILES" ]; then
        IFS=',' read -ra USER_PATTERNS <<< "$SKIP_FILES"
        for pattern in "${USER_PATTERNS[@]}"; do
            pattern=$(echo "$pattern" | xargs)  # trim whitespace
            case "$filename" in
                $pattern) return 0 ;;
            esac
            case "$file_path" in
                $pattern) return 0 ;;
            esac
        done
    fi
    
    # Check default patterns
    for pattern in "${DEFAULT_SKIP_FILE_PATTERNS[@]}"; do
        case "$filename" in
            $pattern) return 0 ;;
        esac
    done
    
    return 1
}

# Redact secrets from a string
# Usage: echo "$content" | redact_secrets
redact_secrets() {
    local input
    input=$(cat)
    
    # Skip if redaction disabled
    if ! redaction_enabled; then
        echo "$input"
        return 0
    fi
    
    local result="$input"
    
    # Apply default patterns
    for pattern in "${DEFAULT_REDACT_PATTERNS[@]}"; do
        result=$(echo "$result" | sed -E "s/$pattern/[REDACTED]/g" 2>/dev/null || echo "$result")
    done
    
    # Apply generic key=value patterns for common secret names
    result=$(echo "$result" | sed -E \
        -e 's/(password["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(secret["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(api_key["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(apikey["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(token["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(private_key["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(access_token["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(refresh_token["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(client_secret["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        -e 's/(database_url["\x27]?\s*[:=]\s*["\x27]?)([^"\x27\s,}]+)/\1[REDACTED]/gi' \
        2>/dev/null || echo "$result")
    
    # Apply user-defined patterns
    if [ -n "$REDACT_PATTERNS" ]; then
        IFS=',' read -ra USER_PATTERNS <<< "$REDACT_PATTERNS"
        for pattern in "${USER_PATTERNS[@]}"; do
            pattern=$(echo "$pattern" | xargs)  # trim whitespace
            result=$(echo "$result" | sed -E "s/$pattern/[REDACTED]/g" 2>/dev/null || echo "$result")
        done
    fi
    
    echo "$result"
}

# Redact JSON content (handles nested structures)
# Usage: redact_json "$json_string"
redact_json() {
    local json="$1"
    
    if ! redaction_enabled; then
        echo "$json"
        return 0
    fi
    
    # Pass through redact_secrets for pattern matching
    echo "$json" | redact_secrets
}

# Create a redacted placeholder for sensitive files
get_redacted_file_placeholder() {
    local file_path="$1"
    jq -n --arg path "$file_path" \
        '{"content": "[REDACTED - SENSITIVE FILE]", "file": $path, "redacted": true}'
}

get_hostname() {
    hostname 2>/dev/null || echo "unknown"
}

get_username() {
    whoami 2>/dev/null || echo "unknown"
}

get_os() {
    uname -s 2>/dev/null || echo "unknown"
}

