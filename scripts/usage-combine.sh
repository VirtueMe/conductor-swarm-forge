#!/usr/bin/env bash
set -euo pipefail
# Append a finished run's usage log to one combined file, so runs can be compared.
#
# Usage: usage-combine.sh [--file <usage.jsonl>] [--into <combined.jsonl>] [--run <id>]
# Env:   CONDUCTOR_DIR (default: .conductor)
#        USAGE_COMBINED  the combined file (default: ~/.conductor/usage-combined.jsonl)
#
# Every line of the run's log is copied with a "run" field added, and nothing else changed, so
# usage-summary.sh reads the combined file as it reads one run's (--file). <id> names the run:
# default is the project directory and the time of the log's first line. Running it twice for the
# same run adds nothing: a run already in the file is skipped, and says so.
# It never edits or removes lines. A line that is not JSON is left out, as the summary leaves it out.
# Whether a run is finished is the caller's call: this does not look.

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
FILE="$CONDUCTOR_DIR/usage.jsonl"
INTO="${USAGE_COMBINED:-$HOME/.conductor/usage-combined.jsonl}"
RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:?--file needs a path}"; shift 2 ;;
    --into) INTO="${2:?--into needs a path}"; shift 2 ;;
    --run)  RUN="${2:?--run needs an id}"; shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: usage-combine.sh [--file <usage.jsonl>] [--into <combined.jsonl>] [--run <id>]" >&2; exit 1 ;;
  esac
done

command -v jq > /dev/null 2>&1 || { echo "usage-combine.sh needs jq" >&2; exit 3; }
[[ -s "$FILE" ]] || { echo "usage-combine.sh: $FILE is missing or empty; nothing to add" >&2; exit 0; }

if [[ -z "$RUN" ]]; then
  first="$(jq -R 'fromjson? // empty | .ts // empty' "$FILE" | head -1 | tr -d '"')"
  project="$(cd "$(dirname "$CONDUCTOR_DIR")" 2> /dev/null && basename "$PWD" || echo project)"
  RUN="$project-${first:-unknown}"
fi

mkdir -p "$(dirname "$INTO")"
if [[ -s "$INTO" ]] && jq -R --arg r "$RUN" 'fromjson? | select(.run == $r)' "$INTO" | grep -q .; then
  echo "usage-combine.sh: run $RUN is already in $INTO; nothing added"
  exit 0
fi

n="$(jq -R 'fromjson? // empty' "$FILE" | jq -c --arg r "$RUN" '. + {run: $r}' | tee -a "$INTO" | wc -l)"
echo "usage-combine.sh: added $n lines of run $RUN to $INTO"
