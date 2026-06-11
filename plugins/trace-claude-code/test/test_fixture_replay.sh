#!/bin/bash
###
# Regression tests against the `test-fixture` session - a real Claude Code
# session captured via BRAINTRUST_RECORD_DIR and verified to look correct
# in the Braintrust UI.
#
# The fixture contains:
#   - 1 session_start
#   - 4 user_prompt_submit (4 turns)
#   - 13 post_tool_use (tool calls across the 4 turns)
#   - 4 stop_hook
#   - 1 session_end
#   - 1 transcript with 17 assistant messages (claude-opus-4-7)
#
# Tool breakdown (from the recorded payloads):
#   Agent: 4, Bash: 5, TaskCreate: 1, ToolSearch: 1, WebFetch: 1, WebSearch: 1
#
# Re-record with:
#   ./record_session.sh test-fixture
#
# Each `it` test below replays the full fixture once. To keep wall time
# reasonable (~3s per replay), related assertions are bundled into a
# single test rather than split across many `it` blocks.
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/assert.sh
source "$SCRIPT_DIR/helpers/assert.sh"
# shellcheck source=helpers/harness.sh
source "$SCRIPT_DIR/helpers/harness.sh"

FIXTURE_DIR="$SCRIPT_DIR/fixtures/sessions/test-fixture"
SESSION_ID="4381b0d7-d67e-4187-bb2d-86a101d3b955"

_setup_default_stubs() {
    stub_response_for "*/v1/project?project_name=*" 200 '{"id":"proj_fixture"}'
    stub_response_for "*/v1/project_logs/*/insert"  200 '{"row_ids":["row_1"]}'
}

# Count tool spans whose metadata.tool_name matches a given value.
_count_tool_spans_by_name() {
    local name="$1"
    all_spans | jq --arg n "$name" '
        [ .[]
          | select(.span_attributes.type == "tool")
          | select(.metadata.tool_name == $n)
        ] | length
    '
}

# ---------------------------------------------------------------------------
describe "test-fixture: replay end-to-end"
# ---------------------------------------------------------------------------

t_replay_all_events() {
    _setup_default_stubs

    local n
    n=$(replay_session "$FIXTURE_DIR")
    assert_success "$?" "every hook in the fixture should exit cleanly"
    assert_eq "$n" "23" "expected 23 events replayed"
}

it "replays all 23 hook events without errors" t_replay_all_events

# ---------------------------------------------------------------------------
describe "test-fixture: top-level span counts"
# ---------------------------------------------------------------------------

t_top_level_counts() {
    _setup_default_stubs
    replay_session "$FIXTURE_DIR" >/dev/null

    # Exactly one root session span
    assert_eq "$(spans_named '^Claude Code: ' | jq 'length')" "1" \
        "expected exactly one root session span"

    # 4 user_prompt_submit events -> 4 Turn spans
    assert_eq "$(spans_named '^Turn ' | jq 'length')" "4" \
        "expected 4 Turn spans (one per user_prompt_submit)"

    # The critical regression assertion: 13 post_tool_use -> 13 tool spans
    # (no drops from async/race issues).
    assert_eq "$(span_count_by_type tool)" "13" \
        "every post_tool_use must produce a tool span"

    # The transcript has 17 assistant messages; the stop_hook collapses
    # them into one LLM span per LLM call. Should be at least one per
    # turn (4) and at most 17.
    local llms
    llms=$(span_count_by_type llm)
    if [ "$llms" -lt 4 ] || [ "$llms" -gt 17 ]; then
        fail "expected 4-17 LLM spans; got $llms"
    fi

    # The stop_hook writes a merge update for each Turn at end-of-turn,
    # carrying the final output text and metrics. 4 turns -> 4 merges.
    local merges
    merges=$(all_spans | jq '[.[] | select(._is_merge == true)] | length')
    assert_eq "$merges" "4" "expected 4 merge updates (one per Turn end)"
}

it "session/turn/tool/llm span counts match the fixture" t_top_level_counts

# ---------------------------------------------------------------------------
describe "test-fixture: tool span breakdown"
# ---------------------------------------------------------------------------

t_tool_breakdown() {
    _setup_default_stubs
    replay_session "$FIXTURE_DIR" >/dev/null

    assert_eq "$(_count_tool_spans_by_name 'Agent')"      "4" "Agent count"
    assert_eq "$(_count_tool_spans_by_name 'Bash')"       "5" "Bash count"
    assert_eq "$(_count_tool_spans_by_name 'TaskCreate')" "1" "TaskCreate count"
    assert_eq "$(_count_tool_spans_by_name 'ToolSearch')" "1" "ToolSearch count"
    assert_eq "$(_count_tool_spans_by_name 'WebFetch')"   "1" "WebFetch count"
    assert_eq "$(_count_tool_spans_by_name 'WebSearch')"  "1" "WebSearch count"
}

it "tool spans match: 4 Agent / 5 Bash / 1 TaskCreate / 1 ToolSearch / 1 WebFetch / 1 WebSearch" \
    t_tool_breakdown

# ---------------------------------------------------------------------------
describe "test-fixture: tree structure"
# ---------------------------------------------------------------------------

t_tree_structure() {
    _setup_default_stubs
    replay_session "$FIXTURE_DIR" >/dev/null

    # 1. The root span's span_id should equal the recorded session id
    local session_span
    session_span=$(span_by_id "$SESSION_ID")
    assert_ne "$session_span" "null" "session span with id=$SESSION_ID should exist"

    # 2. Every non-merge span shares the session root_span_id.
    # (Merge updates omit root_span_id since they target an existing span
    # by id - they only carry the fields being updated, like final output
    # and metrics.)
    local off_root
    off_root=$(all_spans | jq --arg r "$SESSION_ID" '
        [ .[]
          | select(._is_merge != true)
          | select(.root_span_id != $r)
        ] | length
    ')
    assert_eq "$off_root" "0" "all non-merge spans should share the session root_span_id"

    # 3. Every Turn span's first parent is the session id
    local off_turn
    off_turn=$(spans_named "^Turn " | jq --arg s "$SESSION_ID" '
        [ .[] | select((.span_parents // [])[0] != $s) ] | length
    ')
    assert_eq "$off_turn" "0" "all Turn spans should be parented to the session"

    # 4. Collect all turn ids; tools and llms must be children of some turn
    local turn_ids
    turn_ids=$(spans_named "^Turn " | jq -c '[.[].span_id]')

    local orphan_tools
    orphan_tools=$(all_spans | jq --argjson ids "$turn_ids" '
        [ .[]
          | select(.span_attributes.type == "tool")
          | select(((.span_parents // [])[0]) as $p | ($ids | index($p)) == null)
        ] | length
    ')
    assert_eq "$orphan_tools" "0" "every tool span should be a child of some Turn"

    local orphan_llms
    orphan_llms=$(all_spans | jq --argjson ids "$turn_ids" '
        [ .[]
          | select(.span_attributes.type == "llm")
          | select(((.span_parents // [])[0]) as $p | ($ids | index($p)) == null)
        ] | length
    ')
    assert_eq "$orphan_llms" "0" "every LLM span should be a child of some Turn"
}

it "session > turn > tool/llm hierarchy is correct" t_tree_structure

# ---------------------------------------------------------------------------
describe "test-fixture: LLM span content"
# ---------------------------------------------------------------------------

t_llm_content() {
    _setup_default_stubs
    replay_session "$FIXTURE_DIR" >/dev/null

    # All LLM spans use the model the recorded transcript shows
    local off_model
    off_model=$(all_spans | jq '
        [ .[]
          | select(.span_attributes.type == "llm")
          | select(.metadata.model != "claude-opus-4-7")
        ] | length
    ')
    assert_eq "$off_model" "0" "all LLM spans should be tagged with model=claude-opus-4-7"

    # All LLM spans have non-negative token counts
    local bad_metrics
    bad_metrics=$(all_spans | jq '
        [ .[]
          | select(.span_attributes.type == "llm")
          | select((.metrics.prompt_tokens // 0) < 0
                or (.metrics.completion_tokens // 0) < 0)
        ] | length
    ')
    assert_eq "$bad_metrics" "0" "LLM spans should have non-negative token metrics"

    # At least one LLM span should report > 0 completion tokens
    local with_output
    with_output=$(all_spans | jq '
        [ .[]
          | select(.span_attributes.type == "llm")
          | select((.metrics.completion_tokens // 0) > 0)
        ] | length
    ')
    if [ "$with_output" -lt 1 ]; then
        fail "expected at least one LLM span with completion_tokens > 0; got $with_output"
    fi
}

it "LLM spans use claude-opus-4-7 and have sensible token metrics" t_llm_content

# ---------------------------------------------------------------------------
describe "test-fixture: token totals dedupe by requestId"
# ---------------------------------------------------------------------------

# Regression test for the double-counting bug: Claude Code writes one
# transcript line per content block (thinking, text, each tool_use) and
# every line for the same API response repeats the identical `usage` block,
# tagged with the same `requestId`. The stop_hook must count each response's
# usage exactly once, not once per content-block line.
#
# The fixture transcript has 30 assistant lines but only 7 unique
# requestIds. The expected totals below are the sum of each unique
# requestId's usage (computed via:
#   jq -s '[.[]|select(.type=="assistant")
#           | {rid:.requestId, inp:.message.usage.input_tokens,
#              out:.message.usage.output_tokens,
#              cc:.message.usage.cache_creation_input_tokens,
#              cr:.message.usage.cache_read_input_tokens}]
#          | unique_by(.rid)
#          | {inp:(map(.inp)|add), out:(map(.out)|add),
#             cc:(map(.cc)|add), cr:(map(.cr)|add)}' transcript.jsonl
# ).
#
# Turn-level metrics live on the per-Turn merge updates. Summing them
# across all 4 turns gives the whole-session totals, which must match the
# deduped expectation. Before the fix, output alone would be 425*4 + ... +
# 745*8 + ... = thousands too high.
t_token_dedupe_totals() {
    _setup_default_stubs
    replay_session "$FIXTURE_DIR" >/dev/null

    # Sum metrics across the 4 Turn merge updates.
    local merges
    merges=$(all_spans | jq '[.[] | select(._is_merge == true)]')

    local total_prompt total_completion total_cache_creation total_cache_read
    total_prompt=$(echo "$merges" | jq '[.[].metrics.prompt_tokens // 0] | add')
    total_completion=$(echo "$merges" | jq '[.[].metrics.completion_tokens // 0] | add')
    total_cache_creation=$(echo "$merges" | jq '[.[].metrics.cache_creation_input_tokens // 0] | add')
    total_cache_read=$(echo "$merges" | jq '[.[].metrics.cache_read_input_tokens // 0] | add')

    # Expected = sum of usage over the 7 unique requestIds in the transcript.
    assert_eq "$total_prompt"         "368"    "prompt_tokens should dedupe by requestId"
    assert_eq "$total_completion"     "1867"   "completion_tokens should dedupe by requestId"
    assert_eq "$total_cache_creation" "21064"  "cache_creation_input_tokens should dedupe by requestId"
    assert_eq "$total_cache_read"     "165784" "cache_read_input_tokens should dedupe by requestId"

    # tokens = prompt + completion on each merge; verify the aggregate too.
    local total_tokens
    total_tokens=$(echo "$merges" | jq '[.[].metrics.tokens // 0] | add')
    assert_eq "$total_tokens" "2235" "tokens should equal prompt+completion deduped"
}

it "turn token totals count each requestId once (no per-content-block double-count)" \
    t_token_dedupe_totals
