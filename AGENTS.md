# Agent guidelines

## About this repository

This is the **Braintrust Claude Code plugin marketplace** - a repository that distributes Claude Code plugins for Braintrust integration.

### Structure

```
claude-plugin/
├── .claude-plugin/
│   └── marketplace.json      # Marketplace catalog (lists available plugins)
├── plugins/
│   ├── braintrust/           # Plugin: Braintrust evaluation & logging
│   └── trace-claude-code/    # Plugin: Session tracing to Braintrust
└── evals/                    # Evaluation suite for testing the plugins
```

### Plugins

| Plugin | Description |
|--------|-------------|
| `braintrust` | Enables AI agents to use Braintrust for LLM evaluation, logging, and observability. Includes MCP server config and the `troubleshoot-braintrust-mcp` skill. |
| `trace-claude-code` | Automatically traces Claude Code conversations to Braintrust. Uses hooks to capture sessions, turns, and tool calls. |

### Terminology

- **Marketplace**: A repository with a `marketplace.json` that catalogs multiple plugins for distribution
- **Plugin**: An installable unit with its own `.claude-plugin/plugin.json` manifest
- **Skill**: A capability within a plugin (e.g., `troubleshoot-braintrust-mcp` is a skill in the `braintrust` plugin)

## Style conventions

- Use sentence case for all text (capitalize first word only, except for proper nouns and code references)
- Keep criteria concise and specific
- Reference exact function/method names with proper casing (e.g., `init_dataset()`, `Eval()`, `Factuality`)
