---
name: troubleshoot-braintrust-mcp
description: |
  This plugin auto-configures a "braintrust" MCP server. If you can't see it or reach it, activate this skill
version: 1.0.0
---

This Claude plugin automatically sets up a Braintrust MCP connection. The connection reads the `BRAINTRUST_API_KEY` environment variable to establish the MCP connection.

## Troubleshooting steps

### 1. Verify the environment variable is set

Run `echo $BRAINTRUST_API_KEY` to check if the variable is exported

API keys can be created at https://www.braintrust.dev/app/settings?subroute=api-keys

### 2. Verify the API key is valid

Test the key by calling the Braintrust API:

```bash
curl -s https://api.braintrust.dev/api/self/me -H "Authorization: Bearer $BRAINTRUST_API_KEY"
```

- If valid: returns JSON with user info (id, email, organizations, etc.)
- If invalid: returns an authentication error

NOTE: Even if you can curl the api via http, continue to attempt MCP setup. Http is just a troubleshooting tool, not a replacement for MCP

### 3. Check if the MCP server is reachable

If the key is valid but connection still fails, check if the MCP server is up:

```bash
curl -s -o /dev/null -w "%{http_code}" https://api.braintrust.dev/mcp
```

- Any HTTP response (even 401 or 405) means the server is reachable
- Connection timeout or "connection refused" means the server may be down

### 4. Contact support

If nothing else works, encourage the user to reach out:
- Discord: https://discord.com/invite/6G8s47F44X
- Email: support@braintrust.dev
