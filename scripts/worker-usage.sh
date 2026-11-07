#!/usr/bin/env bash
set -euo pipefail
# Meter a worker: note when it is spawned, and when its window closes read what its harness left
# behind and append a line to usage.jsonl.
#
# Usage: worker-usage.sh spawned <task> <role> <adapter> <worktree-dir> [<params-json> [<pool>]]
#        worker-usage.sh read <task> [--outcome finished|interrupted] [--wait <seconds>] [--role <role>]
#        worker-usage.sh sweep
#        worker-usage.sh model <adapter> <directory> <since-epoch>
# Env:   CONDUCTOR_DIR (default: .conductor)
#        CLAUDE_PROJECTS_DIR, CODEX_SESSIONS_DIR, PI_SESSIONS_DIR  where the harnesses keep sessions
#        (default ~/.claude/projects, $CODEX_HOME/sessions or ~/.codex/sessions, ~/.pi/agent/sessions)
#
# spawned  writes $CONDUCTOR_DIR/workers/<role>-<task>.json: who, with which harness, in which
#          worktree, and when. Nothing can be read at spawn time; this is what lets a reader pick
#          the worker's session out of everything the harness has written. <pool> is the pool the
#          workforce gave the member; billing-mode.sh settles it now, against the sign-in as it is at
#          the spawn, and the record keeps the decision (pool_check), so the line says what the worker
#          was billed to and not what the closing process can see. Called by worker-spawn.sh.
# read     finds the sessions of that worktree written since the spawn, adds them up, appends one
#          line to $CONDUCTOR_DIR/usage.jsonl with the worker's role and task, and removes the
#          record. Called by worker-close.sh after the window is closed. --wait gives a harness
#          that writes its cost only when it exits (Claude Code) time to do so.
# sweep    reads, as interrupted, every worker whose record is still there but whose tmux window
#          is gone: closed by hand, or lost with the swarm.
#
# model    prints the model that answered in the harness's sessions in <directory> written since
#          <since-epoch>, or nothing if there is none. It is how a dispatch that has no worker record
#          learns which model Codex really used, since `codex exec --json` does not name it.
#
# What each harness leaves, and how this was found, is in docs/worker-usage-sources.md. In short:
# all three keep a JSON-lines session file with the working directory in it, which is the key.
# Unknown is never zero: a worker whose session cannot be found, or has no model reply in it,
# gets a line with null tokens and cost_source unknown, so the gap shows in the log.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/usage-log.sh
source "$SCRIPTS_DIR/usage-log.sh"

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
WORKERS_DIR="$CONDUCTOR_DIR/workers"
USAGE_LOG="$CONDUCTOR_DIR/usage.jsonl"
TMUX_SESSION="swarm"

die() { echo "worker-usage.sh: $*" >&2; exit 1; }

# --- Finding sessions ---------------------------------------------------------

sessions_root() { # <adapter>
  case "$1" in
    claude-code) echo "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" ;;
    codex)       echo "${CODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}" ;;
    pi)          echo "${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}" ;;
    *)           return 1 ;;
  esac
}

# The working directory a session file records. Where the harness puts the file depends on how it
# spells the directory, so the file itself is asked.
session_cwd() { # <adapter> <file>
  case "$1" in
    claude-code) jq -rn 'first(inputs | .cwd? // empty) // empty' "$2" 2> /dev/null ;;
    codex)       jq -rn 'first(inputs | select(.type == "session_meta") | .payload.cwd) // empty' "$2" 2> /dev/null ;;
    pi)          jq -rn 'first(inputs | select(.type == "session") | .cwd) // empty' "$2" 2> /dev/null ;;
  esac
}

# The session files of <cwd> written to since <epoch>.
sessions_for() { # <adapter> <cwd> <epoch>
  local adapter="$1" cwd="$2" epoch="$3" root f pattern='*.jsonl'
  root="$(sessions_root "$adapter")" || return 0
  [[ -d "$root" ]] || return 0
  [[ "$adapter" == codex ]] && pattern='rollout-*.jsonl'
  while IFS= read -r f; do
    [[ "$(session_cwd "$adapter" "$f")" == "$cwd" ]] && echo "$f"
  done < <(find "$root" -type f -name "$pattern" -newermt "@$epoch" 2> /dev/null | sort)
}

# --- Reading one session file ---------------------------------------------------
# Each reader prints one JSON object: has_usage (the model replied at least once), the model, the
# four token counts (disjoint, as in a usage record), cost (null if the harness left none) and turns.

read_claude_code() { # <file>
  # One API message can be written twice, so deduplicate on message.id. The cost comes from the
  # cost-state line the process writes when it exits; a process killed with SIGKILL leaves none.
  jq -cs '
    ([.[] | select(.type == "assistant")] | unique_by(.message.id)) as $a
    | { has_usage: ($a | length > 0),
        model: ($a[0].message.model // null),
        input_tokens: ($a | map(.message.usage.input_tokens // 0) | add // 0),
        output_tokens: ($a | map(.message.usage.output_tokens // 0) | add // 0),
        cache_read_tokens: ($a | map(.message.usage.cache_read_input_tokens // 0) | add // 0),
        cache_write_tokens: ($a | map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
        cache_write_1h_tokens: ($a | map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0),
        cost: ([.[] | select(.type == "cost-state")] | last | .totalCostUSD // null
               | if . == null then null else (. * 1e8 | round) / 1e8 end),
        turns: ($a | length) }' "$1"
}

read_codex() { # <file>
  # Counts are cumulative, so the last token_count is the total, and its input includes the
  # cached part. Codex leaves no cost.
  jq -cs '
    ([.[] | select(.payload.type == "token_count")] | last | .payload.info.total_token_usage) as $u
    | { has_usage: ($u != null),
        model: ([.[] | select(.type == "turn_context")] | last | .payload.model // null),
        input_tokens: (if $u then ([$u.input_tokens - $u.cached_input_tokens, 0] | max) else 0 end),
        output_tokens: ($u.output_tokens // 0),
        cache_read_tokens: ($u.cached_input_tokens // 0),
        cache_write_tokens: ($u.cache_write_input_tokens // 0),
        cost: null,
        turns: ([.[] | select(.payload.type == "task_complete")] | length) }' "$1"
}

read_pi() { # <file>
  # Every assistant message carries its own usage and cost, so a session is their sum.
  jq -cs '
    ([.[] | select(.type == "message" and .message.role == "assistant") | .message | select(.usage)]) as $m
    | { has_usage: ($m | length > 0),
        model: ($m[0].model // null),
        input_tokens: ($m | map(.usage.input // 0) | add // 0),
        output_tokens: ($m | map(.usage.output // 0) | add // 0),
        cache_read_tokens: ($m | map(.usage.cacheRead // 0) | add // 0),
        cache_write_tokens: ($m | map(.usage.cacheWrite // 0) | add // 0),
        cost: (if ($m | length) > 0 then ($m | map(.usage.cost.total // 0) | add | (. * 1e8 | round) / 1e8) else null end),
        turns: ($m | length) }' "$1"
}

# Add up the sessions of one worker. No session with a reply in it gives null: nothing is known.
# A cost is only reported if every session has one; a sum over some of them would look like the
# whole.
read_sessions() { # <adapter> <file>...
  local adapter="$1"; shift
  local f
  for f in "$@"; do "read_${adapter//-/_}" "$f"; done | jq -cs '
    map(select(.has_usage)) as $s
    | if ($s | length) == 0 then null
      else { model: ($s | map(.model) | map(select(. != null)) | first // null),
             input_tokens: ($s | map(.input_tokens) | add),
             output_tokens: ($s | map(.output_tokens) | add),
             cache_read_tokens: ($s | map(.cache_read_tokens) | add),
             cache_write_tokens: ($s | map(.cache_write_tokens) | add),
             cache_write_1h_tokens: ($s | map(.cache_write_1h_tokens // 0) | add),
             cost_usd: (if ($s | map(.cost) | any(. == null)) then null else ($s | map(.cost) | add) end),
             turns: ($s | map(.turns) | add) } end'
}

# Claude Code writes its cost when the process exits, a moment after the window is closed. Wait,
# up to <seconds>, until every session of the worker has it.
wait_for_cost() { # <cwd> <epoch> <seconds>
  local cwd="$1" epoch="$2" limit="$3" waited=0 f pending
  while :; do
    pending=0
    while IFS= read -r f; do
      grep -q '"type":"cost-state"' "$f" 2> /dev/null || pending=1
    done < <(sessions_for claude-code "$cwd" "$epoch")
    [[ "$pending" -eq 0 || "$waited" -ge "$limit" ]] && return 0
    sleep 0.2
    waited=$(( waited + 1 ))
  done
}

# --- Commands --------------------------------------------------------------------

record_file() { echo "$WORKERS_DIR/$1-$2.json"; } # <role> <task>

# The record of a task's worker, newest first if there are several.
find_record() { # <task>
  local f
  # shellcheck disable=SC2012  # the names are role-task.json, no odd characters
  f="$(ls -t "$WORKERS_DIR"/*-"$1".json 2> /dev/null | head -1)" || true
  echo "$f"
}

cmd_spawned() {
  local task="${1:?Usage: worker-usage.sh spawned <task> <role> <adapter> <worktree-dir> [<params-json> [<pool>]]}"
  local role="${2:?missing role}" adapter="${3:?missing adapter}" worktree="${4:?missing worktree-dir}"
  local params="${5:-}" pool="${6:-}"
  [[ -n "$params" ]] || params="{}"
  local physical
  physical="$(cd "$worktree" 2> /dev/null && pwd -P)" || physical="$worktree"
  mkdir -p "$WORKERS_DIR"
  local file tmp
  file="$(record_file "$role" "$task")"
  tmp="$file.new.$$"
  local check
  check="$("$SCRIPTS_DIR/billing-mode.sh" pool "$adapter" ${pool:+--declared "$pool"} --json 2> /dev/null)" || check=null
  jq -e . <<< "$check" > /dev/null 2>&1 || check=null
  jq -nc --arg task "$task" --arg role "$role" --arg adapter "$adapter" --arg cwd "$physical" \
    --argjson params "$params" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg epoch "$(date +%s)" \
    --arg pool "$pool" --argjson check "$check" '
    { task: $task, role: $role, adapter: $adapter, cwd: $cwd, params: $params,
      declared_pool: (if $pool == "" then null else $pool end),
      pool_check: $check,
      started_at: $started, started_epoch: ($epoch | tonumber) }' > "$tmp"
  mv "$tmp" "$file"
  # A Codex or Claude Code worker, or a pi worker on a ChatGPT plan, draws on a subscription allowance: take the reading its run is measured from.
  local vendor
  vendor="$("$SCRIPTS_DIR/allowance.sh" vendor "$adapter" --pool "$(jq -r '.pool // empty' <<< "$check")" 2> /dev/null || true)"
  if [[ -n "$vendor" ]]; then
    "$SCRIPTS_DIR/allowance.sh" begin "worker:$role-$task" --kind worker --window "$role-$task" --vendor "$vendor" \
      || echo "worker-usage.sh: could not take the allowance reading for $role-$task" >&2
  fi
}

cmd_read() {
  local task="${1:?Usage: worker-usage.sh read <task> [--outcome X] [--wait S] [--role R]}"; shift
  local outcome=finished wait=0 role_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --outcome) outcome="${2:?--outcome needs a value}"; shift 2 ;;
      --wait)    wait="${2:?--wait needs seconds}"; shift 2 ;;
      --role)    role_arg="${2:?--role needs a value}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$outcome" in finished|interrupted) ;; *) die "--outcome is finished or interrupted" ;; esac

  local rec role adapter="" cwd="" epoch="" declared_pool="" pool_check=null
  rec="$(find_record "$task")"
  if [[ -n "$rec" ]]; then
    role="$(jq -r .role "$rec")"; adapter="$(jq -r .adapter "$rec")"
    cwd="$(jq -r .cwd "$rec")"; epoch="$(jq -r .started_epoch "$rec")"
    declared_pool="$(jq -r '.declared_pool // empty' "$rec" 2> /dev/null || true)"
    pool_check="$(jq -c '.pool_check // null' "$rec" 2> /dev/null || echo null)"
  else
    # No spawn record (a worker from before this existed, or a spawn that could not write it): the
    # window name gave the role, and nothing else is known. The line says so.
    role="$role_arg"
    [[ -n "$role" ]] || die "no worker record for task $task and no --role"
  fi

  local usage=none reading=null duration=null files=()
  if [[ -n "$adapter" ]] && sessions_root "$adapter" > /dev/null 2>&1; then
    [[ "$adapter" == claude-code && "$wait" -gt 0 ]] && wait_for_cost "$cwd" "$epoch" "$(( wait * 5 ))"
    while IFS= read -r f; do files+=("$f"); done < <(sessions_for "$adapter" "$cwd" "$epoch")
    if [[ ${#files[@]} -gt 0 ]]; then
      reading="$(read_sessions "$adapter" "${files[@]}")"
      [[ "$reading" == null ]] || usage=reported
    fi
  fi
  [[ -z "$epoch" ]] || duration=$(( $(date +%s) - epoch ))

  # What a Codex or Claude Code worker, or a pi worker on a ChatGPT plan, used of its subscription allowance, from the readings at its spawn and now.
  local allowance=null vendor
  vendor="$("$SCRIPTS_DIR/allowance.sh" vendor "$adapter" --pool "$(jq -r '.pool // empty' <<< "$pool_check")" 2> /dev/null || true)"
  if [[ -n "$vendor" ]]; then
    allowance="$("$SCRIPTS_DIR/allowance.sh" end "worker:$role-$task" 2> /dev/null)" || allowance=null
    jq -e . <<< "$allowance" > /dev/null 2>&1 || allowance=null
  fi

  # A Codex worker is asked for a model by the workforce, and the session says which one answered.
  local requested="" answered=""
  if [[ "$adapter" == codex ]]; then
    [[ -z "$rec" ]] || requested="$(jq -r '.params.model // empty' "$rec" 2> /dev/null || true)"
    answered="$(jq -r '.model // empty' <<< "$reading")"
  fi

  local line
  line="$(jq -nc --argjson r "$reading" --arg task "$task" --arg role "$role" --arg adapter "$adapter" \
    --arg outcome "$outcome" --argjson duration "$duration" --arg usage "$usage" --argjson allowance "$allowance" \
    --arg requested "$requested" --arg answered "$answered" --arg declared "$declared_pool" --argjson pool_check "$pool_check" '
    { event: ($task + "/worker-" + $role),
      task: $task,
      handler: null,
      role: $role,
      attempt: null,
      outcome: $outcome,
      rc: null,
      duration_s: $duration,
      harness: (if $adapter == "" then null else $adapter end),
      declared_pool: (if $declared == "" then null else $declared end),
      pool_check: $pool_check,
      model: $r.model,
      input_tokens: $r.input_tokens,
      output_tokens: $r.output_tokens,
      cache_read_tokens: $r.cache_read_tokens,
      cache_write_tokens: $r.cache_write_tokens,
      cache_write_1h_tokens: $r.cache_write_1h_tokens,
      cost_usd: $r.cost_usd,
      turns: $r.turns,
      usage: $usage,
      allowance: $allowance,
      requested_model: (if $requested == "" then null else $requested end),
      answered_model: (if $answered == "" then null else $answered end) }')"
  usage_append "$USAGE_LOG" "$line"
  usage_model_check "$USAGE_LOG" "$role" "$task" "$task/worker-$role" "$adapter" "$requested" "$answered"
  [[ -z "$rec" ]] || rm -f "$rec"
}

cmd_sweep() {
  local rec role task windows
  [[ -d "$WORKERS_DIR" ]] || return 0
  # If tmux cannot list the windows (it is restarting, or the swarm session is not up) nothing is
  # known about which workers are gone, and reading them all as interrupted would also delete the
  # records of workers that are still alive. An empty list from a tmux that answered is different:
  # then every worker is gone.
  windows="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2> /dev/null)" || return 0
  for rec in "$WORKERS_DIR"/*.json; do
    [[ -e "$rec" ]] || continue
    role="$(jq -r .role "$rec")"; task="$(jq -r .task "$rec")"
    grep -qxF -- "$role-$task" <<< "$windows" && continue
    cmd_read "$task" --outcome interrupted
  done
}

cmd_model() {
  local adapter="${1:?Usage: worker-usage.sh model <adapter> <directory> <since-epoch>}"
  local dir="${2:?missing directory}" since="${3:?missing since-epoch}" files=() f physical
  [[ "$since" =~ ^[0-9]+$ ]] || die "since-epoch is a Unix time in seconds"
  sessions_root "$adapter" > /dev/null 2>&1 || return 0
  physical="$(cd "$dir" 2> /dev/null && pwd -P)" || physical="$dir"
  while IFS= read -r f; do files+=("$f"); done < <(sessions_for "$adapter" "$physical" "$since")
  [[ ${#files[@]} -gt 0 ]] || return 0
  read_sessions "$adapter" "${files[@]}" | jq -r '.model // empty'
}

main() {
  command -v jq > /dev/null 2>&1 || { echo "worker-usage.sh needs jq" >&2; exit 3; }
  local cmd="${1:-}"; [[ $# -eq 0 ]] || shift
  case "$cmd" in
    spawned) cmd_spawned "$@" ;;
    read)    cmd_read "$@" ;;
    sweep)   cmd_sweep ;;
    model)   cmd_model "$@" ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: worker-usage.sh spawned|read|sweep|model ..." >&2; exit 1 ;;
  esac
}

main "$@"
