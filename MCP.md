# MCP in short

**MCP (Model Context Protocol)** is a standard way for AI tools (like Copilot) to connect to external tools and data sources through "servers."  
Think of it like a plugin protocol: MCP servers expose capabilities (read files, query APIs, work with design/dev tools, etc.), and Copilot can call those capabilities safely and consistently.

## How MCP works

1. **MCP server exposes tools/resources**  
   A server defines what actions are available (for example: list PRs, fetch docs, query a database).

2. **Copilot discovers those capabilities**  
   Once connected, Copilot sees the server's tools and their input/output schemas.

3. **Copilot calls tools during a task**  
   When needed, Copilot sends structured requests to the MCP server, gets structured results back, and uses that to answer or complete work.

4. **You stay in control**  
   Depending on setup/policies, tool calls can be constrained, audited, or require approval.

## How to utilize MCP effectively

- **Use MCP when data is outside your repo** (GitHub APIs, design tools, CI systems, internal services).
- **Prefer focused tool calls** instead of broad "search everything" prompts.
- **Give context in prompts** (repo, branch, target object, exact ID/name) so MCP tools return precise results.
- **Chain tools**: discover -> inspect -> act (e.g., list PRs -> get PR details -> comment/update).
- **Use least privilege** for tokens/credentials and keep server scopes narrow.

## How to add an MCP server to Copilot

### Add via Copilot CLI command (recommended)

Use this from your terminal (without starting interactive chat):

```shell
copilot mcp add --transport http SERVER-NAME URL
```

Example:

```shell
copilot mcp add --transport http sentry https://mcp.sentry.dev/mcp
```

### Add from inside interactive Copilot CLI

1. Start Copilot CLI:

```shell
copilot
```

2. Run:

```shell
/mcp add
```

3. Fill server details and press `Ctrl+S` to save.

### Where MCP config is stored

MCP server definitions are saved in:

```text
~/.copilot/mcp-config.json
```

You can change this base location by setting `COPILOT_HOME`.
