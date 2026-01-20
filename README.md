# Braintrust Claude Code Marketplace

A Claude Code plugin marketplace for [Braintrust](https://braintrust.dev) integration - LLM evaluation, logging, observability, and session tracing.

## Prerequisites

- A [Braintrust account](https://braintrust.dev)
- `BRAINTRUST_API_KEY` exported in your environment

## Installation

Add the marketplace:

```bash
claude plugin marketplace add braintrustdata/braintrust-claude-plugin
```

Then install the plugins you need:

## Plugins

### braintrust

Enables AI agents to use Braintrust for LLM evaluation, logging, and observability.

- Query Braintrust projects, experiments, datasets, and logs
- Instrument your code with the Braintrust SDK and write evals

```bash
claude plugin install braintrust@braintrust-claude-plugin
```

### trace-claude-code

Automatically traces Claude Code conversations to Braintrust. Captures sessions, conversation turns, and tool calls as hierarchical traces.

```bash
claude plugin install trace-claude-code@braintrust-claude-plugin
```

To enable tracing, add the following to your `~/.claude/settings.json` or your project's `.claude/settings.local.json`:

```json
{
  "env": {
    "TRACE_TO_BRAINTRUST": "true",
    "BRAINTRUST_CC_PROJECT": "project-name-to-send-cc-traces-to"
  }
}
```

Traces are sent to the `claude-code` project by default.
