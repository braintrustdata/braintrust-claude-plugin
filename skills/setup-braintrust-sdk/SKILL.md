---
name: setup-braintrust-sdk
description: |
  Set up Braintrust SDK instrumentation in a codebase. Detects languages, installs SDKs,
  and instruments LLM providers and AI frameworks automatically.
version: 1.0.0
allowed-tools:
  - Read
  - Glob
  - Grep
  - WebFetch
---

# Set Up Braintrust

This skill guides you through setting up Braintrust SDK instrumentation in a user's codebase. Use this when a user wants to add Braintrust tracing, logging, or observability to their AI application.

## When to Use This Skill

Activate this skill when the user:
- Asks to "set up Braintrust" or "add Braintrust"
- Asks to "install the Braintrust SDK" or "install Braintrust"
- Wants to add tracing/observability to their LLM application
- Mentions wanting to log LLM calls to Braintrust
- Asks about instrumenting their AI code with Braintrust

## Important Principles

1. **Only add Braintrust code** - Do not refactor, improve, or change anything else
2. **Ask before acting** - Confirm hypotheses with the user before making changes
3. **Always fetch latest docs** - Use the documentation links in the language references
4. **Check before installing** - Verify SDK isn't already installed

## Workflow

### Step 1: Detect Languages

Search for these files to detect which languages are in use:

| Language | Detection Files |
|----------|-----------------|
| Python | `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile`, `*.py` |
| TypeScript/JS | `package.json`, `tsconfig.json`, `*.ts`, `*.js` |
| Go | `go.mod`, `*.go` |
| Java | `pom.xml`, `build.gradle`, `build.gradle.kts`, `*.java` |
| Ruby | `Gemfile`, `*.rb` |

### Step 2: Confirm Three Things with User

You must clarify these three things before making changes:

#### (a) Which application(s) to instrument
- If the codebase has multiple apps/services, ask which ones need Braintrust
- Don't assume - let the user specify

#### (b) Where to inject setup code
Braintrust initialization should go in a **main entry point or setup file**. Ask the user to confirm the entry point file(s) where initialization should be added.

#### (c) Which libraries to instrument
Follow the discovery process in Step 3 to find all LLM libraries, then confirm with user which ones to wrap.

### Step 3: Discover Libraries to Instrument

#### (a) Search for known integrations in user's code

See the language reference for libraries to detect. **These lists are not exhaustive** - search the documentation for the complete list.

#### (b) Search Braintrust docs for instrumentation patterns

For each library found, fetch the Braintrust documentation to find how to instrument it.

#### (c) Search SDK repos for additional integrations

The SDK repos may have newer integrations not listed in the reference.

### Step 4: Install SDK and Instrument

Using the fetched documentation:

1. **Check if Braintrust SDK is already installed**
   - If not installed, install the **latest version**:
     - Python: `pip install braintrust` or add `braintrust` to requirements.txt/pyproject.toml
     - TypeScript: `npm install braintrust@latest`
     - Go: `go get github.com/braintrustdata/braintrust-sdk-go@latest`
     - Java: Add latest version from Maven Central
     - Ruby: `gem install braintrust` or add `gem 'braintrust'` to Gemfile

2. Add initialization code to the entry point
3. Wrap the LLM libraries the user confirmed

### Step 5: Configure Environment Variable

Ask the user which option they prefer:

**Option A: Add to .env file**
```
BRAINTRUST_API_KEY=<your-api-key-here>
```

**Option B: Provide instructions only**
Tell them to set the environment variable manually.

Always inform user:
- Get API key from: https://www.braintrust.dev/app/settings/api-keys

### Step 6: Verify Setup

Guide the user through verification:
1. Run your application and make an LLM call
2. Go to https://www.braintrust.dev
3. Navigate to your project
4. Click **Logs** to see traced requests

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
