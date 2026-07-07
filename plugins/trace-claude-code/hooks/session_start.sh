#!/bin/bash
###
# SessionStart Hook - Creates the root trace span when a Claude Code session begins
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SessionStart hook triggered"
debug "TRACE_TO_BRAINTRUST=$TRACE_TO_BRAINTRUST"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
record_hook_input "session_start" "$INPUT"
debug "SessionStart input: $INPUT"

# Extract session ID from input
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    # Generate a session ID if not provided
    SESSION_ID=$(generate_uuid)
    debug "Generated session ID: $SESSION_ID"
fi

# Clean up any queue dirs left behind by previous Claude Code sessions
# that crashed (no SessionEnd hook fired). Sweeps any dir whose worker
# lock is stale or missing-with-leftover-jobs, recovering or removing
# as appropriate. Skips our own session's dir.
sweep_dead_sessions "$SESSION_ID"

# Determine mode and get appropriate IDs
if is_experiment_mode; then
    debug "Experiment mode: CC_EXPERIMENT_ID=$CC_EXPERIMENT_ID"
    # In experiment mode, we still get project_id for state management
    # but spans are inserted to the experiment endpoint
    PROJECT_ID=$(get_project_id "$PROJECT") || PROJECT_ID="experiment-mode"
    log "INFO" "Tracing to experiment: $CC_EXPERIMENT_ID"
else
    # Get project ID for project_logs mode
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Aborting session_start: could not resolve project '$PROJECT' (see prior error)"; exit 0; }
    debug "Using project: $PROJECT (id: $PROJECT_ID)"
fi

# Create the session span
# If CC_PARENT_SPAN_ID is set, this session becomes a child of an existing trace
if [ -n "$CC_PARENT_SPAN_ID" ]; then
    ROOT_SPAN_ID="$CC_ROOT_SPAN_ID"
    debug "Attaching to parent span: $CC_PARENT_SPAN_ID (root: $ROOT_SPAN_ID)"
else
    ROOT_SPAN_ID="$SESSION_ID"
fi
SPAN_ID="$SESSION_ID"
TIMESTAMP=$(get_timestamp)

# Atomically check if we already have a root span for this session and set it if not
# This prevents race conditions when session_start is called multiple times
if ! check_and_set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"; then
    EXISTING_ROOT=$(get_session_state "$SESSION_ID" "root_span_id")
    debug "Session already has root span (race avoided): $EXISTING_ROOT"
    exit 0
fi
debug "Claimed session root span: $ROOT_SPAN_ID"

# Extract workspace info if available
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

# Get system info
HOSTNAME=$(get_hostname)
USERNAME=$(get_username)
OS=$(get_os)

# Version info for observability: this plugin's version and the Claude Code
# CLI version that produced the session.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
PLUGIN_VERSION=$(get_plugin_version)
CLAUDE_CODE_VERSION=$(get_claude_code_version "$TRANSCRIPT_PATH")
GIT_METADATA=$(git_metadata_json "$WORKSPACE")

EVENT=$(jq -n \
    --arg id "$SPAN_ID" \
    --arg span_id "$SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg session "$SESSION_ID" \
    --arg workspace "$WORKSPACE_NAME" \
    --arg cwd "$WORKSPACE" \
    --arg hostname "$HOSTNAME" \
    --arg username "$USERNAME" \
    --arg os "$OS" \
    --arg plugin_version "$PLUGIN_VERSION" \
    --arg claude_code_version "$CLAUDE_CODE_VERSION" \
    --argjson git_metadata "$GIT_METADATA" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        created: $created,
        input: ("Session: " + $workspace),
        metadata: ({
            session_id: $session,
            workspace: $cwd,
            hostname: $hostname,
            username: $username,
            os: $os,
            source: "claude-code",
            trace_claude_code_version: $plugin_version,
            claude_code_version: $claude_code_version
        } + $git_metadata),
        span_attributes: {
            name: ("Claude Code: " + $workspace),
            type: "task"
        }
    }')

# Add span_parents if attaching to an existing trace
if [ -n "$CC_PARENT_SPAN_ID" ]; then
    debug "Setting span_parents to: $CC_PARENT_SPAN_ID"
    EVENT=$(echo "$EVENT" | jq --arg parent "$CC_PARENT_SPAN_ID" '. + {span_parents: [$parent]}')
fi

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || { log "ERROR" "Failed to enqueue session root span"; exit 0; }

# Save remaining session state (root_span_id was already set atomically above)
set_session_state "$SESSION_ID" "session_span_id" "$SPAN_ID"
set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
set_session_state "$SESSION_ID" "turn_count" "0"
set_session_state "$SESSION_ID" "tool_count" "0"
set_session_state "$SESSION_ID" "started" "$TIMESTAMP"

# Store experiment_id if in experiment mode
if is_experiment_mode; then
    set_session_state "$SESSION_ID" "experiment_id" "$CC_EXPERIMENT_ID"
    log "INFO" "Created session root: $SESSION_ID workspace=$WORKSPACE_NAME (experiment=$CC_EXPERIMENT_ID)"
else
    log "INFO" "Created session root: $SESSION_ID workspace=$WORKSPACE_NAME (project=$PROJECT)"
fi

exit 0
