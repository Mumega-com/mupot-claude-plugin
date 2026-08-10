#!/usr/bin/env bash
# mupot receive — Claude Code Stop hook. Runs once when a turn ends.
#
# WHAT THIS IS, STATED HONESTLY
#
# This is a PULL at the turn boundary, not a push. Claude Code has no mechanism for a
# message to arrive in an idle session — Stop is the only hook that fires at a moment
# when new context can still be injected. So:
#
#   • while you are working, mail reaches you at the end of every turn, for the cost of
#     one HTTPS call — no daemon, no poll loop, nothing resident
#   • while you are idle at the prompt, nothing arrives, because no turn ends
#
# Waking an idle seat needs a transport into the harness (a push subscriber plus
# `herdr agent prompt`, or equivalent). That is deliberately NOT in this hook: a hook
# that spawned a background waiter would be a watcher wearing a hook's name.
#
# DELIVERY IS CONSUME-ONCE, AND THAT IS THE LOOP GUARD
#
# mupot's `inbox` with peek:false is one atomic UPDATE...RETURNING — a row is claimed
# exactly once. So consuming IS the idempotency: a delivered message cannot re-block the
# next Stop. That is what makes this safe to run on every single turn.
#
# ORDER IS LOAD-BEARING: peek → spool → consume → emit.
#   killed after spool, before consume → still unread, redelivered next turn. Safe.
#   killed after consume, before emit  → the message is in the spool. Recoverable.
# Spooling after consuming reopens the exact hole this shape exists to close: an earlier
# version consumed and wrote to stderr under suppressOutput, marking rows read that were
# never shown to anyone.
#
# FAIL-OPEN: any network or parse failure exits 0 with no block. A receive path that can
# wedge the agent when the pot is unreachable is worse than one that misses a message —
# the message stays unread and arrives at the next turn boundary.
#
# Install: see /mupot:setup. Config: MUPOT_AGENT, MUPOT_TOKEN_DIR, MUPOT_ENDPOINT.

set -uo pipefail

# WHO AM I: $1 → $MUPOT_AGENT → $AGENT_NAME → ~/.mupot/agent. The file is last and is the
# one that actually works when Claude Code was launched from a desktop icon or a session
# that never sourced a shell profile — which is the common case. No agent → exit 0, silent:
# a machine with the plugin installed but no seat configured must not be nagged every turn.
AGENT="${1:-${MUPOT_AGENT:-${AGENT_NAME:-}}}"
if [ -z "${AGENT}" ] && [ -r "${HOME}/.mupot/agent" ]; then
  AGENT="$(head -n 1 "${HOME}/.mupot/agent" | tr -d '[:space:]')"
fi
[ -n "${AGENT}" ] || exit 0

TOKEN_DIR="${MUPOT_TOKEN_DIR:-${HOME}/.mupot/agents}"
TOKEN_FILE="${TOKEN_DIR}/${AGENT}-agent-bound.token"
[ -r "${TOKEN_FILE}" ] || exit 0

TOKEN="$(cat "${TOKEN_FILE}" 2>/dev/null)"
[ -n "${TOKEN}" ] || exit 0

ENDPOINT="${MUPOT_ENDPOINT:-https://mupot.mumega.com/mcp}"
SPOOL_DIR="${MUPOT_SPOOL_DIR:-${HOME}/.mupot/spool/${AGENT}}"
LIMIT="${MUPOT_INBOX_LIMIT:-10}"
mkdir -p "${SPOOL_DIR}" 2>/dev/null || exit 0

call_inbox() {
  # $1 = peek (true|false). Never echoes the token.
  curl -sf -m 8 "${ENDPOINT}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'content-type: application/json' \
    -H "user-agent: mupot-stop-hook/0.1 (+${AGENT})" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"inbox\",\"arguments\":{\"limit\":${LIMIT},\"peek\":$1}}}" \
    2>/dev/null
}

extract() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    inner = json.loads(d["result"]["content"][0]["text"])
    msgs = inner.get("result", {}).get("messages", []) or []
except Exception:
    raise SystemExit(0)
# Never act on our own traffic. Two seats auto-replying to each other is a paid infinite
# loop, and it only needs one of them to answer its own echo to start.
me = sys.argv[1]
msgs = [m for m in msgs if m.get("from_agent") != me]
if not msgs:
    raise SystemExit(0)
print(json.dumps(msgs))
' "${AGENT}" 2>/dev/null
}

PEEKED="$(call_inbox true | extract)"
[ -n "${PEEKED}" ] || exit 0

# Spool BEFORE consuming — crash-safety invariant, do not reorder.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf '%s\n' "${PEEKED}" > "${SPOOL_DIR}/${STAMP}.peek.json" 2>/dev/null

CONSUMED="$(call_inbox false | extract)"
# If the consume failed, fall back to the peeked copy: those rows are still unread, so
# they will be redelivered — but the operator sees them this turn rather than never.
DELIVER="${CONSUMED:-${PEEKED}}"
printf '%s\n' "${DELIVER}" > "${SPOOL_DIR}/${STAMP}.delivered.json" 2>/dev/null

printf '%s' "${DELIVER}" | python3 -c '
import sys, json
try:
    msgs = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
lines = ["mupot inbox — %d new message(s), consumed (delivered once)." % len(msgs),
         "Reply with mupot `send`. If a message carries request_id, ACK with kind=ack and in_reply_to=<request_id>.",
         ""]
for m in msgs:
    lines.append(
        "- seq=%s from=%s kind=%s request_id=%s in_reply_to=%s\n  %s" % (
            m.get("seq"), m.get("from_agent"), m.get("kind"),
            m.get("request_id"), m.get("in_reply_to"),
            (m.get("body") or "").strip(),
        )
    )
print(json.dumps({"decision": "block", "reason": "\n".join(lines)}))
' 2>/dev/null

exit 0
