#!/usr/bin/env bash
set -uo pipefail
# A Claude Code status line command that keeps the last non-null rate_limits payload, for claude-usage.sh.
#
# Usage: claude-statusline-save.sh [command [args...]]
# Env:   CLAUDE_STATUSLINE_FILE  where to save (default ~/.claude/statusline-rate-limits.json)
#
# Claude Code runs the configured statusLine command and writes a JSON object to its stdin. The first
# payload of a session has rate_limits null; later ones carry the five-hour and the weekly window. This
# reads the payload, saves {taken_at, rate_limits} when rate_limits is present, and then runs the
# command given (your own status line), handing it the same payload on stdin and passing on its output
# and exit status. With no command it prints nothing.
#
# Only rate_limits is kept: the rest of the payload (working directory, session, transcript path) is not
# copied. A null payload never overwrites a saved one. The file is written whole and moved into place, mode
# 600. A save that fails changes nothing about the status line: it is drawn and the exit status is the
# wrapped command's (0 with none).
#
# In settings.json:  "statusLine": { "type": "command", "command": "/path/to/scripts/claude-statusline-save.sh" }
# or wrapping your own:                                    "command": "/path/to/scripts/claude-statusline-save.sh ~/bin/my-line"

SAVE_FILE="${CLAUDE_STATUSLINE_FILE:-$HOME/.claude/statusline-rate-limits.json}"

save() { # <payload>
  command -v jq > /dev/null 2>&1 || return 0
  local kept tmp
  kept="$(jq -c --argjson at "$(date +%s)" \
    'select(type == "object" and (.rate_limits | type) == "object") | { taken_at: $at, rate_limits }' <<< "$1" 2> /dev/null)" || return 0
  [[ -n "$kept" ]] || return 0
  mkdir -p "$(dirname "$SAVE_FILE")" 2> /dev/null || return 0
  tmp="$(umask 077 && mktemp "$SAVE_FILE.XXXXXX" 2> /dev/null)" || return 0
  if printf '%s\n' "$kept" > "$tmp" 2> /dev/null && mv -f "$tmp" "$SAVE_FILE" 2> /dev/null; then :; else rm -f "$tmp"; fi
  return 0
}

main() {
  local payload
  payload="$(cat)"
  save "$payload"
  if [[ $# -gt 0 ]]; then
    printf '%s' "$payload" | "$@"
  fi
}

main "$@"
