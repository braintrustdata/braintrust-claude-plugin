# Development of the plugin itself

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

## Local testing

Test a plugin without installing from marketplace:

```bash
claude --plugin-dir /path/to/thisrepo/plugins/{plugin dir here}
# example
claude --plugin-dir /path/to/thisrepo/plugins/braintrust
```

## Running evals

The `evals/` directory contains tests that verify the plugin works correctly (e.g., Claude generates valid SQL queries, logs data properly).

```bash
cd evals
export BRAINTRUST_API_KEY="your-key"

# Run all evals
uv run braintrust eval .

# Run specific eval
uv run braintrust eval eval_e2e_log_fetch.py
```

## Pre-commit hooks

```bash
# Install hooks
uv run pre-commit install

# Run all hooks
uv run pre-commit run --all-files
```

## Testing the `trace-claude-code` plugin

Bash test suite for the hook scripts. Tests run the hooks against a
stubbed `curl`, capture the resulting HTTP requests, and assert on the
inferred span tree.

### Running

```sh
# From the repo root:
make test

# Or run a specific test file:
bash plugins/trace-claude-code/test/run_tests.sh test_e2e
bash plugins/trace-claude-code/test/run_tests.sh test_replay test_queue
```

### Layout

```
plugins/trace-claude-code/test/
├── helpers/
│   ├── assert.sh        # describe / it / assert_eq / assert_contains, color output
│   ├── harness.sh       # setup_test_env, teardown_test_env, run_hook
│   ├── curl_stub.sh     # curl() shell function that captures requests + returns canned responses
│   ├── fixtures.sh      # builders for hook input JSON (fixture_session_start, etc.)
│   ├── span_tree.sh     # all_spans, span_count_by_type, span_by_name, children_of, ...
│   └── replay.sh        # replay_session, describe_fixture
├── fixtures/
│   └── sessions/        # captured Claude sessions used by test_replay.sh
├── test_*.sh            # one file per area
├── record_session.sh    # CLI to prep a fixture directory for capturing
└── run_tests.sh         # entry point
```

### Writing a test

Each `test_*.sh` follows this pattern:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/assert.sh"
source "$SCRIPT_DIR/helpers/harness.sh"

describe "my feature"

t_my_test_body() {
    # setup_test_env has already created an isolated $HOME and stubbed curl
    stub_response_for "*/v1/project_logs/*/insert" 200 '{"row_ids":["row_1"]}'

    run_hook session_start.sh "$(fixture_session_start "s1" "/tmp/x")"

    assert_eq "$(span_count_by_type task)" "1"
}

it "does the thing" t_my_test_body
```

Key conventions:

- `describe "..."` is a section header (purely visual).
- `it "name" function_name` runs `function_name` between `setup_test_env`
  and `teardown_test_env`, then prints a ✓ or ✗.
- Assertions (`assert_eq`, `assert_contains`, `assert_failure`, ...) record
  failures into the current test but do **not** abort. Multiple assertions
  per test are fine.
- Hooks are run synchronously in tests via `BRAINTRUST_SYNC_QUEUE=true`
  set by `setup_test_env`. Span queue tests opt out of this when needed.

### Capturing a real session as a test fixture

The hooks support recording every invocation to disk when the env var
`BRAINTRUST_RECORD_DIR` is set. The recorded data can then be replayed
in a test.

#### 1. Prepare a fixture directory

```sh
plugins/trace-claude-code/test/record_session.sh my-fixture
```

This prints a `BRAINTRUST_RECORD_DIR` value pointing at
`test/fixtures/sessions/my-fixture/`.

#### 2. Run Claude Code with recording on

```sh
export BRAINTRUST_RECORD_DIR=/abs/path/to/test/fixtures/sessions/my-fixture
claude
# ... use Claude Code normally ...
```

While `BRAINTRUST_RECORD_DIR` is set:

- Every hook invocation appends one NDJSON record to
  `events.ndjson` containing `{ts, hook, payload}`.
- The `stop_hook` also copies the referenced transcript file into
  `transcripts/<session_id>.jsonl`.

You do not need to modify hook scripts or set anything else - the recorder
runs inside the existing hooks.

#### 3. Inspect the fixture

```sh
plugins/trace-claude-code/test/record_session.sh --describe my-fixture
```

Output:

```
Fixture: .../test/fixtures/sessions/my-fixture
  Events: 14
  Hook counts:
    post_tool_use: 8
    session_end: 1
    session_start: 1
    stop_hook: 3
    user_prompt_submit: 1
  Transcripts: 1
```

#### 4. Replay it in a test

```bash
t_replay_my_fixture() {
    stub_response_for "*/v1/project_logs/*/insert" 200 '{"row_ids":["row_1"]}'

    local n
    n=$(replay_session "$SCRIPT_DIR/fixtures/sessions/my-fixture")
    assert_success "$?"
    assert_eq "$n" "14"

    # Now assert on the span tree the hooks produced
    assert_eq "$(span_count_by_type tool)" "8"
    assert_eq "$(span_count_by_type llm)"  "3"
}

it "my real-world fixture produces the expected spans" t_replay_my_fixture
```

The replayer:

- Reads `events.ndjson` line by line in order.
- For `stop_hook` events, rewrites `payload.transcript_path` to point at
  the bundled transcript so the replayed hook can read it.
- Invokes the matching hook script via `run_hook` with the recorded
  payload.

#### When to use replay vs. synthetic fixtures

- **Synthetic fixtures** (`fixture_session_start`, etc.) - fast to write,
  test specific scenarios in isolation, no real Claude needed.
- **Replayed fixtures** - high-fidelity regression tests of real-world
  interactions. Use when you want to lock in behavior on a specific
  pattern of hooks you saw in the wild (e.g. a session with parallel
  tool calls, or a long multi-turn conversation).

### Span-tree queries

The captured HTTP requests are parsed to extract the inserted spans. Available helpers:

| Function | Returns |
|---|---|
| `all_spans` | JSON array of every span sent to any `/insert` endpoint |
| `span_count` | total number of spans |
| `span_count_by_type "tool"` | count of spans with `span_attributes.type == "tool"` |
| `spans_named "^Turn "` | array of spans whose name matches the regex |
| `span_by_name "^Turn 1$"` | first matching span (or `null`) |
| `span_by_type "llm"` | first span of that type |
| `span_by_id "..."` | span with the given `span_id` |
| `children_of "<span_id>"` | array of spans whose first parent is the given id |
| `is_child_of "<child_id>" "<parent_id>"` | exit 0 if true |

All return JSON on stdout; combine with `jq` for further drilling.

# Releasing a plugin

Releases are manual and git-driven. There are no git tags or publish automation: pushing to `main` is the release.

## How version resolution works

Claude Code resolves a plugin's version from the first of these that is set:

1. `version` in the plugin's `plugins/<plugin>/.claude-plugin/plugin.json`
2. `version` in the plugin's entry in `.claude-plugin/marketplace.json`
3. The git commit SHA of the plugin's source

Both plugins set `version` in their own `plugin.json`, and the marketplace entries do **not** declare a per-plugin `version`. So **each plugin's `plugin.json` is the sole authority for its version**, and bumping it is what triggers updates for users.

The top-level `version` field in `marketplace.json` is just marketplace-manifest metadata. It does **not** gate plugin updates.

> [!WARNING]
> Do not add a `version` field to a plugin's entry in `marketplace.json`. The `plugin.json` value always wins silently, so a stale marketplace version can mask the real one. Keep the version in `plugin.json` only.

## Release steps

1. Bump `version` in the plugin's manifest:
   - `plugins/braintrust/.claude-plugin/plugin.json`, or
   - `plugins/trace-claude-code/.claude-plugin/plugin.json`
2. (Optional) Bump the top-level `version` in `.claude-plugin/marketplace.json` for bookkeeping. This is cosmetic and does not affect whether users receive the update.
3. Commit and push to `main` (via PR).
4. Users update with: `claude plugin marketplace update braintrust-claude-plugin`
