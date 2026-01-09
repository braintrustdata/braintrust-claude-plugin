---
name: install-sdk-integration
description: |
  Add Braintrust instrumentation to LLM providers and AI frameworks.
  Wraps clients and adds initialization code.
version: 1.0.0
allowed-tools:
  - Read
  - Glob
  - Grep
  - WebFetch
  - Edit
  - Write
  - Bash
---

# Instrument with Braintrust

This skill adds Braintrust instrumentation to LLM providers and AI frameworks in a codebase.

## When to Use This Skill

Use when:
- User asks to "instrument" or "add tracing" to their code
- Called by the setup-braintrust-sdk orchestrator skill
- User wants to wrap specific LLM clients with Braintrust

## Important Principles

1. **Only add Braintrust code** - Do not refactor, improve, or change anything else
2. **Fetch latest docs** - Always check documentation for correct wrapper patterns
3. **Verify imports** - Test wrapper function exists before using it

## Workflow

### Step 1: Confirm Entry Point

Ask the user to confirm the main entry point file where initialization should be added.

### Step 2: Confirm Project Name

Ask the user what Braintrust project name to use. This will be passed to `init_logger(project="<name>")`.
- Suggest using the app/repo name as default
- The project will be created automatically if it doesn't exist

### Step 3: Fetch Instrumentation Docs

**REQUIRED**: Fetch the Braintrust documentation to get the correct wrapper patterns.

See language reference for documentation URLs.

### Step 4: Add Initialization Code

Add `init_logger()` call to the entry point file with the project name.

### Step 5: Wrap LLM Clients

For each library the user confirmed:
1. Find where the client is created
2. Wrap it with the appropriate Braintrust wrapper
3. Verify the wrapper import works

### Step 6: Configure Environment Variable

Ask the user which option they prefer:

**Option A: Add to .env file**
```
BRAINTRUST_API_KEY=<your-api-key-here>
```

**Option B: Provide instructions only**
Tell them to set the environment variable manually.

Always inform user:
- Get API key from: [Braintrust API Keys](https://www.braintrust.dev/app/settings/api-keys)

## Language References

- [Python](references/python.md)
- [TypeScript/JavaScript](references/typescript.md)
- [Go](references/go.md)
- [Java](references/java.md)
- [Ruby](references/ruby.md)

## What NOT to Do

- Do not refactor existing code
- Do not add error handling beyond what's needed
- Do not add type annotations or documentation
- Do not modify code unrelated to Braintrust
