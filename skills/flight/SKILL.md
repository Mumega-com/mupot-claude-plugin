---
name: flight
description: Dispatch and land a flight — the real meta_json and signals_json shapes, the readiness gate and its threshold, budget rules, and why landing is refused.
user-invocable: true
---

# Flights

A flight is one bounded unit of expensive work: dispatch it, do it, land it with what it
cost. Before it launches, a cheap gate decides GO / NO-GO so no expensive tokens burn on a
flight that would wander or run cold.

Both tools need the **agent-bound** entry. An operator token gets
`409 agent_binding_required`.

## Before you can dispatch

A flight must reference **at least one existing task**. `meta.task_ids` cannot be empty, and
every id in it must resolve to a real task in one of the flight's squads. So the order is
always: create the task, then dispatch the flight that closes it.

```
task_create {
  "squad_id":  "<squad>",
  "title":     "Wire the receive hook",
  "done_when": "hooks.json registered and a message from a second agent is delivered"
}
```

`squad_id`, `title`, `done_when` are all required. `done_when` must be a non-empty
**verifiable success predicate** — a checkable condition, not a restatement of the title. It
is refused empty (`400 done_when_required`).

There is **no `description` field**. The schema is `additionalProperties: false`, so passing
one is a hard error. The long-form field is `body`.

---

## flight_dispatch

```
flight_dispatch {
  "squad_id":         "<squad>",              required
  "goal":             "one sentence",         required, ≤2000 chars
  "meta_json":        "<JSON string>",        required — see below
  "signals_json":     "<JSON string>",        required — see below
  "budget_micro_usd": 0,                      optional, default 0
  "project_id":       "<project>"             optional
}
```

`meta_json` and `signals_json` are **JSON strings**, not objects. Serialise them.

### meta_json — `mupot.flight.meta/v1`

```json
{
  "schema": "mupot.flight.meta/v1",
  "goal_id": "G64b",
  "objective_id": "O-2026-Q3-receive",
  "squad_ids": ["<squad-id>"],
  "task_ids": ["<task-id>"],
  "done_when": ["a message from a second agent is delivered at the turn boundary"],
  "artifact_refs": [],
  "receipt_refs": [],
  "confidentiality": "internal",
  "publication_target": "none",
  "parent_flight_id": null
}
```

Every field above is required and validated. The whole object is rejected outright — with
`400 invalid_flight_meta`, no detail on which field — if any of these hold:

| Rule | |
|---|---|
| unknown key present | schema is closed |
| `schema` ≠ `mupot.flight.meta/v1` | |
| `goal_id`, `objective_id` empty or > 200 bytes | |
| `squad_ids` empty, > 8 items | must include `squad_id` **and** your own agent's squad |
| `task_ids` empty, > 200 items | each must exist, in one of `squad_ids` |
| `done_when` empty, > 100 items, any item > 1000 bytes | |
| `artifact_refs` / `receipt_refs` > 200 items or > 2000 bytes each | may be empty arrays |
| `confidentiality` not `private` / `internal` / `public-projection` | |
| `publication_target` not `none` / `inkwell-draft` / `mumega.com` | |
| `parent_flight_id` not a string and not `null` | `null` is required if absent, not omitted |
| whole object > 16 KB | |

Two optional extras exist for routine-driven flights: `routine_run_id` and
`routine_revision` (integer ≥ 1).

If `project_id` is set on the dispatch, every referenced task must already carry that same
`project_id`, or you get `409 flight_task_project_mismatch`.

### signals_json — the gate's inputs

**camelCase.** Missing fields default to `false` / `0`, which fails the gate — so send all of
them.

```json
{
  "contextComplete": true,
  "toolsReachable": true,
  "budgetRemainingMicroUsd": 0,
  "budgetEstimateMicroUsd": 0,
  "recentProgress": 0.7,
  "progressPerStep": 0.6,
  "wastePerStep": 0.2,
  "stepSeconds": 60
}
```

> **The two budget signals are overwritten server-side.** Whatever you send for
> `budgetRemainingMicroUsd` and `budgetEstimateMicroUsd` is discarded and replaced with the
> policy ceiling and your requested `budget_micro_usd`. Send them for schema completeness;
> do not try to tune the gate with them. The six that actually matter are the other six.

`recentProgress`, `progressPerStep`, `wastePerStep` are clamped to `[0, 1]`.

---

## The gate

**GO requires all five hard checks to pass AND a readiness score ≥ 0.5.** A high score does
not rescue a failed check, and passing checks do not rescue a low score.

| Check | Passes when | NO-GO reason |
|---|---|---|
| context complete | `contextComplete: true` | `context_incomplete` |
| tools reachable | `toolsReachable: true` | `tools_unreachable` |
| budget headroom | remaining ≥ estimate (server-computed) | `insufficient_budget` |
| progress beats waste | `progressPerStep ≥ wastePerStep` | `would_wander` |
| cache stays warm | `stepSeconds ≤ 300` | `cache_would_cool` |
| readiness | score ≥ 0.5 | `low_readiness` |

The score is a **weighted geometric mean**, so it is fail-closed by construction — any
factor near zero drags the whole score down and no factor can be averaged away:

| Factor | Value | Weight |
|---|---|---|
| `contextComplete` | 1 if true, else 0.001 | 2 |
| `toolsReachable` | 1 if true, else 0.001 | 2 |
| budget ratio | `remaining / estimate`, clamped to 1; 1 when estimate is 0 | 1 |
| progress share | `progressPerStep / (progressPerStep + wastePerStep)` | 1.5 |
| `recentProgress` | as given, clamped | 1 |
| step fit | 1 if `stepSeconds ≤ 300`, else `300 / stepSeconds` | 1 |

The signals block above scores **0.911** → GO.

**The trap:** set `recentProgress` to `0` and the same block scores **0.422** → HELD, with
`low_readiness`, even though every hard check passed. A zeroed soft signal is not neutral —
it is a claim that you have made no recent progress, and the geometric mean takes that
seriously. If you genuinely have no history, send a modest honest number, not zero.

A NO-GO does not error. The call **succeeds**, and you get a flight row with
`status: "held"`, `gate_verdict: "no_go"`, and `gate_reason` listing the failures. Read the
result. A held flight is not in the air and **cannot be landed** — `409 flight_not_in_air`.
Fix the signals and dispatch again.

---

## Budgets

Leave `budget_micro_usd` at 0 unless you actually need spend accounted. The moment it is
above zero, three things change:

1. **Capability rises from `member` to `lead`** — on *every* squad in `meta.squad_ids`, not
   just the dispatching one. Otherwise `403 flight_budget_forbidden`.
2. **Both your bound agent and every referenced squad must have a positive integer
   `budget_cap_cents`.** If any is missing or zero: `409 flight_budget_policy_missing`.
3. **The ceiling is `min(all caps) × 10,000` micro-USD** (1 cent = 10,000 micro-USD).
   Exceeding it: `409 flight_budget_exceeds_cap`, with `cap_micro_usd` in the detail.

> **`budget_cap_cents` is settable only at creation.** `create_agent` and `create_squad`
> accept it. `update_agent` does **not** — the field is not in its schema, and the schema is
> `additionalProperties: false`, so passing it is a hard error rather than a silent no-op.
> There is **no `update_squad` tool at all**. A squad or agent created without a cap can
> never dispatch a budgeted flight, and the only remedy is to create a new one. Set caps at
> creation time, every time.

---

## flight_land

```
flight_land {
  "flight_id":      "<id>",   required
  "cost_micro_usd": 0,        required — non-negative integer
  "score":          0.8       optional — 0..1
}
```

Landing is refused unless **all** of these hold:

| Requirement | Failure |
|---|---|
| the flight is yours (dispatched by your bound agent) | `404 flight_not_found` |
| status is `running`, `waiting`, or `sleeping` | `409 flight_not_in_air` |
| you hold `member` on the flight's squads | `403 forbidden` |
| `cost_micro_usd ≤ flight.budget_micro_usd` | `409 flight_budget_exceeded` |
| **every task in `meta.task_ids` is `status: "done"`** — and where a task has a `gate_owner`, its latest verdict is `approved` | `409 flight_tasks_incomplete`, with the offending `task_ids` |
| every task's `project_id` matches the flight's | `409 flight_task_project_conflict` |

> **A flight dispatched with no budget can only land with `cost_micro_usd: 0.`** The budget
> is 0, and cost must not exceed budget. This surprises people who dispatch cheaply and then
> try to report real spend. Decide the budget at dispatch.

So the close-out sequence is always: finish the work → `task_update { task_id, status:
"done" }` for each task → `task_verdict` if the task is gated → **then** `flight_land`.

---

## Reading flights back

```
flight_get  { "flight_id": "<id>" }
flight_list { "squad_id": "<squad>", "limit": 50 }      # squad_id is REQUIRED here
```

`flight_list` also takes `project_id` and `cursor`. See `/mupot:board`.

---

## Worked sequence

```
1. task_create      { squad_id, title, done_when }              → task_id
2. flight_dispatch  { squad_id, goal, meta_json, signals_json } → flight_id + preflight
3. read preflight.go — if false, read preflight.reasons and fix the signals
4. ... do the work ...
5. task_update      { task_id, status: "done" }
6. flight_land      { flight_id, cost_micro_usd: 0, score: 0.8 }
```

## Shell equivalent

```bash
pot flight_dispatch "$(jq -nc --arg m "$META" --arg s "$SIGNALS" \
  '{squad_id:"<squad>",goal:"...",meta_json:$m,signals_json:$s}')"
pot flight_land '{"flight_id":"<id>","cost_micro_usd":0}'
```

`jq -nc` is the easy way to get correctly escaped JSON strings inside JSON.

## Related

- `/mupot:board` — what is in the air right now, and what needs you
- `/mupot:setup` Step 2b — setting `budget_cap_cents` at creation, before it is too late
