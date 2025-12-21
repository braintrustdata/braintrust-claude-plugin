---
name: using-braintrust
description: |
  Enables AI agents to use Braintrust for LLM evaluation, logging, and observability.
  Includes ready-to-use scripts for querying logs, running evals, and logging data.
version: 1.0.0
---

# Using Braintrust

Braintrust is a platform for evaluating, logging, and monitoring LLM applications.

## Scripts (use these directly)

This skill includes scripts that handle authentication and project resolution automatically.
They load API keys from `.env` files in the current or parent directories.

### Query logs

```bash
# Get logs from the last 24 hours
uv run query_logs.py --project "Loop logs" --last-day

# Count logs from the last day
uv run query_logs.py --project "Loop logs" --last-day --count

# Custom query
uv run query_logs.py --project "My Project" --filter "metadata.user_id = 'user123'" --limit 20

# Output as JSON
uv run query_logs.py --project "My Project" --format json
```

### Log data

```bash
# Log a single entry
uv run log_data.py --project "My Project" --input "hello" --output "world"

# Log with metadata
uv run log_data.py --project "My Project" --input "query" --output "response" \
  --metadata '{"user_id": "123"}'

# Batch log from JSON
uv run log_data.py --project "My Project" --data '[{"input": "a", "output": "b"}]'
```

### Run evaluations

```bash
# Run eval with inline data
uv run run_eval.py --project "My Project" --data '[{"input": "test", "expected": "test"}]'

# Run eval from file
uv run run_eval.py --project "My Project" --data-file test_cases.json

# Use factuality scorer
uv run run_eval.py --project "My Project" --data-file data.json --scorer factuality
```

## Setup

Create a `.env` file in your project directory:

```
BRAINTRUST_API_KEY=your-api-key-here
```

The scripts automatically find and load `.env` files from the current directory or any parent directory.

## Writing evaluation code

When users need custom evaluation logic, use the SDK directly.

**IMPORTANT**: The first argument to `Eval()` is the project name (positional), not a keyword argument.

```python
import braintrust
from autoevals import Factuality

# Correct usage - project name is FIRST POSITIONAL argument
braintrust.Eval(
    "My Project",  # Project name (required, positional)
    data=lambda: [
        {"input": "What is 2+2?", "expected": "4"},
    ],
    task=lambda input: my_llm_call(input),
    scores=[Factuality],
)
```

**Common mistakes:**
- ❌ `Eval(project_name="My Project", ...)` - Wrong!
- ❌ `Eval(name="My Project", ...)` - Wrong!
- ✅ `Eval("My Project", data=..., task=..., scores=...)` - Correct!

### Custom scorers

```python
from autoevals import Score

def my_scorer(input, output, expected=None, **kwargs):
    is_correct = expected and expected.lower() in output.lower()
    return Score(
        name="Contains Expected",
        score=1.0 if is_correct else 0.0,
    )
```

## Writing logging code

```python
import braintrust

logger = braintrust.init_logger(project="My Project")

logger.log(
    input="What is the weather?",
    output="It's sunny today",
    metadata={"user_id": "123"},
)

# IMPORTANT: Always flush
logger.flush()
```

### Tracing with spans

```python
logger = braintrust.init_logger(project="My Project")

with logger.start_span(name="process_request") as span:
    span.log(input={"query": "hello"})
    result = call_llm("hello")
    span.log(output=result)

logger.flush()
```

## Common issues

### "Eval() got an unexpected keyword argument 'project_name'"
Use positional argument: `Eval("My Project", ...)` not `Eval(project_name="My Project")`

### Logs not appearing
Call `logger.flush()` after logging.

### Authentication errors
Create a `.env` file with `BRAINTRUST_API_KEY=your-key` or set the environment variable.
