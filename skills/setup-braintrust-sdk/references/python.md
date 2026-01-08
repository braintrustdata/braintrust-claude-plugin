# Python SDK

## Installation

Install the latest version and pin it:

1. Find the latest version:
   - Fetch https://pypi.org/pypi/braintrust/json and read `info.version`
   - Or visit: https://pypi.org/project/braintrust/
2. Add to dependency file with specific version:
   - `requirements.txt`: `braintrust==X.Y.Z`
   - `pyproject.toml`: `braintrust = "X.Y.Z"`
   - `Pipfile`: `braintrust = "==X.Y.Z"`
3. **Verify the wrapper function exists** before writing instrumentation code:
   ```bash
   python -c "from braintrust import <wrapper_function>"
   ```
   Replace `<wrapper_function>` with the function you plan to use (e.g., `wrap_openai`).
   If this fails, check the documentation for the correct function name.

## Documentation

| Type | URL |
|------|-----|
| GitHub repo | https://github.com/braintrustdata/braintrust-sdk |
| Hosted docs | https://www.braintrust.dev/docs/reference/python |
| Tracing guide | https://www.braintrust.dev/docs/guides/tracing |
| Wrap AI providers | https://www.braintrust.dev/docs/guides/tracing/wrap-ai-sdk |
| Framework integrations | https://www.braintrust.dev/docs/guides/tracing/integrate-frameworks |

## Libraries to Detect

Search `requirements.txt`, `pyproject.toml`, or `Pipfile` for these packages.

### AI Providers

- `openai`
- `anthropic`
- `google-generativeai`
- `boto3` (for Bedrock)
- `azure-openai`
- `mistralai`
- `groq`
- `together`
- `replicate`
- `cohere`
- `fireworks-ai`
- `cerebras`

### Frameworks

- `langchain` / `langchain-core`
- `llama-index`
- `dspy` / `dspy-ai`
- `litellm`
- `instructor`
- `pydantic-ai`
- `crewai`
- `autogen` / `pyautogen`

**This list may not be complete.** Search the documentation URLs above for the current list of supported integrations.
