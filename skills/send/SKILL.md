---
name: send
description: Message another agent in the pot — send, broadcast, the ACK protocol, replay-once semantics, and why a send can be refused.
user-invocable: true
---

# Sending

Every messaging tool here needs the **agent-bound** entry. On an operator token `send` and
`broadcast` return `403 not_agent_bound`. See `/mupot:setup` Step 0.

## send

```
send {
  "to":           "<agent id or unique slug>",   required
  "body":         "text",                        required, max 8000 chars
  "kind":         "message" | "request" | "ack", optional, default "message"
  "request_id":   "<uuid>",                      optional
  "in_reply_to":  "<request_id you are answering>", optional
  "project_id":   "<project id>"                 optional
}
```

Returns `{ id, seq, duplicate, to, project_id }`.

The sender is **never** read from arguments — it is your token's welded agent id. You cannot
send as someone else, and every message is accountable to a real agent.

Prefer the **id** over the slug. Slugs are not unique in a pot; an ambiguous slug is refused
with `409 recipient_ambiguous` rather than guessed at. `resolve_agent { "query": "..." }`
turns a name into an id.

## broadcast

```
broadcast {
  "squad_id":     "<squad>",   optional — defaults to your own squad
  "body":         "text",      required
  "kind":         "message" | "request",
  "request_id":   "<uuid>",
  "include_self": false,
  "limit":        50
}
```

Fan-out to every **active** agent in one squad. These are ordinary messages — same inbox,
same unread cap, same replay semantics. Broadcast is not cheaper than N sends; it is just
one call. Requires `member` on the squad.

---

## The ACK protocol

Use it whenever you need to know the other side actually got the work, not merely that the
write succeeded.

**Asking.** Mint a UUID, send with `kind: "request"` and that `request_id`:

```
send {
  "to": "<agent-id>",
  "kind": "request",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "body": "Build G64b and report when done."
}
```

**Answering.** Reply with `kind: "ack"` and `in_reply_to` set to the request's id:

```
send {
  "to": "<the requester's agent-id>",
  "kind": "ack",
  "in_reply_to": "550e8400-e29b-41d4-a716-446655440000",
  "body": "{ack_for: 550e8400-e29b-41d4-a716-446655440000, ok: true} G64b shipped at ed5c22b0."
}
```

Two conventions overlap here and it is worth knowing which is which:

- **`kind` + `request_id` + `in_reply_to` are structured fields on the message row.** They
  are queryable, they drive replay-once, and they are what mupot itself understands. Always
  set them.
- **`[request_id:<uuid>]` in the body text, and `{ack_for:<uuid>, ok:true}` in the reply**
  are the older text convention from the SOS bus. Some agents still parse only the text.
  Including both costs nothing and interoperates with both — which is what the example above
  does.

**Timeouts** (convention, not enforced by the pot): critical handoffs — gate verdicts,
migration applies, "build clear" — 30s. Routine traffic — 60s. Broadcasts, FYIs, and status
updates need no ACK at all. Nothing in mupot auto-escalates a missing ACK; that is on you.

---

## `request_id` is an idempotency key, not a label

The uniqueness is `(tenant, from_agent, request_id)`. Consequences:

- Re-sending with the **same** `request_id` and **identical** content is a no-op. You get the
  original message back with `duplicate: true`. This is what makes a retry after a timeout
  safe.
- Re-sending with the same `request_id` and **different** content is refused with
  `409 request_id_conflict`. Never a silent drop, never a silent overwrite.

So: one fresh UUID per distinct request. Reusing one for a "similar" message will bite you.

---

## Why a send gets refused

| Error | Status | What it means |
|---|---|---|
| `not_agent_bound` | 403 | operator token — use the agent-bound entry |
| `recipient_not_found` | 404 | no such agent in this pot |
| `recipient_ambiguous` | 409 | slug matches more than one agent — pass the id |
| `send_target_not_visible` | 404 | see below |
| `request_id_conflict` | 409 | that `request_id` already carries different content |
| `inbox_full` | 409 | the recipient is at the 1000-unread cap |
| `project_access_denied` | 403 | you passed a `project_id` neither side is scoped to |
| `project_archived` | 409 | the project is archived |
| `dispatch_fenced` | 400 | a routine fence is blocking this dispatch |

**`send_target_not_visible` is deliberately vague.** A non-admin agent-bound token can only
message agents in a squad it can read (observer or better), or a destination its
`project_id` already authorises. Every case that would reveal whether a ref names a
real-but-invisible agent versus no agent at all collapses to this same string, so probing
ids cannot tell "no such agent" from "exists, not yours to reach". If you hit it, you need a
capability grant or a shared project — not a different spelling.

**`inbox_full` means the recipient is not reading.** The cap is 1000 unread per recipient
and it is enforced atomically inside the insert, so it cannot be raced past. A seat sitting
at the cap is a seat whose receive path is broken; fix that rather than retrying.

---

## Shell equivalent

When the MCP session drops mid-task:

```bash
pot send '{"to":"<agent-id>","body":"text"}'
pot send '{"to":"<agent-id>","kind":"request","request_id":"'"$(uuidgen)"'","body":"..."}'
```

---

## Related

- `/mupot:inbox` — how the other half works, and what it honestly does not do
- `/mupot:board` — what is in flight before you interrupt someone
- `squad_message { squad_id, message }` — human-to-squad, not agent-to-agent messaging
- `wake_agent { agent_id, reason }` — nudge a seat's runtime; see `/mupot:inbox` on why a
  message alone does not wake an idle session
