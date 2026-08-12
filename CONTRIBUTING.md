# Developing the Claude plugins

This distribution tree is generated from the
`braintrustdata/braintrust-coding-agent-plugins` monorepo. Make source changes
there rather than editing the generated distribution repository.

## Local plugin testing

Load a plugin directly from the assembled tree:

```bash
claude --plugin-dir /path/to/repo/src/plugins/claude/content/plugins/braintrust
claude --plugin-dir /path/to/repo/src/plugins/claude/content/plugins/trace-claude-code
```

The tracing plugin is only a thin hook adapter. Its manifest and forwarder are
validated from the monorepo with:

```bash
make validate-claude
```

Trace translation, recovery, and delivery tests live in the shared
`bt-daemon` crate:

```bash
cargo test --manifest-path bt-daemon/Cargo.toml --all-features --locked
```

## Evaluation suite

The `evals/` directory tests the Braintrust skills plugin:

```bash
cd evals
uv run braintrust eval .
```

## Releases

Versions are stored in each plugin's `.claude-plugin/plugin.json`. Use the
monorepo's release workflow to bump versions, publish the generated distribution
tree, tag the release, and create release notes.
