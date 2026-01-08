# Java SDK

## Installation

Install the latest version:

1. Check latest version on Maven Central: https://central.sonatype.com/artifact/com.braintrust/braintrust-java
2. Add to pom.xml:
   ```xml
   <dependency>
     <groupId>com.braintrust</groupId>
     <artifactId>braintrust-java</artifactId>
     <version>X.Y.Z</version>
   </dependency>
   ```
   Or build.gradle:
   ```groovy
   implementation 'com.braintrust:braintrust-java:X.Y.Z'
   ```

## Documentation

| Type | URL |
|------|-----|
| GitHub repo | https://github.com/braintrustdata/braintrust-java |
| Hosted docs | https://www.braintrust.dev/docs/reference/java |
| Tracing guide | https://www.braintrust.dev/docs/guides/tracing |

## Libraries to Detect

Search `pom.xml` or `build.gradle` for these dependencies.

### AI Providers

- `com.openai:openai-java`
- `com.anthropic:anthropic-java`

**This list may not be complete.** Search the documentation URLs above for the current list of supported integrations.
