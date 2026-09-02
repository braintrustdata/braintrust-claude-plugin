# Agent guidelines

## About this repository

This is the **Braintrust Claude Code plugin marketplace** - a repository that distributes Claude Code tracing for Braintrust.

### Structure

```
claude-plugin/
├── .claude-plugin/
│   └── marketplace.json      # Marketplace catalog (lists available plugins)
├── plugins/
│   └── trace-claude-code/    # Plugin: Session tracing to Braintrust
└── evals/                    # Evaluation suite for Braintrust MCP behavior
```

### Plugins

| Plugin | Description |
|--------|-------------|
| `trace-claude-code` | Forwards Claude Code lifecycle hooks to `bt trace hook --source claude-code`; the shared daemon builds and delivers traces. |

### Terminology

- **Marketplace**: A repository with a `marketplace.json` that catalogs multiple plugins for distribution
- **Plugin**: An installable unit with its own `.claude-plugin/plugin.json` manifest

## Style conventions

- Use sentence case for all text (capitalize first word only, except for proper nouns and code references)
- Keep criteria concise and specific
- Reference exact function/method names with proper casing (e.g., `init_dataset()`, `Eval()`, `Factuality`)
