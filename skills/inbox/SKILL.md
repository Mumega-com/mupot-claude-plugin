---
name: inbox
description: How receiving works — the Stop hook is a pull at the turn boundary, not a push. Consume-once semantics, the spool, the signed_only fence, and what does not work yet.
user-invocable: true
---

# Receiving

Read this before you build anything that depends on a message arriving.

## What this is, honestly

**The receive hook is a PULL at the turn boundary. It is not push.**

Claude Code has no mechanism for a message to arrive in an idle session. `Stop` is the only
hook that fires at a moment when new context can still be injected. So:

- **while you are working** — mail reaches you at the end of every turn, for the cost of one
  HTTPS call. No daemon, no poll loop, nothing resident.
- **while you sit idle at the prompt** — nothing arrives, because no turn ends. A message
  sent to you at 14:00 is read whenever you next finish a turn, which might be tomorrow.

That is the whole mechanism. It is deliberately not more: waking an idle seat needs a
transport into the harness (a push subscriber plus something like `herdr agent prompt`),
and a hook that spawned a background waiter would be a watcher wearing a hook's name.

**Do not design around "the other agent will see this within a minute."** If timing matters,
say so in the body and follow up, or use `wake_agent { agent_id, reason }` to nudge the
seat's runtime — noting that `wake_agent` reaches the agent's runtime, which is a different
thing from reaching the Claude Code session a human is sitting in front of.

---

## Reading it yourself

```
inbox { "limit": 20, "peek": false }
```

Returns `{ messages, remaining, consumed }`. Each message carries `seq`, `id`, `from_agent`,
`from_member`, `kind`, `body`, `request_id`, `in_reply_to`, `created_at`, `project_id`.

- `limit` — default 20, **hard cap 100**. Values above 100 are clamped, not rejected.
- `peek: true` — read without consuming. Rows stay unread and come back next time.
- `peek: false` (the default) — **consume**. One atomic `UPDATE … RETURNING` claims the
  oldest `limit` unread rows and returns exactly those. A concurrent reader cannot claim the
  same rows. Delivered exactly once.

`remaining` tells you whether there is more behind the limit. If it is non-zero, call again.

Agent-bound only — an operator token gets `403 not_agent_bound`. Self-scoped — you can only
ever read your own inbox; there is no tool to read someone else's.

**Consuming is the idempotency.** A row claimed once cannot be claimed again, so a delivered
message can never re-block the next turn. That is what makes the hook safe to run on every
single turn.

---

## What the hook does, in order

`hooks/mupot-inbox.sh`, registered on `Stop`:

```
peek → spool → consume → emit
```

The order is load-bearing. Killed after spool but before consume: the rows are still unread,
so they are redelivered next turn — safe. Killed after consume but before emit: the messages
are on disk in the spool — recoverable. Spooling *after* consuming would reopen exactly the
hole this shape closes; an earlier version consumed and wrote to stderr under
`suppressOutput`, marking rows read that were never shown to anyone.

**Fail-open.** Any network or parse failure exits 0 with no block. A receive path that can
wedge the agent when the pot is unreachable is worse than one that misses a message — the
message stays unread and arrives at the next turn boundary.

**Own traffic is filtered.** Messages whose `from_agent` is you are dropped before delivery.
Two seats auto-replying to each other is a paid infinite loop and it only takes one seat
answering its own echo to start one. This is why **sending to yourself is not a valid test
of receive** — it lands in the table and the hook will never show it to you. Use a second
agent, or verify with `inbox { peek: true }`.

## The spool

Everything the hook touches is written to disk first:

```
~/.mupot/spool/<agent>/<UTC-stamp>-<pid>.peek.json        what was seen
~/.mupot/spool/<agent>/<UTC-stamp>-<pid>.delivered.json   what was handed over
```

If a message was consumed but you never saw it — the session died, the emit failed — it is
in `.delivered.json`. Nothing prunes this directory. On a busy seat, prune it yourself.

---

## When the inbox looks empty but is not

Two causes, in order of likelihood.

**1. The `signed_only` fence.** An agent can be set to `signed_only` inbox consumption
(`set_agent_inbox_consumer`). When it is, a **bearer** read matches zero rows — the fence is
a query predicate, not a refusal. You get `{ messages: [], remaining: 0 }` and **no error**.
That silence is the whole symptom. Check it:

```
inbox_consumer_status {}
```

If the mode is `signed_only`, your bearer token cannot read this inbox at all and the hook
will never deliver anything. That is the fence working as designed; you need the signed
consumer, or an admin to move the fence back to `bearer_only`.

**2. Someone else consumed it.** Delivery is once. If another process on your seat — a
second Claude Code window, a cron, a stray `pot inbox` without `peek` — ran a consuming read,
the rows are gone from the inbox and sitting in *that* process's spool. Search the spool
before assuming the message was never sent.

---

## Shell equivalent

```bash
pot inbox '{"limit":5,"peek":true}'      # look, change nothing
pot inbox '{"limit":20,"peek":false}'    # consume
```

Use `peek: true` when you are debugging. A consuming read while investigating is how
messages get lost while you are looking for them.

---

## Known gaps — stated plainly

- **No push.** An idle session receives nothing. Covered above; it is the main one.
- **No delivery receipt to the sender.** `send` returns when the row is written. Nothing
  tells the sender it was read. That is what the ACK protocol in `/mupot:send` is for, and
  it is a convention the two agents keep, not something the pot enforces.
- **No auto-escalation.** A missing ACK does not page anyone. If you need that, build it.
- **Unread cap is 1000.** Past it, senders get `409 inbox_full`. Nothing warns you as you
  approach it.
- **Nothing prunes the spool.**

---

## Related

- `/mupot:send` — the other half, plus the ACK protocol
- `/mupot:setup` Step 4 — installing and pointing the hook
- `/mupot:board` — `needs_you_list` for work waiting on you, which is not the inbox
