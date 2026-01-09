# Python SDK

## Fetch Latest Version

Fetch `https://pypi.org/pypi/braintrust/json` and read `info.version`

Or visit: https://pypi.org/project/braintrust/

## Add to Dependencies

Add with specific version:
- `requirements.txt`: `braintrust==X.Y.Z`
- `pyproject.toml`: `braintrust = "X.Y.Z"` (in `[project.dependencies]` or `[tool.poetry.dependencies]`)
- `Pipfile`: `braintrust = "==X.Y.Z"`

## Install Command

```bash
# requirements.txt
pip install -r requirements.txt

# pyproject.toml (with pip)
pip install .

# pyproject.toml (with poetry)
poetry install

# Pipfile
pipenv install
```

## Verify Installation

Test that the SDK is installed and the wrapper function exists:

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
