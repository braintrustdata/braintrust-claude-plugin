# Braintrust Claude Code tracing plugin

This plugin synchronously forwards Claude Code lifecycle payloads to:

```text
bt trace hook --source claude-code
```

Use `bt trace enable claude --project <project>` to install and configure it.
The hook first installs the `bt` CLI with the official installer when it is not
already available, then forwards the event. The plugin is credential-free and
fail-open; the `bt` CLI and shared daemon own authentication, event journaling,
trace construction, and delivery.

## Supported surfaces

This plugin supports Claude Code CLI and Claude Code mode in the desktop app.
It does not support the Cowork tab. Cowork executes hooks in a separate VM that
does not inherit the host's `bt` binary, saved Braintrust route, or credentials,
so installing this plugin there does not enable tracing.

To add fields to each root trace span, pass a JSON object (as
`--additional-metadata` or `BRAINTRUST_ADDITIONAL_METADATA`) to
`bt trace enable claude` for a persistent configuration, or to
`bt trace run claude` for one invocation. The hook itself never reads that
environment variable — only `bt trace enable`, `bt trace run`, and
`bt trace import` do.
