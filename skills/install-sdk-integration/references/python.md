# Python Instrumentation

## Documentation URLs

**Always fetch these before writing instrumentation code:**
- [Wrap AI providers](https://www.braintrust.dev/docs/guides/tracing/wrap-ai-sdk)
- [Framework integrations](https://www.braintrust.dev/docs/guides/tracing/integrate-frameworks)
- [Python SDK reference](https://www.braintrust.dev/docs/reference/python)
- [Tracing guide](https://www.braintrust.dev/docs/guides/tracing)

## Verify Wrapper Function

Before writing code, verify the wrapper function exists:

```bash
python -c "from braintrust import <wrapper_function>"
```

If this fails, check the documentation for the correct function name.

## Initialization

Add to entry point:

```python
from braintrust import init_logger

logger = init_logger(project="<project-name>")
```

## Common Patterns

**Note:** These patterns may be outdated. Always fetch the latest documentation.

### OpenAI

```python
from braintrust import wrap_openai
from openai import OpenAI

client = wrap_openai(OpenAI())
```

### Anthropic

```python
from braintrust import wrap_anthropic
from anthropic import Anthropic

client = wrap_anthropic(Anthropic())
```

### LangChain

```python
from braintrust import BraintrustCallbackHandler

handler = BraintrustCallbackHandler()
# Pass to LangChain invoke/run calls
```

## Environment Variable

```
BRAINTRUST_API_KEY=<your-api-key>
```
