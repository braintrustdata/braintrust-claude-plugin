#!/bin/bash
###
# Replay helper: drive hooks from a recorded session fixture.
#
# A session fixture is a directory produced by setting BRAINTRUST_RECORD_DIR
# during a real Claude Code session. It contains:
#
#   events.ndjson         - one JSON record per hook invocation, in order:
#                             {ts, hook, payload}. The `hook` field holds
#                             Claude Code's event name (e.g. "PostToolUse").
#   transcripts/<id>.jsonl - any transcript files referenced by a Stop event
#
# Usage in a test:
#
#   replay_session "$TEST_DIR/fixtures/sessions/my-session"
#   assert_eq "$(span_count_by_type tool)" "5"
###

# Replay every event in a session fixture exactly the way Claude Code
# would: for each recorded event, look up its handlers in hooks.json and
# run each registered command with the payload piped to stdin. Replay is
# intentionally dumb - it does not know or care which hooks "do something".
# Whatever is registered for an event runs; whatever isn't, doesn't. This
# means record-only events (PreToolUse, PreCompact, ...) replay through
# record_event.sh and simply no-op (recording is off during replay), while
# the acting hooks create their spans.
#
# Stop payloads have their transcript_path rewritten to point at the
# fixture's transcripts/ directory so the hook can find the file.
#
# Returns the number of events that matched at least one handler on stdout;
# returns non-zero if the fixture is missing or any hook returns non-zero.
#
# Requires $HOOKS_DIR and $PLUGIN_DIR (exported by helpers/harness.sh).
replay_session() {
    local fixture_dir="$1"
    local events_file="$fixture_dir/events.ndjson"
    local hooks_json="${HOOKS_DIR:-}/hooks.json"

    if [ ! -f "$events_file" ]; then
        echo "replay_session: fixture not found: $events_file" >&2
        return 1
    fi
    if [ ! -f "$hooks_json" ]; then
        echo "replay_session: hooks.json not found: $hooks_json" >&2
        return 1
    fi

    local replayed=0
    local line event payload

    # Read line-by-line. NDJSON, one event per line.
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        event=$(echo "$line" | jq -r '.hook // empty')
        payload=$(echo "$line" | jq -c '.payload // {}')

        [ -z "$event" ] && continue

        # Rewrite transcript paths so the replayed hook reads the bundled
        # copies instead of the absolute paths from the original machine.
        # Stop references the main transcript via `transcript_path`;
        # SubagentStop references the sub-agent transcript via
        # `agent_transcript_path`. Both are snapshotted flat into
        # transcripts/ by record_hook_input and resolved here by basename.
        local _field
        for _field in transcript_path agent_transcript_path; do
            local original_path basename_t replay_path
            original_path=$(echo "$payload" | jq -r --arg f "$_field" '.[$f] // empty')
            [ -z "$original_path" ] && continue
            basename_t=$(basename "$original_path")
            replay_path="$fixture_dir/transcripts/$basename_t"
            if [ -f "$replay_path" ]; then
                payload=$(echo "$payload" | jq -c \
                    --arg f "$_field" --arg p "$replay_path" '.[$f] = $p')
            fi
        done

        # Look up every command registered for this event in hooks.json and
        # run them in order, mirroring how Claude Code dispatches an event.
        # We read the raw command strings (which embed ${CLAUDE_PLUGIN_ROOT})
        # and substitute the plugin root before executing.
        local commands
        commands=$(jq -r --arg e "$event" '
            .hooks[$e][]?.hooks[]?
            | select(.type == "command")
            | .command
        ' "$hooks_json" 2>/dev/null)

        [ -z "$commands" ] && continue  # no handler registered: nothing to do

        local ran_any=0
        local cmd
        while IFS= read -r cmd; do
            [ -z "$cmd" ] && continue
            # Substitute the plugin-root placeholder with the real path.
            cmd=${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_DIR}

            # Run the command with the payload on stdin, exactly as Claude
            # Code would. Errors fail the replay so tests catch them.
            echo "$payload" | bash -c "$cmd"
            local rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "replay_session: '$event' handler exited $rc on event $((replayed + 1)): $cmd" >&2
                return "$rc"
            fi
            ran_any=1
        done <<< "$commands"

        [ "$ran_any" -eq 1 ] && replayed=$((replayed + 1))
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
