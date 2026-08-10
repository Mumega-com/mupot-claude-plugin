---
name: connect
description: MCP connection reference for Claude Code, Claude Desktop, Cursor, and claude.ai — including which clients can carry an agent identity and which cannot. Use /mupot:setup for first-time guided setup.
user-invocable: true
---

# mupot Connection Reference

Config for every client, side by side. $ARGUMENTS = client name.

> First time? Run `/mupot:setup` instead — it walks the whole path including how to get a
> token and how to verify it.

## The endpoint

```
https://mupot.mumega.com/mcp        Streamable HTTP
```

Two facts govern every config below:

1. **The bearer is read only from the `Authorization` header.** There is no URL-path token
   route. A token in the path is ignored and the call 401s.
2. **A token is either operator or agent-bound, never both** (`/mupot:setup` Step 0). Two
   token kinds means two server entries. Name them `mupot` (operator) and `mupot-agent`
   (agent-bound) so the tool names tell you which surface you are on.

## Which client can carry an agent identity

| Client | Header auth (agent-bound possible) | OAuth (operator only) |
|---|---|---|
| Claude Code | yes — `claude mcp add --header` | yes |
| Cursor | yes — `headers` in `mcp.json` | yes |
| Claude Desktop | via the `mcp-remote` bridge | yes, native |
| claude.ai custom connector | no (see below) | yes, only option |

**Any client connecting by OAuth alone gets an operator, not an agent.** The OAuth door
mints `agent_id = null` by design, on the `directory` channel, which carries zero standing
capabilities. That seat can call `status` and read; it cannot `send`, cannot `inbox`, and
cannot `connect` to an agent name. This is the number one source of confusion — it looks
like a permissions problem and is not one. No grant fixes it. See `/mupot:setup` Step 2c.

---

## Claude Code

```bash
# agent-bound
claude mcp add --transport http --scope user mupot-agent \
  https://mupot.mumega.com/mcp \
  --header "Authorization: Bearer $(cat ~/.mupot/agents/<slug>-agent-bound.token)"

# operator
claude mcp add --transport http --scope user mupot \
  https://mupot.mumega.com/mcp \
  --header "Authorization: Bearer OPERATOR_TOKEN"
```

Scopes: `user` → `~/.claude.json` (all projects). `project` → `.mcp.json` in the repo,
shared with everyone who clones it — **never put a real token there**. `local` → this
project, this machine only.

Equivalent `~/.claude.json` fragment, if you prefer editing:

```json
{
  "mcpServers": {
    "mupot": {
      "type": "http",
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer OPERATOR_TOKEN" }
    },
    "mupot-agent": {
      "type": "http",
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer AGENT_BOUND_TOKEN" }
    }
  }
}
```

Verify: `mcp__mupot-agent__status {}` → `bound_agent_id` set; `mcp__mupot__status {}` →
`bound_agent_id: null`. If both are `null` you installed the same token twice.

---

## Cursor

`~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (project):

```json
{
  "mcpServers": {
    "mupot": {
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer OPERATOR_TOKEN" }
    },
    "mupot-agent": {
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer AGENT_BOUND_TOKEN" }
    }
  }
}
```

Cursor will also connect by URL alone and run the OAuth flow. That path gives you an
operator. If you want the agent surface, use the headers above.

---

## Claude Desktop

Desktop's **Custom Connectors** UI (Settings → Connectors → Add) takes a URL and runs
OAuth. That works, and gives you an operator.

For an agent-bound identity, Desktop's config file is stdio-oriented, so the usual route is
the `mcp-remote` bridge (needs Node):

`~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or
`%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "mupot-agent": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "https://mupot.mumega.com/mcp",
        "--header", "Authorization:${MUPOT_AUTH}"
      ],
      "env": { "MUPOT_AUTH": "Bearer AGENT_BOUND_TOKEN" }
    }
  }
}
```

The header is written `Authorization:${MUPOT_AUTH}` with no space after the colon, and the
value carries the `Bearer ` prefix. Some Desktop builds split `args` entries on whitespace,
which mangles `"Authorization: Bearer xyz"` into two arguments; keeping the space inside an
env var sidesteps it. If your build handles it fine, the plain form works too.

Restart Desktop fully after editing — quit, do not just close the window.

---

## claude.ai (web) custom connectors

Add a connector at Settings → Connectors → Add custom connector, URL
`https://mupot.mumega.com/mcp`.

**The UI is OAuth-only — there is no field for a bearer token.** So a claude.ai connector
lands on the directory channel as an operator with zero capabilities. It can call `status`.
It cannot message, cannot read an inbox, and `connect` will refuse with
`directory_channel_zero_capability`.

There is a static-header escape (`static_headers` on the connector), but be clear about what
it is:

- it is a **beta**, available to Team/Enterprise organisations, not to individual accounts
- the header is stored on the **organisation's** connector, so **every user of that
  connector arrives as the same agent**

That second point is the disqualifier for most uses. It is a bridge for a shared read-only
seat, not a fix for per-person agent identity. If three people use an org connector wired to
one agent-bound token, mupot sees one agent doing everything, and the audit trail says so.

If you need per-person identity on the web today, the honest answer is: use Claude Code or
Cursor with header auth. That is the gap.

---

## The shell fallback — `bin/pot`

MCP sessions expire. When one does, every mupot tool disappears mid-task. `bin/pot` holds no
session — one HTTPS request per call — so it keeps working:

```bash
export PATH="$PATH:/path/to/mupot-claude-plugin/bin"
pot status '{}'
pot inbox  '{"limit":5,"peek":true}'
pot peers  '{}'
MUPOT_AGENT=researcher pot inbox '{"limit":3,"peek":true}'   # another seat you own
```

It reads `~/.mupot/agents/<slug>-agent-bound.token`, so it is the **agent-bound** half only.
It never echoes the token, and it surfaces JSON-RPC errors instead of swallowing them.

Config: `MUPOT_AGENT` (or `~/.mupot/agent`), `MUPOT_TOKEN_DIR`, `MUPOT_ENDPOINT`.

---

## Multiple pots

One entry per pot per token kind, distinct names:

```json
{
  "mcpServers": {
    "mupot-acme-agent":  { "type": "http", "url": "https://acme.example.com/mcp",
                           "headers": { "Authorization": "Bearer ACME_AGENT_TOKEN" } },
    "mupot-house-agent": { "type": "http", "url": "https://mupot.mumega.com/mcp",
                           "headers": { "Authorization": "Bearer HOUSE_AGENT_TOKEN" } }
  }
}
```

Tokens are tenant-scoped: a pot forces its own tenant server-side, so a token from one pot
cannot address agents in another. There is no cross-pot `send`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` on everything | token in the URL path, or missing/misspelt `Authorization` header | bearer in the header; check for a stray newline in the token file |
| `403 not_agent_bound` | operator token on `send`/`broadcast`/`inbox` | use the agent-bound entry |
| `403 operator_principal_required` | agent-bound token on `mint_*`/`grant_*`/`revoke_*` | use the operator entry |
| `409 agent_binding_required` | operator token on `flight_dispatch`/`flight_land` | use the agent-bound entry |
| `403 directory_channel_zero_capability` | OAuth/directory seat | needs a workspace-channel token; a grant will not help |
| `409 ambiguous_slug` | duplicate slugs in the pot | pass the agent id |
| tools vanish mid-session | MCP session expired | re-run `/mcp` to reconnect, or use `bin/pot` |
| `peers` demands `squad_id` | your token is not agent-bound | you are on the operator entry |
