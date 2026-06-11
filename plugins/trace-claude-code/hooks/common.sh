#!/bin/bash
###
# Common utilities for Braintrust Claude Code tracing hooks
###

# Config
export LOG_FILE="$HOME/.claude/state/braintrust_hook.log"
export CACHE_FILE="$HOME/.claude/state/braintrust_cache.json"
export SESSION_STATE_DIR="$HOME/.claude/state/braintrust_sessions"
export QUEUE_DIR="$HOME/.claude/state/braintrust_queue"
export DEBUG="${BRAINTRUST_CC_DEBUG:-false}"
export API_KEY="${BRAINTRUST_API_KEY}"
export PROJECT="${BRAINTRUST_CC_PROJECT:-claude-code}"
export APP_URL="${BRAINTRUST_APP_URL:-https://www.braintrust.dev}"

# If true, enqueue_span processes jobs inline rather than spawning a worker.
# Used by tests and as a debugging knob. Default: false (async worker).
export BRAINTRUST_SYNC_QUEUE="${BRAINTRUST_SYNC_QUEUE:-false}"

# How long drain_queue will wait (seconds) before giving up. Hooks must
# never block Claude Code forever.
export BRAINTRUST_DRAIN_TIMEOUT="${BRAINTRUST_DRAIN_TIMEOUT:-30}"

# How long the worker.lock mtime can be stale (seconds) before a session
# is considered crashed and its queue dir is swept on the next
# session_start. The worker refreshes its lock every loop iteration
# (~0.2s), so 5 minutes is ~1500x margin against transient slowness.
export BRAINTRUST_WORKER_STALE_SECS="${BRAINTRUST_WORKER_STALE_SECS:-300}"

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

# Ensure top-level directories exist. Per-session sub-trees under
# $QUEUE_DIR/<session_id>/ are created on demand by enqueue_span.
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$SESSION_STATE_DIR"
mkdir -p "$QUEUE_DIR"

# Logging (defined early so other functions can use it)
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }

# Check if a value is truthy (true, 1, yes, on - case insensitive)
is_truthy() {
    local val="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" || "$val" == "on" ]]
}

debug() { is_truthy "$DEBUG" && log "DEBUG" "$1" || true; }

###
# Hook input recording (for capturing real Claude Code sessions to use
# as test fixtures).
#
# When BRAINTRUST_RECORD_DIR is set, every hook calls record_hook_input
# right after reading stdin. The function appends an NDJSON record to
# $BRAINTRUST_RECORD_DIR/events.ndjson and, for the Stop hook, copies the
# transcript file referenced in the payload to
# $BRAINTRUST_RECORD_DIR/transcripts/.
#
# To capture a session:
#   export BRAINTRUST_RECORD_DIR=~/my-session-fixture
#   <run claude code normally>
#
# Recordings are then replayed in tests via test/helpers/replay.sh.
###
record_hook_input() {
    local hook_name="$1"
    local payload="$2"

    [ -z "${BRAINTRUST_RECORD_DIR:-}" ] && return 0

    mkdir -p "$BRAINTRUST_RECORD_DIR" "$BRAINTRUST_RECORD_DIR/transcripts" 2>/dev/null || return 0

    local ts events_file
    ts=$(get_timestamp 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    events_file="$BRAINTRUST_RECORD_DIR/events.ndjson"

    # Build the record. payload may already be valid JSON; if not, treat as string.
    local payload_field
    if [ -n "$payload" ] && echo "$payload" | jq -e . >/dev/null 2>&1; then
        payload_field=$(echo "$payload" | jq -c .)
    else
        payload_field=$(jq -nc --arg p "$payload" '$p')
    fi

    # Always label the event with Claude Code's canonical event name. The
    # payload carries it as `hook_event_name` (e.g. "SessionStart",
    # "PostToolUse", "PreCompact"); fall back to the caller-supplied name
    # only when the payload doesn't include it. This gives the recording a
    # single CamelCase namespace so replay can dispatch every event through
    # hooks.json exactly the way Claude Code does.
    local event_name
    event_name=$(echo "$payload_field" | jq -r '.hook_event_name // empty' 2>/dev/null)
    [ -z "$event_name" ] && event_name="$hook_name"
    hook_name="$event_name"

    local record
    record=$(jq -nc \
        --arg ts "$ts" \
        --arg hook "$hook_name" \
        --argjson payload "$payload_field" \
        '{ts: $ts, hook: $hook, payload: $payload}' 2>/dev/null) || return 0

    # Atomic append: claim an exclusive lock via mkdir, write, release.
    # Parallel PostToolUse hooks can otherwise interleave bytes into the
    # NDJSON file, corrupting fixture lines (one torn line makes jq reject
    # the whole file at replay time). mkdir is the only portable lock
    # primitive we have (flock is not available on macOS by default).
    #
    # If we can't acquire the lock within ~500ms we DROP the record and
    # log a warning rather than fall back to an unlocked write. Recording
    # is opt-in and best-effort; losing one record on contention is
    # strictly better than producing a fixture that won't parse.
    #
    # If a previous writer was killed and left the lock dir behind, the
    # directory's mtime will be older than RECORD_LOCK_STALE_SECS and we
    # forcibly remove it before retrying (same pattern as worker.lock).
    #
    # 30s threshold balances two concerns:
    #   - Crash recovery: a SIGKILLed holder needs to be reclaimed.
    #   - False preemption: the recording lock has no heartbeat, so a
    #     healthy holder stuck on slow disk I/O (Time Machine snapshots,
    #     disk pressure) must not be preempted while still working. The
    #     critical section is one printf >> file, so 30s is ~6 orders of
    #     magnitude above the expected duration.
    local lock_dir="$events_file.lock"
    local stale_secs=30
    local i acquired=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if mkdir "$lock_dir" 2>/dev/null; then
            acquired=1
            break
        fi
        # Lock is held - check whether it's stale.
        local lock_mtime now age
        lock_mtime=$(stat -f '%m' "$lock_dir" 2>/dev/null \
            || stat -c '%Y' "$lock_dir" 2>/dev/null \
            || echo 0)
        now=$(date +%s)
        age=$((now - lock_mtime))
        if [ "$age" -gt "$stale_secs" ]; then
            # Lock is stale; reclaim it.
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        sleep 0.05
    done

    if [ "$acquired" -eq 1 ]; then
        printf '%s\n' "$record" >> "$events_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
    else
        log "WARN" "record_hook_input: dropped $hook_name record after lock contention timeout"
        return 0
    fi

    # Snapshot any transcript files referenced by this event so the
    # recording can be replayed deterministically. (Path rewriting from
    # absolute to fixture-relative happens at replay time in
    # test/helpers/replay.sh, not here; we only copy the files.)
    #
    # Two cases:
    #   - Stop carries `transcript_path` (the main conversation transcript).
    #   - SubagentStop carries `agent_transcript_path` (the sub-agent's own
    #     transcript, which holds its model calls - e.g. haiku - and which
    #     Claude Code may clean up shortly after the agent finishes, so we
    #     must snapshot it now, while it still exists).
    #
    # All transcripts land flat in transcripts/. Basenames are globally
    # unique (main: "<session>.jsonl"; agent: "agent-<id>.jsonl"), so there
    # is no collision and replay can resolve any of them by basename.
    _snapshot_transcript() {
        local src="$1"
        [ -n "$src" ] && [ -f "$src" ] || return 0
        local base
        base=$(basename "$src")
        cp "$src" "$BRAINTRUST_RECORD_DIR/transcripts/$base" 2>/dev/null || true
    }

    case "$hook_name" in
        Stop)
            _snapshot_transcript "$(echo "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
            ;;
        SubagentStop)
            _snapshot_transcript "$(echo "$payload" | jq -r '.agent_transcript_path // empty' 2>/dev/null)"
            ;;
    esac
}

###
# Cache management (shared across sessions, used for API URL and project IDs)
# Uses simple file-based caching - minor races here are harmless (just extra API calls)
###

get_cache_value() {
    local key="$1"
    # Use --arg + bracket lookup so keys containing dashes/dots/etc work
    [ -f "$CACHE_FILE" ] && jq -r --arg k "$key" '.[$k] // empty' "$CACHE_FILE" 2>/dev/null || echo ""
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

    local resp http_code
    resp=$(curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer $API_KEY" "$APP_URL/api/apikey/login" 2>/dev/null)
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        log "ERROR" "Braintrust authentication failed (HTTP $http_code) at $APP_URL/api/apikey/login - BRAINTRUST_API_KEY appears to be invalid or expired. Check your API key at $APP_URL/app/settings?subroute=api-keys"
        # Fall back to default API URL so callers can produce a definitive auth error too
        echo "https://api.braintrust.dev"
        return 0
    fi

    if [ "$http_code" != "200" ]; then
        log "WARN" "Braintrust login endpoint returned HTTP $http_code at $APP_URL/api/apikey/login: $resp"
    fi

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
    local resp http_code
    resp=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $API_KEY" "$api_url/v1/project?project_name=$encoded_name" 2>/dev/null)
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        log "ERROR" "Braintrust authentication failed (HTTP $http_code) - BRAINTRUST_API_KEY is invalid, expired, or lacks permission. Get a new key at $APP_URL/app/settings?subroute=api-keys and set BRAINTRUST_API_KEY. Response: $resp"
        return 1
    fi

    local pid
    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    if [ "$http_code" != "200" ] && [ "$http_code" != "404" ]; then
        log "WARN" "Project lookup returned HTTP $http_code at $api_url/v1/project: $resp"
    fi

    # Create project. Build the JSON body with jq so any special chars
    # (quotes, backslashes, control chars) in the project name are
    # properly escaped rather than interpolated raw into a string literal.
    debug "Creating project: $name"
    local create_body
    create_body=$(jq -nc --arg name "$name" '{name: $name}')
    resp=$(curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "$create_body" "$api_url/v1/project" 2>/dev/null)
    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        log "ERROR" "Braintrust authentication failed (HTTP $http_code) while creating project '$name' - BRAINTRUST_API_KEY is invalid, expired, or lacks permission. Get a new key at $APP_URL/app/settings?subroute=api-keys. Response: $resp"
        return 1
    fi

    pid=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$pid" ]; then
        set_cache_value "$cache_key" "$pid"
        echo "$pid"
        return 0
    fi

    log "ERROR" "Failed to create project '$name' (HTTP $http_code) at $api_url/v1/project: $resp"
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

# Low-level HTTP insert: POSTs a single span event to the Braintrust insert
# endpoint and returns the inserted row id on stdout. Used by the queue
# worker; hooks should call enqueue_span() instead.
#
# In experiment mode, project_id is ignored and CC_EXPERIMENT_ID is used.
_http_insert_span() {
    local project_id="$1"
    local event_json="$2"

    debug "Inserting span: $(echo "$event_json" | jq -c '.')"

    if [ -z "$API_KEY" ]; then
        log "ERROR" "API_KEY is empty - check BRAINTRUST_API_KEY env var"
        return 1
    fi

    local endpoint
    endpoint=$(get_insert_endpoint "$project_id")
    debug "Insert endpoint: $endpoint"

    # Wrap the (already-jq-built) event in the insert envelope via jq.
    # This validates the event is well-formed JSON before we POST it and
    # avoids hand-crafted string concatenation around the body.
    local body
    body=$(jq -nc --argjson event "$event_json" '{events: [$event]}') || {
        log "ERROR" "Insert aborted: event JSON failed to parse"
        return 1
    }

    local resp http_code
    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$endpoint" 2>&1)

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
# Queue layer (per-session)
#
# Hooks call enqueue_span() to schedule a span insert without blocking.
# Each Claude Code session gets its own queue subtree and its own
# background worker (hooks/worker.sh). This isolates sessions from one
# another: one session's slow inserts can't delay another's, and one
# session's worker crash doesn't strand another's spans.
#
# Filesystem layout:
#   $QUEUE_DIR/<session_id>/pending/<ts>-<uuid>.json
#   $QUEUE_DIR/<session_id>/processing/<ts>-<uuid>.json
#   $QUEUE_DIR/<session_id>/worker.lock
#
# The worker.lock file holds the worker PID, and the worker refreshes its
# mtime on every loop iteration. A future session_start invocation can
# detect a crashed session by finding stale lock files (mtime older than
# $BRAINTRUST_WORKER_STALE_SECS).
#
# Job file is one JSON object: {project_id, experiment_id, event}
###

# Return the queue dir for a session (no trailing slash).
session_queue_dir() {
    local session_id="$1"
    echo "$QUEUE_DIR/$session_id"
}

# Create the on-disk layout for a session's queue if it doesn't already exist.
_ensure_session_queue() {
    local session_id="$1"
    local dir
    dir=$(session_queue_dir "$session_id")
    mkdir -p "$dir/pending" "$dir/processing"
}

# Generate a monotonic-ish job filename. Uses epoch-ns + uuid suffix so the
# directory listing sorts in roughly insertion order without needing a
# central counter (multiple processes can enqueue concurrently safely).
#
# FIFO caveats:
#   - Across distinct hook invocations, timestamps differ enough that
#     create-then-merge orderings (e.g. user_prompt_submit creating a
#     Turn span and a later stop_hook enqueuing a merge update to it)
#     are reliably ordered correctly.
#   - Within a SINGLE process that enqueues multiple spans back-to-back,
#     timestamps can collide. We tie-break on uuid suffix, which is
#     effectively random - meaning two enqueues from the same process at
#     the same timestamp are NOT guaranteed FIFO. Don't enqueue a span
#     and its merge from the same hook script.
#   - On macOS without python3, the fallback drops to second-level
#     precision (appending `000000000`), widening the collision window
#     dramatically. Prefer python3 (or coreutils `gdate +%s%N`) when
#     available to keep nanosecond precision.
_queue_job_name() {
    local ts uuid
    # Linux: `date +%s%N` gives epoch-nanoseconds directly.
    if date +%s%N 2>/dev/null | grep -qv 'N$'; then
        ts=$(date +%s%N)
    elif command -v python3 >/dev/null 2>&1; then
        # macOS: prefer python's time_ns for true ns precision.
        ts=$(python3 -c 'import time; print(time.time_ns())')
    elif command -v gdate >/dev/null 2>&1; then
        # macOS with GNU coreutils installed.
        ts=$(gdate +%s%N)
    else
        # Last resort: second-level precision (FIFO collisions likely
        # under high load). See caveat above.
        ts=$(date +%s)000000000
    fi
    uuid=$(generate_uuid 2>/dev/null || echo "$$-$RANDOM")
    echo "${ts}-${uuid}.json"
}

# Enqueue a span insert for a specific session. Returns immediately after
# writing the job file. If BRAINTRUST_SYNC_QUEUE is truthy, processes the
# job inline instead (used in tests and as a debug fallback).
#
# Args: session_id project_id event_json
enqueue_span() {
    local session_id="$1"
    local project_id="$2"
    local event_json="$3"

    if [ -z "$session_id" ]; then
        log "ERROR" "enqueue_span called without session_id"
        return 1
    fi

    # Build the job JSON
    local job
    job=$(jq -nc \
        --arg pid "$project_id" \
        --arg exp "${CC_EXPERIMENT_ID:-}" \
        --argjson event "$event_json" \
        '{type: "insert_span", project_id: $pid, experiment_id: $exp, event: $event}')

    # Synchronous mode: process inline. This is what tests use, and it's
    # also the fallback if a user wants the old blocking behavior.
    if is_truthy "$BRAINTRUST_SYNC_QUEUE"; then
        _process_job_inline "$job"
        return $?
    fi

    # Async mode: write to <session>/pending/ and ensure a worker is running.
    _ensure_session_queue "$session_id"
    local sdir
    sdir=$(session_queue_dir "$session_id")
    local job_file="$sdir/pending/$(_queue_job_name)"

    # Write atomically: write to tmp, then rename.
    local tmp="${job_file}.tmp.$$"
    echo "$job" > "$tmp" || return 1
    mv "$tmp" "$job_file" || return 1

    debug "Enqueued job for session $session_id: $(basename "$job_file")"
    ensure_worker_running "$session_id"
    return 0
}

# Process a job in the current process. Returns the same exit code as
# _http_insert_span. Used by both sync mode and the worker.
_process_job_inline() {
    local job="$1"
    local project_id experiment_id event_json
    project_id=$(echo "$job" | jq -r '.project_id // ""')
    experiment_id=$(echo "$job" | jq -r '.experiment_id // ""')
    event_json=$(echo "$job" | jq -c '.event')

    # Temporarily set CC_EXPERIMENT_ID so _http_insert_span routes correctly.
    local prev_exp="${CC_EXPERIMENT_ID:-}"
    CC_EXPERIMENT_ID="$experiment_id"
    _http_insert_span "$project_id" "$event_json" >/dev/null
    local rc=$?
    CC_EXPERIMENT_ID="$prev_exp"
    return $rc
}

# Ensure a background worker is running for the given session. If one is
# already alive (worker.lock exists with a live PID), do nothing.
# Otherwise fork a new worker.
#
# Args: session_id
ensure_worker_running() {
    is_truthy "$BRAINTRUST_SYNC_QUEUE" && return 0

    local session_id="$1"
    if [ -z "$session_id" ]; then
        log "ERROR" "ensure_worker_running called without session_id"
        return 1
    fi

    local sdir lock_file
    sdir=$(session_queue_dir "$session_id")
    lock_file="$sdir/worker.lock"

    # If a live worker holds the lock, we're done.
    if [ -f "$lock_file" ]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale lock; clean it up before spawning.
        rm -f "$lock_file"
    fi

    # Fork a new worker, scoped to this session.
    local script_dir worker_script
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    worker_script="$script_dir/worker.sh"

    if [ ! -f "$worker_script" ]; then
        log "ERROR" "Worker script not found: $worker_script"
        return 1
    fi

    _ensure_session_queue "$session_id"

    # Detach the worker so it persists after this hook exits.
    nohup bash "$worker_script" "$session_id" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    debug "Spawned worker for session $session_id (parent pid=$$)"
    return 0
}

# Block until this session's queue is drained, or BRAINTRUST_DRAIN_TIMEOUT
# elapses. Used by session_end.sh to ensure all spans are flushed before
# Claude Code exits.
#
# Args: session_id [timeout_secs]
drain_queue() {
    is_truthy "$BRAINTRUST_SYNC_QUEUE" && return 0

    local session_id="$1"
    local timeout="${2:-$BRAINTRUST_DRAIN_TIMEOUT}"

    if [ -z "$session_id" ]; then
        log "ERROR" "drain_queue called without session_id"
        return 1
    fi

    local deadline=$(( $(date +%s) + timeout ))
    debug "Draining queue for session $session_id (timeout=${timeout}s)"

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! _queue_has_jobs "$session_id"; then
            debug "Queue drained successfully for session $session_id"
            return 0
        fi
        # Make sure a worker is running on every iteration so a transient
        # worker death does not stall the drain.
        ensure_worker_running "$session_id"
        sleep 0.2
    done

    local remaining
    remaining=$(_queue_pending_count "$session_id")
    log "WARN" "drain_queue timed out for session $session_id after ${timeout}s with $remaining job(s) still pending"
    return 1
}

# True if any jobs are in this session's pending/ or processing/ dir.
# Args: session_id
_queue_has_jobs() {
    local session_id="$1"
    [ "$(_queue_pending_count "$session_id")" -gt 0 ] || \
        [ "$(_queue_processing_count "$session_id")" -gt 0 ]
}

# Args: session_id
_queue_pending_count() {
    local session_id="$1"
    local sdir
    sdir=$(session_queue_dir "$session_id")
    local n
    n=$(find "$sdir/pending" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
    echo "${n// /}"
}

# Args: session_id
_queue_processing_count() {
    local session_id="$1"
    local sdir
    sdir=$(session_queue_dir "$session_id")
    local n
    n=$(find "$sdir/processing" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
    echo "${n// /}"
}

# Sweep $QUEUE_DIR for session dirs that look crashed (worker.lock mtime
# older than BRAINTRUST_WORKER_STALE_SECS, or lock missing while pending
# files exist). For each stale session: kill the lock-holder PID if still
# around, sweep processing/ back to pending/, and respawn a worker to
# drain anything that's left. Empty stale dirs are removed.
#
# Skips the session_id passed as an argument (the current session), if any.
#
# Args: [current_session_id]
sweep_dead_sessions() {
    is_truthy "$BRAINTRUST_SYNC_QUEUE" && return 0

    local current_session="${1:-}"
    local stale_secs="$BRAINTRUST_WORKER_STALE_SECS"
    local now
    now=$(date +%s)

    [ -d "$QUEUE_DIR" ] || return 0

    local entry sid sdir lock_file pid lock_mtime age pending processing
    for entry in "$QUEUE_DIR"/*; do
        [ -d "$entry" ] || continue
        sid=$(basename "$entry")
        [ "$sid" = "$current_session" ] && continue

        sdir="$entry"
        lock_file="$sdir/worker.lock"
        pending=$(_queue_pending_count "$sid")
        processing=$(_queue_processing_count "$sid")

        if [ -f "$lock_file" ]; then
            # _file_mtime returns 0 if it can't stat the file
            lock_mtime=$(_file_mtime "$lock_file")
            age=$(( now - lock_mtime ))
            if [ "$age" -lt "$stale_secs" ]; then
                # Looks alive (or recently was). Leave it alone.
                continue
            fi
            # Stale lock - try to kill the holder (harmless if already gone).
            pid=$(cat "$lock_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log "WARN" "Sweeping dead session $sid: killing stale worker pid=$pid (lock age=${age}s)"
                kill "$pid" 2>/dev/null || true
            else
                log "INFO" "Sweeping dead session $sid (lock age=${age}s, pid=$pid not running)"
            fi
            rm -f "$lock_file"
        elif [ "$pending" -eq 0 ] && [ "$processing" -eq 0 ]; then
            # No lock and no jobs - clean leftover empty dir.
            rmdir "$sdir/pending" "$sdir/processing" 2>/dev/null || true
            rmdir "$sdir" 2>/dev/null || true
            continue
        fi

        # Recover any in-flight jobs by moving them back to pending.
        local f
        for f in "$sdir"/processing/*.json; do
            [ -e "$f" ] || continue
            mv "$f" "$sdir/pending/$(basename "$f")" 2>/dev/null || true
        done

        pending=$(_queue_pending_count "$sid")
        if [ "$pending" -gt 0 ]; then
            log "INFO" "Recovering $pending orphaned span(s) from crashed session $sid"
            ensure_worker_running "$sid"
        else
            # Nothing left to do. Tidy up.
            rmdir "$sdir/pending" "$sdir/processing" 2>/dev/null || true
            rmdir "$sdir" 2>/dev/null || true
        fi
    done
}

# Stat a file's mtime in epoch seconds, portable across macOS (BSD stat)
# and Linux (GNU stat). Returns 0 if the file can't be stat'd.
_file_mtime() {
    local f="$1"
    [ -f "$f" ] || { echo 0; return; }
    stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0
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
    # Use --arg + bracket lookup so keys containing dashes/dots/etc work
    [ -f "$state_file" ] && jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null || echo ""
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
