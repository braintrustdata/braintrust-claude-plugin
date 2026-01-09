# Go Instrumentation

## Documentation URLs

**Always fetch these before writing instrumentation code:**
- [Go SDK reference](https://www.braintrust.dev/docs/reference/go)
- [pkg.go.dev](https://pkg.go.dev/github.com/braintrustdata/braintrust-sdk-go)
- [Tracing guide](https://www.braintrust.dev/docs/guides/tracing)
- [GitHub repo](https://github.com/braintrustdata/braintrust-sdk-go)

## Initialization

Add to entry point:

```go
import "github.com/braintrustdata/braintrust-sdk-go"

logger := braintrust.InitLogger(braintrust.InitLoggerParams{
    Project: "<project-name>",
})
```

## Common Patterns

**Note:** These patterns may be outdated. Always fetch the latest documentation.

Check the pkg.go.dev documentation for available wrapper functions.

## Environment Variable

```
BRAINTRUST_API_KEY=<your-api-key>
```
