#!/usr/bin/env bash
# Tell the human and the architect that conductor-loop.sh has halted.
#
# Usage: loop-halt-notify.sh --kind <kind> --artifact <path> --handler <skill> \
#                            --detail <text> [--last-error <text>]
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# A halt stops the whole loop, for every task, so unlike task-notify.sh this is not tied
# to a task or a stage. It uses the same places a person already looks:
#   - a banner on stdout, which is the conductor window
#   - human-inbox/loop-halt-<timestamp>.md
#   - architect-inbox/loop-halt-<timestamp>.md, with `type: halt`, for the architect's
#     inbox watch (skills/architect/on-halt.md). The watcher reports new file names, not
#     overwrites, hence the timestamp.
#   - a desktop notification on macOS when config.md has `notify-channel: push`
#
# It is best effort. A halt must not turn into some other failure because a notice could
# not be written, so every step is allowed to fail and the exit status is always 0.
# conductor-loop.sh removes the loop-halt-*.md files when it starts again.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"

KIND="" ARTIFACT="" HANDLER="" DETAIL="" LAST_ERROR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)       KIND="${2-}";       shift 2 || shift ;;
    --artifact)   ARTIFACT="${2-}";   shift 2 || shift ;;
    --handler)    HANDLER="${2-}";    shift 2 || shift ;;
    --detail)     DETAIL="${2-}";     shift 2 || shift ;;
    --last-error) LAST_ERROR="${2-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

# One line each: the values go into a front matter field and a banner.
oneline() { printf '%s' "$1" | tr '\n\t\r' '   ' | cut -c1-300; }
KIND="$(oneline "$KIND")"; ARTIFACT="$(oneline "$ARTIFACT")"; HANDLER="$(oneline "${HANDLER:-none}")"
DETAIL="$(oneline "$DETAIL")"; LAST_ERROR="$(oneline "$LAST_ERROR")"

TS="$(date +%Y%m%d-%H%M%S)"
NAME="loop-halt-${TS}.md"

body() { # <type> -> the notice, front matter first. printf, so no value is ever expanded.
  printf -- '---\ntype: %s\nkind: %s\nartifact: %s\nhandler: %s\ntimestamp: %s\n---\n' \
    "$1" "$KIND" "$ARTIFACT" "$HANDLER" "$TS"
  printf 'The conductor loop has halted. No task will move until it is started again.\n\n'
  printf 'Halt:      %s\n' "$KIND"
  printf 'Artifact:  %s\n' "$ARTIFACT"
  printf 'Handler:   %s\n' "$HANDLER"
  printf 'Why:       %s\n' "$DETAIL"
  [[ -n "$LAST_ERROR" ]] && printf 'Last error: %s\n' "$LAST_ERROR"
  printf '\nThe event was not skipped: it is still waiting. Fix the cause, then start the loop\n'
  printf 'again (scripts/conductor-loop.sh) and it will retry this event first.\n'
  printf 'Details: %s/conductor-loop.halted\n' "$CONDUCTOR_DIR"
}

# 1. the human
{ mkdir -p "$CONDUCTOR_DIR/human-inbox" && body loop-halt > "$CONDUCTOR_DIR/human-inbox/$NAME"; } 2> /dev/null || true

# 2. the architect
{ mkdir -p "$CONDUCTOR_DIR/architect-inbox" && body halt > "$CONDUCTOR_DIR/architect-inbox/$NAME"; } 2> /dev/null || true

# 3. the conductor window
printf '\n=== CONDUCTOR LOOP HALTED ===\n'
printf 'Halt:      %s\nArtifact:  %s\nHandler:   %s\nWhy:       %s\n' "$KIND" "$ARTIFACT" "$HANDLER" "$DETAIL"
[[ -n "$LAST_ERROR" ]] && printf 'Last error: %s\n' "$LAST_ERROR"
printf 'Restart:   scripts/conductor-loop.sh   (the event is still waiting)\n'
printf '=============================\n\n'

# 4. a desktop notification, if asked for. Strip double quotes first: a value inside the
# AppleScript string would otherwise close it early (the same care as task-notify.sh).
CHANNEL="$(awk '/^notify-channel:/{print $2; exit}' "$CONDUCTOR_DIR/config.md" 2> /dev/null || true)"
if [[ "$CHANNEL" == "push" ]] && command -v osascript > /dev/null 2>&1; then
  MSG="Conductor loop halted ($KIND): $DETAIL"
  MSG="${MSG//\"/}"; MSG="${MSG//\\/}"
  osascript -e "display notification \"$MSG\" with title \"Swarm: Conductor Halted\" sound name \"Glass\"" > /dev/null 2>&1 || true
fi

exit 0
