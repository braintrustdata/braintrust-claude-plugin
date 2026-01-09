# Java Instrumentation

## Documentation URLs

**Always fetch these before writing instrumentation code:**
- [Java SDK reference](https://www.braintrust.dev/docs/reference/java)
- [GitHub repo](https://github.com/braintrustdata/braintrust-java)
- [Tracing guide](https://www.braintrust.dev/docs/guides/tracing)

## Initialization

Add to entry point:

```java
import com.braintrust.Braintrust;

Braintrust.initLogger(new InitLoggerParams.Builder()
    .project("<project-name>")
    .build());
```

## Common Patterns

**Note:** These patterns may be outdated. Always fetch the latest documentation.

Check the GitHub repo and SDK reference for available wrapper methods.

## Environment Variable

```
BRAINTRUST_API_KEY=<your-api-key>
```
