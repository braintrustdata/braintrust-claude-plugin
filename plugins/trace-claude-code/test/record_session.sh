#!/bin/bash
###
# record_session.sh - convenience wrapper for capturing a Claude Code
# session as a test fixture.
#
# Usage:
#   ./record_session.sh <fixture-name>
#
# This prints the env vars you need to set in your shell before running
# Claude Code. After the session, the fixture will be under
# test/fixtures/sessions/<fixture-name>/ ready to be used by replay_session.
#
# Example:
#   $ ./record_session.sh my-session
#   # then in another terminal:
#   $ export BRAINTRUST_RECORD_DIR=/path/printed/above
#   $ claude
#   # ... use claude normally ...
#   # When done:
#   $ ./record_session.sh --describe my-session
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/sessions"

usage() {
    cat <<USAGE
Usage:
  $0 <name>                   Prepare a new fixture and print instructions.
  $0 --describe <name>        Show a summary of an existing fixture.
  $0 --list                   List all existing fixtures.

When recording, all you need to do is set BRAINTRUST_RECORD_DIR (printed by
this script) in your shell before running 'claude'. The hooks themselves
do the recording automatically.
USAGE
    exit 1
}

case "${1:-}" in
    "" | "-h" | "--help") usage ;;
    "--list")
        if [ ! -d "$FIXTURES_DIR" ]; then
            echo "(no fixtures yet)"
            exit 0
        fi
        for d in "$FIXTURES_DIR"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d")
            events_file="$d/events.ndjson"
            n_events=0
            if [ -f "$events_file" ]; then
                n_events=$(wc -l < "$events_file" | tr -d ' ')
            fi
            printf '  %-30s %d events\n' "$name" "$n_events"
        done
        ;;
    "--describe")
        name="${2:-}"
        [ -z "$name" ] && usage
        # Load helpers and dispatch
        # shellcheck source=helpers/replay.sh
        source "$SCRIPT_DIR/helpers/replay.sh"
        describe_fixture "$FIXTURES_DIR/$name"
        ;;
    *)
        name="$1"
        case "$name" in
            -*) usage ;;
        esac
        dest="$FIXTURES_DIR/$name"
        if [ -e "$dest" ]; then
            echo "Fixture '$name' already exists at $dest" >&2
            echo "Remove it first if you want to re-record." >&2
            exit 1
        fi
        mkdir -p "$dest"
        cat <<INFO
Fixture directory created: $dest

To record a session, run these in your shell, then start Claude Code:

    export BRAINTRUST_RECORD_DIR=$dest
    claude

The hooks will append every invocation to:
    $dest/events.ndjson

Any transcript files referenced by the Stop hook will be copied to:
    $dest/transcripts/

When the session ends, you can:
  - View the fixture: $0 --describe $name
  - Use it in a test: replay_session "\$TEST_DIR/fixtures/sessions/$name"

INFO
        ;;
esac
