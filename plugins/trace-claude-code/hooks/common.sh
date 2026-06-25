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

# Check if a value is truthy (true, 1, yes, on - case insensitive)
is_truthy() {
    local val="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" || "$val" == "on" ]]
}

debug() { is_truthy "$DEBUG" && log "DEBUG" "$1" || true; }

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
    cached_id=$(get_state_value "$cache_key")
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
        set_state_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    # Create project
    debug "Creating project: $name"
    resp=$(curl -sf -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "{\"name\": \"$name\"}" "$api_url/v1/project" 2>/dev/null) || true
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_state_value "$cache_key" "$pid"
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

# --- Skill resolution (shared by UserPromptSubmit and PostToolUse) ---
# Extract a one-line description from a SKILL.md: inline `description:`, a YAML
# block scalar (`description: |` / `>`), else the first `#`+ heading.
__bt_skill_desc() {
    local f="$1" d
    d=$(awk '
        /^description:[[:space:]]*[|>]/ { blk=1; next }
        blk==1 { if ($0 ~ /^[[:space:]]+/) { sub(/^[[:space:]]+/,""); print; exit } else exit }
        /^description:[[:space:]]*[^|>[:space:]]/ { sub(/^description:[[:space:]]*/,""); print; exit }
    ' "$f")
    [ -n "$d" ] || d=$(awk '/^#+[[:space:]]/ { sub(/^#+[[:space:]]+/,""); print; exit }' "$f")
    printf '%s' "$d" | tr -d '"\r'
}

# Resolve a skill token (e.g. "my-skill" or "plugin:skill") to its definition.
# Echoes {name, description, instructions[, source]} JSON on success; nothing if
# unresolved. Best-effort: callers must guard -- this never aborts on its own.
# The token is sanitized to [A-Za-z0-9:_-] (no "." or "/"), so it can never be
# steered to read files outside the standard skill locations.
__bt_resolve_skill() {
    local name="$1" cwd="$2" source="${3:-}" subpath leaf base cand plugin sname sdesc sbody
    name=$(printf '%s' "$name" | sed 's#[^A-Za-z0-9:_-]##g')
    [ -n "$name" ] || return 0
    subpath=$(printf '%s' "$name" | tr ':' '/')
    leaf="${name##*:}"
    cand=""
    # 1) user- and project-authored skills (cheap stat, no scan)
    for base in "$cwd/.claude/skills" "$HOME/.claude/skills"; do
        [ -n "$base" ] || continue
        [ -f "$base/$subpath/SKILL.md" ] && { cand="$base/$subpath/SKILL.md"; break; }
        [ -f "$base/$name/SKILL.md" ] && { cand="$base/$name/SKILL.md"; break; }
    done
    # 2) installed plugin skills (cache) -- ONLY for namespaced "plugin:skill" tokens,
    #    so bare built-in commands (/clear, /model, ...) never trigger a filesystem scan.
    if [ -z "$cand" ]; then
        case "$name" in
            *:*)
                plugin="${name%%:*}"
                cand=$(find "$HOME/.claude/plugins/cache" -maxdepth 9 -type f -name SKILL.md -path "*/$plugin/*/$leaf/SKILL.md" 2>/dev/null | head -1)
                [ -n "$cand" ] || cand=$(find "$HOME/.claude/plugins/cache" -maxdepth 9 -type f -name SKILL.md -path "*/$leaf/SKILL.md" 2>/dev/null | head -1)
                ;;
        esac
    fi
    [ -n "$cand" ] && [ -f "$cand" ] || return 0
    sname=$(sed -n 's/^name:[[:space:]]*//p' "$cand" | head -1 | tr -d '"\r')
    [ -n "$sname" ] || sname="$leaf"
    sdesc=$(__bt_skill_desc "$cand")
    # Capturing the SKILL.md body (instructions) is what powers skill audits and
    # efficacy evals, but it puts the skill's text in the trace. On by default;
    # set BRAINTRUST_CC_CAPTURE_SKILL_INSTRUCTIONS=false (or 0/no/off) to record
    # only name + description for stricter environments.
    if is_truthy "${BRAINTRUST_CC_CAPTURE_SKILL_INSTRUCTIONS:-true}"; then
        sbody=$(awk 'c>=2{print} /^---[[:space:]]*$/{c++}' "$cand" | head -c 6000)
        [ -n "$sbody" ] || sbody=$(head -c 6000 "$cand")
        jq -n --arg n "$sname" --arg d "$sdesc" --arg i "$sbody" --arg s "$source" \
            '{name:$n, description:$d, instructions:$i} + (if $s != "" then {source:$s} else {} end)'
    else
        jq -n --arg n "$sname" --arg d "$sdesc" --arg s "$source" \
            '{name:$n, description:$d} + (if $s != "" then {source:$s} else {} end)'
    fi
    return 0
}

# Capture git diff for the current directory
capture_git_diff() {
    local cwd="${1:-.}"

    # Check if we're in a git repo
    if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    # Get all changes (staged and unstaged)
    local diff_output
    diff_output=$(git -C "$cwd" diff HEAD 2>/dev/null || echo "")

    # If no diff from HEAD, try to get untracked/staged files
    if [ -z "$diff_output" ]; then
        diff_output=$(git -C "$cwd" diff --cached 2>/dev/null || echo "")
    fi

    echo "$diff_output"
}

# Get current git state hash for comparison
get_git_state_hash() {
    local cwd="${1:-.}"

    if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    # Create a hash of current state (HEAD + status)
    local state
    state=$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo "no-git")
    state="${state}-$(git -C "$cwd" status --porcelain 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || md5 2>/dev/null || echo "no-changes")"
    echo "$state"
}
