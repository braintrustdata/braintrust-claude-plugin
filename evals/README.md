# Braintrust skill evaluations

Python evaluations for Braintrust documentation answers, data workflows, and
MCP tool use. These are separate from the daemon's tracing integration tests.

## Setup

Use Python 3.12+ and [uv](https://docs.astral.sh/uv/). From the monorepo root:

```bash
cd src/plugins/claude/content/evals
uv sync --locked
```

In the generated Claude distribution repository, use `cd evals` instead.
Set `ANTHROPIC_API_KEY` for model calls and `BRAINTRUST_API_KEY` for reporting.
These evaluations use live services and write results to Braintrust.

## Run evaluations

From the `evals` directory:

```bash
uv run python eval_docs_search.py
uv run python eval_datasets.py
uv run python eval_experiments.py
uv run python eval_log_querying.py
```

These scripts score answers against criteria using an LLM judge.
The end-to-end scripts also run Claude agents and create test data in Braintrust:

```bash
uv run --with claude-agent-sdk python eval_e2e_log_fetch.py
uv run --with claude-agent-sdk python eval_e2e_eval_improve.py
```

The agent SDK is an extra dependency for these two scripts. Their MCP calls
use `BRAINTRUST_API_KEY`.

## API helper tests

```bash
uv run --with pytest pytest test_braintrust_api.py -v
```

These tests call the live Braintrust API and create test projects and data.
They are skipped when `BRAINTRUST_API_KEY` is unset.
