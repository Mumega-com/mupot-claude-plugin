# mupot Claude Code Plugin — conventions for agents working in this repo

This repository **is** a Claude Code plugin. It is not a library, not a service. Everything
in it ships to customers who install it from a marketplace and read it to learn how mupot
works. Write accordingly.

## What is here

```
.claude-plugin/plugin.json       plugin manifest
.claude-plugin/marketplace.json  marketplace manifest (repo: Mumega-com/mupot-claude-plugin)
bin/pot                          session-free shell client, agent-bound calls
hooks/mupot-inbox.sh             Stop hook — pulls the inbox at the turn boundary
hooks/hooks.json                 registers the Stop hook on plugin install
skills/<name>/SKILL.md           six user-invocable skills
README.md                        install + the two-token rule up front
```

## The one thing every file must get right

**A mupot token can provision OR message, never both.** Operator (`bound_agent_id: null`) →
`mint_agent_token`, `grant_agent_capability`, `revoke_agent_token`, `list_agent_tokens`,
`provision_agent_connection`; `send`/`inbox` refuse with `403 not_agent_bound` and
`flight_dispatch`/`flight_land` with `409 agent_binding_required`. Agent-bound → the reverse,
refusing the five provisioning tools with `403 operator_principal_required`.

Any example, snippet, or troubleshooting row that ignores this is wrong. When you add
documentation for a tool, state which token kind it needs.

## House style

Follow the tone already in `bin/pot` and `hooks/mupot-inbox.sh`: explain *why* a thing is
shaped the way it is, name the failure it prevents, and never write marketing.

- **No marketing.** No "seamless", no "powerful", no "just works". If it does not work, say
  so in the same paragraph where you say what it does.
- **Every skill carries a "what does not work" note** where one applies. OAuth first
  connect on a personal team invite makes the agent. `mint_agent_token` returns a claim;
  `reveal_credential_claim` gives the value once. `update_agent` and `update_squad` accept
  `budget_cap_cents`. This plugin does not implement idle wake or push. During a turn,
  check inbox if the connection is allowed to read it. These are load-bearing and must not
  be softened in an edit.
- **Verify the mechanism before documenting it.** Read the mupot source or call the tool.
  Docstrings are claims about the past; behaviour changes and comments do not.
- **Exact error strings.** `not_agent_bound`, `operator_principal_required`,
  `agent_binding_required`, `flight_budget_policy_missing`, `directory_channel_zero_capability`,
  `flight_tasks_incomplete`, `request_id_conflict`, `send_target_not_visible`. Customers
  search for these. Spell them exactly as the server emits them.
- **Placeholders only.** No real token, agent id, squad id, project id, or tenant slug in any
  file, ever — including in an example that "obviously" is not real. Use `<slug>`,
  `${SEAT_TOKEN}`, `<squad-id>`. Never paste a key into chat, a shell command, or a
  `--header` argument. Keep a headless key in a mode `600` file and reference it from the
  environment.
- **`~/.mupot/` only.** Never reference `~/.fleet`, `~/SOS`, tmux session names, or any other
  host-specific layout. Those belong to one operator's machine and must not leak into a
  customer plugin.

## Skill format

YAML frontmatter, then Markdown:

```yaml
---
name: <dirname>
description: <one line — what it covers and when to reach for it>
user-invocable: true
---
```

`name` must equal the directory name. The skill is then reachable as `/mupot:<name>`.
Cross-link siblings as `/mupot:setup`, `/mupot:flight`, and so on.

## Shell files

- `bash -n` every shell file you write or edit, before committing. No exceptions.
- The hook is **fail-open**: any network or parse failure exits 0 with no block. A receive
  path that can wedge the agent when the pot is unreachable is worse than one that misses a
  message.
- The hook's order is `peek → spool → consume → emit`, and it is load-bearing. Do not
  reorder. Spooling after consuming marks rows read that nobody ever saw.
- The hook compares `from_agent` with the configured slug. An agent id and a slug are not
  the same value, so that comparison does not filter the agent's own mail. Do not document
  it as if it does, and do not change the hook in a text edit. A self-send can still start
  a reply loop.
- Neither `pot` nor the hook may echo a token, to stdout, stderr, or a log.
- Token filenames are strictly `<slug>-agent-bound.token`. Do not add a fallback to
  `<slug>.token` — a near-miss filename holding a credential for a different agent makes the
  caller act as that agent, silently.

## Verified tool shapes

Do not change these in the docs without re-checking against the mupot source.

- `task_create` requires `{squad_id, title, done_when}`. There is **no `description` field**
  — the schema is `additionalProperties: false`; the long-form field is `body`.
- `flight_dispatch` requires `{squad_id, goal, meta_json, signals_json}`. Both `*_json` are
  JSON **strings**. `meta_json` is `mupot.flight.meta/v1` with a closed key set;
  `task_ids` and `squad_ids` must be non-empty. `signals_json` is camelCase, and its two
  budget fields are overwritten server-side.
- The readiness gate is five hard checks **and** score ≥ 0.5. A NO-GO is not an error: the
  flight row exists with `status: "held"`, `gate_verdict: "no_go"`.
- `flight_land` takes `{flight_id, cost_micro_usd, score?}` and refuses unless every task in
  `meta.task_ids` is `done` (and approved, where gated) and `cost ≤ budget`.
- `inbox` takes `{limit, peek}`; default limit 20, cap 100; `peek: false` consumes atomically.
- Routine list calls require `project_id` and cap `limit` at 100.

## Releasing

Bump `version` in **both** `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
— they are read by different consumers and drift is invisible until someone installs a stale
version.

Never commit `.code-review-graph/` (gitignored — it embeds absolute local paths).
