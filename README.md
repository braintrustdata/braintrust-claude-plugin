# Braintrust Claude plugins

Claude Code plugins for Braintrust - LLM evaluation, logging, observability, and tracing.

## Plugins

### 1. Braintrust (evaluation & logging)

Enables AI agents to use Braintrust for LLM evaluation, logging, and observability.

```bash
claude plugin marketplace add braintrustdata/braintrust-claude-plugin
claude plugin install braintrust@braintrust-claude-plugin
```

### 2. Trace Claude Code (observability)

Automatically trace Claude Code conversations to Braintrust.

```bash
claude plugin install trace-claude-code@braintrust-claude-plugin
```

See [trace-claude-code/SKILL.md](skills/trace-claude-code/SKILL.md) for setup instructions.

## Agent skills

This repo includes skills built on the open [Agent Skills](https://agentskills.io/home) format, compatible with Claude Code, Cursor, Amp, and other agents.

**Install all skills:**
```bash
curl -sL https://github.com/braintrustdata/braintrust-claude-plugin/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 braintrust-claude-plugin-main/skills
```

Available skills:
- [using-braintrust](skills/using-braintrust/SKILL.md) - Evaluation, logging, and SQL queries
- [trace-claude-code](skills/trace-claude-code/SKILL.md) - Automatic conversation tracing

## Setup

Create a `.env` file in your project directory:

```
BRAINTRUST_API_KEY=your-api-key-here
```

The plugin scripts automatically load `.env` files from the current directory or parent directories.

## What the plugin provides

### Scripts

The plugin includes ready-to-use scripts for common operations:

**Query logs with SQL:**
```bash
uv run query_logs.py --project "My Project" --query "SELECT count(*) as count FROM logs WHERE created > now() - interval 1 day"
```

**Log data:**
```bash
uv run log_data.py --project "My Project" --input "hello" --output "world"
```

**Run evaluations:**
```bash
uv run run_eval.py --project "My Project" --data '[{"input": "test", "expected": "test"}]'
```

### SDK patterns

The skill teaches Claude how to use the Braintrust SDK correctly:

```python
# Correct Eval() usage - project name is FIRST POSITIONAL arg
braintrust.Eval(
    "My Project",  # NOT project_name="My Project"
    data=lambda: [...],
    task=lambda input: ...,
    scores=[Factuality],
)

# Logging with flush
logger = braintrust.init_logger(project="My Project")
logger.log(input="hello", output="world")
logger.flush()  # Important!
```

### SQL query syntax

The skill teaches Claude to write SQL queries for Braintrust logs:

```sql
SELECT input, output, created FROM logs WHERE created > now() - interval 1 day LIMIT 10
```

**SQL quirks in Braintrust:**
- Use `hour()`, `day()`, `month()`, `year()` instead of `date_trunc()`
- Intervals use format `interval 1 day` (no quotes, singular unit)

## Project structure

```
braintrust-claude-plugin/
├── .claude-plugin/
│   ├── plugin.json         # Plugin manifest
│   └── marketplace.json    # Marketplace index
├── skills/
│   ├── using-braintrust/
│   │   ├── SKILL.md        # Evaluation & logging skill
│   │   └── scripts/        # Helper scripts
│   │       ├── query_logs.py
│   │       ├── log_data.py
│   │       └── run_eval.py
│   └── trace-claude-code/
│       ├── SKILL.md        # Claude Code tracing skill
│       └── hooks/
│           └── stop_hook.sh  # Hook script
├── evals/                  # Evaluation suite
│   ├── eval_e2e_*.py       # End-to-end tests
│   └── eval_*.py           # Baseline tests
└── README.md
```

## Development

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) package manager

### Local testing

Test the plugin without installing from marketplace:

```bash
claude --plugin-dir /path/to/braintrust-claude-plugin
```

### Running evals

The `evals/` directory contains tests that verify the skill works correctly (e.g., Claude generates valid SQL queries, logs data properly).

```bash
cd evals
export BRAINTRUST_API_KEY="your-key"

# Run all evals
uv run braintrust eval .

# Run specific eval
uv run braintrust eval eval_e2e_log_fetch.py
```

### Pre-commit hooks

```bash
# Install hooks
uv run pre-commit install

# Run all hooks
uv run pre-commit run --all-files
```

## Updating the plugin

After making changes:

1. Bump version in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit and push
3. Users update with: `claude plugin marketplace update braintrust-claude-plugin`
