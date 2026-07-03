#!/bin/bash
###
# End-to-end tests for explicit skill capture from UserPromptExpansion.
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

_skill_listing_transcript() {
    local path="$1"
    jq -nc '{attachment: {type: "skill_listing", names: ["review", "security-review"]}}' > "$path"
}

_fixture_user_prompt_expansion() {
    local session_id="$1"
    local command_name="$2"
    local transcript_path="$3"
    jq -nc \
        --arg s "$session_id" \
        --arg c "$command_name" \
        --arg t "$transcript_path" \
        '{
            session_id: $s,
            expansion_type: "slash_command",
            command_name: $c,
            transcript_path: $t
        }'
}

_with_started_session() {
    local session_id="$1"
    _setup_default_stubs
    run_hook session_start.sh "$(fixture_session_start "$session_id" "/tmp/x")"
}

_with_turn_started() {
    local session_id="$1"
    _with_started_session "$session_id"
    run_hook user_prompt_submit.sh "$(fixture_user_prompt "$session_id" "do something")"
    : > "$CAPTURED_REQUESTS"
}

# ---------------------------------------------------------------------------
describe "user_prompt_expansion.sh"
# ---------------------------------------------------------------------------

t_expansion_merges_current_turn_metadata() {
    _with_turn_started "sess-upe-merge"
    local transcript="$TEST_TMP/transcript.jsonl"
    _skill_listing_transcript "$transcript"

    run_hook user_prompt_expansion.sh "$(_fixture_user_prompt_expansion "sess-upe-merge" "/review" "$transcript")"
    assert_success "$HOOK_STATUS"

    local span
    span=$(all_spans | jq -c '.[0]')
    assert_eq "$(echo "$span" | jq -r '._is_merge')" "true"
    assert_eq "$(echo "$span" | jq -r '.metadata.loaded_skill_names[0]')" "review"
    assert_eq "$(echo "$span" | jq -r '.metadata.loaded_skills[0].name')" "review"
}

t_pending_expansion_is_added_to_next_turn() {
    _with_started_session "sess-upe-pending"
    local transcript="$TEST_TMP/transcript.jsonl"
    _skill_listing_transcript "$transcript"

    run_hook user_prompt_expansion.sh "$(_fixture_user_prompt_expansion "sess-upe-pending" "/review" "$transcript")"
    assert_success "$HOOK_STATUS"
    : > "$CAPTURED_REQUESTS"

    run_hook user_prompt_submit.sh "$(fixture_user_prompt "sess-upe-pending" "after expansion")"
    assert_success "$HOOK_STATUS"

    local turn
    turn=$(span_by_name "^Turn 1$")
    assert_eq "$(echo "$turn" | jq -r '.metadata.loaded_skill_names[0]')" "review"
    assert_eq "$(echo "$turn" | jq -r '.metadata.loaded_skills[0].name')" "review"
}

t_matching_skill_tool_is_marked_explicit() {
    _with_turn_started "sess-upe-tool"
    local transcript="$TEST_TMP/transcript.jsonl"
    _skill_listing_transcript "$transcript"

    run_hook user_prompt_expansion.sh "$(_fixture_user_prompt_expansion "sess-upe-tool" "/review" "$transcript")"
    assert_success "$HOOK_STATUS"
    : > "$CAPTURED_REQUESTS"

    run_hook post_tool_use.sh "$(fixture_post_tool_use "sess-upe-tool" "Skill" \
        "$(jq -nc '{name: "review"}')" \
        "$(fixture_tool_response_text 'loaded')")"

    local tool_span
    tool_span=$(span_by_type "tool")
    assert_eq "$(echo "$tool_span" | jq -r '.metadata.skill_load_trigger')" "explicit"
}

t_non_skill_slash_command_is_ignored() {
    _with_turn_started "sess-upe-ignore"
    local transcript="$TEST_TMP/transcript.jsonl"
    _skill_listing_transcript "$transcript"

    run_hook user_prompt_expansion.sh "$(_fixture_user_prompt_expansion "sess-upe-ignore" "/not-a-skill" "$transcript")"
    assert_success "$HOOK_STATUS"

    assert_eq "$(span_count)" "0"
}

it "merges explicit skill metadata onto the current turn" t_expansion_merges_current_turn_metadata
it "adds pending explicit skill metadata to the next turn" t_pending_expansion_is_added_to_next_turn
it "marks matching Skill tool spans as explicit" t_matching_skill_tool_is_marked_explicit
it "ignores slash commands not present in skill listings" t_non_skill_slash_command_is_ignored
