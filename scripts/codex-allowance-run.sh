#!/usr/bin/env bash
set -euo pipefail
# A real Codex run, to see what it used of the subscription allowance. This is the check that
# cannot be done without Codex and an account: it spends a little of your allowance.
#
# Usage: codex-allowance-run.sh [--runs <n>] [--prompt <text>] [--yes] [--dry-run]
#   --runs n     how many runs, one after the other (default 1, at most 10). The allowance is
#                reported in whole percents, so one small run often moves nothing: several runs add up
#   --prompt t   what to ask Codex (default: review a small shell script it is given, read-only)
#   --yes        do not ask before spending allowance
#   --dry-run    show the current reading and what would be run, run nothing
# Env:   CODEX_HOME, CODEX_SESSIONS_DIR (see codex-usage.sh), CODEX_AUTH_FILE (see codex-billing.sh)
#
# What it does, per run: takes a reading, runs `codex exec` (read-only, in a scratch directory),
# takes a second reading, and appends a line to a usage log of its own with the run's tokens, the
# model that answered and the allowance difference, the way the swarm's lines carry them. At the end
# it prints those lines and the summary's Codex allowance section. It checks first that Codex is
# billed to a subscription (codex-billing.sh), and stops if it is not.
#
# Everything is written under one scratch directory, which is printed and left in place. The
# swarm's own .conductor is not touched. This exercises the readers and the difference with a real
# Codex; the wiring into the loop and the workers is covered by the tests, which cannot say what a
# live Codex writes. If the difference shows as unknown, the reason says why.
#
# The runs are NOT --ephemeral, unlike the conductor's headless dispatches (adapters/codex.sh): an
# ephemeral run writes no session file, so there would be nothing for the readers to find.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/usage-log.sh
source "$SCRIPTS_DIR/usage-log.sh"

RUNS=1
PROMPT=""
YES=false
DRY=false
DEFAULT_PROMPT='Review review-me.sh in this directory. List the problems you find as at most five short bullet points, and say which is the most serious. Do not change any file.'

die() { echo "codex-allowance-run.sh: $*" >&2; exit 1; }

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runs)    RUNS="${2:?--runs needs a number}"; shift 2 ;;
      --prompt)  PROMPT="${2:?--prompt needs text}"; shift 2 ;;
      --yes)     YES=true; shift ;;
      --dry-run) DRY=true; shift ;;
      -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 && "$RUNS" -le 10 ]] || die "--runs is a number from 1 to 10"
  [[ -n "$PROMPT" ]] || PROMPT="$DEFAULT_PROMPT"
  command -v jq > /dev/null 2>&1 || die "needs jq"
  command -v codex > /dev/null 2>&1 || die "needs the codex CLI on the PATH"

  echo "Codex billing:"
  if ! "$SCRIPTS_DIR/codex-billing.sh" check; then
    echo "Stopping: Codex would not be billed to a subscription, so there is no allowance to measure." >&2
    return 2
  fi
  echo "  ok"
  echo
  echo "Allowance now:"
  "$SCRIPTS_DIR/codex-usage.sh" --text | sed 's/^/  /'
  echo

  if [[ "$DRY" == true ]]; then
    echo "Dry run: would run $RUNS real Codex run(s) (read-only, not ephemeral) with the prompt:"
    echo "  $PROMPT"
    return 0
  fi
  if [[ "$YES" != true ]]; then
    [[ -t 0 ]] || die "this spends subscription allowance; run it from a terminal, or pass --yes"
    printf 'Run %s real Codex run(s) on your subscription? [y/N] ' "$RUNS"
    local answer; read -r answer
    [[ "$answer" == y || "$answer" == Y ]] || { echo "Not run."; return 0; }
  fi

  local work project
  work="$(mktemp -d "${TMPDIR:-/tmp}/codex-allowance-run.XXXXXX")"
  project="$work/project"; mkdir -p "$project" "$work/conductor"
  export CONDUCTOR_DIR="$work/conductor"
  local log="$CONDUCTOR_DIR/usage.jsonl"
  cat > "$project/review-me.sh" <<'SH'
#!/bin/bash
# prints the size of every file in a directory given as $1
dir=$1
for f in $dir/*; do
  size=`wc -c $f`
  echo $size
done
if [ $dir = "" ]; then echo "no directory"; fi
SH
  echo "Scratch directory: $work"
  echo

  local i start rc events line allowance answered tokens outcome
  for (( i = 1; i <= RUNS; i++ )); do
    echo "Run $i of $RUNS ..."
    start="$(date +%s)"
    "$SCRIPTS_DIR/allowance.sh" begin "check-$i" --kind dispatch --pid $$
    rc=0
    events="$work/events-$i.jsonl"
    ( cd "$project" && codex exec --json -s read-only --skip-git-repo-check "$PROMPT" < /dev/null > "$events" 2> "$work/err-$i.txt" ) || rc=$?
    allowance="$("$SCRIPTS_DIR/allowance.sh" end "check-$i" 2> /dev/null)" || allowance=null
    jq -e . <<< "$allowance" > /dev/null 2>&1 || allowance=null
    answered="$("$SCRIPTS_DIR/worker-usage.sh" model codex "$project" "$start" 2> /dev/null || true)"
    tokens="$(jq -cR 'fromjson? // empty' "$events" 2> /dev/null | jq -cs '
      [.[] | select(.type == "turn.completed") | .usage] as $u
      | if ($u | length) == 0 then null
        else { input_tokens: ([$u[] | ((.input_tokens // 0) - (.cached_input_tokens // 0))] | add | if . < 0 then 0 else . end),
               output_tokens: ([$u[] | .output_tokens // 0] | add),
               cache_read_tokens: ([$u[] | .cached_input_tokens // 0] | add),
               cache_write_tokens: ([$u[] | .cache_write_input_tokens // 0] | add) } end' 2> /dev/null || echo null)"
    [[ -n "$tokens" ]] || tokens=null
    outcome=finished; [[ "$rc" -eq 0 ]] || outcome=failed
    line="$(jq -nc --argjson t "$tokens" --argjson al "$allowance" --arg i "$i" --arg outcome "$outcome" --argjson rc "$rc" \
      --argjson d "$(( $(date +%s) - start ))" --arg answered "$answered" '
      { event: ("check/run-" + $i), task: null, handler: null, role: "check", attempt: ($i | tonumber), outcome: $outcome, rc: $rc,
        duration_s: $d, harness: "codex", model: (if $answered == "" then null else $answered end),
        input_tokens: $t.input_tokens, output_tokens: $t.output_tokens, cache_read_tokens: $t.cache_read_tokens,
        cache_write_tokens: $t.cache_write_tokens, usage: (if $t == null then "none" else "reported" end),
        allowance: $al, answered_model: (if $answered == "" then null else $answered end) }')"
    usage_append "$log" "$line"
    jq -r '"  tokens: in \(.input_tokens // "unknown"), out \(.output_tokens // "unknown"); model that answered: \(.answered_model // "unknown")",
           (.allowance // null | if . == null then "  allowance: no reading before the run" else
              "  5-hour: \(.five_hour | if .points == null then "unknown (\(.reason))" elif .points == 0 then "+0 points (under one step)" else "+\(.points) points" end)",
              "  weekly: \(.weekly | if .points == null then "unknown (\(.reason))" elif .points == 0 then "+0 points (under one step)" else "+\(.points) points" end)" end)' <<< "$line"
    if [[ "$rc" -ne 0 ]]; then
      echo "  codex exited with $rc: $(head -c 300 "$work/err-$i.txt" | tr '\n' ' ')" >&2
    fi
  done

  echo
  echo "The lines written to $log:"
  jq -c 'select(.record == null) | {event, outcome, model, answered_model, input_tokens, output_tokens, allowance: (.allowance | if . == null then null else {attributed_to, five_hour: .five_hour.points, weekly: .weekly.points} end)}' "$log" | sed 's/^/  /'
  echo
  "$SCRIPTS_DIR/usage-summary.sh" --file "$log" --by allowance
  echo
  echo "What to look for: the 5-hour and weekly points are whole-percent steps, so a single small run may"
  echo "show '+0 (under one step)', which means less than one percent, not nothing, or 1 (or 'Codex wrote"
  echo "nothing new' if Codex wrote no event). Compare 'Allowance now'"
  echo "above with the window line in the summary. Everything is in $work."
}

main "$@"
