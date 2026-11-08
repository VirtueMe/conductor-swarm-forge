#!/usr/bin/env bash
set -euo pipefail
# Budgets per pool, measured against the usage log. Report only: nothing here pauses a run or
# refuses a dispatch (enforcement is out of scope, see #111).
#
# Usage: budget.sh merge <workforce.json> [<brief.md>]
#        budget.sh status [--file <usage.jsonl>] [--budgets <budgets.json>] [--now <timestamp>]
#        budget.sh warn   [--file <usage.jsonl>] [--budgets <budgets.json>] [--now <timestamp>]
# Env:   CONDUCTOR_DIR (default: .conductor)
#
# A budget is declared per pool in the workforce file ("budgets", docs/workforce-schema.md):
#   {"pool": "api:anthropic", "usd": 50, "period": "week", "warn_at": 80,
#    "caps": [{"role": "coder", "usd": 20}]}
# The unit follows the pool: usd (real dollars) for an api pool, percent of the weekly allowance
# for a subscription pool. On a subscription the pool's spent is how far the weekly window rose over
# the period, from the allowance readings in the log (the first and the last live reading of one
# window), because that covers the whole swarm, needs no attribution and survives overlapping
# workers (#174). It is the account's rise, so it also counts what a person did by hand in the same
# window. When it cannot be measured (fewer than two live readings, or the window reset in between)
# spent is the floor of the runs' own points, as before, and the row says why. period is "run" (the whole
# log, the default) or "week" (the last seven days). A cap narrows the budget to the lines of a
# role, an adapter (the line's harness) or a model, or a combination.
#
# merge   Prints the budgets in effect, as JSON: the workforce's, tightened by a brief. A brief
#         says so in its frontmatter, one "<pool> <amount>" per line:
#           ---
#           budget:
#             - api:anthropic 20
#           ---
#         It can lower the amount of a budget the workforce has, and never raise it or add one: the
#         workforce is the ceiling. What it did not take is said on stderr.
# status  Prints one row per budget and per cap, as a JSON array: pool, scope, unit, period,
#         budget, spent, percent, state (ok, warn at warn_at percent, over at 100), basis ("window":
#         the rise of the weekly window, with from, to, since and until; or "runs": the sum of the runs'
#         own points, with reason when the rise could not be measured) and unmeasured, the lines in
#         the group that have no cost (or, on a run basis, no points) and so are not in spent. A
#         role, adapter or model cap is always on the runs. Spent on a runs basis is a floor, as in
#         usage-summary.sh. No budgets file: [].
# warn    Writes one line to stdout for each budget or cap that is now warn or over and has not
#         been warned about in this period, and appends a {"record": "budget_warning"} to the
#         usage log so that it is not said again. The log is the memory; there is no other state.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/frontmatter.sh
source "$HERE/frontmatter.sh"

# the rows, or [] when there are no budgets
status_rows() { # <usage file> <budgets file> <now or empty>
  local file="$1" budgets="$2" now="$3"
  if [[ ! -s "$budgets" ]]; then echo "[]"; return 0; fi
  local lines="[]"
  if [[ -s "$file" ]]; then lines="$(jq -R 'fromjson? // empty' "$file" | jq -cs '.')"; fi
  jq -n --argjson lines "$lines" --slurpfile budgets "$budgets" --arg now "$now" '
    (if $now == "" then now else ($now | fromdateiso8601) end) as $t
    | ($t - 604800 | todate) as $cutoff
    | def unit_of($pool): if ($pool | startswith("api:")) then "usd" else "percent" end;
      def capmatch($c): ($c.role == null or $c.role == .role) and ($c.adapter == null or $c.adapter == .harness) and ($c.model == null or $c.model == .model);
      def scope_of($c): [(if $c.role then "role=" + $c.role else empty end), (if $c.adapter then "adapter=" + $c.adapter else empty end), (if $c.model then "model=" + $c.model else empty end)] | join(",");
      def r4: . * 10000 | round / 10000;
      # The rise of the weekly window over the period for a subscription pool: first to last live
      # reading of the one window. Not measurable with fewer than two, or when the window changed.
      def rise($b):
        [$lines[] | select(.record == "allowance" and .pool == $b.pool
                           and (($b.period // "run") == "run" or .ts >= $cutoff)
                           and (.source == "endpoint" or .source == null)
                           and .weekly.state == "known" and (.weekly.used_percent | type) == "number" and (.weekly.resets_at | type) == "number")]
        | sort_by(.snapshot_at // .ts) as $rs
        | if ($rs | length) < 2 then { basis: "runs", reason: "fewer than two live weekly readings in the period" }
          elif ([$rs[].weekly.resets_at] | (max - min)) > 120 then { basis: "runs", reason: "the weekly window reset during the period" }
          elif $rs[-1].weekly.used_percent < $rs[0].weekly.used_percent then { basis: "runs", reason: "the weekly figure fell within one window" }
          else { basis: "window", spent: ($rs[-1].weekly.used_percent - $rs[0].weekly.used_percent),
                 from: $rs[0].weekly.used_percent, to: $rs[-1].weekly.used_percent,
                 since: ($rs[0].snapshot_at // $rs[0].ts), until: ($rs[-1].snapshot_at // $rs[-1].ts) } end;
      def mkrow($b; $scope; $amount; $rows):
        unit_of($b.pool) as $u
        | (if $u == "percent" and $scope == "pool" then rise($b) else { basis: "runs" } end) as $m
        | ($rows | map(if $u == "usd" then (.cost_usd // .estimated_cost_usd // 0) else (.allowance.weekly.points // 0) end) | add // 0 | r4) as $floor
        | (if $m.basis == "window" then ($m.spent | r4) else $floor end) as $spent
        | (if $m.basis == "window" then 0
           else ($rows | map(select(if $u == "usd" then (.cost_usd == null and .estimated_cost_usd == null) else (.allowance.weekly.points == null) end)) | length) end) as $unm
        | (if $amount > 0 then ($spent / $amount * 100 | r4) else 0 end) as $pct
        | { pool: $b.pool, scope: $scope, unit: $u, period: ($b.period // "run"), budget: $amount, spent: $spent, percent: $pct,
            warn_at: ($b.warn_at // 80),
            state: (if $pct >= 100 then "over" elif $pct >= ($b.warn_at // 80) then "warn" else "ok" end),
            basis: $m.basis, unmeasured: $unm }
          + (if $m.basis == "window" then { from: $m.from, to: $m.to, since: $m.since, until: $m.until } else {} end)
          + (if $m.reason then { reason: $m.reason } else {} end);
      ($budgets[0] // [])
    | map(. as $b
        | ($lines | map(select(.record == null and .pool == $b.pool and (($b.period // "run") == "run" or .ts >= $cutoff)))) as $rows
        | mkrow($b; "pool"; ($b.usd // $b.percent); $rows),
          (($b.caps // []) | .[] | . as $c | mkrow($b; scope_of($c); ($c.usd // $c.percent); ($rows | map(select(capmatch($c)))))))
    | flatten' || { echo "budget.sh: cannot read $budgets as a list of budgets; reporting none" >&2; echo "[]"; }
}

cmd_status() {
  local file="${CONDUCTOR_DIR:-.conductor}/usage.jsonl" budgets="${CONDUCTOR_DIR:-.conductor}/budgets.json" now=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)    file="${2:?--file needs a path}"; shift 2 ;;
      --budgets) budgets="${2:?--budgets needs a path}"; shift 2 ;;
      --now)     now="${2:?--now needs a timestamp}"; shift 2 ;;
      *) echo "budget.sh: unknown option $1" >&2; exit 1 ;;
    esac
  done
  status_rows "$file" "$budgets" "$now"
}

cmd_warn() {
  local file="${CONDUCTOR_DIR:-.conductor}/usage.jsonl" budgets="${CONDUCTOR_DIR:-.conductor}/budgets.json" now=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)    file="${2:?--file needs a path}"; shift 2 ;;
      --budgets) budgets="${2:?--budgets needs a path}"; shift 2 ;;
      --now)     now="${2:?--now needs a timestamp}"; shift 2 ;;
      *) echo "budget.sh: unknown option $1" >&2; exit 1 ;;
    esac
  done
  [[ -s "$file" ]] || return 0
  local rows due ts
  rows="$(status_rows "$file" "$budgets" "$now")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A row is due when it is warn or over and the log has no warning for the same pool, scope and
  # state since the period began.
  due="$(jq -R 'fromjson? // empty' "$file" | jq -cs --argjson rows "$rows" --arg now "$now" '
    . as $log
    | (if $now == "" then now else ($now | fromdateiso8601) end) as $t
    | ($t - 604800 | todate) as $cutoff
    | $rows | map(select(.state != "ok") | . as $r
        | select(($log | map(select(.record == "budget_warning" and .pool == $r.pool and .scope == $r.scope and .state == $r.state
                                    and ($r.period == "run" or .ts >= $cutoff))) | length) == 0)) | .[]' 2> /dev/null)" || due=""
  [[ -n "$due" ]] || return 0
  local row pool scope unit state budget spent pct warn_at
  while IFS= read -r row; do
    pool="$(jq -r .pool <<< "$row")"; scope="$(jq -r .scope <<< "$row")"; unit="$(jq -r .unit <<< "$row")"
    state="$(jq -r .state <<< "$row")"; budget="$(jq -r .budget <<< "$row")"; spent="$(jq -r .spent <<< "$row")"
    pct="$(jq -r '.percent | floor' <<< "$row")"; warn_at="$(jq -r .warn_at <<< "$row")"
    if [[ "$unit" == usd ]]; then
      printf '%sbudget %s%s: $%.2f of $%.2f (%s%%%s)\n' "$([[ $state == over ]] && echo 'over ')" "$pool" "$([[ $scope != pool ]] && echo " ($scope)")" "$spent" "$budget" "$pct" "$([[ $state == warn ]] && echo ", warn at $warn_at%")"
    else
      printf '%sbudget %s%s: %s%% of %s%% of the weekly allowance (%s%%%s)%s\n' "$([[ $state == over ]] && echo 'over ')" "$pool" "$([[ $scope != pool ]] && echo " ($scope)")" "$spent" "$budget" "$pct" "$([[ $state == warn ]] && echo ", warn at $warn_at%")" \
        "$([[ $(jq -r .basis <<< "$row") == window ]] && echo ", the weekly window rose $(jq -r .from <<< "$row")% to $(jq -r .to <<< "$row")%, which includes use by hand" || echo ", the runs' own points")"
    fi
    jq -nc --arg ts "$ts" --argjson r "$row" '{record: "budget_warning", ts: $ts, pool: $r.pool, scope: $r.scope, state: $r.state, unit: $r.unit, budget: $r.budget, spent: $r.spent}' >> "$file" 2> /dev/null || true
  done <<< "$due"
}

cmd_merge() {
  local wf="${1:?budget.sh merge <workforce.json> [<brief.md>]}" brief="${2:-}"
  local base brief_json="[]" item pool amount
  base="$(jq -c '.budgets // []' "$wf")"
  if [[ -n "$brief" && -f "$brief" ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      pool="${item%% *}"; amount="${item#* }"; amount="${amount//[\$% ]/}"
      if ! [[ "$amount" =~ ^[0-9]+([.][0-9]+)?$ ]]; then echo "budget: brief entry '$item' ignored: no amount" >&2; continue; fi
      brief_json="$(jq -c --arg p "$pool" --argjson a "$amount" '. + [{pool: $p, amount: $a}]' <<< "$brief_json")"
    done < <(fm_list "$brief" budget)
  fi
  # The amount a budget has, by the unit its pool implies.
  local amt='(if (.pool | startswith("api:")) then .usd else .percent end)'
  jq -r --argjson brief "$brief_json" '
    . as $base | $brief[] | . as $e
    | ($base | map(select(.pool == $e.pool)) | first) as $b
    | if $b == null then "budget: brief entry for " + $e.pool + " ignored: the workforce has no budget for it (a brief tightens, it does not add)"
      elif $e.amount > ($b | '"$amt"') then "budget: brief entry for " + $e.pool + " not raised: the workforce budget is lower"
      else empty end' <<< "$base" >&2
  jq -c --argjson brief "$brief_json" '
    map(. as $b
      | ('"$amt"') as $cur
      | ($brief | map(select(.pool == $b.pool and .amount < $cur) | .amount) | min) as $lower
      | if $lower == null then .
        elif ($b.pool | startswith("api:")) then .usd = $lower else .percent = $lower end)' <<< "$base"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status) cmd_status "$@" ;;
    warn)   cmd_warn "$@" ;;
    merge)  cmd_merge "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: budget.sh merge <workforce.json> [<brief.md>] | status | warn  (see --help)" >&2; exit 1 ;;
  esac
}

main "$@"
