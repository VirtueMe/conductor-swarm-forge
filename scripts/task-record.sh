#!/usr/bin/env bash
set -euo pipefail
# Write the record of a finished task to the usage log: what it cost in all, how big it was, how
# much rework it took. Called by on-merge-success.sh when a task reaches done.
#
# Usage: task-record.sh <task> [--print]
# Env:   CONDUCTOR_DIR (default: .conductor)
#        Run it from the project's working tree: the size is read from its git history.
#
# One line, {"record": "task", ...}, is appended to $CONDUCTOR_DIR/usage.jsonl (--print writes it to
# stdout instead). It is a record of its own and not an attempt, so the summary's attempt totals do
# not count it twice. Fields (see docs/event-driven-conductor.md, "Task record"):
#   cost      one row per pool, because dollars are never added across billing kinds: the pool and
#             billing, reported and estimated dollars apart, the steps in it, and how many of them
#             had no cost (unknown is not free)
#   steps     the worker steps that ran for the task, by role
#   rework    rounds sent back: reviews rejected, validations failed
#   git       lines added and removed, commits, files, from the merge artifact's base-sha..head-sha
#             (the merger notes both: the base tip it rebased onto, and the branch tip). The commits
#             stay reachable after the branch is deleted, so this does not depend on the branch.
#             null with a reason when the merger left no sha or git cannot read it: never zero.
#   weight    the planned weight of the task, from `weight:` in the task file (the strategist's
#             estimate, #188), null until something writes one
#   type, title, merged_at

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"

die() { echo "task-record.sh: $*" >&2; exit 1; }

task="${1:?Usage: task-record.sh <task> [--print]}"; shift
print=0
[[ "${1:-}" != --print ]] || print=1
command -v jq > /dev/null 2>&1 || { echo "task-record.sh needs jq" >&2; exit 3; }

# shellcheck source=scripts/frontmatter.sh
source "$SCRIPTS_DIR/frontmatter.sh"

work="$CONDUCTOR_DIR/work/$task"
task_file="$CONDUCTOR_DIR/tasks/$task.md"
[[ -d "$work" ]] || die "no work directory for task $task at $work"

# A handler that failed partway runs again from the top (on-merge-success.sh), and a second line for
# the same task would count it twice. The log is one run's, so one record per task is the rule.
if [[ "$print" -eq 0 && -s "$USAGE_LOG" ]] && jq -R --arg t "$task" 'fromjson? | select(.record == "task" and .task == $t)' "$USAGE_LOG" | grep -q .; then
  exit 0
fi

# --- Rework: rounds the task was sent back ---------------------------------------
count_outcome() { # <type> <outcome>
  local f n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$(fm_field "$f" outcome 2> /dev/null || true)" == "$2" ]] && n=$(( n + 1 ))
  done < <(find "$work" -maxdepth 1 -name "$1-*.md" 2> /dev/null | sort)
  echo "$n"
}
rejected="$(count_outcome review rejected)"
failed="$(count_outcome validation failed)"

# --- Size: the task's commits, from the merge artifact ---------------------------
merge_art="$(find "$work" -maxdepth 1 -name 'merge-*.md' 2> /dev/null | sort | while IFS= read -r f; do
  [[ "$(fm_field "$f" outcome 2> /dev/null || true)" == success ]] && echo "$f"
done | tail -1)"

git_json=null
files_json='[]'
merged_at=null
if [[ -z "$merge_art" ]]; then
  git_json='{"unknown": "no successful merge artifact"}'
else
  merged_at="$(jq -Rn --arg t "$(fm_field "$merge_art" timestamp 2> /dev/null || true)" 'if $t == "" then null else $t end')"
  base="$(fm_field "$merge_art" base-sha 2> /dev/null || true)"
  head="$(fm_field "$merge_art" head-sha 2> /dev/null || true)"
  if [[ -z "$base" || -z "$head" ]]; then
    git_json='{"unknown": "the merger noted no base-sha and head-sha"}'
  elif ! git rev-parse --verify -q "$base^{commit}" > /dev/null 2>&1 || ! git rev-parse --verify -q "$head^{commit}" > /dev/null 2>&1; then
    git_json='{"unknown": "git cannot read the base-sha and head-sha"}'
  else
    numstat="$(git diff --numstat "$base..$head" 2> /dev/null || true)"
    commits="$(git rev-list --count "$base..$head" 2> /dev/null || echo 0)"
    # A binary file shows "-" for both counts: it is a file touched, and adds no lines.
    git_json="$(jq -Rn --arg commits "$commits" --arg base "$base" --arg head "$head" '
      [inputs | split("\t")] as $rows
      | { base_sha: $base, head_sha: $head, commits: ($commits | tonumber),
          lines_added: ($rows | map(.[0] | tonumber? // 0) | add // 0),
          lines_removed: ($rows | map(.[1] | tonumber? // 0) | add // 0),
          files: ($rows | length) }' <<< "$numstat")"
    files_json="$(jq -Rn '[inputs | split("\t")[2]]' <<< "$numstat")"
  fi
fi

# --- Cost and steps: the task's lines in the log ---------------------------------
lines='[]'
if [[ -s "$USAGE_LOG" ]]; then
  lines="$(jq -R 'fromjson? // empty' "$USAGE_LOG" | jq -sc --arg t "$task" 'map(select(.record == null and .task == $t))')"
fi

weight=null; type=null; title=null
if [[ -f "$task_file" ]]; then
  w="$(fm_field "$task_file" weight 2> /dev/null || true)"; [[ -z "$w" ]] || weight="$(jq -Rn --arg w "$w" '$w | tonumber? // $w')"
  t="$(fm_field "$task_file" type 2> /dev/null || true)"; [[ -z "$t" ]] || type="$(jq -Rn --arg t "$t" '$t')"
  ti="$(fm_field "$task_file" title 2> /dev/null || true)"; [[ -z "$ti" ]] || title="$(jq -Rn --arg t "$ti" '$t')"
fi

record="$(jq -nc --arg task "$task" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson lines "$lines" \
  --argjson git "$git_json" --argjson files "$files_json" --argjson merged_at "$merged_at" \
  --argjson weight "$weight" --argjson type "$type" --argjson title "$title" \
  --argjson rejected "$rejected" --argjson failed "$failed" '
  ($lines | map(select(.role != "conductor"))) as $steps
  | { record: "task", ts: $ts, task: $task, title: $title, type: $type, weight: $weight, merged_at: $merged_at,
      steps: ($steps | length),
      steps_by_role: ($steps | group_by(.role) | map({key: (.[0].role // "-"), value: length}) | from_entries),
      rework: { review_rejected: $rejected, validation_failed: $failed, rounds: ($rejected + $failed) },
      cost: ($lines | group_by(.pool // "unknown")
             | map({ pool: (.[0].pool // "unknown"), billing: (.[0].billing // "unknown"), steps: length,
                     reported_usd: (map(select(.cost_usd != null) | .cost_usd) | add // 0),
                     estimated_usd: (map(select(.cost_usd == null and .estimated_cost_usd != null) | .estimated_cost_usd) | add // 0),
                     unknown: (map(select(.cost_usd == null and .estimated_cost_usd == null)) | length) })),
      git: $git, files: $files }')"

if [[ "$print" -eq 1 ]]; then echo "$record"; else echo "$record" >> "$USAGE_LOG" 2> /dev/null || echo "task-record.sh: could not write $USAGE_LOG" >&2; fi
