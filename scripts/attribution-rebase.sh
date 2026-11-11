#!/usr/bin/env bash
# The merger's rebase, which also stamps each of the task's commits with trailer lines (#130,
# docs/commit-attribution.md).
#
# Usage: attribution-rebase.sh <base-sha> [--task <id>] [<trailer-line>...]
#        run from the task's worktree, on the task's branch.
# Env:   CONDUCTOR_DIR (default: .conductor), for --task
#
# Rebases the branch onto <base-sha>. With trailer lines, every commit that lands on <base-sha>
# ends up with each of them in its message. With none it is the plain `git rebase <base-sha>`.
#
# --task <id> takes the lines from attribution-trailer.sh for that task: the setting in config.md, the
# coder's adapter and the model. This is the merger's one command, so no model assembles the lines or
# can run the rebase and skip them. Lines given as well are added after the resolved ones. When the
# resolver gives none (`attribution: none`, or what it needs is missing, which it warns about on stderr)
# the rebase is the plain one. When the resolver fails (a bad `attribution:` value) the script fails
# with its exit code before it rebases, so nothing has been rewritten.
#
# The stamp only ever adds. A line is added to a commit only when that exact line is not one of
# the commit's trailers: a second run changes nothing (the merger retries a failed fast-forward up to
# three times), and a trailer the commit already has, a human's Co-Authored-By among them, is kept.
# Git's own trailer.ifexists options do not give this: the default doubles the lines when several are
# added, and `replace` removes every trailer with the same key.
#
# A conflict stops the rebase, which this script leaves in progress and reports with git's exit code:
# the merger aborts it and signals, as before.
#
# A trailer line has to look like one, `Key: value`; anything else (a mistyped flag, say) is refused
# before the resolver runs or a commit is touched, rather than written into the history.
#
# Exit: 0 rebased (and stamped); 2 usage: no base, --task with no id, or an argument that is not a
# trailer line; the resolver's own code when it fails (1 a bad `attribution:` value, 3 no jq);
# anything else is git's.

set -euo pipefail

# Add each given line to HEAD's message unless that exact line is already one of its trailers.
# Called by `git rebase --exec` once per commit, so HEAD is the commit just replayed.
#
# --no-verify: the amend changes a trailer and nothing else, so it must not depend on the project's own
# commit rules. A commit-msg hook that lints messages, or a signing prompt, would fail the rebase here
# and the merger would read that as a conflict.
stamp_head() {
  local line args=()
  for line in "$@"; do
    git log -1 --format=%B | git interpret-trailers --parse | grep -qxF -- "$line" \
      || args+=(--trailer "$line")
  done
  [[ ${#args[@]} -eq 0 ]] || git commit -q --amend --no-edit --no-verify "${args[@]}"
}

# --stamp is not for people: it is the command `git rebase --exec` runs for each replayed commit (see the
# end of this file, where the lines are quoted into one string with printf %q).
if [[ "${1:-}" == "--stamp" ]]; then
  shift
  stamp_head "$@"
  exit 0
fi

usage() { echo "usage: attribution-rebase.sh <base-sha> [--task <id>] [<trailer-line>...]" >&2; exit 2; }

BASE="${1:-}"
[[ -n "$BASE" ]] || usage
shift

TASK=""
LINES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) [[ -n "${2:-}" ]] || usage; TASK="$2"; shift 2 ;;
    *)      LINES+=("$1"); shift ;;
  esac
done

for line in ${LINES[@]+"${LINES[@]}"}; do
  if [[ ! "$line" =~ ^[A-Za-z][A-Za-z0-9-]*:\ .+ ]]; then
    echo "attribution-rebase: '$line' is not a trailer line (Key: value)" >&2
    exit 2
  fi
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "$TASK" ]]; then
  # The resolver first and on its own: if it fails, set -e stops here, before any commit is touched.
  resolved="$("$SCRIPTS_DIR/attribution-trailer.sh" "$TASK")"
  resolved_lines=()
  if [[ -n "$resolved" ]]; then mapfile -t resolved_lines <<< "$resolved"; fi
  LINES=(${resolved_lines[@]+"${resolved_lines[@]}"} ${LINES[@]+"${LINES[@]}"})
fi

if [[ ${#LINES[@]} -eq 0 ]]; then
  git rebase -q "$BASE"
else
  # --exec takes one shell string: this script again, in --stamp mode, with the lines quoted.
  stamp="$(printf '%q ' "$SCRIPTS_DIR/$(basename "${BASH_SOURCE[0]}")" --stamp "${LINES[@]}")"
  git rebase -q --exec "$stamp" "$BASE"
fi
