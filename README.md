# Braintrust tracing for Claude Code

> **This repository is generated.** It is built from
> [braintrustdata/braintrust-coding-agent-plugins](https://github.com/braintrustdata/braintrust-coding-agent-plugins).
> Don't edit files here — make changes and file issues in that repository, and they
> will be rebuilt into this one.

A Claude Code plugin marketplace for tracing Claude Code sessions to [Braintrust](https://braintrust.dev).

## Prerequisites

- A [Braintrust account](https://braintrust.dev)
- Claude Code
- The [Braintrust CLI](https://www.braintrust.dev/docs/reference/cli/quickstart)

## Supported Claude surfaces

This marketplace plugin supports Claude Code CLI and Claude Code mode in the
desktop app. It does not currently support the Cowork tab, which runs tools and
hooks inside a separate VM without the host's `bt` installation, Braintrust
configuration, or environment variables.

In Cowork, use the Braintrust connector provided through Claude for MCP access.
Automatic Cowork session tracing is not currently supported.

## Quickstart

Authenticate and install the published tracing plugin:

```bash
bt login
bt trace enable claude --project my-coding-agent
```

Setup adds the marketplace and installs or enables `trace-claude-code`.
The plugin forwards lifecycle events locally; `bt` owns authentication,
trace construction, and delivery.

Use `--profile` or `--org` when needed. Setup stores only non-secret routing
settings under `~/.claude/braintrust.json`. Restart Claude Code after setup.

Every registered lifecycle event is forwarded synchronously to
`bt trace hook --source claude-code`, preserving per-session ordering. Hook
failures never fail a Claude Code turn.

This marketplace does not install or configure the Braintrust MCP server. Use
your agent's native connector or MCP configuration when you want MCP access.

## Data handling

Tracing forwards Claude Code's native hook payloads and reads the session
transcript to construct traces. This can include user prompts, tool inputs and
outputs, model requests and responses, and session metadata. Each turn records
the effective Claude permission mode. Root-span metadata includes, when Claude
provides it, the complete client system prompt.

System prompts and the other captured content can contain confidential
instructions, file contents, or secrets. The plugin does not redact these
values locally. Configure the applicable Braintrust content-redaction controls
before enabling tracing, and do not trace content that must not be sent to
Braintrust. Redaction cannot remove data that has already been delivered.

## Additional root metadata

For a persistent route, pass a JSON object to `bt trace enable claude
--additional-metadata '<JSON>'` to tag the root span of every Claude Code
session. Standard session metadata takes precedence if keys conflict.

For one invocation without changing the persistent configuration, use
`bt trace run --additional-metadata '{"ci":true,"run_id":"abc-123"}' claude`,
or set `BRAINTRUST_ADDITIONAL_METADATA` before that command (`bt trace run`
still accepts it; a launched `claude` session's live hooks do not).

## Root-span tags

Use repeatable `--tag` options to apply filterable tags to every root span in a
route. Tags can be persisted with setup, supplied to one invocation, or added
while importing a transcript:

```bash
bt trace enable claude --tag ci --tag release-validation
bt trace run claude --tag ci -- "review this change"
bt trace import claude session-id --tag historical-import
```

For automation, set `BRAINTRUST_TAGS` to a comma-separated list before
invoking setup, a run, or an import:

```bash
BRAINTRUST_TAGS=ci,release-validation bt trace run claude -- "review this change"
```

## One-off runs and transcript import

```bash
bt trace run --project my-coding-agent claude -- -p "summarize this repository"
bt trace import claude SESSION_ID
bt trace import claude SESSION_ID --attach
```

`run` leaves your saved settings alone. `import` reads a saved transcript;
`--attach` follows it until Ctrl-C. Imports include only what the agent recorded.

## Manage tracing

```bash
bt trace doctor claude
bt trace status
bt trace update claude
bt trace disable claude
```

See the [tracing plugin guide](plugins/trace-claude-code/README.md) for the
capture architecture and supported surfaces.
