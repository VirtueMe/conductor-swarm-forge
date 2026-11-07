#!/usr/bin/env bash
# Notice a worker window that is waiting for a person (#168).
#
# Each worker is an interactive window; when it stops to ask something (a permission or trust
# question) nothing else says so: the card does not move and the window is in the background. This
# looks at the visible end of every worker window (not the scrollback, where an answered question would still show) and reports, once, what it finds:
#
#   <window> <task> waiting <question>    the pane ends in a numbered menu or a y/n question
#   <window> <task> quiet <minutes>       no new artifact for QUIET_AFTER minutes, and no menu seen
#
# A pane that shows something else is not guessed at: it is "quiet" if the time limit says so, and
# otherwise nothing. Report only: nothing is answered on the person's behalf.
#
# Printed once per window and finding (state in $CONDUCTOR_DIR/window-watch.seen; a window that is no
# longer flagged is forgotten, so its next stop is reported again). For each new finding it also
# leaves human-inbox/window-<window>-<timestamp>.md, colours the window red in the tmux status bar
# until it moves on, and sends a desktop notification on macOS when config.md has `notify-channel: push`.
#
# Usage: window-watch.sh
# Env:   CONDUCTOR_DIR (default: .conductor), TMUX_SESSION (default: swarm),
#        CONDUCTOR_QUIET_AFTER minutes without an artifact (default 20; 0 = never say "quiet"),
#        CONDUCTOR_WINDOW_WATCH=off to do nothing.
# Exits 0 whatever it found; it is a check, not a gate.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
SESSION="${TMUX_SESSION:-swarm}"
QUIET_AFTER="${CONDUCTOR_QUIET_AFTER:-20}"
SEEN="$CONDUCTOR_DIR/window-watch.seen"

[[ "${CONDUCTOR_WINDOW_WATCH:-on}" != off ]] || exit 0
command -v tmux > /dev/null 2>&1 || exit 0
windows="$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2> /dev/null)" || exit 0

oneline() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-200; }

# The question a numbered menu or a y/n prompt is asking, from the last lines of the pane. Prints
# nothing when the pane shows neither. Claude Code draws a menu as "❯ 1. Yes" with the question on a
# line above it ("Do you want to proceed?"); a plain "(y/n)" or "[Y/n]" question is also a wait.
pane_question() {
  local tail="$1" menu q
  menu="$(grep -n -E '^[[:space:]│]*(❯|>)[[:space:]]*1\.[[:space:]]' <<< "$tail" | tail -1 | cut -d: -f1 || true)"
  if [[ -n "$menu" ]]; then
    q="$(head -n "$((menu - 1))" <<< "$tail" | grep -v -E '^[[:space:]│╭╰─╮╯]*$' | tail -1 || true)"
    printf '%s' "${q:-a numbered question}"
    return 0
  fi
  grep -E '(\(y/n\)|\[[yY]/[nN]\]|\[[yY]es/[nN]o\])[[:space:]]*$' <<< "$tail" | tail -1 || true
}

new_seen="" findings=""
while IFS= read -r win; do
  [[ -n "$win" ]] || continue
  task="${win##*-}"
  [[ "$win" == *-* && -f "$CONDUCTOR_DIR/tasks/$task.md" ]] || continue
  pane="$(tmux capture-pane -p -t "$SESSION:$win" 2> /dev/null)" || continue
  question="$(oneline "$(pane_question "$(grep -v '^[[:space:]]*$' <<< "$pane" | tail -15)")")"
  kind="" text=""
  if [[ -n "$question" ]]; then
    kind=waiting text="$question"
  elif [[ "$QUIET_AFTER" =~ ^[0-9]+$ ]] && (( QUIET_AFTER > 0 )); then
    if [[ -d "$CONDUCTOR_DIR/work/$task" && -z "$(find "$CONDUCTOR_DIR/work/$task" -type f -mmin "-$QUIET_AFTER" 2> /dev/null | head -1)" ]]; then
      kind=quiet text="$QUIET_AFTER"
    fi
  fi
  if [[ -z "$kind" ]]; then
    tmux set-option -w -u -t "$SESSION:$win" window-status-style > /dev/null 2>&1 || true
    continue
  fi
  key="$win:$kind:$(printf '%s' "$text" | cksum | cut -d' ' -f1)"
  new_seen="$new_seen$key"$'\n'
  grep -qxF -- "$key" "$SEEN" 2> /dev/null && continue
  last="$(oneline "$(grep -v '^[[:space:]]*$' <<< "$pane" | tail -1)")"
  findings="$findings$win"$'\t'"$task"$'\t'"$kind"$'\t'"$text"$'\t'"$last"$'\n'
  tmux set-option -w -t "$SESSION:$win" window-status-style 'bg=red,fg=white' > /dev/null 2>&1 || true
done <<< "$windows"

{ mkdir -p "$CONDUCTOR_DIR" && printf '%s' "$new_seen" > "$SEEN"; } 2> /dev/null || true

CHANNEL="$(awk '/^notify-channel:/{print $2; exit}' "$CONDUCTOR_DIR/config.md" 2> /dev/null || true)"
TS="$(date +%Y%m%d-%H%M%S)"
while IFS=$'\t' read -r win task kind text last; do
  [[ -n "$win" ]] || continue
  if [[ "$kind" == waiting ]]; then
    msg="window $win (task $task) is waiting for you: $text"
  else
    msg="window $win (task $task) has produced nothing for $text minutes; the pane ends: ${last:-empty}"
  fi
  printf '%s\t%s\t%s\t%s\n' "$win" "$task" "$kind" "$msg"
  mkdir -p "$CONDUCTOR_DIR/human-inbox" 2> /dev/null || true
  {
    printf -- '---\ntype: window-%s\nwindow: %s\ntask-id: %s\ntimestamp: %s\n---\n' "$kind" "$win" "$task" "$TS"
    printf '%s\n\nLook at it with: tmux select-window -t %s:%s\n' "$msg" "$SESSION" "$win"
  } > "$CONDUCTOR_DIR/human-inbox/window-$win-$TS.md" 2> /dev/null || true
  if [[ "$CHANNEL" == "push" ]] && command -v osascript > /dev/null 2>&1; then
    m="${msg//\"/}"; m="${m//\\/}"
    osascript -e "display notification \"$m\" with title \"Swarm: Window Waiting\" sound name \"Glass\"" > /dev/null 2>&1 || true
  fi
done <<< "$findings"
exit 0
