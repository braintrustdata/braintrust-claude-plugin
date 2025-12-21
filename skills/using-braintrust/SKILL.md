---
name: using-braintrust
description: |
  Enables AI agents to use Braintrust for LLM evaluation, logging, and observability.
  Provides correct API usage, working examples, and helper scripts for common operations.
  Requires BRAINTRUST_API_KEY environment variable.
version: 1.0.0
---

# Using Braintrust

Braintrust is a platform for evaluating, logging, and monitoring LLM applications.

## Quick start

```bash
# Install
pip install braintrust autoevals

# Set API key
export BRAINTRUST_API_KEY="your-api-key"
```

## Core APIs

### Running evaluations with `Eval()`

**IMPORTANT**: The first argument is the project name (positional), not a keyword argument.

```python
import braintrust
from autoevals import Factuality

# Correct usage - project name is FIRST POSITIONAL argument
braintrust.Eval(
    "My Project",  # Project name (required, positional)
    data=lambda: [
        {"input": "What is 2+2?", "expected": "4"},
        {"input": "What is the capital of France?", "expected": "Paris"},
    ],
    task=lambda input: my_llm_call(input["input"]),  # Returns string
    scores=[Factuality],  # List of scorer functions
)
```

**Common mistakes:**
- ❌ `Eval(project_name="My Project", ...)` - Wrong! No `project_name` kwarg
- ❌ `Eval(name="My Project", ...)` - Wrong! No `name` kwarg
- ✅ `Eval("My Project", data=..., task=..., scores=...)` - Correct!

### Data format

Each item in data must have an `input` key. Optional: `expected`, `metadata`.

```python
data = [
    {
        "input": {"question": "What is AI?"},  # Can be string or dict
        "expected": "Artificial Intelligence",  # Optional, for comparison
        "metadata": {"category": "basics"},    # Optional
    },
]
```

### Task function

The task function receives `input` and should return the output to evaluate:

```python
def my_task(input):
    # input is the "input" field from your data
    question = input["question"] if isinstance(input, dict) else input
    response = call_llm(question)
    return response  # Return string or dict
```

### Scorers

Scorers evaluate the output. Use autoevals or create custom scorers:

```python
from autoevals import Factuality, Score

# Using autoevals (recommended)
scores = [Factuality]

# Custom scorer - must return Score object
def my_scorer(input, output, expected=None, **kwargs):
    is_correct = expected and expected.lower() in output.lower()
    return Score(
        name="Contains Expected",
        score=1.0 if is_correct else 0.0,
        metadata={"expected": expected},
    )

scores = [Factuality, my_scorer]
```

### Logging with `init_logger()`

For production logging (not evals):

```python
import braintrust

# Initialize logger
logger = braintrust.init_logger(project="My Project")

# Log an LLM call
logger.log(
    input="What is the weather?",
    output="It's sunny today",
    metadata={"user_id": "123", "session_id": "abc"},
    scores={"relevance": 0.9},
)

# IMPORTANT: Flush to ensure logs are sent
logger.flush()
```

### Tracing with spans

For detailed tracing of multi-step operations:

```python
import braintrust

logger = braintrust.init_logger(project="My Project")

# Create a traced span
with logger.start_span(name="process_request") as span:
    span.log(input={"query": "hello"})

    # Nested span
    with span.start_span(name="llm_call") as llm_span:
        result = call_llm("hello")
        llm_span.log(output=result)

    span.log(output={"response": result})

logger.flush()
```

## Working examples

### Example 1: Simple Q&A evaluation

```python
import braintrust
from autoevals import Factuality

def answer_question(input):
    # Your LLM call here
    return f"The answer to '{input}' is 42"

braintrust.Eval(
    "QA Evaluation",
    data=lambda: [
        {"input": "What is 6 times 7?", "expected": "42"},
        {"input": "What is the meaning of life?", "expected": "42"},
    ],
    task=answer_question,
    scores=[Factuality],
)
```

### Example 2: Custom scorer

```python
import braintrust
from autoevals import Score

def length_scorer(input, output, **kwargs):
    """Score based on output length."""
    length = len(output) if output else 0
    score = min(1.0, length / 100)  # Normalize to 0-1
    return Score(name="Length", score=score, metadata={"length": length})

def summarize(input):
    return input[:50] + "..."  # Simple truncation

braintrust.Eval(
    "Summarization",
    data=lambda: [
        {"input": "This is a long paragraph that needs summarizing..." * 10},
    ],
    task=summarize,
    scores=[length_scorer],
)
```

### Example 3: Logging production data

```python
import braintrust

logger = braintrust.init_logger(project="Production App")

def handle_request(user_query):
    response = call_llm(user_query)

    # Log the interaction
    logger.log(
        input=user_query,
        output=response,
        metadata={
            "user_id": get_user_id(),
            "timestamp": get_timestamp(),
        },
    )
    logger.flush()

    return response
```

### Example 4: Using with OpenAI

```python
import braintrust
from openai import OpenAI

# Wrap the client for automatic tracing
client = braintrust.wrap_openai(OpenAI())

logger = braintrust.init_logger(project="OpenAI App")

with logger.start_span(name="chat"):
    response = client.chat.completions.create(
        model="gpt-4",
        messages=[{"role": "user", "content": "Hello!"}],
    )
    print(response.choices[0].message.content)

logger.flush()
```

## Helper scripts

This skill includes helper scripts in the `scripts/` directory:

- `scripts/run_eval.py` - Run an evaluation with custom data and scorers
- `scripts/log_data.py` - Log data to a project
- `scripts/query_logs.py` - Query logs using BTQL

Run scripts with:
```bash
uv run scripts/run_eval.py --project "My Project" --data data.json
```

## API reference

### `braintrust.Eval()`
```python
Eval(
    name: str,                    # Project name (required, positional)
    data: Callable | list,        # Data or function returning data
    task: Callable,               # Function to evaluate
    scores: list[Callable],       # List of scorer functions
    experiment_name: str = None,  # Optional experiment name
    metadata: dict = None,        # Optional metadata
)
```

### `braintrust.init_logger()`
```python
init_logger(
    project: str,                 # Project name (required)
    api_key: str = None,          # API key (uses env var if not provided)
) -> Logger
```

### `logger.log()`
```python
logger.log(
    input: Any = None,            # Input data
    output: Any = None,           # Output data
    expected: Any = None,         # Expected output
    metadata: dict = None,        # Metadata
    scores: dict = None,          # Scores dict {"name": value}
    tags: list[str] = None,       # Tags
)
```

### `Score` (from autoevals)
```python
Score(
    name: str,                    # Score name
    score: float,                 # Score value (0-1)
    metadata: dict = None,        # Optional metadata
)
```

## Common issues

### "Eval() got an unexpected keyword argument 'project_name'"
Use positional argument: `Eval("My Project", ...)` not `Eval(project_name="My Project")`

### Logs not appearing
Call `logger.flush()` after logging to ensure data is sent.

### Import errors
Install required packages: `pip install braintrust autoevals`

### Authentication errors
Set `BRAINTRUST_API_KEY` environment variable or pass `api_key` parameter.
