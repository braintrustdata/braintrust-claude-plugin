#!/bin/bash
###
# reconcile_usage.sh - drive a real Claude Code session headlessly, then
# compare Claude Code's own reported token usage against what the plugin's
# transcript parsing extracts. This is a developer tool for closing token
# reconciliation gaps (e.g. getting opus totals to match).
#
# It runs `claude -p` with the dev plugin dir and BRAINTRUST_RECORD_DIR set,
# captures CC's authoritative per-model usage from `--output-format json`
# (the same numbers /usage shows), then re-derives per-model totals from the
# recorded transcripts (main + sub-agents) using the same rules the plugin
# uses: dedupe by requestId, take MAX output_tokens per request (it streams),
# count input/cache once per request.
#
# Usage:
#   ./reconcile_usage.sh "your prompt here"
#   ./reconcile_usage.sh                       # uses a default sub-agent prompt
#
# Env:
#   CC_PROJECT   Braintrust project (default: trace-cc-debug)
#   KEEP_REC=1   keep the recording dir (otherwise printed but not deleted)
###

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CC_PROJECT="${CC_PROJECT:-trace-cc-debug}"

PROMPT="${1:-Launch two Explore subagents to look at different parts of /tmp, then summarize.}"

SID=$(uuidgen)
REC="${TMPDIR:-/tmp}/cc-reconcile-$SID"
mkdir -p "$REC"

echo "==> Running Claude Code headlessly"
echo "    session: $SID"
echo "    record:  $REC"
echo "    prompt:  $PROMPT"
echo

SETTINGS=$(jq -nc \
    --arg p "$CC_PROJECT" \
    --arg r "$REC" \
    '{env:{TRACE_TO_BRAINTRUST:"true", BRAINTRUST_CC_PROJECT:$p, BRAINTRUST_RECORD_DIR:$r}}')

# Capture CC's JSON result (includes modelUsage + session_id).
CC_JSON=$(cd "${TMPDIR:-/tmp}" && claude -p "$PROMPT" \
    --output-format json \
    --settings "$SETTINGS" \
    --plugin-dir "$PLUGIN_DIR" \
    --session-id "$SID" 2>/dev/null)

if [ -z "$CC_JSON" ]; then
    echo "ERROR: no output from claude -p" >&2
    exit 1
fi

# Resolve the session's transcript from the LIVE Claude projects dir rather
# than the recording's snapshot. In -p mode the plugin's Stop hook copies the
# transcript before the assistant reply is flushed to disk, so the recorded
# copy can be incomplete. The live file under ~/.claude/projects is complete by
# the time `claude -p` has returned. We pull its path (and any sub-agent
# transcripts) from the Stop event payload the plugin recorded.
SESSION_LC=$(echo "$CC_JSON" | jq -r '.session_id' | tr 'A-Z' 'a-z')
LIVE_MAIN=$(jq -rc 'select(.hook=="Stop")|.payload.transcript_path' "$REC/events.ndjson" 2>/dev/null | head -1)
LIVE_DIR=""
[ -n "$LIVE_MAIN" ] && LIVE_DIR=$(dirname "$LIVE_MAIN")

echo "==> Claude Code reported usage (authoritative):"
echo "$CC_JSON" | jq -r '
    .modelUsage // {}
    | to_entries[]
    | "    \(.key): input=\(.value.inputTokens) output=\(.value.outputTokens) cache_read=\(.value.cacheReadInputTokens) cache_write=\(.value.cacheCreationInputTokens) cost=$\(.value.costUSD)"
'
echo "    total_cost=$(echo "$CC_JSON" | jq -r '.total_cost_usd // "?"')"
echo

# ---- Derive plugin-side totals from the recorded transcripts ----
# Normalize model names: CC's modelUsage uses e.g. "claude-opus-4-8[1m]",
# transcripts use "claude-opus-4-8". Strip the "[...]" suffix for comparison.
_strip_model() { sed -E 's/\[[^]]*\]$//'; }

echo "==> Plugin-derived usage from the session transcripts:"
# Prefer the live transcript(s): the main file plus any sub-agent transcripts
# under <session>/subagents/. Fall back to the recorded snapshot.
TRANSCRIPTS=""
if [ -n "$LIVE_MAIN" ] && [ -f "$LIVE_MAIN" ]; then
    SESSION_BASE=$(basename "$LIVE_MAIN" .jsonl)
    TRANSCRIPTS="$LIVE_MAIN"
    if [ -d "$LIVE_DIR/$SESSION_BASE/subagents" ]; then
        TRANSCRIPTS="$TRANSCRIPTS
$(find "$LIVE_DIR/$SESSION_BASE/subagents" -name 'agent-*.jsonl' -type f 2>/dev/null)"
    fi
fi
[ -z "${TRANSCRIPTS//[[:space:]]/}" ] && TRANSCRIPTS=$(find "$REC/transcripts" -name '*.jsonl' -type f 2>/dev/null)
if [ -z "${TRANSCRIPTS//[[:space:]]/}" ]; then
    echo "    (no transcripts found)"
else
    # Per model: dedupe assistant lines by requestId; max each token field.
    # shellcheck disable=SC2086
    jq -rs '
        [ .[]
          | select(.type=="assistant")
          | select(.message.usage != null)
          | { model:(.message.model // "claude"),
              rid:(.requestId // .message.id),
              inp:(.message.usage.input_tokens // 0),
              out:(.message.usage.output_tokens // 0),
              cr:(.message.usage.cache_read_input_tokens // 0),
              cc:(.message.usage.cache_creation_input_tokens // 0) }
        ]
        | group_by(.model)
        | map(
            .[0].model as $m
            | (group_by(.rid)
               | { model:$m,
                   requests:length,
                   input:(map([.[].inp]|max)|add),
                   output:(map([.[].out]|max)|add),
                   cache_read:(map([.[].cr]|max)|add),
                   cache_write:(map([.[].cc]|max)|add) })
          )
        | .[]
        | "    \(.model): input=\(.input) output=\(.output) cache_read=\(.cache_read) cache_write=\(.cache_write) (\(.requests) requests)"
    ' $TRANSCRIPTS
fi
echo

# ---- Print a focused diff for each model CC reported ----
echo "==> Diff (CC - plugin), per model:"
echo "$CC_JSON" | jq -r '.modelUsage // {} | to_entries[] | "\(.key)\t\(.value.inputTokens)\t\(.value.outputTokens)\t\(.value.cacheReadInputTokens)\t\(.value.cacheCreationInputTokens)"' \
| while IFS=$'\t' read -r ccmodel ci co ccr ccw; do
    model=$(echo "$ccmodel" | _strip_model)
    # plugin totals for this model
    ptot=$(jq -s --arg m "$model" '
        [ .[] | select(.type=="assistant") | select(.message.usage != null)
          | select((.message.model // "") == $m)
          | { rid:(.requestId // .message.id),
              inp:(.message.usage.input_tokens // 0),
              out:(.message.usage.output_tokens // 0),
              cr:(.message.usage.cache_read_input_tokens // 0),
              cc:(.message.usage.cache_creation_input_tokens // 0) } ]
        | group_by(.rid)
        | { input:(map([.[].inp]|max)|add // 0),
            output:(map([.[].out]|max)|add // 0),
            cache_read:(map([.[].cr]|max)|add // 0),
            cache_write:(map([.[].cc]|max)|add // 0) }
    ' $TRANSCRIPTS 2>/dev/null)
    pi=$(echo "$ptot" | jq -r '.input // 0')
    po=$(echo "$ptot" | jq -r '.output // 0')
    pcr=$(echo "$ptot" | jq -r '.cache_read // 0')
    pcw=$(echo "$ptot" | jq -r '.cache_write // 0')
    printf '    %s\n' "$model"
    printf '      input:       cc=%-8s plugin=%-8s diff=%s\n' "$ci"  "$pi"  "$((ci - pi))"
    printf '      output:      cc=%-8s plugin=%-8s diff=%s\n' "$co"  "$po"  "$((co - po))"
    printf '      cache_read:  cc=%-8s plugin=%-8s diff=%s\n' "$ccr" "$pcr" "$((ccr - pcr))"
    printf '      cache_write: cc=%-8s plugin=%-8s diff=%s\n' "$ccw" "$pcw" "$((ccw - pcw))"
done

echo
echo "==> session_id: $(echo "$CC_JSON" | jq -r '.session_id')"
echo "==> recording: $REC"
if [ "${KEEP_REC:-0}" != "1" ]; then
    echo "    (set KEEP_REC=1 to preserve; leaving in place for inspection)"
fi
