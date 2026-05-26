#!/bin/bash
###
# Tests for the per-session span queue + background worker.
#
# Covers:
#   - Sync mode: enqueue_span processes inline (default for tests)
#   - Async mode: each session has its own pending/ and its own worker
#   - drain_queue blocks until that session's queue is empty
#   - sweep_dead_sessions cleans up crashed sessions
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

_test_event() {
    local id="${1:-test-span-1}"
    jq -nc \
        --arg id "$id" \
        '{
            id: $id,
            span_id: $id,
            root_span_id: $id,
            input: "test",
            span_attributes: { name: "test", type: "task" }
        }'
}

_setup_default_stubs() {
    stub_response_for "*/v1/project_logs/*/insert" 200 '{"row_ids":["row_x"]}'
    stub_response_for "*/v1/experiment/*/insert"   200 '{"row_ids":["row_x"]}'
}

# Stop the worker for a session by removing its lock file (the in-loop
# heartbeat will fail to touch and the worker exits). Then poll until
# the PID is gone or we give up.
_stop_worker() {
    local session_id="$1"
    local lock_file
    lock_file="$(session_queue_dir "$session_id")/worker.lock"
    if [ -f "$lock_file" ]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null)
        rm -f "$lock_file"
        if [ -n "$pid" ]; then
            local i
            for i in $(seq 1 50); do
                kill -0 "$pid" 2>/dev/null || return 0
                sleep 0.1
            done
            kill "$pid" 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
describe "enqueue_span: sync mode (default in tests)"
# ---------------------------------------------------------------------------

t_sync_enqueue_inserts_immediately() {
    _setup_default_stubs
    # Harness already sets BRAINTRUST_SYNC_QUEUE=true

    local event
    event=$(_test_event)
    enqueue_span "sess-sync" "proj_sync" "$event"
    assert_success "$?"

    local count
    count=$(span_count)
    assert_eq "$count" "1" "expected the span to be inserted immediately"

    # No job files should be left in the queue.
    # In sync mode the session dir is never created at all.
    assert_eq "$(_queue_pending_count "sess-sync")" "0"
    assert_eq "$(_queue_processing_count "sess-sync")" "0"
}

t_sync_enqueue_does_not_spawn_worker() {
    _setup_default_stubs

    enqueue_span "sess-sync2" "proj_sync" "$(_test_event)" >/dev/null

    # No worker lock should exist
    local lock="$(session_queue_dir "sess-sync2")/worker.lock"
    if [ -f "$lock" ]; then
        fail "expected no worker lock in sync mode, got $lock"
    fi
}

t_sync_enqueue_uses_experiment_endpoint() {
    _setup_default_stubs
    CC_EXPERIMENT_ID="exp_sync"

    enqueue_span "sess-exp" "proj_irrelevant" "$(_test_event)" >/dev/null

    local pl_count exp_count
    pl_count=$(captured_request_count '/project_logs/')
    exp_count=$(captured_request_count '/v1/experiment/exp_sync/insert')
    assert_eq "$pl_count" "0"
    assert_eq "$exp_count" "1"
}

t_sync_enqueue_requires_session_id() {
    _setup_default_stubs
    # Calling without a session_id should fail and log an error.
    enqueue_span "" "proj_x" "$(_test_event)" >/dev/null 2>&1
    assert_failure "$?"
    local log
    log=$(hook_log)
    assert_contains "$log" "without session_id"
}

it "inserts the span immediately when BRAINTRUST_SYNC_QUEUE=true" t_sync_enqueue_inserts_immediately
it "does not spawn a background worker in sync mode"             t_sync_enqueue_does_not_spawn_worker
it "honors CC_EXPERIMENT_ID and routes to experiment endpoint"   t_sync_enqueue_uses_experiment_endpoint
it "returns an error if session_id is missing"                   t_sync_enqueue_requires_session_id

# ---------------------------------------------------------------------------
describe "enqueue_span: async mode"
# ---------------------------------------------------------------------------

t_async_enqueue_writes_job_file() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Disable worker spawn by hiding worker.sh so we can inspect pending/
    # before any draining can happen.
    mv "$HOOKS_DIR/worker.sh" "$HOOKS_DIR/worker.sh.disabled"

    enqueue_span "sess-async" "proj_async" "$(_test_event)"
    assert_success "$?"

    assert_eq "$(_queue_pending_count "sess-async")" "1"

    # The file should contain valid JSON with the right fields
    local sdir job_file
    sdir=$(session_queue_dir "sess-async")
    job_file=$(find "$sdir/pending" -maxdepth 1 -name '*.json' -type f | head -1)
    local proj_id event_id
    proj_id=$(jq -r '.project_id' "$job_file")
    event_id=$(jq -r '.event.id' "$job_file")
    assert_eq "$proj_id" "proj_async"
    assert_eq "$event_id" "test-span-1"

    mv "$HOOKS_DIR/worker.sh.disabled" "$HOOKS_DIR/worker.sh"
}

t_async_drain_processes_pending_jobs() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    local i
    for i in 1 2 3; do
        enqueue_span "sess-drain" "proj_drain" "$(_test_event "span-$i")"
    done

    drain_queue "sess-drain" 10
    assert_success "$?"

    assert_eq "$(_queue_pending_count "sess-drain")" "0"
    assert_eq "$(_queue_processing_count "sess-drain")" "0"
    assert_eq "$(span_count)" "3"

    _stop_worker "sess-drain"
}

t_async_drain_timeout_returns_failure() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Disable worker spawn so the queue can never drain
    mv "$HOOKS_DIR/worker.sh" "$HOOKS_DIR/worker.sh.disabled"

    enqueue_span "sess-stuck" "proj_stuck" "$(_test_event)" >/dev/null

    local start_time end_time elapsed
    start_time=$(date +%s)
    drain_queue "sess-stuck" 1
    local rc=$?
    end_time=$(date +%s)
    elapsed=$(( end_time - start_time ))

    assert_failure "$rc" "drain_queue should return non-zero on timeout"
    if [ "$elapsed" -gt 3 ]; then
        fail "drain_queue took ${elapsed}s; expected ~1s"
    fi

    local log
    log=$(hook_log)
    assert_contains "$log" "drain_queue timed out"

    mv "$HOOKS_DIR/worker.sh.disabled" "$HOOKS_DIR/worker.sh"
}

t_async_sessions_are_isolated() {
    # Two sessions enqueueing concurrently should each get their own
    # queue dir and their own worker.
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    enqueue_span "sess-A" "proj_a" "$(_test_event "a-1")"
    enqueue_span "sess-B" "proj_b" "$(_test_event "b-1")"

    drain_queue "sess-A" 10
    drain_queue "sess-B" 10

    assert_eq "$(_queue_pending_count "sess-A")" "0"
    assert_eq "$(_queue_pending_count "sess-B")" "0"
    assert_eq "$(span_count)" "2"

    # Two separate POSTs should have been made
    local pl_count
    pl_count=$(captured_request_count '/insert$')
    assert_eq "$pl_count" "2"

    _stop_worker "sess-A"
    _stop_worker "sess-B"
}

it "writes a job file to pending/ when worker is offline" t_async_enqueue_writes_job_file
it "drain_queue processes all pending jobs"               t_async_drain_processes_pending_jobs
it "drain_queue returns non-zero on timeout"              t_async_drain_timeout_returns_failure
it "different sessions have isolated queues and workers"  t_async_sessions_are_isolated

# ---------------------------------------------------------------------------
describe "worker.sh"
# ---------------------------------------------------------------------------

t_worker_drains_existing_jobs() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Pre-seed the queue with two job files (bypassing enqueue_span so we
    # don't spawn a worker yet).
    _ensure_session_queue "sess-seed"
    local sdir
    sdir=$(session_queue_dir "sess-seed")
    local job1 job2
    job1=$(jq -nc --argjson e "$(_test_event "pre-1")" \
        '{type:"insert_span", project_id:"proj_w", experiment_id:"", event:$e}')
    job2=$(jq -nc --argjson e "$(_test_event "pre-2")" \
        '{type:"insert_span", project_id:"proj_w", experiment_id:"", event:$e}')
    echo "$job1" > "$sdir/pending/01-aaa.json"
    echo "$job2" > "$sdir/pending/02-bbb.json"

    # Start the worker, give it time to drain, then remove its lock to
    # signal shutdown.
    bash "$HOOKS_DIR/worker.sh" sess-seed >/dev/null 2>&1 &
    local worker_pid=$!

    # Poll for completion (up to 5s)
    local i
    for i in $(seq 1 50); do
        if [ "$(_queue_pending_count "sess-seed")" = "0" ] && \
           [ "$(_queue_processing_count "sess-seed")" = "0" ]; then
            break
        fi
        sleep 0.1
    done

    assert_eq "$(span_count)" "2"
    assert_eq "$(_queue_pending_count "sess-seed")" "0"

    # Signal worker to exit by removing the lock, then wait briefly.
    _stop_worker "sess-seed"
    # Belt-and-suspenders: ensure background process is gone
    kill "$worker_pid" 2>/dev/null || true
}

t_worker_only_one_at_a_time_per_session() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Start the first worker for sess-W.
    bash "$HOOKS_DIR/worker.sh" sess-W >/dev/null 2>&1 &
    local first_pid=$!

    # Give it time to claim the lock
    sleep 0.5

    # Try to start a second worker for the same session - it should exit
    # immediately (rc=0) and the first worker should still be alive.
    bash "$HOOKS_DIR/worker.sh" sess-W
    local rc=$?
    assert_eq "$rc" "0"

    if ! kill -0 "$first_pid" 2>/dev/null; then
        fail "first worker should still be alive"
    fi

    _stop_worker "sess-W"
}

t_worker_two_sessions_concurrent() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    bash "$HOOKS_DIR/worker.sh" sess-1 >/dev/null 2>&1 &
    local pid1=$!
    bash "$HOOKS_DIR/worker.sh" sess-2 >/dev/null 2>&1 &
    local pid2=$!

    sleep 0.5

    # Both workers should be alive (different sessions = different locks)
    if ! kill -0 "$pid1" 2>/dev/null; then
        fail "session 1 worker should be alive"
    fi
    if ! kill -0 "$pid2" 2>/dev/null; then
        fail "session 2 worker should be alive"
    fi

    # And each should hold its own lock
    assert_file_exists "$(session_queue_dir sess-1)/worker.lock"
    assert_file_exists "$(session_queue_dir sess-2)/worker.lock"

    _stop_worker "sess-1"
    _stop_worker "sess-2"
}

t_worker_heartbeat_refreshes_lock_mtime() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    bash "$HOOKS_DIR/worker.sh" sess-hb >/dev/null 2>&1 &
    local pid=$!

    # Wait for the lock file to appear
    local lock_file="$(session_queue_dir sess-hb)/worker.lock"
    local i
    for i in $(seq 1 50); do
        [ -f "$lock_file" ] && break
        sleep 0.1
    done
    assert_file_exists "$lock_file"

    # Capture the initial mtime
    local mtime1
    mtime1=$(_file_mtime "$lock_file")

    # Wait a bit longer than one heartbeat (0.2s loop) and re-check.
    # Use a generous 1.5s to absorb scheduling jitter on slow CI.
    sleep 1.5

    local mtime2
    mtime2=$(_file_mtime "$lock_file")

    # mtime should have advanced
    if [ "$mtime2" -le "$mtime1" ]; then
        fail "expected lock mtime to advance: was=$mtime1 now=$mtime2"
    fi

    _stop_worker "sess-hb"
    kill "$pid" 2>/dev/null || true
}

t_worker_survives_parent_exit() {
    # Regression test for the core bug this whole refactor addresses:
    # when a hook script enqueues a span and then exits, the background
    # worker it spawned must keep running and drain the queue. Pre-refactor,
    # `async: true` hooks were killed mid-curl and dropped spans.
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    local sid="sess-survives"

    # Run a child shell that enqueues a span and then exits. The child
    # inherits our $HOME (which is the test's isolated tmp dir) and our
    # stubbed curl + stub config. From the child's perspective this looks
    # exactly like a hook script run by Claude Code:
    #   - sources common.sh
    #   - calls enqueue_span (which spawns a worker via nohup ... & disown)
    #   - exits.
    #
    # The worker has no idle-timeout mechanism; it lives until its lock
    # file is removed (which only happens when session_end runs or when
    # _stop_worker is invoked at the end of this test).
    bash -c "
        source '$HOOKS_DIR/common.sh'
        event='$(_test_event 'survive-1')'
        enqueue_span '$sid' 'proj_s' \"\$event\"
    "
    assert_success "$?" "child shell that enqueued should exit cleanly"

    # The child shell is gone. The worker should still be alive.
    # Read its PID from the lock and assert.
    local lock_file pid
    lock_file="$(session_queue_dir "$sid")/worker.lock"

    # Worker may take a brief moment to claim its lock; wait up to 2s.
    local i
    for i in $(seq 1 20); do
        [ -f "$lock_file" ] && break
        sleep 0.1
    done
    assert_file_exists "$lock_file" "worker should have claimed its lock"

    pid=$(cat "$lock_file" 2>/dev/null)
    if [ -z "$pid" ]; then
        fail "worker lock has no pid"
        return 1
    fi

    # The PID must NOT be the long-gone child shell. It should be a
    # detached process whose parent is init (pid 1) on Linux or launchd
    # on macOS. Either way, the key assertion is: it's alive.
    if ! kill -0 "$pid" 2>/dev/null; then
        fail "worker pid $pid should still be alive after parent exit"
        return 1
    fi

    # And it should have drained the job we enqueued.
    local deadline=$(( $(date +%s) + 5 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(span_count)" -gt 0 ] && break
        sleep 0.1
    done
    assert_eq "$(span_count)" "1" "worker should have drained the enqueued job"

    _stop_worker "$sid"
}

t_worker_survives_parent_exit_and_drains_more() {
    # Stronger version: after the parent shell exits, we keep enqueuing
    # jobs from the test process. The surviving worker should pick them up.
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    local sid="sess-survives-2"

    # Child enqueues one job and exits, spawning the worker.
    bash -c "
        source '$HOOKS_DIR/common.sh'
        event='$(_test_event 'first')'
        enqueue_span '$sid' 'proj_s' \"\$event\"
    "

    # Wait for the worker to claim its lock so subsequent enqueues don't
    # try to spawn a second worker.
    local lock_file="$(session_queue_dir "$sid")/worker.lock"
    local i
    for i in $(seq 1 20); do
        [ -f "$lock_file" ] && break
        sleep 0.1
    done

    # From the test process, enqueue more jobs. Same session, so the
    # already-running worker picks them up.
    local n
    for n in 2 3 4 5; do
        enqueue_span "$sid" "proj_s" "$(_test_event "later-$n")"
    done

    # Wait for the worker to drain all 5 jobs.
    local deadline=$(( $(date +%s) + 5 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(span_count)" -ge 5 ] && break
        sleep 0.1
    done

    assert_eq "$(span_count)" "5" "worker should have drained all 5 jobs across parent exit"

    _stop_worker "$sid"
}

it "drains pre-existing jobs from pending/"              t_worker_drains_existing_jobs
it "only one worker per session can hold the lock"       t_worker_only_one_at_a_time_per_session
it "two sessions can have concurrent workers"            t_worker_two_sessions_concurrent
it "worker refreshes its lock mtime on every iteration"  t_worker_heartbeat_refreshes_lock_mtime
it "worker survives the spawning shell's exit"           t_worker_survives_parent_exit
it "surviving worker drains jobs enqueued after parent exit" t_worker_survives_parent_exit_and_drains_more

# ---------------------------------------------------------------------------
describe "drain_queue: edge cases"
# ---------------------------------------------------------------------------

t_drain_empty_queue() {
    export BRAINTRUST_SYNC_QUEUE=false
    drain_queue "sess-empty" 1
    assert_success "$?" "draining an empty queue should succeed immediately"
}

t_drain_sync_mode_noop() {
    export BRAINTRUST_SYNC_QUEUE=true
    drain_queue "sess-noop" 1
    assert_success "$?" "drain_queue is a no-op in sync mode"
}

t_drain_requires_session_id() {
    export BRAINTRUST_SYNC_QUEUE=false
    drain_queue "" 1
    assert_failure "$?" "drain_queue without session_id should fail"
}

it "succeeds immediately when the queue is empty" t_drain_empty_queue
it "is a no-op when BRAINTRUST_SYNC_QUEUE=true"   t_drain_sync_mode_noop
it "returns an error if session_id is missing"    t_drain_requires_session_id

# ---------------------------------------------------------------------------
describe "sweep_dead_sessions"
# ---------------------------------------------------------------------------

t_sweep_removes_empty_dead_session() {
    export BRAINTRUST_SYNC_QUEUE=false

    # Create an empty session dir with no lock at all.
    _ensure_session_queue "sess-empty-dead"
    [ -d "$(session_queue_dir sess-empty-dead)/pending" ] || \
        fail "setup precondition: pending dir should exist"

    sweep_dead_sessions "current-session"

    # Empty dead dirs should be removed.
    if [ -d "$(session_queue_dir sess-empty-dead)" ]; then
        fail "expected empty dead session dir to be removed"
    fi
}

t_sweep_recovers_orphaned_jobs() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Create a session with leftover jobs but no live worker.
    _ensure_session_queue "sess-crashed"
    local sdir
    sdir=$(session_queue_dir "sess-crashed")
    local job
    job=$(jq -nc --argjson e "$(_test_event "orphan-1")" \
        '{type:"insert_span", project_id:"proj_x", experiment_id:"", event:$e}')
    echo "$job" > "$sdir/pending/01-orphan.json"

    # Sweep should recover the orphaned job by spawning a worker.
    sweep_dead_sessions "current-session"

    # Wait for the recovery worker to drain
    local i
    for i in $(seq 1 50); do
        [ "$(_queue_pending_count "sess-crashed")" = "0" ] && \
        [ "$(_queue_processing_count "sess-crashed")" = "0" ] && break
        sleep 0.1
    done

    # The orphaned span should now have been POSTed.
    assert_eq "$(span_count)" "1"

    _stop_worker "sess-crashed"
}

t_sweep_skips_current_session() {
    export BRAINTRUST_SYNC_QUEUE=false

    # Create what looks like a dead session for "active-sess" - empty dir
    # with no lock. If sweep didn't skip the current session, it would
    # rmdir this dir.
    _ensure_session_queue "active-sess"
    [ -d "$(session_queue_dir active-sess)/pending" ] || \
        fail "setup precondition: pending dir should exist"

    sweep_dead_sessions "active-sess"

    # The current session's dir should still exist.
    if [ ! -d "$(session_queue_dir active-sess)" ]; then
        fail "sweep should not have removed the current session's dir"
    fi
}

t_sweep_leaves_fresh_sessions_alone() {
    _setup_default_stubs
    export BRAINTRUST_SYNC_QUEUE=false

    # Spawn a worker for a "live" session - its heartbeat keeps the lock
    # fresh, so sweep should leave it alone.
    bash "$HOOKS_DIR/worker.sh" sess-live >/dev/null 2>&1 &
    sleep 0.3

    assert_file_exists "$(session_queue_dir sess-live)/worker.lock"

    sweep_dead_sessions "current-session"

    # The live session's lock should still exist.
    assert_file_exists "$(session_queue_dir sess-live)/worker.lock"

    _stop_worker "sess-live"
}

it "removes empty dead session dirs"                     t_sweep_removes_empty_dead_session
it "recovers orphaned jobs by spawning a recovery worker" t_sweep_recovers_orphaned_jobs
it "skips the current session"                           t_sweep_skips_current_session
it "leaves sessions with fresh heartbeats alone"         t_sweep_leaves_fresh_sessions_alone
