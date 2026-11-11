#!/usr/bin/env bash
set -euo pipefail
# The trailer lines the conductor stamps on a task's commits (#130, docs/commit-attribution.md): who
# did the work, taken from the conductor and not from the member, which cannot be trusted to know its
# own model. Prints one line per trailer, nothing for `none`.
#
# Usage: attribution-trailer.sh <task>
# Env:   CONDUCTOR_DIR (default: .conductor)
#
#   Co-Authored-By: <tool> <<url>>        the coder's adapter names itself: adapter_attribution, in
#                                         adapters/<adapter>.sh
#   Assisted-by: <adapter>:<model>        the coder's adapter and model; the model is the workforce's,
#                                         with the task's strategy over it (task-strategy.sh params);
#                                         with no model, the adapter alone
#
# The setting is `attribution:` in $CONDUCTOR_DIR/config.md: `trailer` (the default when the key is
# absent or empty) or `none`. Any other value is an error, exit 1, because a typo should not pass for "off".
#
# The coder is the role whose commits these are. What cannot be found (no workforce.json, no coder in
# it, an adapter with no file) costs the lines it would have given, with a warning on stderr and exit 0:
# the stamp is metadata, and a merge must not stop for it.
#
# Exit: 0 lines printed, or none by setting or for want of information; 1 a bad setting; 2 no task;
# 3 jq missing.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTERS_DIR="$(cd "$SCRIPTS_DIR/../adapters" && pwd)"

TASK="${1:-}"
if [[ -z "$TASK" ]]; then echo "usage: attribution-trailer.sh <task>" >&2; exit 2; fi
command -v jq > /dev/null 2>&1 || { echo "attribution-trailer.sh needs jq" >&2; exit 3; }

warn() { echo "attribution-trailer: $*" >&2; }

# The first "attribution:" line of config.md, as config_field reads a key (handler-steps.sh).
mode=""
if [[ -f "$CONDUCTOR_DIR/config.md" ]]; then
  mode="$(sed -n 's/^attribution:[[:space:]]*//p' "$CONDUCTOR_DIR/config.md" | sed -n '1s/[[:space:]]*$//p')"
fi
mode="${mode:-trailer}"
case "$mode" in
  none) exit 0 ;;
  trailer) ;;
  *) echo "attribution-trailer: attribution: '$mode' in config.md is neither trailer nor none" >&2; exit 1 ;;
esac

WORKFORCE="$CONDUCTOR_DIR/workforce.json"
if [[ ! -f "$WORKFORCE" ]]; then warn "no $WORKFORCE: the task's commits get no attribution"; exit 0; fi
adapter="$(jq -r '[.members[]? | select(.role == "coder")][0].adapter // empty' "$WORKFORCE" 2> /dev/null || true)"
if [[ -z "$adapter" ]]; then warn "the workforce has no coder with an adapter: the task's commits get no attribution"; exit 0; fi

adapter_file="$ADAPTERS_DIR/$adapter.sh"
if [[ ! -f "$adapter_file" ]]; then warn "no adapter file for '$adapter': the task's commits get no attribution"; exit 0; fi
# In a subshell: an adapter is sourced for one function and must leave nothing behind.
# shellcheck source=/dev/null
attribution="$( (source "$adapter_file"; adapter_attribution) 2> /dev/null || true)"
if [[ -z "$attribution" ]]; then warn "adapter '$adapter' does not name itself: the task's commits get no attribution"; exit 0; fi
IFS=$'\t' read -r name url <<< "$attribution"

base="$(jq -c '[.members[]? | select(.role == "coder")][0].params // {}' "$WORKFORCE" 2> /dev/null || echo '{}')"
model="$(CONDUCTOR_DIR="$CONDUCTOR_DIR" "$SCRIPTS_DIR/task-strategy.sh" params "$TASK" coder "$base" 2> /dev/null \
  | jq -r '.model // empty' 2> /dev/null || true)"

echo "Co-Authored-By: $name <$url>"
if [[ -n "$model" ]]; then echo "Assisted-by: $adapter:$model"; else echo "Assisted-by: $adapter"; fi
