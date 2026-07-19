#!/bin/bash
###
# Regression tests for credential sanitization across hook telemetry,
# persistence, recordings, logs, and transport.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

_setup_insert_stub() {
    stub_response_for "*/v1/project_logs/*/insert" 200 '{"row_ids":["row_secure"]}'
}

_set_transport_secret() {
    local secret="$1"
    export BRAINTRUST_API_KEY="$secret"
    export API_KEY="$secret"
}

_activate_turn() {
    local session_id="$1"
    set_session_state "$session_id" "root_span_id" "root-$session_id"
    set_session_state "$session_id" "session_span_id" "root-$session_id"
    set_session_state "$session_id" "project_id" "proj-secure"
    set_session_state "$session_id" "current_turn_span_id" "turn-$session_id"
    set_session_state "$session_id" "current_turn_tool_count" "0"
    set_session_state "$session_id" "turn_last_line" "0"
}

_assert_absent() {
    local content="$1"
    local secret="$2"
    local message="$3"
    assert_not_contains "$content" "$secret" "$message"
}

# ---------------------------------------------------------------------------
describe "sanitize_text"
# ---------------------------------------------------------------------------

t_text_redacts_credential_forms() {
    local input output slack_token
    slack_token=$(printf '%s%s' 'xox' 'b-1234567890-abcdefghijklmnopqrstuvwxyz')
    input=$(printf '%s\n' \
        'BRAINTRUST_API_KEY=sk-xyz' \
        'export OPENAI_API_KEY="openai short value"' \
        "ANTHROPIC_API_KEY='anthropic-short'" \
        'CUSTOM_API_KEY=custom-short-value' \
        'SERVICE_TOKEN=service-token-value SERVICE_SECRET=service-secret-value DB_PASSWORD=db-password-value' \
        'bt --api-key cli-api-value --token="cli token value"' \
        'Authorization: Bearer bearer-value' \
        'Authorization: Bearer "quoted-bearer-value"' \
        'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789' \
        'ghp_abcdefghijklmnopqrstuvwxyz0123456789' \
        "$slack_token" \
        '-----BEGIN PRIVATE KEY-----' \
        'private-key-body' \
        '-----END PRIVATE KEY-----')

    output=$(sanitize_text "$input")

    for secret in \
        sk-xyz \
        "openai short value" \
        anthropic-short \
        custom-short-value \
        service-token-value \
        service-secret-value \
        db-password-value \
        cli-api-value \
        "cli token value" \
        bearer-value \
        quoted-bearer-value \
        sk-proj-abcdefghijklmnopqrstuvwxyz0123456789 \
        ghp_abcdefghijklmnopqrstuvwxyz0123456789 \
        "$slack_token" \
        private-key-body; do
        _assert_absent "$output" "$secret" "redacts $secret"
    done
    assert_contains "$output" "$BRAINTRUST_REDACTION_PLACEHOLDER" "uses the standard placeholder"
}

t_text_preserves_ordinary_values() {
    local input output
    input='task-status ask-user 123e4567-e89b-12d3-a456-426614174000 monkey keyboard normal-id-42'
    output=$(sanitize_text "$input")
    assert_eq "$output" "$input" "ordinary hyphenated names and identifiers remain unchanged"
}

t_text_redacts_multiple_secrets() {
    local input output
    input='OPENAI_API_KEY=first-short OTHER_TOKEN=second-short Authorization: Bearer third-short'
    output=$(sanitize_text "$input")
    _assert_absent "$output" "first-short" "first secret removed"
    _assert_absent "$output" "second-short" "second secret removed"
    _assert_absent "$output" "third-short" "third secret removed"
    assert_eq "$(printf '%s' "$output" | grep -oF "$BRAINTRUST_REDACTION_PLACEHOLDER" | wc -l | tr -d ' ')" "3" "all secrets receive placeholders"
}

it "redacts assignments, CLI flags, headers, provider tokens, and PEM keys" t_text_redacts_credential_forms
it "preserves task-status, ask-user, UUIDs, and ordinary words" t_text_preserves_ordinary_values
it "redacts multiple secrets in one string" t_text_redacts_multiple_secrets

# ---------------------------------------------------------------------------
describe "sanitize_json and sanitize_span_event"
# ---------------------------------------------------------------------------

t_json_redacts_nested_sensitive_fields() {
    local input output
    input='{
        "ApiKey":"one",
        "AUTHORIZATION":"Bearer two",
        "nested":[
            {"access-token":"three","refresh_token":"four"},
            {"clientSecret":"five","password":"six","credentials":{"user":"seven"}}
        ],
        "arguments":"{\"api_key\":\"eight\",\"command\":\"OTHER_SECRET=nine\"}",
        "monkey":"banana",
        "keyboard":"mechanical",
        "key":"harmless-key",
        "id":"123e4567-e89b-12d3-a456-426614174000"
    }'
    output=$(sanitize_json "$input")

    for secret in one two three four five six seven eight nine; do
        _assert_absent "$output" "$secret" "nested secret $secret removed"
    done
    assert_eq "$(echo "$output" | jq -r '.monkey')" "banana"
    assert_eq "$(echo "$output" | jq -r '.keyboard')" "mechanical"
    assert_eq "$(echo "$output" | jq -r '.key')" "harmless-key"
    assert_eq "$(echo "$output" | jq -r '.id')" "123e4567-e89b-12d3-a456-426614174000"
    assert_eq "$(echo "$output" | jq -r '.nested[0]["access-token"]')" "$BRAINTRUST_REDACTION_PLACEHOLDER"
}

t_span_event_sanitizes_all_payload_sections() {
    local secret='sk-span-event-secret-1234567890'
    local event output
    event=$(jq -nc --arg secret "$secret" '{
        id:"span-1",
        input:{command:("BRAINTRUST_API_KEY=" + $secret)},
        output:{stdout:("Authorization: Bearer " + $secret)},
        metadata:{access_token:$secret, harmless_id:"normal-id"},
        span_attributes:{name:("Terminal: BRAINTRUST_API_KEY=" + $secret), type:"tool"}
    }')
    output=$(sanitize_span_event "$event")

    _assert_absent "$output" "$secret" "complete event is sanitized"
    assert_eq "$(echo "$output" | jq -r '.metadata.harmless_id')" "normal-id"
    assert_contains "$(echo "$output" | jq -r '.span_attributes.name')" "$BRAINTRUST_REDACTION_PLACEHOLDER"
}

it "redacts nested fields, arrays, and JSON-serialized tool arguments" t_json_redacts_nested_sensitive_fields
it "sanitizes span names, input, output, and metadata" t_span_event_sanitizes_all_payload_sections

# ---------------------------------------------------------------------------
describe "PostToolUse security boundaries"
# ---------------------------------------------------------------------------

t_bash_hook_sanitizes_transport_logs_and_recording() {
    local secret='sk-bt-hook-fixture-1234567890'
    local sid='secure-bash'
    _set_transport_secret "$secret"
    _setup_insert_stub
    _activate_turn "$sid"
    export BRAINTRUST_CC_DEBUG=true
    export BRAINTRUST_RECORD_DIR="$TEST_TMP/recording"

    local command response payload
    command="export BRAINTRUST_API_KEY=\"$secret\"; bt --api-key $secret run"
    response=$(jq -nc --arg secret "$secret" '{stdout:("Authorization: Bearer " + $secret), password:$secret}')
    payload=$(fixture_post_tool_use "$sid" "Bash" \
        "$(fixture_tool_input_bash "$command")" \
        "$response")

    run_hook post_tool_use.sh "$payload"
    assert_success "$HOOK_STATUS"

    local spans requests logs recording
    spans=$(captured_spans)
    requests=$(cat "$CAPTURED_REQUESTS")
    logs=$(hook_log)
    recording=$(cat "$BRAINTRUST_RECORD_DIR/events.ndjson")

    _assert_absent "$spans" "$secret" "tool span telemetry excludes the configured key"
    _assert_absent "$requests" "$secret" "captured API payload excludes the configured key"
    _assert_absent "$logs" "$secret" "debug and normal logs exclude the configured key"
    _assert_absent "$recording" "$secret" "recorded hook fixture excludes the configured key"
    assert_contains "$(echo "$spans" | jq -r '.[0].span_attributes.name')" "$BRAINTRUST_REDACTION_PLACEHOLDER" "span name uses sanitized command preview"
    assert_eq "$(jq -s '[.[] | select(.url | test("/insert$"))][0].auth_uses_configured_api_key' "$CAPTURED_REQUESTS")" "true" "transport uses the real configured API key"
}

t_queue_and_http_boundaries_are_non_bypassable() {
    local secret='sk-boundary-fixture-1234567890'
    _set_transport_secret "$secret"
    _setup_insert_stub
    export BRAINTRUST_SYNC_QUEUE=false

    # Keep the job on disk so the persisted queue payload can be inspected.
    ensure_worker_running() { return 0; }

    local event
    event=$(jq -nc --arg secret "$secret" '{
        id:"span-boundary",
        span_id:"span-boundary",
        input:{command:("OPENAI_API_KEY=" + $secret)},
        output:{token:$secret},
        span_attributes:{name:("Terminal: " + $secret), type:"tool"}
    }')

    enqueue_span "secure-queue" "proj-secure" "$event"
    assert_success "$?" "enqueue accepts the event after sanitizing it"

    local queue_file queue_payload
    queue_file=$(find "$(session_queue_dir secure-queue)/pending" -name '*.json' -type f | head -1)
    queue_payload=$(cat "$queue_file")
    _assert_absent "$queue_payload" "$secret" "queue file excludes the raw secret"

    # Pass the original unsanitized event directly to the low-level transport;
    # its own final scrub must still prevent an outbound leak.
    _http_insert_span "proj-secure" "$event" >/dev/null
    assert_success "$?" "direct HTTP insertion succeeds"
    _assert_absent "$(cat "$CAPTURED_REQUESTS")" "$secret" "outbound payload excludes the raw secret"
    assert_eq "$(jq -s '.[-1].auth_uses_configured_api_key' "$CAPTURED_REQUESTS")" "true" "Authorization header still uses the configured key"
}

it "sanitizes Bash spans, outputs, debug logs, recordings, and API payloads" t_bash_hook_sanitizes_transport_logs_and_recording
it "sanitizes both queue files and direct outbound requests" t_queue_and_http_boundaries_are_non_bypassable

# ---------------------------------------------------------------------------
describe "LLM conversation and sub-agent transcript sanitization"
# ---------------------------------------------------------------------------

t_stop_hook_sanitizes_accumulated_history() {
    local secret='sk-history-fixture-1234567890'
    local sid='secure-history'
    _set_transport_secret "$secret"
    _setup_insert_stub
    _activate_turn "$sid"

    local transcript="$TEST_TMP/history.jsonl"
    {
        jq -nc --arg secret "$secret" '{
            type:"user", timestamp:"2026-01-01T00:00:00.000Z",
            message:{role:"user", content:("use BRAINTRUST_API_KEY=" + $secret)}
        }'
        jq -nc --arg secret "$secret" '{
            type:"assistant", requestId:"req-secret-1", timestamp:"2026-01-01T00:00:01.000Z",
            message:{model:"claude-test", content:[{
                type:"tool_use", id:"tool-secret", name:"Bash",
                input:{command:("bt --api-key " + $secret), api_key:$secret}
            }], usage:{input_tokens:5, output_tokens:5, cache_creation_input_tokens:0, cache_read_input_tokens:0}}
        }'
        jq -nc --arg secret "$secret" '{
            type:"user", timestamp:"2026-01-01T00:00:02.000Z",
            message:{content:[{type:"tool_result", tool_use_id:"tool-secret", content:("Authorization: Bearer " + $secret)}]}
        }'
        jq -nc --arg secret "$secret" '{
            type:"assistant", requestId:"req-secret-2", timestamp:"2026-01-01T00:00:03.000Z",
            message:{model:"claude-test", content:[{type:"text", text:("finished with " + $secret)}], usage:{input_tokens:4, output_tokens:4, cache_creation_input_tokens:0, cache_read_input_tokens:0}}
        }'
    } > "$transcript"

    run_hook stop_hook.sh "$(fixture_stop "$sid" "$transcript" "final $secret")"
    assert_success "$HOOK_STATUS"

    local spans
    spans=$(captured_spans)
    _assert_absent "$spans" "$secret" "LLM inputs, outputs, tool arguments, and accumulated history exclude the secret"
    assert_eq "$(echo "$spans" | jq '[.[] | select(.span_attributes.type == "llm")] | length')" "2" "LLM spans are still emitted"
}

t_subagent_transcript_spans_are_sanitized() {
    local secret='sk-subagent-fixture-1234567890'
    local sid='secure-subagent'
    _set_transport_secret "$secret"
    _setup_insert_stub
    _activate_turn "$sid"

    local main_transcript="$TEST_TMP/main.jsonl"
    local agent_id='agent-secure'
    local agent_transcript="$TEST_TMP/agent-${agent_id}.jsonl"
    : > "$main_transcript"
    {
        jq -nc --arg secret "$secret" '{
            type:"assistant", requestId:"agent-req-1", timestamp:"2026-01-01T00:00:00.000Z",
            message:{model:"claude-haiku", content:[
                {type:"text", text:("using " + $secret)},
                {type:"tool_use", id:"agent-tool", name:"Bash", input:{command:("BRAINTRUST_API_KEY=" + $secret + " bt")}}
            ], usage:{input_tokens:2, output_tokens:3, cache_creation_input_tokens:0, cache_read_input_tokens:0}}
        }'
        jq -nc --arg secret "$secret" '{
            type:"user", timestamp:"2026-01-01T00:00:01.000Z",
            message:{content:[{type:"tool_result", tool_use_id:"agent-tool", content:("token=" + $secret)}]}
        }'
        jq -nc --arg secret "$secret" '{
            type:"assistant", requestId:"agent-req-2", timestamp:"2026-01-01T00:00:02.000Z",
            message:{model:"claude-haiku", content:[{type:"text", text:("done " + $secret)}], usage:{input_tokens:2, output_tokens:3, cache_creation_input_tokens:0, cache_read_input_tokens:0}}
        }'
    } > "$agent_transcript"

    local payload
    payload=$(jq -nc \
        --arg sid "$sid" \
        --arg path "$main_transcript" \
        --arg agent_id "$agent_id" \
        '{
            session_id:$sid,
            transcript_path:$path,
            tool_name:"Agent",
            tool_input:{description:"secure agent"},
            tool_response:{agentId:$agent_id, status:"completed"}
        }')
    run_hook post_tool_use.sh "$payload"
    assert_success "$HOOK_STATUS"

    local spans
    spans=$(captured_spans)
    _assert_absent "$spans" "$secret" "sub-agent LLM and tool spans exclude the secret"
    assert_eq "$(echo "$spans" | jq '[.[] | select(.span_attributes.type == "llm")] | length')" "2" "sub-agent LLM span hierarchy is preserved"
    assert_contains "$(echo "$spans" | jq -r '[.[] | select(.metadata.tool_name == "Bash")][0].span_attributes.name')" "$BRAINTRUST_REDACTION_PLACEHOLDER" "sub-agent terminal name uses a sanitized preview"
}

it "sanitizes LLM tool-call arguments and accumulated conversation history" t_stop_hook_sanitizes_accumulated_history
it "sanitizes transcript-derived sub-agent LLM and tool spans" t_subagent_transcript_spans_are_sanitized

# ---------------------------------------------------------------------------
describe "recording fixtures"
# ---------------------------------------------------------------------------

t_recording_sanitizes_events_and_transcript_snapshots() {
    local secret='sk-recording-fixture-1234567890'
    _set_transport_secret "$secret"
    export BRAINTRUST_RECORD_DIR="$TEST_TMP/recording"

    local transcript="$TEST_TMP/agent-recorded.jsonl"
    jq -nc --arg secret "$secret" '{
        type:"assistant",
        message:{content:[{type:"text", text:("BRAINTRUST_API_KEY=" + $secret)}], api_key:$secret}
    }' > "$transcript"

    local payload
    payload=$(jq -nc \
        --arg path "$transcript" \
        --arg secret "$secret" \
        '{
            hook_event_name:"SubagentStop",
            session_id:"record-secure",
            agent_transcript_path:$path,
            tool_response:{authorization:("Bearer " + $secret)}
        }')
    record_hook_input "SubagentStop" "$payload"

    # Exercise the generic record-only hook as well.
    printf '%s' "$(jq -nc --arg secret "$secret" '{hook_event_name:"PreToolUse", token:$secret}')" \
        | bash "$HOOKS_DIR/record_event.sh" PreToolUse

    local events snapshot
    events=$(cat "$BRAINTRUST_RECORD_DIR/events.ndjson")
    snapshot=$(cat "$BRAINTRUST_RECORD_DIR/transcripts/agent-recorded.jsonl")
    _assert_absent "$events" "$secret" "recorded hook events exclude the secret"
    _assert_absent "$snapshot" "$secret" "recorded transcript snapshot excludes the secret"
    assert_contains "$events" "$BRAINTRUST_REDACTION_PLACEHOLDER"
    assert_contains "$snapshot" "$BRAINTRUST_REDACTION_PLACEHOLDER"
}

it "sanitizes hook recording mode and copied transcript fixtures" t_recording_sanitizes_events_and_transcript_snapshots

exit "$(tests_failed)"
