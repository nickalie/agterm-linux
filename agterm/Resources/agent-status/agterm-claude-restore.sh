#!/usr/bin/env bash
# agterm-claude-restore — keep an agterm pane reattaching to the Claude Code session it was running.
#
#   agterm-claude-restore.sh session-start   # pin `claude --resume <id>` for the next launch
#   agterm-claude-restore.sh session-end     # drop that pin when you left claude on purpose
#
# The restore capture alone re-runs the pane's foreground argv, and a bare `claude` starts an EMPTY
# session — so reattaching needs the live session id, which only the agent knows. This hook writes it
# into the pane's `session restore` override on every start, so the override always names the session
# you were last in; it is consumed at the next launch and never touches the running pane.
#
# Outside agterm this is a silent no-op, so it is safe to call from any hook.
#
# As a hook it must never interfere with the agent: stdout/stderr are suppressed (Claude Code injects a
# SessionStart hook's stdout into the prompt context) and it always exits 0 (a non-zero exit can block
# the turn).
#
# agtermctl resolution order (the binary that talks to the control socket):
#   1. $AGTERMCTL — an explicit override the caller set.
#   2. the absolute bundled-binary path the installer bakes in.
#   3. `agtermctl` on PATH — the fallback when nothing above resolved.
set -u

[ -n "${AGTERM_SESSION_ID:-}" ] || exit 0   # not inside agterm: nothing to do

action=${1:-}
[ -n "$action" ] || exit 0

# the hook payload arrives on stdin as JSON; there is no $CLAUDE_SESSION_ID to read instead. Newlines
# are folded so a pretty-printed payload still matches as one line.
payload=$(cat 2>/dev/null | tr '\n' ' ')

# only the two flat string fields this hook reads, so a jq/python dependency the agent's environment may
# not carry would buy nothing.
json_field() {
  printf '%s' "$payload" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n 1 \
    | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# the stable per-surface token plus the role it falls back to when that token no longer resolves.
pane_args=()
[ -n "${AGTERM_PANE:-}" ] && pane_args+=(--pane "$AGTERM_PANE")
[ -n "${AGTERM_PANE_ID:-}" ] && pane_args+=(--pane-id "$AGTERM_PANE_ID")
socket_args=()
[ -n "${AGTERM_SOCKET:-}" ] && socket_args+=(--socket "$AGTERM_SOCKET")

# --socket is a SUBCOMMAND option, so it comes AFTER `session restore`. A scratch pane and a split that
# no longer exists are both refused agterm-side; the pin is best-effort, so swallow that.
restore() {
  "${AGTERMCTL:-agtermctl}" session restore "$@" \
    --target "$AGTERM_SESSION_ID" \
    "${socket_args[@]+"${socket_args[@]}"}" \
    "${pane_args[@]+"${pane_args[@]}"}" >/dev/null 2>&1 || true
}

case "$action" in
session-start)
  sid=$(json_field session_id)
  # the pin is sticky and persisted, so a malformed id would be re-typed on every launch until
  # cleared. Require the UUID shape and hex digits, and leave the existing pin alone otherwise.
  case "$sid" in
  ????????-????-????-????-????????????) ;;
  *) exit 0 ;;
  esac
  case "$sid" in
  *[!0-9a-fA-F-]*) exit 0 ;;
  esac
  restore "claude --resume $sid"
  ;;
session-end)
  # only a DELIBERATE exit unpins, so the pane you left at a shell comes back as one. Every other
  # reason — `other` covers a killed process, which is exactly what quitting agterm does — keeps the
  # pin, since that is the restart this hook exists for.
  case "$(json_field reason)" in
  logout | prompt_input_exit) restore --clear ;;
  esac
  ;;
esac
exit 0
