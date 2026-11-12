#!/usr/bin/env bash
# Tests scripts/codex-app-server-check.sh: the script a person runs to see a real read through
# `codex app-server`, timed (#228). Here the codex is a stand-in that speaks the protocol, so it
# checks the script's own verdicts and exit status, never what a real Codex does. The real Codex
# is never started.
#
# Usage: scripts/test-codex-app-server-check.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPTS_DIR/codex-app-server-check.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
section() { echo ""; echo "── $1"; }
has() { if grep -q -- "$1" "$TMP/out"; then ok "$2"; else fail "$2 (in output: $(tr '\n' '|' < "$TMP/out" | cut -c1-400))"; fi; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.166.0"; exit 0 ;;
  app-server) ;;
  *) exit 2 ;;
esac
while IFS= read -r line; do
  method="$(jq -r '.method // empty' <<< "$line")"; id="$(jq -r '.id // empty' <<< "$line")"
  echo "$method" >> "$STUB_LOG"
  case "$method" in
    initialize) jq -nc --argjson id "$id" --arg ua "${STUB_UA-codex_cli_rs/0.166.0 (stub)}" '{id: $id, result: {userAgent: $ua}}' ;;
    account/rateLimits/read)
      case "${STUB_MODE:-ok}" in
        ok)    jq -nc --argjson id "$id" --slurpfile r "$STUB_RESULT" '{id: $id, result: $r[0]}' ;;
        error) jq -nc --argjson id "$id" '{id: $id, error: {code: -32000, message: "not signed in"}}' ;;
        leak)  # leaves a process behind under the name `<this binary> app-server`, after the answer
               ( exec -a "$0 app-server" sleep 20 ) > /dev/null 2>&1 &
               jq -nc --argjson id "$id" --slurpfile r "$STUB_RESULT" '{id: $id, result: $r[0]}' ;;
      esac ;;
  esac
done
STUB
chmod +x "$TMP/bin/codex"
export STUB_LOG="$TMP/stub.log" STUB_RESULT="$TMP/result.json" CODEX_APP_SERVER_TIMEOUT=5
FUTURE=$(( $(date +%s) + 100000 ))
cat > "$STUB_RESULT" <<JSON
{"rateLimits":{"limitId":"codex","planType":"plus",
 "primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":$FUTURE},
 "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":$(( FUTURE + 500000 ))}}}
JSON
run() { : > "$STUB_LOG"; RC=0; env CODEX_BIN="$TMP/bin/codex" "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?; }

section "1 · A good read passes"
run "$CHECK" --runs 2
assert_eq "exit 0" "$RC" "0"
has '^read 1: [0-9]* ms  source=codex app-server' "each read is timed and says where it came from"
has '^read 2:' "and there are two of them"
has 'five_hour=known 7%  weekly=known 12%  plan=plus  version=0.166.0' "the windows, the plan and the version are shown"
has '^time: *fastest [0-9]* ms, median [0-9]* ms, slowest [0-9]* ms' "the times are summed up"
has '^Machine: ' "the machine is named (a macOS run should say so)"
has '^bash: ' "and its bash"
has '^PASS  source' "source passes"
has '^PASS  windows' "windows pass"
has '^PASS  version' "version passes"
has '^PASS  cleanup' "cleanup passes"
assert_eq "the stand-in was asked twice, in order" "$(tr '\n' ' ' < "$STUB_LOG")" "initialize initialized account/rateLimits/read initialize initialized account/rateLimits/read "
assert_eq "the default is three reads" "$(run "$CHECK"; grep -c '^read ' "$TMP/out")" "3"

section "2 · What is wrong shows as a FAIL and exit 1"
run env STUB_MODE=error "$CHECK" --runs 1
assert_eq "an app-server that answers with an error: exit 1" "$RC" "1"
has '^FAIL  source' "the source is not the app-server"
has '^FAIL  windows' "the windows are not known"
has 'not signed in\|app-server answered with an error' "and the reason is shown"
run env STUB_UA="no version here" "$CHECK" --runs 1
assert_eq "an initialize answer with no version in it: exit 1" "$RC" "1"
has '^FAIL  version' "the version guess is reported as wrong"
has '^PASS  windows' "while the windows still pass"

run env STUB_MODE=leak "$CHECK" --runs 1
assert_eq "a process left running under the binary's name: exit 1" "$RC" "1"
has '^FAIL  cleanup: 1 app-server process' "the cleanup verdict fails and counts it"
has '^PASS  source' "while the read itself passed"
pkill -f "$TMP/bin/codex app-server" 2> /dev/null || true
run env STUB_MODE=error "$CHECK" --runs 2
has '^time: *none' "reads that failed give no time, so no misleadingly fast figure"

section "3 · Setup problems and options"
run "$CHECK" --dry-run
assert_eq "--dry-run: exit 0" "$RC" "0"
assert_eq "and nothing was started" "$(wc -c < "$STUB_LOG" | tr -d ' ')" "0"
has 'dry run' "it says so"
run env CODEX_BIN="$TMP/does-not-exist" "$CHECK"
assert_eq "no codex binary: exit 1" "$RC" "1"
case "$(cat "$TMP/err")" in *"no codex binary"*"CODEX_BIN"*) ok "and it says what to do" ;; *) fail "message: $(cat "$TMP/err")" ;; esac
run "$CHECK" --runs 0
assert_eq "--runs 0: exit 1" "$RC" "1"
run "$CHECK" --runs 21
assert_eq "--runs 21 (above the limit): exit 1" "$RC" "1"
run "$CHECK" --runs abc
assert_eq "--runs that is not a number: exit 1" "$RC" "1"
run "$CHECK" --bogus
assert_eq "an unknown flag: exit 1" "$RC" "1"
run "$CHECK" --help
assert_eq "--help: exit 0" "$RC" "0"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "$FAILS check(s) failed." >&2; exit 1
