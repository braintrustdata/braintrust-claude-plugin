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

# Updating the plugin

After making changes:

1. Bump version in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit and push
3. Users update with: `claude plugin marketplace update braintrust-claude-plugin`
