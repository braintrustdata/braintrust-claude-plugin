#!/bin/bash
###
# End-to-end tests for the PostToolUse hook.
#
# PostToolUse fires after each tool invocation by the assistant. It creates
# a "tool" span as a child of the current Turn span. If no current Turn is
# active (no UserPromptSubmit since last Stop), the tool span is skipped.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

_setup_default_stubs() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_test"}'
    stub_response_for "*/v1/project_logs/*/insert"  200 '{"row_ids":["row_1"]}'
}

# Setup helper: run session_start + user_prompt_submit, then clear capture.
_with_turn_started() {
    local session_id="$1"
    _setup_default_stubs
    run_hook session_start.sh "$(fixture_session_start "$session_id" "/tmp/x")"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$session_id" "do something")"
    : > "$CAPTURED_REQUESTS"
}

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: with active turn"
# ---------------------------------------------------------------------------

t_post_tool_creates_tool_span() {
    _with_turn_started "sess-pt-1"

    local payload
    payload=$(fixture_post_tool_use "sess-pt-1" "Bash" \
        "$(fixture_tool_input_bash 'ls -la')" \
        "$(fixture_tool_response_text 'a.txt\nb.txt')")
    payload=$(echo "$payload" | jq -c '. + {tool_use_id: "toolu_success"}')

    run_hook post_tool_use.sh "$payload"
    assert_success "$HOOK_STATUS"

    local count
    count=$(span_count)
    assert_eq "$count" "1"

    local tool_span
    tool_span=$(span_by_type "tool")
    assert_ne "$tool_span" "null"

    local name
    name=$(echo "$tool_span" | jq -r '.span_attributes.name')
    # Bash spans become "Terminal: <cmd>"
    assert_contains "$name" "Terminal"
    assert_contains "$name" "ls -la"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_approval')" "approved"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_call_id')" "toolu_success"
}

t_post_tool_failure_creates_error_span() {
    _with_turn_started "sess-pt-fail"

    run_hook post_tool_use_failure.sh "$(fixture_post_tool_use_failure "sess-pt-fail" "Bash" \
        "$(fixture_tool_input_bash 'exit 1')" \
        "Exit code 1" \
        "$(fixture_tool_response_text 'failed')")"
    assert_success "$HOOK_STATUS"

    local tool_span
    tool_span=$(span_by_type "tool")
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_approval')" "approved"
    assert_eq "$(echo "$tool_span" | jq -r '.error')" "Exit code 1"
}

t_permission_denied_creates_denied_span() {
    _with_turn_started "sess-pt-denied"

    run_hook permission_denied.sh "$(fixture_permission_denied "sess-pt-denied" "Bash" \
        "$(fixture_tool_input_bash 'rm -rf /tmp/nope')" \
        "toolu_denied")"
    assert_success "$HOOK_STATUS"

    local tool_span
    tool_span=$(span_by_type "tool")
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_approval')" "denied"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_call_id')" "toolu_denied"
    assert_eq "$(echo "$tool_span" | jq 'has("output")')" "false"
    assert_eq "$(echo "$tool_span" | jq 'has("error")')" "false"
}

t_tool_span_is_child_of_turn() {
    _with_turn_started "sess-pt-child"

    # Capture the current turn id from state
    local turn_id
    turn_id=$(get_session_state "sess-pt-child" "current_turn_span_id")
    assert_ne "$turn_id" "" "expected a current turn span"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-child" "Read" \
        "$(fixture_tool_input_read /tmp/a.txt)" \
        "$(fixture_tool_response_text 'hello')")"

    local tool_span
    tool_span=$(span_by_type "tool")
    local parent
    parent=$(echo "$tool_span" | jq -r '.span_parents[0]')

    assert_eq "$parent" "$turn_id"
}

t_read_tool_span_name_includes_basename() {
    _with_turn_started "sess-pt-read"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-read" "Read" \
        "$(fixture_tool_input_read /tmp/some/long/path/file.txt)" \
        "$(fixture_tool_response_text 'content')")"

    local tool_span name
    tool_span=$(span_by_type "tool")
    name=$(echo "$tool_span" | jq -r '.span_attributes.name')
    assert_eq "$name" "Read: file.txt"
}

t_skill_tool_span_marks_tool_kind() {
    _with_turn_started "sess-pt-skill"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-skill" "Skill" \
        "$(jq -nc '{name: "review"}')" \
        "$(fixture_tool_response_text 'loaded')")"

    local tool_span name
    tool_span=$(span_by_type "tool")
    name=$(echo "$tool_span" | jq -r '.span_attributes.name')
    assert_eq "$name" "skill: review"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_name')" "Skill"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.tool_kind')" "skill"
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.skill_name')" "review"
}

t_multiple_tools_in_turn() {
    _with_turn_started "sess-pt-multi"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Bash" \
        "$(fixture_tool_input_bash 'echo 1')" \
        "$(fixture_tool_response_text '1')")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Bash" \
        "$(fixture_tool_input_bash 'echo 2')" \
        "$(fixture_tool_response_text '2')")"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-pt-multi" "Read" \
        "$(fixture_tool_input_read /tmp/x)" \
        "$(fixture_tool_response_text 'x')")"

    local tool_count
    tool_count=$(span_count_by_type "tool")
    assert_eq "$tool_count" "3"
}

it "creates a tool span on PostToolUse"             t_post_tool_creates_tool_span
it "creates an error tool span on PostToolUseFailure" t_post_tool_failure_creates_error_span
it "creates a denied tool span on PermissionDenied" t_permission_denied_creates_denied_span
it "tool span is a child of the current Turn span"  t_tool_span_is_child_of_turn
it "Read tool span name includes file basename"     t_read_tool_span_name_includes_basename
it "Skill tool span marks tool kind"                t_skill_tool_span_marks_tool_kind
it "all tools in a turn produce distinct spans"     t_multiple_tools_in_turn

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: without active turn"
# ---------------------------------------------------------------------------

t_post_tool_skipped_without_turn() {
    # No session_start or user_prompt_submit ran. The hook should bail out
    # without creating any span (and without erroring).
    _setup_default_stubs

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-no-turn" "Bash" \
        "$(fixture_tool_input_bash 'ls')" \
        "$(fixture_tool_response_text 'output')")"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "skips silently when no current turn is active" t_post_tool_skipped_without_turn

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: input validation"
# ---------------------------------------------------------------------------

t_post_tool_no_tool_name() {
    _with_turn_started "sess-no-name"

    # Payload without tool_name
    local payload
    payload=$(jq -nc --arg s "sess-no-name" '{session_id: $s}')
    run_hook post_tool_use.sh "$payload"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

t_post_tool_no_session_id() {
    _setup_default_stubs

    local payload
    payload=$(jq -nc --arg t "Bash" '{tool_name: $t, tool_input: {}, tool_response: {}}')
    run_hook post_tool_use.sh "$payload"

    assert_success "$HOOK_STATUS"
    local count
    count=$(span_count)
    assert_eq "$count" "0"
}

it "skips silently when payload has no tool_name"   t_post_tool_no_tool_name
it "skips silently when payload has no session_id"  t_post_tool_no_session_id

# ---------------------------------------------------------------------------
describe "post_tool_use.sh: Agent sub-agent LLM spans"
# ---------------------------------------------------------------------------

# When the tool is an Agent (sub-agent), the hook should locate the
# sub-agent's transcript and emit its model calls as LLM spans nested under
# the Agent tool span.
t_agent_emits_subagent_llm_spans() {
    _with_turn_started "sess-agent"

    # The Agent payload references the main transcript_path. The hook derives
    # the sub-agent transcript from dirname(transcript_path) + agent-<id>;
    # we place a synthetic one in that flat fallback location.
    local main_transcript="$TEST_TMP/88a535be.jsonl"
    : > "$main_transcript"
    local agent_id="aea5test"
    local agent_transcript="$TEST_TMP/agent-${agent_id}.jsonl"
    {
        # r1: text + a tool_use (Bash) -> emits an LLM span and a tool span.
        echo '{"type":"assistant","requestId":"r1","timestamp":"2026-06-11T03:00:00.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls -la"}}],"usage":{"input_tokens":5,"output_tokens":40,"cache_creation_input_tokens":10,"cache_read_input_tokens":1000}}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"Exit code 128","is_error":true}]}}'
        # r2: final text answer -> emits a second LLM span (with history).
        echo '{"type":"assistant","requestId":"r2","timestamp":"2026-06-11T03:00:02.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"bye"}],"usage":{"input_tokens":3,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":1500}}}'
    } > "$agent_transcript"

    # Build an Agent PostToolUse payload with transcript_path + tool_response.agentId.
    local payload
    payload=$(jq -nc \
        --arg s "sess-agent" \
        --arg tp "$main_transcript" \
        --arg aid "$agent_id" \
        '{
            session_id: $s,
            transcript_path: $tp,
            tool_name: "Agent",
            tool_input: {description: "explore", subagent_type: "Explore"},
            tool_response: {agentId: $aid, content: "result"}
        }')

    run_hook post_tool_use.sh "$payload"
    assert_success "$HOOK_STATUS"

    # Tool spans: the Agent tool span itself + the sub-agent's Bash tool span.
    assert_eq "$(span_count_by_type tool)" "2" "Agent span + sub-agent Bash tool span"
    # Two sub-agent LLM spans (r1, r2).
    assert_eq "$(span_count_by_type llm)"  "2" "two sub-agent LLM spans"

    # The Agent tool span is the one named "Agent"; the sub-agent spans nest
    # under it.
    local agent_span_id
    agent_span_id=$(all_spans | jq -r '[.[]|select(.span_attributes.type=="tool" and .span_attributes.name=="Agent")][0].span_id')

    # Every LLM span is a child of the Agent tool span.
    local llm_parents_ok
    llm_parents_ok=$(all_spans | jq --arg p "$agent_span_id" \
        'all(.[]|select(.span_attributes.type=="llm"); .span_parents[0] == $p)')
    assert_eq "$llm_parents_ok" "true" "LLM spans nested under the Agent tool span"

    # The sub-agent's Bash tool span also nests under the Agent tool span.
    local subagent_tool
    subagent_tool=$(all_spans | jq --arg p "$agent_span_id" \
        '[.[]|select(.span_attributes.type=="tool" and .span_parents[0]==$p)][0]')
    assert_eq "$(echo "$subagent_tool" | jq -r '.span_attributes.name')" "Terminal: ls -la" "sub-agent tool span named after the Bash command"
    assert_eq "$(echo "$subagent_tool" | jq -r '.metadata.tool_approval')" "approved" "sub-agent tool approval state"
    assert_eq "$(echo "$subagent_tool" | jq -r '.metadata.tool_call_id')" "tu1" "sub-agent tool call id"
    assert_eq "$(echo "$subagent_tool" | jq -r '.error')" "Exit code 128" "sub-agent tool error text"

    # Token totals match the deduped transcript. Braintrust prompt_tokens are
    # inclusive for Anthropic: input 8 + cache_read 2500 + cache_creation 15 = 2523.
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")|.metrics.completion_tokens]|add')"             "60"   "completion summed"
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_tokens]|add')"                "2523" "prompt includes input and cache tokens"
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")|.metrics.tokens]|add')"                       "2583" "total tokens includes inclusive prompt and completion"
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_cached_tokens]|add')"         "2500" "cache_read summed"
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")|.metrics.prompt_cache_creation_tokens]|add')" "15"   "cache_creation summed"
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm" and (.metrics | (has("cache_read_input_tokens") or has("cache_creation_input_tokens"))))]|length')" "0" "raw Anthropic cache metrics are not emitted"

    # The LLM spans are tagged with the sub-agent's model.
    assert_eq "$(all_spans | jq '[.[]|select(.span_attributes.type=="llm")]|all(.span_attributes.name=="claude-haiku-4-5")')" "true" "sub-agent model tagged"

    # The second LLM span's input carries the prior assistant + tool history.
    assert_eq "$(all_spans | jq -r '[.[]|select(.span_attributes.type=="llm")][1].input|map(.role)|join(",")')" "assistant,tool" "sub-agent LLM input includes history"
}

t_non_agent_tool_emits_no_llm_spans() {
    # A normal (non-Agent) tool must not emit any LLM spans.
    _with_turn_started "sess-noagent"
    local payload
    payload=$(fixture_post_tool_use "sess-noagent" "Bash" \
        "$(fixture_tool_input_bash 'ls')" \
        "$(fixture_tool_response_text 'out')")
    run_hook post_tool_use.sh "$payload"

    assert_eq "$(span_count_by_type llm)" "0" "no LLM spans for non-Agent tools"
}

it "emits sub-agent LLM spans under the Agent tool span" t_agent_emits_subagent_llm_spans
it "does not emit LLM spans for non-Agent tools"         t_non_agent_tool_emits_no_llm_spans
