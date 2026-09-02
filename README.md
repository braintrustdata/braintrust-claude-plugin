# Braintrust Claude Code Marketplace

> **This repository is generated.** It is built from
> [braintrustdata/braintrust-coding-agent-plugins](https://github.com/braintrustdata/braintrust-coding-agent-plugins).
> Don't edit files here — make changes and file issues in that repository, and they
> will be rebuilt into this one.

A Claude Code plugin marketplace for tracing Claude Code sessions to [Braintrust](https://braintrust.dev).

## Prerequisites

- A [Braintrust account](https://braintrust.dev)
- The `bt` CLI, authenticated with `bt login`

## Supported Claude surfaces

This marketplace plugin supports Claude Code CLI and Claude Code mode in the
desktop app. It does not currently support the Cowork tab, which runs tools and
hooks inside a separate VM without the host's `bt` installation, Braintrust
configuration, or environment variables.

In Cowork, use the Braintrust connector provided through Claude for MCP access.
Automatic Cowork session tracing is not currently supported.

## Installation

Add the marketplace:

```bash
claude plugin marketplace add braintrustdata/braintrust-claude-plugin
```

Then enable tracing:

Automatically traces Claude Code conversations to Braintrust through the shared
Braintrust daemon. The plugin contains only a fail-open hook forwarder; `bt`
owns authentication, trace construction, and delivery.

```bash
bt trace enable claude --project my-coding-agent
```

Use `--profile` or `--org` when needed. Setup stores only non-secret routing
settings under `~/.claude/braintrust.json`. Restart Claude Code after setup.

Every registered lifecycle event is forwarded synchronously to
`bt trace hook --source claude-code`, preserving per-session ordering. Hook
failures never fail a Claude Code turn.

This marketplace does not install or configure the Braintrust MCP server. Use
your agent's native connector or MCP configuration when you want MCP access.

#### Additional root metadata

For a persistent route, pass a JSON object to `bt trace enable claude
--additional-metadata '<JSON>'` to tag the root span of every Claude Code
session. Standard session metadata takes precedence if keys conflict.

For one invocation without changing the persistent configuration, use
`bt trace run --additional-metadata '{"ci":true,"run_id":"abc-123"}' claude`,
or set `BRAINTRUST_ADDITIONAL_METADATA` before that command (`bt trace run`
still accepts it; a launched `claude` session's live hooks do not).
