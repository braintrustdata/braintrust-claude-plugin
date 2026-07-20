#!/bin/bash
###
# Fixture builders for Claude Code hook payloads.
#
# Each builder returns a JSON object on stdout that matches the shape
# Claude Code passes to the corresponding hook script over stdin.
#
# Usage in tests:
#   payload=$(fixture_session_start "sess-1" "/tmp/proj")
#   run_hook session_start.sh "$payload"
###

# SessionStart payload
#
# Args: [session_id] [cwd]
fixture_session_start() {
    local session_id="${1:-test-session}"
    local cwd="${2:-/tmp/test-workspace}"
    jq -nc \
        --arg s "$session_id" \
        --arg c "$cwd" \
        '{session_id: $s, cwd: $c}'
}

# UserPromptSubmit payload
#
# Args: session_id prompt [cwd]
fixture_user_prompt() {
    local session_id="$1"
    local prompt="$2"
    local cwd="${3:-/tmp/test-workspace}"
    jq -nc \
        --arg s "$session_id" \
        --arg p "$prompt" \
        --arg c "$cwd" \
        '{session_id: $s, prompt: $p, cwd: $c}'
}

# PostToolUse payload
#
# Args: session_id tool_name tool_input_json tool_response_json
fixture_post_tool_use() {
    local session_id="$1"
    local tool_name="$2"
    local tool_input="$3"      # JSON object
    local tool_response="$4"   # JSON object
    jq -nc \
        --arg s "$session_id" \
        --arg t "$tool_name" \
        --argjson i "$tool_input" \
        --argjson r "$tool_response" \
        '{session_id: $s, tool_name: $t, tool_input: $i, tool_response: $r}'
}

# PostToolUseFailure payload
#
# Args: session_id tool_name tool_input_json error [tool_response_json]
fixture_post_tool_use_failure() {
    local session_id="$1"
    local tool_name="$2"
    local tool_input="$3"      # JSON object
    local error="$4"
    local tool_response="${5:-}"
    [ -z "$tool_response" ] && tool_response="{}"
    jq -nc \
        --arg s "$session_id" \
        --arg t "$tool_name" \
        --arg e "$error" \
        --argjson i "$tool_input" \
        --argjson r "$tool_response" \
        '{session_id: $s, tool_name: $t, tool_input: $i, tool_response: $r, error: $e}'
}

# PermissionDenied payload
#
# Args: session_id tool_name tool_input_json [tool_use_id]
fixture_permission_denied() {
    local session_id="$1"
    local tool_name="$2"
    local tool_input="$3"      # JSON object
    local tool_use_id="${4:-}"
    jq -nc \
        --arg s "$session_id" \
        --arg t "$tool_name" \
        --arg tuid "$tool_use_id" \
        --argjson i "$tool_input" \
        '{session_id: $s, tool_name: $t, tool_input: $i} + (if $tuid != "" then {tool_use_id: $tuid} else {} end)'
}

# Stop payload - includes the transcript path and optionally the
# last assistant message that Claude Code provides in real Stop events.
#
# Args: session_id transcript_path [last_assistant_message]
fixture_stop() {
    local session_id="$1"
    local transcript_path="$2"
    local last_msg="${3:-}"
    jq -nc \
        --arg s "$session_id" \
        --arg t "$transcript_path" \
        --arg m "$last_msg" \
        '{session_id: $s, transcript_path: $t, last_assistant_message: $m}'
}

# SessionEnd payload
#
# Args: session_id
fixture_session_end() {
    local session_id="$1"
    jq -nc --arg s "$session_id" '{session_id: $s}'
}

# Convenience: tool input/output JSON builders
fixture_tool_input_bash() {
    local command="$1"
    jq -nc --arg c "$command" '{command: $c}'
}

fixture_tool_input_read() {
    local file_path="$1"
    jq -nc --arg p "$file_path" '{file_path: $p}'
}

fixture_tool_response_text() {
    local output="$1"
    jq -nc --arg o "$output" '{output: $o}'
}
