#!/bin/bash
###
# UserPromptSubmit Hook - Creates a Turn container span when user submits a prompt
###

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"

tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Read input from stdin
INPUT=$(cat)
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

# Extract session ID and prompt
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# --- Skill invocation capture (best-effort; must never abort the hook) ---
# If the prompt invokes a slash-command skill (e.g. "/my-skill" or "/plugin:skill"),
# record the invoked skill's name, description, and instructions (the SKILL.md body)
# on the turn. Covers user/project skills (~/.claude/skills, <project>/.claude/skills)
# and installed plugin skills. Built-in commands and skills we can't resolve are
# silently skipped (invoked_skill is simply not added).
INVOKED_SKILL_JSON=""
# Extract a one-line description: inline `description:`, YAML block scalar
# (`description: |` / `>`), else the first `#`+ heading.
__bt_skill_desc() {
    local f="$1" d
    d=$(awk '
        /^description:[[:space:]]*[|>]/ { blk=1; next }
        blk==1 { if ($0 ~ /^[[:space:]]+/) { sub(/^[[:space:]]+/,""); print; exit } else exit }
        /^description:[[:space:]]*[^|>[:space:]]/ { sub(/^description:[[:space:]]*/,""); print; exit }
    ' "$f")
    [ -n "$d" ] || d=$(awk '/^#+[[:space:]]/ { sub(/^#+[[:space:]]+/,""); print; exit }' "$f")
    printf '%s' "$d" | tr -d '"\r'
}
__bt_detect_skill() {
    local prompt="$1" cwd="$2" name subpath base cand leaf plugin sname sdesc sbody
    name=$(printf '%s' "$prompt" | sed -n 's#^/\([A-Za-z0-9:_-]\{1,\}\).*#\1#p' | head -1)
    [ -n "$name" ] || return 0
    subpath=$(printf '%s' "$name" | tr ':' '/')
    leaf="${name##*:}"
    cand=""
    # 1) user- and project-authored skills (cheap stat, no scan)
    for base in "$cwd/.claude/skills" "$HOME/.claude/skills"; do
        [ -n "$base" ] || continue
        [ -f "$base/$subpath/SKILL.md" ] && { cand="$base/$subpath/SKILL.md"; break; }
        [ -f "$base/$name/SKILL.md" ] && { cand="$base/$name/SKILL.md"; break; }
    done
    # 2) installed plugin skills (cache) -- ONLY for namespaced "plugin:skill" tokens,
    #    so bare built-in commands (/clear, /model, ...) never trigger a filesystem scan.
    if [ -z "$cand" ]; then
        case "$name" in
            *:*)
                plugin="${name%%:*}"
                cand=$(find "$HOME/.claude/plugins/cache" -maxdepth 9 -type f -name SKILL.md -path "*/$plugin/*/$leaf/SKILL.md" 2>/dev/null | head -1)
                [ -n "$cand" ] || cand=$(find "$HOME/.claude/plugins/cache" -maxdepth 9 -type f -name SKILL.md -path "*/$leaf/SKILL.md" 2>/dev/null | head -1)
                ;;
        esac
    fi
    [ -n "$cand" ] && [ -f "$cand" ] || return 0
    sname=$(sed -n 's/^name:[[:space:]]*//p' "$cand" | head -1 | tr -d '"\r')
    [ -n "$sname" ] || sname="$leaf"
    sdesc=$(__bt_skill_desc "$cand")
    sbody=$(awk 'c>=2{print} /^---[[:space:]]*$/{c++}' "$cand" | head -c 6000)
    [ -n "$sbody" ] || sbody=$(head -c 6000 "$cand")
    jq -n --arg n "$sname" --arg d "$sdesc" --arg i "$sbody" '{name:$n,description:$d,instructions:$i}'
    return 0
}
CWD_FOR_SKILL=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD_FOR_SKILL=""
INVOKED_SKILL_JSON=$(__bt_detect_skill "$PROMPT" "$CWD_FOR_SKILL" 2>/dev/null) || INVOKED_SKILL_JSON=""
echo "$INVOKED_SKILL_JSON" | jq empty >/dev/null 2>&1 || INVOKED_SKILL_JSON=""
# --- end skill capture ---

# Get session info
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
SESSION_SPAN_ID=$(get_session_state "$SESSION_ID" "session_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")

# If no session root exists yet, we'll create it
if [ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; exit 0; }
    ROOT_SPAN_ID="$SESSION_ID"

    # Get workspace name from cwd
    CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    WORKSPACE_NAME=$(basename "$CWD" 2>/dev/null || echo "workspace")

    TIMESTAMP=$(get_timestamp)
    HOSTNAME=$(get_hostname)
    USERNAME=$(get_username)
    OS=$(get_os)

    EVENT=$(jq -n \
        --arg id "$ROOT_SPAN_ID" \
        --arg span_id "$ROOT_SPAN_ID" \
        --arg root_span_id "$ROOT_SPAN_ID" \
        --arg created "$TIMESTAMP" \
        --arg session "$SESSION_ID" \
        --arg workspace "$WORKSPACE_NAME" \
        --arg hostname "$HOSTNAME" \
        --arg username "$USERNAME" \
        --arg os "$OS" \
        '{
            id: $id,
            span_id: $span_id,
            root_span_id: $root_span_id,
            created: $created,
            input: ("Session: " + $workspace),
            metadata: {
                session_id: $session,
                workspace: $workspace,
                hostname: $hostname,
                username: $username,
                os: $os,
                source: "claude-code"
            },
            span_attributes: {
                name: ("Claude Code: " + $workspace),
                type: "task"
            }
        }')

    insert_span "$PROJECT_ID" "$EVENT" >/dev/null || true
    set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "session_span_id" "$ROOT_SPAN_ID"
    set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
    SESSION_SPAN_ID="$ROOT_SPAN_ID"
    log "INFO" "Created session root: $SESSION_ID"
fi

# Increment turn count and create Turn span
TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TURN_COUNT=${TURN_COUNT:-0}
TURN_COUNT=$((TURN_COUNT + 1))

TURN_SPAN_ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)
START_TIME=$(date +%s)

# Truncate prompt for display (first 100 chars)
PROMPT_PREVIEW="${PROMPT:0:100}"
[ ${#PROMPT} -gt 100 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW}..."

# Create Turn container span (parent is the session span, not the root)
EVENT=$(jq -n \
    --arg id "$TURN_SPAN_ID" \
    --arg span_id "$TURN_SPAN_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg session_span_id "$SESSION_SPAN_ID" \
    --arg created "$TIMESTAMP" \
    --arg prompt "$PROMPT" \
    --argjson turn "$TURN_COUNT" \
    --argjson start_time "$START_TIME" \
    '{
        id: $id,
        span_id: $span_id,
        root_span_id: $root_span_id,
        span_parents: [$session_span_id],
        created: $created,
        input: $prompt,
        metrics: {
            start: $start_time
        },
        span_attributes: {
            name: ("Turn " + ($turn | tostring)),
            type: "task"
        }
    }')

# Attach invoked_skill to the turn only when one was detected (non-skill turns are
# left exactly as stock; a merge failure falls back to the original event).
if [ -n "$INVOKED_SKILL_JSON" ]; then
    MERGED=$(echo "$EVENT" | jq --argjson s "$INVOKED_SKILL_JSON" '.metadata = ((.metadata // {}) + {invoked_skill: $s})' 2>/dev/null) || MERGED=""
    [ -n "$MERGED" ] && EVENT="$MERGED"
fi

ROW_ID=$(insert_span "$PROJECT_ID" "$EVENT") || { log "ERROR" "Failed to create turn span"; exit 0; }

# Save turn state
set_session_state "$SESSION_ID" "turn_count" "$TURN_COUNT"
set_session_state "$SESSION_ID" "current_turn_span_id" "$TURN_SPAN_ID"
set_session_state "$SESSION_ID" "current_turn_start" "$START_TIME"
set_session_state "$SESSION_ID" "current_turn_tool_count" "0"

log "INFO" "Turn $TURN_COUNT started: $TURN_SPAN_ID"

exit 0
