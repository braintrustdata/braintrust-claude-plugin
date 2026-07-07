#!/bin/bash
###
# UserPromptSubmit Hook - Creates a Turn container span when user submits a prompt
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
record_hook_input "user_prompt_submit" "$INPUT"
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract session ID and prompt
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
SESSION_SPAN_ID=$(get_session_state "$SESSION_ID" "session_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")

# Load experiment_id from session state if not already set
if [ -z "$CC_EXPERIMENT_ID" ]; then
    CC_EXPERIMENT_ID=$(get_session_state "$SESSION_ID" "experiment_id")
    export CC_EXPERIMENT_ID
fi

# If no session root exists yet, we'll create it
if [ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Aborting user_prompt_submit: could not resolve project '$PROJECT' (see prior error)"; exit 0; }
    ROOT_SPAN_ID="$SESSION_ID"

    # Get workspace name from cwd
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    WORKSPACE_NAME=$(basename "$CWD" 2>/dev/null || echo "workspace")

    TIMESTAMP=$(get_timestamp)
    HOSTNAME=$(get_hostname)
    USERNAME=$(get_username)
    OS=$(get_os)

    # Version info for observability (mirrors session_start.sh).
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    PLUGIN_VERSION=$(get_plugin_version)
    CLAUDE_CODE_VERSION=$(get_claude_code_version "$TRANSCRIPT_PATH")
    GIT_METADATA=$(git_metadata_json "$CWD")

    EVENT=$(jq -n \
        --arg id "$ROOT_SPAN_ID" \
        --arg span_id "$ROOT_SPAN_ID" \
        --arg root_span_id "$ROOT_SPAN_ID" \
        --arg created "$TIMESTAMP" \
        --arg session "$SESSION_ID" \
        --arg workspace "$WORKSPACE_NAME" \
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
                workspace: $workspace,
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

    enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || true
    set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "session_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
    SESSION_SPAN_ID="$ROOT_SPAN_ID"
    log "INFO" "Created session root: $SESSION_ID"
fi

# Increment turn count and create Turn span
TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TURN_COUNT=${TURN_COUNT:-0}
TURN_COUNT=$((TURN_COUNT + 1))

TURN_SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
START_TIME=$(date +%s)

EXPLICIT_SKILL_NAMES=$(get_session_state "$SESSION_ID" "current_turn_explicit_skill_names")
[ -z "$EXPLICIT_SKILL_NAMES" ] && EXPLICIT_SKILL_NAMES="[]"

# Truncate prompt for display (first 100 chars)
PROMPT_PREVIEW="${PROMPT:0:100}"
[ ${#PROMPT} -gt 100 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW}..."

# Create Turn container span (parent is the session span, not the root)
EVENT=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --arg span_id "$TURN_SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg session_span_id "$SESSION_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg prompt "$PROMPT" \
    --argjson explicit_skill_names "$EXPLICIT_SKILL_NAMES" \
    --argjson turn "$TURN_COUNT" \
    --argjson start_time "$START_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$session_span_id],
        created: $created,
        input: $prompt,
        metrics: {
            start: $start_time
        },
        metadata: (if ($explicit_skill_names | length) > 0 then {
            loaded_skill_names: $explicit_skill_names,
            loaded_skills: ($explicit_skill_names | map({name: .}))
        } else {} end),
        span_attributes: {
            name: ("Turn " + ($turn | tostring)),
            type: "task"
        }
    }')

enqueue_span "$SESSION_ID" "$PROJECT_ID" "$EVENT" || { log "ERROR" "Failed to enqueue turn span"; exit 0; }

# Save turn state
set_session_state "$SESSION_ID" "turn_count" "$TURN_COUNT"
set_session_state "$SESSION_ID" "current_turn_span_id" "$TURN_SPAN_ID"
set_session_state "$SESSION_ID" "current_turn_start" "$START_TIME"
set_session_state "$SESSION_ID" "current_turn_tool_count" "0"

log "INFO" "Turn $TURN_COUNT started: $TURN_SPAN_ID"

exit 0
