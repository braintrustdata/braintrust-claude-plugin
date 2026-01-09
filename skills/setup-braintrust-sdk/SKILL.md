---
name: setup-braintrust-sdk
description: |
  Set up Braintrust SDK instrumentation in a codebase. Detects languages, installs SDKs,
  and instruments LLM providers and AI frameworks automatically.
version: 2.0.0
allowed-tools:
  - Read
  - Glob
  - Grep
  - WebFetch
  - Bash
  - Edit
  - Write
---

# Set Up Braintrust

This skill sets up Braintrust SDK instrumentation in a user's codebase.

## When to Use This Skill

Activate this skill when the user:
- Asks to "set up Braintrust" or "add Braintrust"
- Asks to "install the Braintrust SDK" or "install Braintrust"
- Wants to add tracing/observability to their LLM application
- Mentions wanting to log LLM calls to Braintrust

## Important Principles

1. **Only add Braintrust code** - Do not refactor, improve, or change anything else
2. **Ask before acting** - Confirm with the user before making changes
3. **Always fetch latest docs** - Use documentation links, don't rely on memory
4. **Verify at each step** - Build and test before moving to next step

## Workflow Overview

1. **Install SDK** - Detect language, install latest SDK version
2. **Discover Integrations** - Find LLM providers and frameworks in codebase
3. **Instrument** - Add wrapper code and initialization
4. **Verify** - Build, run, and confirm traces appear

## Step 1: Install the SDK

### 1a. Detect Language

Search for these files to detect which language to install for:

| Language | Detection Files |
|----------|-----------------|
| Python | `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile`, `*.py` |
| TypeScript/JS | `package.json`, `tsconfig.json`, `*.ts`, `*.js` |
| Go | `go.mod`, `*.go` |
| Java | `pom.xml`, `build.gradle`, `build.gradle.kts`, `*.java` |
| Ruby | `Gemfile`, `*.rb` |

### 1b. Check if Already Installed

Search the dependency file for `braintrust`. If already installed, report the version and continue to Step 2.

### 1c. Fetch Latest Version

**REQUIRED**: Use WebFetch to get the current version from the package registry API.

See the [language references](#language-references) for the specific API URL to fetch.

**Do NOT guess or use a version from memory** - always fetch the live version.

### 1d. Add to Dependencies and Install

Add the SDK to the project's dependency file with the fetched version number, then run the install command.

### 1e. Verify Installation

Verify the SDK is installed correctly by testing an import. See language reference for verification command.

## Step 2: Discover Integrations

Follow the [discover-sdk-integrations](../discover-sdk-integrations/SKILL.md) skill:

1. Search for LLM providers (OpenAI, Anthropic, etc.)
2. Search for AI frameworks (LangChain, LlamaIndex, etc.)
3. Report findings to user
4. Confirm which integrations to instrument

## Step 3: Instrument Code

Follow the [install-sdk-integration](../install-sdk-integration/SKILL.md) skill:

1. Confirm entry point file
2. Get project name from user
3. Fetch latest instrumentation docs
4. Add `init_logger()` call
5. Wrap confirmed LLM clients
6. Configure environment variable (API key)

## Step 4: Verify Setup

This step uses a **try-do-verify loop** to ensure tracing is working.

### 4a. Build the app

Run the build/install command for the project. Fix any import errors or missing dependencies before proceeding.

### 4b. Verification Loop

```
WHILE traces not appearing:
  1. TRY: Run the app to trigger an LLM call
  2. DO: Query Braintrust API to check for logs
  3. VERIFY: Did logs appear?
     - YES: Exit loop, proceed to 4c
     - NO: Debug and fix:
       - Check BRAINTRUST_API_KEY is set correctly
       - Check init_logger() is being called
       - Check the wrapper is applied to the client
       - Check console for any error messages
     - REPEAT from step 1
```

API endpoint to check logs: `https://api.braintrust.dev/v1/project_logs/<project_id>/fetch`

### 4c. Success - Provide Link

Once traces appear, provide the link to view them:
- Direct link: `https://www.braintrust.dev/app/<org>/p/<project-name>/logs`
- Or browse: [Braintrust Dashboard](https://www.braintrust.dev)

Construct the actual URL with their org and project name:
```
View your traces: https://www.braintrust.dev/app/acme-corp/p/my-project/logs
```

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
- Do not add evaluation code unless specifically asked
