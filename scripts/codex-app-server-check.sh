#!/usr/bin/env bash
set -euo pipefail
# A real read of the ChatGPT plan window through `codex app-server`, timed. This is the check that
# cannot be done without Codex and an account (#228): it shows that codex-usage.sh gets a reading
# from the live app-server, how long that takes, and that nothing is left running afterwards. Run it
# on the machines that matter (Linux, and macOS with its own bash 3.2).
#
# Usage: codex-app-server-check.sh [--runs <n>] [--dry-run]
#   --runs n     how many reads, one after the other (default 3, at most 20)
#   --dry-run    show what would be run and the machine it would run on, start nothing
# Env:   CODEX_BIN  the codex binary to ask (default: codex on PATH)
#        CODEX_APP_SERVER_TIMEOUT  seconds to wait for each read (default 15, as codex-usage.sh)
#
# What it does: points codex-usage.sh at an empty sessions directory, so there is no log to fall back
# on and the only possible source is the app-server, then reads n times and times each read. It
# prints each reading, the fastest, median and slowest time (of the reads that came from the app-server), the machine (uname, bash, codex
# versions), and four verdicts:
#   source     every read came from the app-server
#   windows    both windows are known on every read
#   version    the version was found in initialize's userAgent (null means that guess was wrong)
#   cleanup    no `app-server` process of this binary is left that was not running before (by pid,
#              matched on the command line; other Codex apps keep their own, which do not count). A
#              helper process a real Codex started under its own name is not seen by this
# The exit status is 0 when all four pass, 1 when any fails. It reads the plan's limits; it asks no
# model anything, so it should not use any allowance. Nothing under .conductor is touched.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS=3
DRY=false

die() { echo "codex-app-server-check.sh: $*" >&2; exit 1; }

now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; } # BSD date has no %N

# The pids of the running `<binary> app-server` processes, one per line. A fixed-string match on
# the command line (no regex, so a path with odd characters is safe); ps -axo works on Linux and macOS.
# The match is done in the shell: a grep or awk given the pattern would show up as a match itself.
server_pids() { # <binary>
  local pid args
  while read -r pid args; do
    [[ "$args" == *"$1 app-server"* ]] && echo "$pid"
  done < <(ps -axo pid=,args= 2> /dev/null || true) | sort
  return 0
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runs)    RUNS="${2:?--runs needs a number}"; shift 2 ;;
      --dry-run) DRY=true; shift ;;
      -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "Usage: codex-app-server-check.sh [--runs <n>] [--dry-run]" ;;
    esac
  done
  [[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 && "$RUNS" -le 20 ]] || die "--runs takes a number from 1 to 20"
  command -v jq > /dev/null 2>&1 || die "needs jq"
  command -v python3 > /dev/null 2>&1 || die "needs python3 (for millisecond timing)"
  local bin="${CODEX_BIN:-codex}"
  command -v "$bin" > /dev/null 2>&1 || die "no codex binary ('$bin'): install Codex and sign in with ChatGPT, or set CODEX_BIN"

  echo "Machine:  $(uname -srm)"
  echo "bash:     $BASH_VERSION"
  local version
  version="$({ "$bin" --version 2> /dev/null || true; } | head -n 1)"
  echo "codex:    ${version:-unknown} ($(command -v "$bin"))"
  echo "reads:    $RUNS, from an empty sessions directory, so only the app-server can answer"
  if [[ "$DRY" == true ]]; then echo "(dry run: nothing was started)"; return 0; fi

  local scratch before after leaked i start end ms reading times=() good=0 fails=0 src_ok=true win_ok=true ver_ok=true
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch:-}"' EXIT
  mkdir -p "$scratch/sessions"
  before="$(server_pids "$bin")"
  echo ""
  for (( i = 1; i <= RUNS; i++ )); do
    start="$(now_ms)"
    reading="$(CODEX_SESSIONS_DIR="$scratch/sessions" CODEX_BIN="$bin" "$SCRIPTS_DIR/codex-usage.sh" 2> /dev/null)" || reading=""
    end="$(now_ms)"; ms=$(( end - start ))
    if ! jq -e . <<< "$reading" > /dev/null 2>&1; then
      echo "read $i: ${ms} ms  no JSON from codex-usage.sh"; src_ok=false; win_ok=false; ver_ok=false; continue
    fi
    echo "read $i: ${ms} ms  $(jq -r '"source=\(.source // "none")  five_hour=\(.five_hour.state) \(.five_hour.used_percent // "-")%  weekly=\(.weekly.state) \(.weekly.used_percent // "-")%  plan=\(.plan_type // "-")  version=\(.codex_version // "null")"' <<< "$reading")"
    if [[ "$(jq -r .source <<< "$reading")" == "codex app-server" ]]; then times+=("$ms"); good=$(( good + 1 )); else src_ok=false; fi
    [[ "$(jq -r '[.five_hour.state, .weekly.state] | all(. == "known")' <<< "$reading")" == true ]] || win_ok=false
    [[ "$(jq -r '.codex_version // empty' <<< "$reading")" != "" ]] || ver_ok=false
    [[ "$i" -eq 1 ]] && { jq -r '"  first reading: five_hour reason=\(.five_hour.reason // "none"), weekly reason=\(.weekly.reason // "none")"' <<< "$reading"; }
  done
  # Give a server that was told to stop (TERM, then KILL after two seconds) time to be gone, then
  # look for ones that were not there before and still are. Only new pids count: other Codex apps
  # keep their own running.
  sleep 3
  after="$(server_pids "$bin")"
  leaked="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true)"

  echo ""
  if [[ "$good" -gt 0 ]]; then
    local sorted min med max
    sorted="$(printf '%s\n' "${times[@]}" | sort -n)"
    min="$(head -n 1 <<< "$sorted")"; max="$(tail -n 1 <<< "$sorted")"
    med="$(sed -n "$(( (good + 1) / 2 ))p" <<< "$sorted")"
    echo "time:     fastest ${min} ms, median ${med} ms, slowest ${max} ms (of $good read(s) that came from the app-server, $RUNS made)"
  else
    echo "time:     none: no read came from the app-server, so there is no time to report"
  fi
  echo ""
  verdict() { if [[ "$2" == true ]]; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$(( fails + 1 )); fi; }
  verdict "source: every read came from the app-server" "$src_ok"
  verdict "windows: both known on every read" "$win_ok"
  verdict "version: found in initialize's userAgent" "$ver_ok"
  verdict "cleanup: $leaked app-server process(es) left running that were not there before" "$([[ "$leaked" -eq 0 ]] && echo true || echo false)"
  [[ "$fails" -eq 0 ]]
}

main "$@"
