#!/usr/bin/env bash
# Tests import-github.sh with no AI and no network: a hand-built .conductor/
# fixture, a fake `gh` on PATH that records every call and body, and assertions
# on those calls. The fixture is built to catch the traps in the format:
# filenames that do not sort chronologically, same-second timestamps, a
# forward depends-on, a markdown rule in a task body, and secrets.
#
# Usage: scripts/test-import-github.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/proj"
CONDUCTOR="$PROJ/.conductor"
BIN="$WORK/bin"
GH_LOG="$WORK/gh.log"
GH_BODIES="$WORK/gh-bodies.log"
GH_COUNTER="$WORK/gh-counter"
MAP="$PROJ/.export/github-map.tsv"
mkdir -p "$PROJ" "$BIN"
export GH_LOG GH_BODIES GH_COUNTER

FAILS=0
ok()   { echo "   ✓  $1"; }
fail() { echo "   ✗  $1" >&2; FAILS=$(( FAILS + 1 )); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then ok "$1"; else fail "$1 (missing '$3')"; fi
}

# ── Fake gh ───────────────────────────────────────────────────────────────────
# Logs "<args>" per call, copies any --body-file into GH_BODIES under a marker
# line, and answers `issue create` with an incrementing issue URL.

cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
  if [[ "${args[i]}" == "--body-file" ]]; then
    { echo "=== $1 $2 ${3:-} ==="; cat "${args[i+1]}"; } >> "$GH_BODIES"
  fi
done
if [[ "$1 $2" == "issue list" ]]; then
  # Answers with the already-extracted "<id>\t<number>" lines (the jq is ours, not run here).
  [[ -n "${GH_EXISTING:-}" && -f "$GH_EXISTING" ]] && cat "$GH_EXISTING"
  exit 0
fi
if [[ "$1 $2" == "issue create" ]]; then
  n=$(( $(cat "$GH_COUNTER" 2>/dev/null || echo 100) + 1 ))
  echo "$n" > "$GH_COUNTER"
  echo "https://github.com/o/r/issues/$n"
fi
EOF
chmod +x "$BIN/gh"

# ── Fixture ───────────────────────────────────────────────────────────────────

mk_task() { # <id> <title> <type> <deps csv|""> <body>
  local id="$1" title="$2" type="$3" deps="$4" body="$5" d
  mkdir -p "$CONDUCTOR/tasks"
  {
    printf -- '---\nid: %s\ntitle: %s\ntype: %s\n' "$id" "$title" "$type"
    if [[ -z "$deps" ]]; then
      echo "depends-on: []"
    else
      echo "depends-on:"
      for d in ${deps//,/ }; do echo "  - $d"; done
    fi
    printf -- '---\n\n%s\n' "$body"
  } > "$CONDUCTOR/tasks/$id.md"
}

art() { # <task> <type> <timestamp> <body> [extra frontmatter lines...]
  local task="$1" type="$2" ts="$3" body="$4" l
  shift 4
  local f="$CONDUCTOR/work/$task/$type-$ts.md"
  mkdir -p "$(dirname "$f")"
  {
    printf -- '---\ntype: %s\ntask-id: %s\ntimestamp: %s\n' "$type" "$task" "$ts"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n'
    if [[ -n "$body" ]]; then printf '%s\n' "$body"; fi
  } > "$f"
}

mk_task 0001 "Define model" design "" "## Description
Define the model.

---

Second section after a rule.

## Acceptance Criteria
- [ ] "
mk_task 0002 "Build graph" feature 0001 "## Description
Use token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and API_KEY=hunter2hunter2 from /Users/alice/proj.
Contact alice@example.com."
mk_task 0003 "Game loop" feature 0004 "## Description
Needs the Wumpus first (a forward reference: 0004 is created later in id order)."
mk_task 0004 "Wumpus" feature "" "## Description
Wumpus behaviour."

# 0001: filename order is NOT chronological, and three pairs share a second.
art 0001 card     20260101-100000 "" "priority: normal"
art 0001 moved    20260101-100000 "" "to: ready"
art 0001 assigned 20260101-100100 "" "worker-type: coder" "branch: feature/0001-define-model"
art 0001 moved    20260101-100100 "" "to: in-progress"
art 0001 progress 20260101-100200 "halfway there"
art 0001 signal   20260101-100300 "model done" "outcome: complete" "files-changed:" "  - src/model.clj"
art 0001 moved    20260101-100400 "" "to: done"

art 0002 card     20260101-100500 "" "priority: normal"
art 0002 moved    20260101-100500 "" "to: ready"
art 0002 progress 20260101-100600 "worked in /Users/alice/proj/.worktrees/coder-0002
Authorization: Bearer abc123def456ghi789"

art 0003 card     20260101-100700 "" "priority: normal"
art 0003 moved    20260101-100700 "" "to: ready"
art 0004 card     20260101-100800 "" "priority: normal"
art 0004 moved    20260101-100800 "" "to: backlog"

snap() { (cd "$PROJ" && find .conductor -type f | LC_ALL=C sort | xargs cksum); }
SNAP_BEFORE=$(snap)

imp() { (cd "$PROJ" && PATH="$BIN:$PATH" "$SCRIPTS_DIR/import-github.sh" "$@" 2>&1); }
reset_log() { : > "$GH_LOG"; : > "$GH_BODIES"; }
calls() { grep -c "^$1" "$GH_LOG" || true; }
issue_for() { awk -F'\t' -v id="$1" '$1==id{print $2}' "$MAP"; }
comment_heads() {
  awk -v n="$1" '/^=== /{ on = ($0 == "=== issue comment " n " ==="); next } on && /^\*\*/ {print}' "$GH_BODIES" \
    | sed -E 's/^\*\*([a-z]+)\*\*.*(→ [a-z-]+).*/\1 \2/; s/^\*\*([a-z]+)\*\*.*/\1/' \
    | paste -sd'|' -
}

# ── Usage errors ──────────────────────────────────────────────────────────────

echo "── usage"
reset_log
if imp >/dev/null; then fail "--repo is required"; else ok "--repo is required"; fi

# ── Dry run ───────────────────────────────────────────────────────────────────

echo "── dry run"
reset_log
OUT=$(imp --repo o/r --dry-run)
assert_eq "dry run makes no gh calls"    "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
if [[ -e "$MAP" ]]; then fail "dry run writes no map"; else ok "dry run writes no map"; fi
assert_contains "dry run lists comments"  "$OUT" "would comment on #dry1: card-20260101-100000.md"
assert_contains "dry run reports issues"   "$OUT" "would import 4 issue(s)"
assert_contains "dry run reports comments" "$OUT" "14 comment(s)"
if grep -qE '[1-9][0-9]* redaction' <<< "$OUT"; then ok "dry run reports redactions"; else fail "dry run reports redactions"; fi

# ── First import ──────────────────────────────────────────────────────────────

echo "── first import"
reset_log
imp --repo o/r >/dev/null
assert_eq "one issue per task"           "$(calls 'issue create')" "4"
assert_eq "creation order respects depends-on" \
  "$(grep '^issue create' "$GH_LOG" | sed -E 's/.*--title (.*) --body-file.*/\1/' | paste -sd'|' -)" \
  "Define model|Build graph|Wumpus|Game loop"
assert_eq "map has a repo header and 4 rows" "$(head -1 "$MAP")|$(grep -vc '^#' "$MAP")" "# repo=o/r|4"
N1=$(issue_for 0001); N2=$(issue_for 0002); N3=$(issue_for 0003); N4=$(issue_for 0004)

BODY1=$(awk '/^=== issue create/{c++} c==1' "$GH_BODIES")
assert_contains "task body keeps its markdown rule" "$BODY1" "Second section after a rule."
if grep -qx -- '---' <<< "$BODY1"; then ok "rule line preserved"; else fail "rule line preserved"; fi
assert_contains "issue carries task type"        "$BODY1" "type: design"
assert_contains "issue carries created timestamp" "$BODY1" "20260101-100000"
assert_contains "backward dependency"            "$(grep -A99 '^=== issue create' "$GH_BODIES" | grep -F "Blocked by #$N1" || true)" "Blocked by #$N1"
assert_contains "forward dependency"             "$(grep -F "Blocked by #$N4" "$GH_BODIES" || true)" "Blocked by #$N4"

assert_eq "comments follow time, ties by type" "$(comment_heads "$N1")" \
  "card|moved → ready|assigned|moved → in-progress|progress|signal|moved → done"
assert_eq "comment count per task" \
  "$(for n in $N1 $N2 $N3 $N4; do comment_heads "$n" | tr '|' '\n' | wc -l | tr -d ' '; done | paste -sd, -)" \
  "7,3,2,2"

assert_contains "stage label created"  "$(cat "$GH_LOG")" "label create stage: done"
assert_contains "final stage applied, not the history" "$(cat "$GH_LOG")" "issue edit $N1 --repo o/r --add-label stage: done"
if grep -qF "issue edit $N1 --repo o/r --add-label stage: ready" "$GH_LOG"; then
  fail "intermediate stages are not applied"; else ok "intermediate stages are not applied"; fi
assert_eq "only the done task is closed" "$(grep '^issue close' "$GH_LOG" | paste -sd, -)" "issue close $N1 --repo o/r"

for secret in ghp_abcdefghijklmnopqrstuvwxyz0123456789 hunter2hunter2 alice abc123def456ghi789; do
  if grep -qF -- "$secret" "$GH_BODIES" "$GH_LOG"; then fail "secret '$secret' never reaches GitHub"; else ok "secret '$secret' never reaches GitHub"; fi
done
assert_eq ".conductor is left untouched" "$(snap)" "$SNAP_BEFORE"

# ── Re-run is idempotent ──────────────────────────────────────────────────────

echo "── re-run"
reset_log
imp --repo o/r >/dev/null
assert_eq "re-run makes no gh calls" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# ── Incremental ───────────────────────────────────────────────────────────────

echo "── incremental"
art 0003 progress 20260101-110000 "started the loop"
art 0003 moved    20260101-110100 "" "to: in-progress"
reset_log
imp --repo o/r >/dev/null
assert_eq "no new issues"        "$(calls 'issue create')" "0"
assert_eq "only the new comments" "$(calls "issue comment $N3")" "2"
assert_contains "stage moves on" "$(cat "$GH_LOG")" "issue edit $N3 --repo o/r --add-label stage: in-progress --remove-label stage: ready"

# ── Crash between create and map write ────────────────────────────────────────

echo "── crash recovery"
cp "$MAP" "$WORK/map.bak"
grep -v "^0004	" "$WORK/map.bak" > "$MAP"
printf '0004\t%s\n' "$N4" > "$WORK/existing.tsv"
export GH_EXISTING="$WORK/existing.tsv"
reset_log
imp --repo o/r >/dev/null
assert_eq "existing issue is adopted, not duplicated" "$(calls 'issue create')" "0"
assert_eq "adopted issue is mapped again" "$(issue_for 0004)" "$N4"
unset GH_EXISTING

# ── Guard rails ───────────────────────────────────────────────────────────────

echo "── guard rails"
reset_log
if imp --repo other/repo >/dev/null; then fail "map from another repo is refused"; else ok "map from another repo is refused"; fi
assert_eq "refusal makes no gh calls" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

echo "── real swarm output (test-flow.sh)"
FLOW="$WORK/flow"
STEP_DELAY=0 "$SCRIPTS_DIR/test-flow.sh" "$FLOW" >/dev/null 2>&1
FLOW_SNAP=$(cd "$FLOW" && find .conductor -type f | LC_ALL=C sort | xargs cksum)
reset_log; rm -f "$GH_COUNTER"
(cd "$FLOW" && PATH="$BIN:$PATH" "$SCRIPTS_DIR/import-github.sh" --repo o/r >/dev/null 2>&1)
assert_eq "one issue per swarm task"  "$(calls 'issue create')" "$(find "$FLOW/.conductor/tasks" -name '*.md' | wc -l | tr -d ' ')"
assert_eq "swarm map is under .export" "$(test -f "$FLOW/.export/github-map.tsv" && echo yes)" "yes"
assert_eq "swarm .conductor untouched" "$(cd "$FLOW" && find .conductor -type f | LC_ALL=C sort | xargs cksum)" "$FLOW_SNAP"
reset_log
(cd "$FLOW" && PATH="$BIN:$PATH" "$SCRIPTS_DIR/import-github.sh" --repo o/r >/dev/null 2>&1)
assert_eq "swarm re-run makes no gh calls" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

echo "── preflight"
if PATH="$WORK/empty" /bin/bash "$SCRIPTS_DIR/preflight-check.sh" --github-import >/dev/null 2>&1; then
  fail "preflight fails without gh"; else ok "preflight fails without gh"; fi
if PATH="$BIN:$PATH" "$SCRIPTS_DIR/preflight-check.sh" --github-import >/dev/null 2>&1; then
  ok "preflight passes with gh, without needing tmux or claude"; else fail "preflight passes with gh, without needing tmux or claude"; fi

echo "── .export is ignored"
if grep -qx '.export/' "$ROOT_DIR/.gitignore"; then ok "repo .gitignore"; else fail "repo .gitignore"; fi
assert_eq "swarm-start .gitignore templates" "$(grep -c '^\.export/$' "$ROOT_DIR/scripts/swarm-start.sh")" "2"

echo ""
if (( FAILS > 0 )); then echo "$FAILS check(s) failed" >&2; exit 1; fi
echo "All checks passed"
