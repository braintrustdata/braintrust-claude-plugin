#!/bin/bash
###
# SessionEnd Hook - Finalizes the trace when a Claude Code session ends
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SessionEnd hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract session ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(load_state | jq -r '.sessions | keys | .[-1] // empty' 2>/dev/null)
fi

[ -z "$SESSION_ID" ] && { debug "No session ID, skipping"; exit 0; }

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
SESSION_SPAN_ID=$(get_session_state "$SESSION_ID" "session_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TOOL_COUNT=$(get_session_state "$SESSION_ID" "tool_count")
STARTED=$(get_session_state "$SESSION_ID" "started")
WORKSPACE_DIR=$(get_session_state "$SESSION_ID" "workspace_dir")
INITIAL_GIT_STATE=$(get_session_state "$SESSION_ID" "initial_git_state")

[ -z "$ROOT_SPAN_ID" ] && { debug "No root span for session"; exit 0; }
[ -z "$PROJECT_ID" ] && { debug "No project ID for session"; exit 0; }

# Calculate duration if we have start time
DURATION=""
if [ -n "$STARTED" ]; then
    # Note: This is a rough estimate, proper duration tracking would need more work
    DURATION="session"
fi

# Update the root span with final stats
TIMESTAMP=$(get_timestamp)

# We could update the root span with summary info, but Braintrust doesn't
# support updating existing spans via the insert API. Instead, we'll just
# log the session summary.

TURN_COUNT=${TURN_COUNT:-0}
TOOL_COUNT=${TOOL_COUNT:-0}

# Capture git diff if we have a workspace directory
if [ -n "$WORKSPACE_DIR" ] && [ -d "$WORKSPACE_DIR" ]; then
    debug "Capturing git diff from: $WORKSPACE_DIR"
    CURRENT_GIT_STATE=$(get_git_state_hash "$WORKSPACE_DIR")

    # Only capture diff if state has changed
    if [ "$CURRENT_GIT_STATE" != "$INITIAL_GIT_STATE" ]; then
        GIT_DIFF=$(capture_git_diff "$WORKSPACE_DIR")

        if [ -n "$GIT_DIFF" ]; then
            debug "Git diff captured ($(echo "$GIT_DIFF" | wc -l) lines)"

            # Update the session span with the diff using merge write
            SESSION_UPDATE=$(jq -n \
                --arg id "${SESSION_SPAN_ID:-$ROOT_SPAN_ID}" \
                --arg diff "$GIT_DIFF" \
                --argjson turns "$TURN_COUNT" \
                --argjson tools "$TOOL_COUNT" \
                '{
                    id: $id,
                    _is_merge: true,
                    output: $diff,
                    metadata: {
                        code_changes: $diff,
                        turn_count: $turns,
                        tool_count: $tools
                    }
                }')

            insert_span "$PROJECT_ID" "$SESSION_UPDATE" >/dev/null && {
                log "INFO" "Added git diff to session span ($(echo "$GIT_DIFF" | wc -l) lines)"
            } || {
                log "WARN" "Failed to add git diff to session span"
            }
        else
            debug "No git diff to capture"
        fi
    else
        debug "Git state unchanged"
    fi
else
    debug "No workspace directory for diff capture"
fi

log "INFO" "Session ended: $SESSION_ID (turns=$TURN_COUNT, tools=$TOOL_COUNT)"

# Clean up session state (optional - keeps state file cleaner)
# Uncomment to remove session from state after it ends:
# STATE=$(load_state)
# STATE=$(echo "$STATE" | jq --arg s "$SESSION_ID" 'del(.sessions[$s])')
# save_state "$STATE"

exit 0
