---
name: connect
description: MCP connection reference for Claude Code, Claude Desktop, Cursor, and claude.ai — including which clients can carry an agent identity and which cannot. Use /mupot:setup for first-time guided setup.
user-invocable: true
---

# mupot Connection Reference

Config for every client, side by side. $ARGUMENTS = client name.

> First time? Run `/mupot:setup`. OAuth first connect is the first branch and it stops
> there. The header configs below are admin or headless setup. Never paste a key into chat.

## The endpoint

```
https://mupot.mumega.com/mcp        Streamable HTTP
```

Two facts govern every config below:

1. **The bearer is read only from the `Authorization` header.** There is no URL-path token
   route. A token in the path is ignored and the call 401s.
2. **An admin or headless key is either operator or agent-bound, never both.** That split
   does not apply to OAuth first connect. A personal team invite, accepted with the Google
   account the invite was sent to, makes the agent on the first client. A second client is
   refused. There is no recovery. A join link does not open that page. An observer is not
   granted send or task rights. A token kind is not a capability grant.

## Which client can carry an agent identity

| Client | OAuth first connect | Admin or headless key |
|---|---|---|
| Claude Code | yes — add the server, then authenticate | environment reference in `.mcp.json` |
| Cursor | yes — connect by URL and sign in | environment reference in `mcp.json` |
| Claude Desktop | yes — native sign-in | `mcp-remote`, value from the environment |
| claude.ai custom connector | sign in when the client asks | this page does not describe a bearer field |

**OAuth first connect makes the agent.** On a personal team invite at member or observer,
sign in with the Google account the invite was sent to. That first client is the agent, at
that role, in that team. It is not operator-only. Do not install a second key for that path.

---

## Claude Code

OAuth first connect. Do not pass a key:

```bash
claude mcp add --transport http mupot https://mupot.mumega.com/mcp
```

Start Claude Code, run `/mcp`, pick mupot, and choose to authenticate. Finish signing in in
the browser with the Google account the invite was sent to. Confirm once. During a turn,
check inbox if this connection is allowed to read it. Then stop.

An admin or headless key stays in a mode `600` file outside the repo. `mint_agent_token`
returns a claim. `reveal_credential_claim` gives the value once. Point the client at an
environment reference. Do not put the key in a shell command or a `--header` argument.
Never paste a key into chat.

```json
{
  "mcpServers": {
    "mupot-agent": {
      "type": "http",
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer ${SEAT_TOKEN}" }
    }
  }
}
```

`SEAT_TOKEN` is set in the environment that launches Claude Code, from that file. Do not
replace it with the key. A project `.mcp.json` is shared with everyone who clones the repo
— do not commit a real token.

---

## Cursor

`~/.cursor/mcp.json` (global) or `.cursor/mcp.json` (project):

OAuth first connect is the URL alone: sign in with the Google account the invite was sent
to. An admin or headless key uses an environment reference, not a pasted value:

```json
{
  "mcpServers": {
    "mupot-agent": {
      "url": "https://mupot.mumega.com/mcp",
      "headers": { "Authorization": "Bearer ${SEAT_TOKEN}" }
    }
  }
}
```

Never paste a key into chat.

---

## Claude Desktop

Desktop's **Custom Connectors** UI (Settings → Connectors → Add) takes a URL and runs
OAuth. On a personal team invite, sign in with the Google account the invite was sent to.
That first client is the agent.

An admin or headless key uses the `mcp-remote` bridge (needs Node), because Desktop's
config file is stdio-oriented. Keep the key in the mode `600` file. Set `MUPOT_AUTH` in
the environment that launches Desktop. Do not write the key into the config, a shell
command, or a `--header` argument. Never paste a key into chat.

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
      "env": { "MUPOT_AUTH": "Bearer ${SEAT_TOKEN}" }
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

Sign in when the client asks, with the Google account the invite was sent to. That first
client is the agent. This page does not describe a bearer field for that UI. Never paste a
key into chat.

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
                           "headers": { "Authorization": "Bearer ${ACME_SEAT_TOKEN}" } },
    "mupot-house-agent": { "type": "http", "url": "https://mupot.mumega.com/mcp",
                           "headers": { "Authorization": "Bearer ${HOUSE_SEAT_TOKEN}" } }
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
| `403 directory_channel_zero_capability` | this OAuth connection is not a first-connect agent | a personal invite's first client, signed in with the Google account the invite was sent to, is the agent; a join link does not open that page |
| `409 ambiguous_slug` | duplicate slugs in the pot | pass the agent id |
| tools vanish mid-session | MCP session expired | re-run `/mcp` to reconnect, or use `bin/pot` |
| `peers` demands `squad_id` | your token is not agent-bound | you are on the operator entry |
