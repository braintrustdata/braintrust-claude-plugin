# Braintrust Claude Code Marketplace

> **This repository is generated.** It is built from
> [braintrustdata/braintrust-coding-agent-plugins](https://github.com/braintrustdata/braintrust-coding-agent-plugins).
> Don't edit files here — make changes and file issues in that repository, and they
> will be rebuilt into this one.

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
# run the setup script to confgure tracing
$HOME/.claude/plugins/marketplaces/braintrust-claude-plugin/plugins/trace-claude-code/setup.sh
```

Traces are sent to the `claude-code` project by default.

#### manual configuration

Instead of running `setup.sh`, you can manually edit `~/.claude/settings.json` or your project's `.claude/settings.local.json`:

```json
{
  "env": {
    "TRACE_TO_BRAINTRUST": "true",
    "BRAINTRUST_CC_PROJECT": "project-name-to-send-cc-traces-to",
    "BRAINTRUST_API_KEY": "sk-yourkey",
    "BRAINTRUST_DEBUG": "false"
  }
}
```

#### add claude code trace to an existing trace

You can attach a Claude Code session to an existing Braintrust trace by passing `CC_PARENT_SPAN_ID`:

```bash
claude --settings '{"env":{"CC_PARENT_SPAN_ID":"your-parent-span-id"}}' -p "task"
```

If the parent span is not the trace root, also pass `CC_ROOT_SPAN_ID`:

```bash
claude --settings '{"env":{"CC_PARENT_SPAN_ID":"parent-span-id","CC_ROOT_SPAN_ID":"root-span-id"}}' -p "task"
```

The Claude Code session and all its turns/tools will appear as children of your parent span in Braintrust.

To attach claude code to an experiment's trace, specify CC_EXPERIMENT_ID as well:

```bash
claude --settings '{"env":{"CC_PARENT_SPAN_ID":"parent-span-id","CC_ROOT_SPAN_ID":"root-span-id", "CC_EXPERIMENT_ID":"the-experiment-id"}}' -p "task"
```

#### token accounting

The plugin derives token usage from the conversation transcript that Claude Code
writes. For every model request that appears in the transcript — the main
conversation and sub-agents alike — the traced token counts match Claude Code's
own `/usage` exactly and are emitted with Braintrust's canonical metric names.

For Anthropic usage, `prompt_tokens` is inclusive: Claude Code's
`input_tokens` plus cache-read tokens plus cache-write tokens. Cache reads are
also emitted as `prompt_cached_tokens`. Cache writes are emitted as
`prompt_cache_creation_5m_tokens` / `prompt_cache_creation_1h_tokens` when
Claude Code includes the Anthropic TTL breakdown, or as
`prompt_cache_creation_tokens` when only the legacy aggregate is present. This
is the shape Braintrust's backend uses to compute cost.

There is one known and unavoidable exception: **Claude Code's internal background
model calls** (most notably the automatic **session-title generation**, and
conversation summarization). These calls are billed and counted in `/usage`, but
Claude Code records only their result (e.g. an `ai-title` entry) in the
transcript — never a request id, model, or token usage — and they are not exposed
through any hook. Because the plugin has no data source for these tokens, traced
totals for an interactive session can read slightly below `/usage` (typically a
small amount of opus cache-read tokens for the title call). Non-interactive
(`-p`) sessions do not make these background calls and reconcile exactly.
