# TypeScript/JavaScript Instrumentation

## Documentation URLs

**Always fetch these before writing instrumentation code:**
- [Wrap AI providers](https://www.braintrust.dev/docs/guides/tracing/wrap-ai-sdk)
- [Framework integrations](https://www.braintrust.dev/docs/guides/tracing/integrate-frameworks)
- [TypeScript SDK reference](https://www.braintrust.dev/docs/reference/typescript)
- [Tracing guide](https://www.braintrust.dev/docs/guides/tracing)

## Initialization

Add to entry point:

```typescript
import { initLogger } from "braintrust";

const logger = initLogger({ project: "<project-name>" });
```

## Common Patterns

**Note:** These patterns may be outdated. Always fetch the latest documentation.

### OpenAI

```typescript
import { wrapOpenAI } from "braintrust";
import OpenAI from "openai";

const client = wrapOpenAI(new OpenAI());
```

### Anthropic

```typescript
import { wrapAnthropic } from "braintrust";
import Anthropic from "@anthropic-ai/sdk";

const client = wrapAnthropic(new Anthropic());
```

### Vercel AI SDK

```typescript
import { BraintrustAdapter } from "braintrust";
// See docs for integration pattern
```

## Environment Variable

```
BRAINTRUST_API_KEY=<your-api-key>
```
