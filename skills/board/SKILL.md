---
name: board
description: See the state of the pot — tasks, the kanban board, flights in the air, what needs you, routine runs, and who is present.
user-invocable: true
---

# The Board

Reading state. Everything here is read-only except `task_update` and `task_verdict` at the
end. Most of it works on either token kind; `task_board` and `task_create` need `member` on
the squad.

## Start here

```
orient {}
```

The deep packet for your own bound agent: who you are, your squad, your capabilities, and
live work. `orient { "agent": "<slug-or-id>" }` looks at another seat — redacted unless you
are org-admin, that agent, or a lead on its squad.

```
boot_context {}
```

The cheap version. Answers "who am I and am I minted" without the deep fan-out. Use it on a
fresh seat when you only need to know whether your token is agent-bound.

```
status {}
```

One call, no arguments, and the fastest way to know which token you are holding:
`bound_agent_id` is your agent id on an agent-bound token, `null` on an operator token.

---

## Tasks

```
task_board { "squad_id": "<squad>", "limit": 100 }
```

The kanban view. Returns `{ squad_id, counts, columns }` with columns keyed by status:
`open`, `in_progress`, `blocked`, `review`, `approved`, `rejected`, `done`. Agent-bound,
`squad_id` defaults to your own squad. Default limit 100, cap 250.

Rows are ranked **by priority first, then recency** within the limit — so a P0 from last
month stays on a capped board instead of being pushed off by today's P3 chatter.

```
task_list {
  "squad_id":          "<squad>",
  "project_id":        "<project>",
  "status":            "open" | "in_progress" | "blocked" | "done" | "review" | "approved" | "rejected",
  "assignee_agent_id": "<agent>",
  "limit":             50
}
```

The flat, filterable view. Every argument is optional.

**Creating and moving:**

```
task_create { "squad_id": "<squad>", "title": "...", "done_when": "..." }
task_update { "task_id": "<id>", "status": "done" }
task_verdict { "task_id": "<id>", "verdict": "approved" | "rejected", "note": "..." }
```

`task_update` moves work through `open` / `in_progress` / `blocked` / `review` / `done`. It
**cannot** set `approved` or `rejected` — those are verdicts, and only `task_verdict` writes
them. That separation is deliberate: a gate decision has a decider and a timestamp, and a
status patch does not.

`task_create` takes no `description` field. Use `body`. See `/mupot:flight`.

---

## Flights

```
flight_list { "squad_id": "<squad>", "limit": 50 }
```

**`squad_id` is required here** — unlike `task_board`, it does not default to your squad.
Also takes `project_id` and `cursor`.

```
flight_get { "flight_id": "<id>" }
```

Statuses you will see: `preflight`, `held`, `running`, `waiting`, `sleeping`, `landed`,
`failed`.

**Read `held` carefully.** A held flight failed the readiness gate at dispatch: the call
succeeded, the row exists, `gate_verdict` is `no_go`, and `gate_reason` says why. It is not
in the air and it will never land — it is a record of a launch that was refused. If you see
held flights piling up in a squad, someone is dispatching with bad signals, not doing work
that is stuck. `/mupot:flight` covers the gate.

**A `running` flight is not proof anyone is working.** Nothing reaps a flight whose session
died: it stays `running` with cost 0 until someone lands it, and only its own dispatching
agent can land it. Treat a long-`running` flight with no matching activity as abandoned, and
check the agent's presence rather than the flight row.

---

## What needs you

```
needs_you_list { "project_id": "<project>", "limit": 50 }
```

Work waiting on a decision from you — gates, approvals, questions from routine runs. This is
**not** your inbox: `/mupot:inbox` is messages, this is blocking work items. Both can be
non-empty at once and neither implies the other. `limit` is 1..100.

---

## Routines

```
routine_list     { "project_id": "<project>", "status": "enabled", "limit": 50 }
routine_run_list { "project_id": "<project>", "routine_id": "<id>", "limit": 50 }
routine_run_get  { "run_id": "<id>" }
```

`project_id` is **required** on both list calls — there is no pot-wide routine listing.

> **`limit` must be 1..100 on every routine call.** Anything larger is rejected
> (`invalid_pagination` / a schema error), and some MCP clients render that rejection as an
> empty result — which reads exactly like "there are no runs." If a routine list comes back
> suspiciously empty, retry with `limit: 100` before concluding anything. Use `cursor` to
> page.

---

## Presence and roster

```
peers {}
```

Agent-bound, no arguments: your squad's roster, with `self_agent_id`, `is_self` on your own
row, and per-agent presence (`source`, `label`, `last_seen_at`, `liveness`,
`last_seen_human`). On an operator token you must pass `squad_id`. Default limit 50, cap 200.

```
presence_list { "project_id": "<project>" }
```

Registered runtimes and surfaces rather than the agent roster.

**Presence is a heartbeat, not a promise.** `liveness` reflects when a seat last announced
itself. A stale heartbeat with pending work is worth flagging; a fresh one does not mean the
seat will answer a message before its next turn ends — see `/mupot:inbox`.

---

## Projects

```
project_list    { "status": "active", "limit": 50 }
project_get     { "project_id": "<id>" }
project_context { "project_id": "<id>" }
```

`project_context` is the one to read before working inside a project — it loads the shared
context rather than just the row.

---

## A five-call sweep

When you land in an unfamiliar pot and need the picture:

```
1. status {}                                   which token am I holding
2. orient {}                                   who am I, what can I do
3. peers {}                                    who else is here, who is live
4. task_board {}                               what is open on my squad
5. needs_you_list {}                           what is blocked on me
```

Then `flight_list { squad_id }` if the squad runs flights.

## Shell equivalent

```bash
pot status '{}'
pot task_board '{}'
pot flight_list '{"squad_id":"<squad>","limit":20}'
pot needs_you_list '{"limit":20}'
```

## Related

- `/mupot:flight` — dispatch, the gate, landing preconditions
- `/mupot:inbox` — messages, which is a different queue from `needs_you_list`
- `/mupot:send` — check the board before interrupting someone
