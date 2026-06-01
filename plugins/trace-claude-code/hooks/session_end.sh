#!/bin/bash
###
# SessionEnd Hook - drains pending spans and shuts down this session's
# background worker. The only blocking step in the plugin's hook chain;
# Claude Code waits for this to return before it exits.
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SessionEnd hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
record_hook_input "session_end" "$INPUT"
debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract session ID. Claude Code always sends one; if it doesn't, there's
# nothing we can drain (per-session queues are keyed by session id).
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID in payload, skipping"; exit 0; }

# Log a one-line session summary for observability. State may be partial
# if the session never had a turn/tool, so default to 0.
TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TOOL_COUNT=$(get_session_state "$SESSION_ID" "tool_count")
log "INFO" "Session ended: $SESSION_ID (turns=${TURN_COUNT:-0}, tools=${TOOL_COUNT:-0})"

# Block until this session's worker has flushed all pending spans. This
# is the critical step that prevents spans from being lost when Claude
# Code exits. drain_queue is bounded by BRAINTRUST_DRAIN_TIMEOUT.
drain_queue "$SESSION_ID" || log "WARN" "Some spans may not have been flushed before session end"

# Shut down this session's worker and clean up its queue dir. No-op in
# sync mode since there's no worker to stop.
if ! is_truthy "$BRAINTRUST_SYNC_QUEUE"; then
    SDIR=$(session_queue_dir "$SESSION_ID")
    LOCK_FILE="$SDIR/worker.lock"

    # Removing the lock file is the worker's exit signal: it checks
    # ownership at the top of every loop and self-exits when the lock
    # is gone. We avoid `kill` whenever possible because the PID we
    # read from the lock could have been reused by an unrelated process
    # between the read and the kill (the worker may have already exited
    # after seeing the missing lock).
    if [ -f "$LOCK_FILE" ]; then
        WORKER_PID=$(cat "$LOCK_FILE" 2>/dev/null)
        rm -f "$LOCK_FILE"

        if [ -n "$WORKER_PID" ]; then
            # Poll up to 1s for the worker to self-exit. Loop period is
            # ~200ms so one cycle is usually enough.
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$WORKER_PID" 2>/dev/null || break
                sleep 0.1
            done

            # Still alive? Only escalate to SIGTERM if the process really
            # is still our worker - verify by inspecting its command line.
            if kill -0 "$WORKER_PID" 2>/dev/null; then
                WORKER_CMD=$(ps -p "$WORKER_PID" -o command= 2>/dev/null || true)
                if [[ "$WORKER_CMD" == *worker.sh* ]] && [[ "$WORKER_CMD" == *"$SESSION_ID"* ]]; then
                    kill "$WORKER_PID" 2>/dev/null || true
                else
                    debug "Not killing pid $WORKER_PID; command line does not look like our worker: $WORKER_CMD"
                fi
            fi
        fi
    fi

    # Remove the now-empty session queue dir. rmdir is silent on
    # non-empty dirs, which is the right behavior if a late job slipped
    # in after the drain.
    rmdir "$SDIR/pending" "$SDIR/processing" 2>/dev/null || true
    rmdir "$SDIR" 2>/dev/null || true
fi

exit 0
