#!/usr/bin/env bash
set -euo pipefail
# Processed-artifact ledger: records which work artifacts the conductor has
# handled, so "what is left to do" does not depend on file mtimes.
#
# Usage:
#   artifact-ledger.sh mark <artifact>     record an artifact as processed
#   artifact-ledger.sh check <artifact>    exit 0 if recorded, 1 if not
#   artifact-ledger.sh unprocessed         list unrecorded artifacts, oldest first
#
# <artifact> is a path to a file under $CONDUCTOR_DIR/work/ (absolute, or
# relative to the current directory or to the work directory).
# Env: CONDUCTOR_DIR (default: .conductor)
#
# The ledger lives at $CONDUCTOR_DIR/processed.log, one line per artifact, as a
# path relative to the work directory (e.g. task-001/signal-20261031-170400.md).
# `mark` only appends, so marking twice leaves a duplicate line; `check` and
# `unprocessed` treat the ledger as a set, so that is harmless.
#
# This does not replace the spawn guard in worker-spawn.sh. A crash between
# "handler finished" and `mark` still replays the event, so handlers must stay
# safe to replay. It sits next to $CONDUCTOR_DIR/last-poll, which it does not
# touch: last-poll stays a cheap pre-filter, the ledger decides what is processed.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
WORK_DIR="$CONDUCTOR_DIR/work"
LEDGER="$CONDUCTOR_DIR/processed.log"

usage() {
  echo "Usage: artifact-ledger.sh mark <artifact> | check <artifact> | unprocessed" >&2
  exit 1
}

# Print the artifact's path relative to the work directory. The argument may be a
# path that exists as given (absolute or relative to the current directory) or
# one relative to the work directory.
rel_path() {
  local p="$1" work_abs abs
  work_abs="$(cd "$WORK_DIR" 2>/dev/null && pwd)" || { echo "No work directory: $WORK_DIR" >&2; return 1; }
  if [[ -f "$p" ]]; then
    abs="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
    p="${abs#"$work_abs"/}"
    [[ "$p" != "$abs" ]] || { echo "Not under $WORK_DIR: $1" >&2; return 1; }
  fi
  [[ -f "$work_abs/$p" ]] || { echo "Not an artifact under $WORK_DIR: $1" >&2; return 1; }
  echo "$p"
}

is_recorded() {
  [[ -f "$LEDGER" ]] && grep -Fxq -- "$1" "$LEDGER"
}

cmd="${1:-}"
case "$cmd" in
  mark)
    [[ $# -eq 2 ]] || usage
    rel="$(rel_path "$2")"
    echo "$rel" >> "$LEDGER"
    ;;
  check)
    [[ $# -eq 2 ]] || usage
    rel="$(rel_path "$2")"
    is_recorded "$rel"
    ;;
  unprocessed)
    [[ $# -eq 1 ]] || usage
    [[ -d "$WORK_DIR" ]] || exit 0
    # Oldest first by the timestamp in the file name (<type>-<YYYYMMDD-HHMMSS>.md),
    # then by path. Order comes from the name, never from mtime.
    # One pass: the ledger is read once, then the work tree is filtered against it.
    (cd "$WORK_DIR" && find . -name '*.md' | sed 's|^\./||') |
      awk -v ledger="$LEDGER" '
        BEGIN { while ((getline line < ledger) > 0) seen[line] = 1 }
        !($0 in seen) {
          base = $0; sub(/^.*\//, "", base); sub(/\.md$/, "", base); sub(/^[^-]*-/, "", base)
          printf "%s\t%s\n", base, $0
        }' |
      sort -t$'\t' -k1,1 -k2,2 | cut -f2
    ;;
  *) usage ;;
esac
