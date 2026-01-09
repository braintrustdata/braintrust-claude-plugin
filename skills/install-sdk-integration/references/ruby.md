# Ruby Instrumentation

## Documentation URLs

**Always fetch these before writing instrumentation code:**
- [Ruby SDK reference](https://www.braintrust.dev/docs/reference/ruby)
- [gemdocs](https://gemdocs.org/gems/braintrust/)
- [GitHub repo](https://github.com/braintrustdata/braintrust-sdk-ruby)
- [Tracing guide](https://www.braintrust.dev/docs/guides/tracing)

## Initialization

Add to entry point:

```ruby
require 'braintrust'

Braintrust.init_logger(project: "<project-name>")
```

## Common Patterns

**Note:** These patterns may be outdated. Always fetch the latest documentation.

Check the gemdocs and GitHub repo for available wrapper methods.

## Environment Variable

```
BRAINTRUST_API_KEY=<your-api-key>
```
