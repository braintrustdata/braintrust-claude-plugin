#!/bin/bash
###
# Record-only hook - captures a hook event's stdin payload for fixtures,
# and otherwise does nothing.
#
# This script is registered for every Claude Code hook event that the
# plugin does not otherwise act on (PreToolUse, SubagentStart/Stop,
# PreCompact/PostCompact, etc.). Its sole purpose is observability: when
# BRAINTRUST_RECORD_DIR is set it appends the event to the recording so we
# can see exactly what data Claude Code makes available at each lifecycle
# point. When recording is off it is a near-instant no-op.
#
# The event name is passed as the first argument because not every hook
# payload self-identifies the event, and we want the recording to label
# each event unambiguously.
#
# Usage (from hooks.json):
#   "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/record_event.sh PreToolUse"
#
# This hook NEVER blocks Claude Code and NEVER fails the event: it always
# exits 0, even on internal errors, so adding it everywhere is safe.
###

# Note: intentionally no `set -e`. A record-only hook must never abort a
# Claude Code event, so we swallow all errors and always exit 0.

# Fast path: if recording is off there is nothing to do. Avoid even
# reading stdin so the hook is as close to a no-op as possible.
[ -z "${BRAINTRUST_RECORD_DIR:-}" ] && exit 0

EVENT_NAME="${1:-unknown_event}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh" 2>/dev/null || exit 0

# Read the event payload from stdin and record it under the event's name.
INPUT=$(cat 2>/dev/null)
record_hook_input "$EVENT_NAME" "$INPUT" 2>/dev/null || true

exit 0
