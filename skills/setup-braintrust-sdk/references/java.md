# Java SDK

## Fetch Latest Version

Fetch `https://search.maven.org/solrsearch/select?q=g:com.braintrust+AND+a:braintrust-java&rows=1&wt=json` and read `response.docs[0].latestVersion`

Or visit: https://central.sonatype.com/artifact/com.braintrust/braintrust-java

## Add to Dependencies

**Maven (pom.xml):**
```xml
<dependency>
  <groupId>com.braintrust</groupId>
  <artifactId>braintrust-java</artifactId>
  <version>X.Y.Z</version>
</dependency>
```

**Gradle (build.gradle):**
```groovy
implementation 'com.braintrust:braintrust-java:X.Y.Z'
```

**Gradle Kotlin (build.gradle.kts):**
```kotlin
implementation("com.braintrust:braintrust-java:X.Y.Z")
```

## Install Command

```bash
# Maven
mvn install

# Gradle
./gradlew build
```

## Documentation

| Type | URL |
|------|-----|
| GitHub repo | https://github.com/braintrustdata/braintrust-java |
| Hosted docs | https://www.braintrust.dev/docs/reference/java |
| Tracing guide | https://www.braintrust.dev/docs/guides/tracing |
