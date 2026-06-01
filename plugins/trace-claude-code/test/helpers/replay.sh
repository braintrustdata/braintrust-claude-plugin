#!/bin/bash
###
# Replay helper: drive hooks from a recorded session fixture.
#
# A session fixture is a directory produced by setting BRAINTRUST_RECORD_DIR
# during a real Claude Code session. It contains:
#
#   events.ndjson         - one JSON record per hook invocation, in order:
#                             {ts, hook, payload}
#   transcripts/<id>.jsonl - any transcript files referenced by stop_hook
#
# Usage in a test:
#
#   replay_session "$TEST_DIR/fixtures/sessions/my-session"
#   assert_eq "$(span_count_by_type tool)" "5"
###

# Replay every event in a session fixture by invoking the corresponding
# hook script via run_hook. Stop-hook payloads have their transcript_path
# rewritten to point at the fixture's transcripts/ directory so the hook
# can find the file at replay time.
#
# Returns the number of events replayed on stdout; returns non-zero if
# the fixture is missing or any hook returns non-zero.
replay_session() {
    local fixture_dir="$1"
    local events_file="$fixture_dir/events.ndjson"

    if [ ! -f "$events_file" ]; then
        echo "replay_session: fixture not found: $events_file" >&2
        return 1
    fi

    local replayed=0
    local line hook payload script

    # Read line-by-line. NDJSON, one event per line.
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        hook=$(echo "$line" | jq -r '.hook // empty')
        payload=$(echo "$line" | jq -c '.payload // {}')

        [ -z "$hook" ] && continue

        # Map the hook name to its script. Recorder writes the bare name
        # (e.g. "session_start"); the script file is "session_start.sh".
        # stop_hook is special because the file is named stop_hook.sh
        # rather than stop.sh.
        case "$hook" in
            session_start|user_prompt_submit|post_tool_use|stop_hook|session_end)
                script="${hook}.sh"
                ;;
            *)
                echo "replay_session: unknown hook '$hook' on line $((replayed + 1))" >&2
                return 1
                ;;
        esac

        # Rewrite transcript_path for stop_hook so the replayed hook can
        # find the bundled transcript file.
        if [ "$hook" = "stop_hook" ]; then
            local original_path basename_t
            original_path=$(echo "$payload" | jq -r '.transcript_path // empty')
            if [ -n "$original_path" ]; then
                basename_t=$(basename "$original_path")
                local replay_path="$fixture_dir/transcripts/$basename_t"
                if [ -f "$replay_path" ]; then
                    payload=$(echo "$payload" | jq -c \
                        --arg p "$replay_path" '.transcript_path = $p')
                else
                    echo "replay_session: transcript missing for stop_hook: $replay_path" >&2
                fi
            fi
        fi

        run_hook "$script" "$payload"
        local rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "replay_session: hook $hook exited $rc on event $((replayed + 1))" >&2
            return "$rc"
        fi

        replayed=$((replayed + 1))
    done < "$events_file"

    echo "$replayed"
    return 0
}

# Print a summary of what's in a fixture (count of each hook type, etc.)
# Useful for debugging.
describe_fixture() {
    local fixture_dir="$1"
    local events_file="$fixture_dir/events.ndjson"
    [ -f "$events_file" ] || { echo "(no events)"; return 1; }

    echo "Fixture: $fixture_dir"
    echo "  Events: $(wc -l < "$events_file" | tr -d ' ')"
    echo "  Hook counts:"
    jq -r '.hook' "$events_file" | sort | uniq -c | awk '{printf "    %s: %s\n", $2, $1}'
    local n_transcripts=0
    if [ -d "$fixture_dir/transcripts" ]; then
        n_transcripts=$(find "$fixture_dir/transcripts" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
    echo "  Transcripts: $n_transcripts"
}
