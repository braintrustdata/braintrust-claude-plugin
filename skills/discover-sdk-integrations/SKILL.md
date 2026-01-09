---
name: discover-sdk-integrations
description: |
  Discover LLM providers and AI frameworks in a codebase that can be instrumented
  with Braintrust tracing.
version: 1.0.0
allowed-tools:
  - Read
  - Glob
  - Grep
  - WebFetch
---

# Discover Braintrust Integrations

This skill discovers LLM providers and AI frameworks in a codebase that can be instrumented with Braintrust.

## When to Use This Skill

Use when:
- User asks to "find what can be traced" or "discover integrations"
- Called by the setup-braintrust-sdk orchestrator skill
- User wants to know what LLM libraries are in their codebase

## Workflow

### Step 1: Detect Language

Search for dependency files to detect which language(s) are in use:

| Language | Dependency Files |
|----------|------------------|
| Python | `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile` |
| TypeScript/JS | `package.json` |
| Go | `go.mod` |
| Java | `pom.xml`, `build.gradle`, `build.gradle.kts` |
| Ruby | `Gemfile` |

### Step 2: Search for Known Libraries

See the language reference for libraries to search for. **These lists are not exhaustive.**

### Step 3: Fetch Latest Supported Integrations

Always check the Braintrust documentation for the current list of supported integrations:
- https://www.braintrust.dev/docs/guides/tracing/wrap-ai-sdk
- https://www.braintrust.dev/docs/guides/tracing/integrate-frameworks

### Step 4: Report Findings

Report to the user:
1. Which LLM providers were found (e.g., OpenAI, Anthropic)
2. Which AI frameworks were found (e.g., LangChain, LlamaIndex)
3. Where they are used in the codebase (file paths)

### Step 5: Confirm with User

Ask the user which integrations they want to instrument. Don't assume all should be instrumented.

## Language References

- [Python](references/python.md)
- [TypeScript/JavaScript](references/typescript.md)
- [Go](references/go.md)
- [Java](references/java.md)
- [Ruby](references/ruby.md)
