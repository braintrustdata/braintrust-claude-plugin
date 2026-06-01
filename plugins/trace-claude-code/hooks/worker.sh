#!/bin/bash
###
# Background queue worker for a single Claude Code session.
#
# Spawned by ensure_worker_running() in common.sh. Drains the session's
# pending/ dir in FIFO order. The worker:
#   1. Acquires an exclusive lock by writing its PID to worker.lock.
#   2. Refreshes the lock file mtime on every loop iteration so a future
#      sweep can distinguish "alive" from "crashed".
#   3. Picks the oldest pending/*.json file.
#   4. Atomically renames it into processing/.
#   5. Runs _http_insert_span() on it.
#   6. Deletes the file on success, or logs and drops on failure.
#
# Lifecycle: the worker runs until its lock file is removed (clean
# shutdown by session_end.sh) or it loses the lock (some other entity
# took over, e.g. crash recovery). There is no idle timeout: the worker
# lives as long as its Claude Code session is alive.
#
# Args: session_id (positional, required)
###

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

SESSION_ID="${1:-}"
if [ -z "$SESSION_ID" ]; then
    log "ERROR" "worker.sh started without a session_id argument"
    exit 2
fi

SDIR=$(session_queue_dir "$SESSION_ID")
LOCK_FILE="$SDIR/worker.lock"

# Ensure the session subtree exists. ensure_worker_running normally does
# this for us, but it's cheap and makes the worker robust if invoked
# manually (e.g. during crash recovery).
mkdir -p "$SDIR/pending" "$SDIR/processing"

# If another worker holds the lock, exit. (We trust ensure_worker_running
# to have checked, but races happen.)
if [ -f "$LOCK_FILE" ]; then
    other_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$other_pid" ] && [ "$other_pid" != "$$" ] && kill -0 "$other_pid" 2>/dev/null; then
        debug "Worker for session $SESSION_ID: another worker (pid=$other_pid) holds the lock; exiting"
        exit 0
    fi
fi

# Claim the lock. We use noclobber to make this somewhat atomic against
# other workers racing to claim the same session.
if ! { set -C; echo "$$" > "$LOCK_FILE"; } 2>/dev/null; then
    # Lost the race - someone else just took the lock.
    debug "Worker for session $SESSION_ID: lost lock race; exiting"
    exit 0
fi

cleanup_worker() {
    # Only remove the lock if it's still ours. Crash recovery may have
    # already removed and replaced it.
    if [ -f "$LOCK_FILE" ]; then
        local owner
        owner=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ "$owner" = "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
    debug "Worker $$ for session $SESSION_ID exiting"
}
trap cleanup_worker EXIT

# Sweep any in-flight files that a previous worker left behind. We're now
# the owner of this session's queue, so it's safe to recover them.
for f in "$SDIR"/processing/*.json; do
    [ -e "$f" ] || continue
    mv "$f" "$SDIR/pending/$(basename "$f")" 2>/dev/null || true
done

debug "Worker $$ started for session $SESSION_ID"

# Main loop. Runs until the lock file disappears (clean shutdown signal
# from session_end.sh).
while true; do
    # Heartbeat: keep the lock file's mtime fresh so the sweep doesn't
    # mistake us for a crashed worker.
    touch "$LOCK_FILE" 2>/dev/null || {
        debug "Worker $$ for session $SESSION_ID: lock file disappeared; exiting"
        break
    }

    # Verify we still own the lock. If something else claimed it (e.g. a
    # crash-recovery sweep killed us and respawned), exit so the new
    # worker can take over without contention.
    owner=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ "$owner" != "$$" ]; then
        debug "Worker $$ for session $SESSION_ID: lock now owned by pid=$owner; exiting"
        # Don't remove the lock - it's not ours anymore.
        trap - EXIT
        exit 0
    fi

    # Pick the oldest pending job (sorted lexically; filenames sort by
    # epoch-ns timestamp so this is effectively FIFO).
    job_file=$(find "$SDIR/pending" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
        | sort | head -n1)

    if [ -z "$job_file" ]; then
        sleep 0.2
        continue
    fi

    # Atomically claim the job by moving it to processing/.
    processing_file="$SDIR/processing/$(basename "$job_file")"
    if ! mv "$job_file" "$processing_file" 2>/dev/null; then
        # Another mover beat us to it (shouldn't happen with a single
        # worker per session, but harmless). Retry.
        continue
    fi

    job=$(cat "$processing_file" 2>/dev/null)
    if [ -z "$job" ]; then
        log "WARN" "Empty job file in session $SESSION_ID: $(basename "$processing_file") - discarding"
        rm -f "$processing_file"
        continue
    fi

    if _process_job_inline "$job"; then
        rm -f "$processing_file"
    else
        log "ERROR" "Worker for session $SESSION_ID dropping failed job: $(basename "$processing_file")"
        rm -f "$processing_file"
    fi
done

exit 0
