#!/bin/bash
###
# Span query helpers - the bash equivalent of opencode-plugin's spansToTree().
#
# These read the captured POST requests from $CAPTURED_REQUESTS, extract
# spans from /insert calls, and provide flat + relational queries for tests.
#
# All functions print JSON to stdout. Tests use `jq` to drill into results.
###

# Flat array of all spans sent to any /insert endpoint, in arrival order.
all_spans() {
    [ -f "${CAPTURED_REQUESTS:-/dev/null}" ] || { echo '[]'; return 0; }
    jq -s '
        [ .[]
          | select(.url | test("/insert$"))
          | .body.events[]?
        ]
    ' "$CAPTURED_REQUESTS"
}

# Total count of spans inserted.
span_count() {
    all_spans | jq 'length'
}

# Count of spans by .span_attributes.type (e.g. "task", "tool", "llm").
span_count_by_type() {
    local type="$1"
    all_spans | jq --arg t "$type" '
        [ .[] | select(.span_attributes.type == $t) ] | length
    '
}

# Return spans whose span_attributes.name matches the given regex.
# Spans without a name (e.g. merge updates that only touch metrics) are
# excluded.
spans_named() {
    local pattern="$1"
    all_spans | jq --arg p "$pattern" '
        [ .[]
          | select(.span_attributes.name != null)
          | select(.span_attributes.name | test($p))
        ]
    '
}

# Return the first span matching a name regex (or `null`).
span_by_name() {
    local pattern="$1"
    spans_named "$pattern" | jq '.[0] // null'
}

# Return the first span with a given .span_attributes.type (or `null`).
span_by_type() {
    local type="$1"
    all_spans | jq --arg t "$type" '
        [.[] | select(.span_attributes.type == $t)][0] // null
    '
}

# Return the span with the given span_id (or `null`).
span_by_id() {
    local id="$1"
    all_spans | jq --arg i "$id" '
        [.[] | select(.span_id == $i)][0] // null
    '
}

# Return all spans whose first parent matches the given span_id.
children_of() {
    local parent_id="$1"
    all_spans | jq --arg p "$parent_id" '
        [ .[]
          | select(.span_parents and (.span_parents | length > 0)
                   and (.span_parents[0] == $p))
        ]
    '
}

# True/false: does a span_id have a span_parents[0] equal to the given id?
is_child_of() {
    local child_id="$1"
    local parent_id="$2"
    all_spans | jq --arg c "$child_id" --arg p "$parent_id" -e '
        any(.[]; .span_id == $c and (.span_parents // [])[0] == $p)
    ' >/dev/null
}
