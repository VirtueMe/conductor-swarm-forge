#!/usr/bin/env bash
# Publishes a swarm's .conductor/ history to GitHub issues, after the fact.
# Reads .conductor/ and never writes to it.
#
#   task                 -> one issue (title, body, type, created timestamp)
#   work artifact        -> one comment, in time order
#   current stage        -> a "stage: <name>" label; the issue closes at "done"
#   depends-on           -> plain "Blocked by #n" text
#
# Re-runs are idempotent: a map file (.conductor id -> issue number, last
# artifact posted, stage applied) lets a re-run post only what is new.
# Everything posted is scrubbed of known secret patterns and private paths.
#
# Usage: import-github.sh --repo <owner/name> [--dry-run] [--map-file <path>]
#
# Environment: CONDUCTOR_DIR (default .conductor)

set -euo pipefail
export LC_ALL=C

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
REPO=""
DRY_RUN=false
MAP_FILE=""

usage() {
  echo "Usage: import-github.sh --repo <owner/name> [--dry-run] [--map-file <path>]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="${2:-}";     shift 2 ;;
    --dry-run)  DRY_RUN=true;      shift ;;
    --map-file) MAP_FILE="${2:-}"; shift 2 ;;
    --help|-h)  usage ;;
    *)          echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" ]] || usage
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid --repo: $REPO (expected owner/name)" >&2; exit 1; }
[[ -d "$CONDUCTOR_DIR/tasks" ]] || { echo "No tasks found in $CONDUCTOR_DIR/tasks" >&2; exit 1; }

PREFLIGHT_OUT="$("$SCRIPTS_DIR/preflight-check.sh" --github-import 2>&1)" || {
  echo "$PREFLIGHT_OUT" >&2; exit 1; }

# shellcheck source=scripts/frontmatter.sh
source "$SCRIPTS_DIR/frontmatter.sh"

PROJECT_DIR="$(cd "$(dirname "$CONDUCTOR_DIR")" && pwd)"
MAP_FILE="${MAP_FILE:-$PROJECT_DIR/.export/github-map.tsv}"

WORKTMP="$(mktemp -d)"
trap 'rm -rf "$WORKTMP"' EXIT
SCRUB_COUNT_FILE="$WORKTMP/redactions"
: > "$SCRUB_COUNT_FILE"
export SCRUB_COUNT_FILE

# ── Map file ──────────────────────────────────────────────────────────────────
# Header line "# repo=<owner/name>", then one row per task:
#   <task id> <issue number> <last artifact key> <stage applied> <closed yes|no>
# An empty field is stored as "-": read splits on tab as whitespace, so empty
# fields between tabs would collapse into their neighbours.

if [[ -f "$MAP_FILE" ]]; then
  [[ "$(head -1 "$MAP_FILE")" == "# repo=$REPO" ]] || {
    echo "Map file $MAP_FILE belongs to a different repo ($(head -1 "$MAP_FILE")); refusing to import into $REPO" >&2
    exit 1; }
fi
if [[ "$DRY_RUN" == true ]]; then
  # Work on a copy so the dry run plans against real state without touching it.
  REAL_MAP="$MAP_FILE"
  MAP_FILE="$WORKTMP/map.tsv"
  if [[ -f "$REAL_MAP" ]]; then cp "$REAL_MAP" "$MAP_FILE"; else printf '# repo=%s\n' "$REPO" > "$MAP_FILE"; fi
else
  mkdir -p "$(dirname "$MAP_FILE")"
  [[ -f "$MAP_FILE" ]] || printf '# repo=%s\n' "$REPO" > "$MAP_FILE"
  if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
     && ! git -C "$PROJECT_DIR" check-ignore -q "$MAP_FILE"; then
    echo "Note: $MAP_FILE is not git-ignored in $PROJECT_DIR — add .export/ to its .gitignore" >&2
  fi
fi

map_get()  { awk -F'\t' -v id="$1" '$1==id' "$MAP_FILE"; }
issue_of() { awk -F'\t' -v id="$1" '$1==id{print $2}' "$MAP_FILE"; }
map_put() { # id issue last stage closed
  awk -F'\t' -v id="$1" '$1!=id' "$MAP_FILE" > "$MAP_FILE.tmp"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:--}" "$5" >> "$MAP_FILE.tmp"
  mv "$MAP_FILE.tmp" "$MAP_FILE"
}

# ── Scrubbing ─────────────────────────────────────────────────────────────────

SCRUB_PY=$(cat << 'PY'
import os, re, sys
text = sys.stdin.read()
n = 0
def sub(pat, repl, flags=0):
    global text, n
    text, c = re.subn(pat, repl, text, flags=flags)
    n += c
sub(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', '[REDACTED private key]', re.S)
sub(r'\bgh[pousr]_[A-Za-z0-9]{20,}', '[REDACTED token]')
sub(r'\bgithub_pat_[A-Za-z0-9_]{20,}', '[REDACTED token]')
sub(r'\bAKIA[0-9A-Z]{16}\b', '[REDACTED key]')
sub(r'\bxox[abprs]-[A-Za-z0-9-]{10,}', '[REDACTED token]')
sub(r'\bsk-[A-Za-z0-9_-]{20,}', '[REDACTED key]')
sub(r'(authorization:\s*(?:bearer|basic|token)\s+)\S+', r'\1[REDACTED]', re.I)
sub(r'\b((?:api[_-]?key|secret|token|passw(?:or)?d|pwd)\s*[:=]\s*)\S+', r'\1[REDACTED]', re.I)
sub(r'\b(https?://)[^/\s:@]+:[^/\s@]+@', r'\1[REDACTED]@', re.I)
sub(r'/(?:Users|home)/[^/\s]+', '~')
sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[REDACTED email]')
sys.stdout.write(text)
with open(os.environ['SCRUB_COUNT_FILE'], 'a') as f:
    f.write('%d\n' % n)
PY
)

scrub() { python3 -c "$SCRUB_PY"; }

# ── Tracker ───────────────────────────────────────────────────────────────────
# Every call to GitHub lives in the tracker_* functions below, so another
# backend means replacing this block. Inputs are body files; results come back
# through globals (no subshells, so set -e and counters behave).

NEW_ISSUE=""
DRY_ISSUE_SEQ=0
EXISTING_FILE=""   # "<task id>\t<issue number>" for issues already on the remote
LABELS_ENSURED=" "

tracker_label_ensure() { # <label>
  [[ "$LABELS_ENSURED" == *" $1 "* ]] && return 0
  LABELS_ENSURED+="$1 "
  if [[ "$DRY_RUN" == true ]]; then echo "  would ensure label: $1"; return 0; fi
  gh label create "$1" --repo "$REPO" --force --description "Imported from the swarm's .conductor log" >/dev/null
}

# The remote is the source of truth for "was this task imported": each issue
# body carries a conductor-import marker. The map is only a cache of it, so a
# crash between creating an issue and recording it does not duplicate the issue.
tracker_existing_issue() { # <task id> -> prints the issue number, if any
  if [[ -z "$EXISTING_FILE" ]]; then
    EXISTING_FILE="$WORKTMP/existing.tsv"
    # shellcheck disable=SC2016  # the $ are jq's, not the shell's
    gh issue list --repo "$REPO" --state all --limit 1000 --json number,body \
      --jq '.[] | (.body | capture("<!-- conductor-import: (?<id>[^ ]+) -->")? // empty) as $m | "\($m.id)\t\(.number)"' \
      > "$EXISTING_FILE"
  fi
  awk -F'\t' -v id="$1" '$1==id{print $2; exit}' "$EXISTING_FILE"
}

tracker_issue_create() { # <task id> <title> <body-file>
  if [[ "$DRY_RUN" == true ]]; then
    DRY_ISSUE_SEQ=$(( DRY_ISSUE_SEQ + 1 )); NEW_ISSUE="dry$DRY_ISSUE_SEQ"
    echo "  would create issue: $2"; return 0
  fi
  local url
  NEW_ISSUE="$(tracker_existing_issue "$1")"
  if [[ -n "$NEW_ISSUE" ]]; then echo "  adopting existing #$NEW_ISSUE for task $1" >&2; return 0; fi
  url=$(gh issue create --repo "$REPO" --title "$2" --body-file "$3")
  NEW_ISSUE="${url##*/}"
}

tracker_comment() { # <issue> <body-file> <artifact name>
  if [[ "$DRY_RUN" == true ]]; then echo "  would comment on #$1: $3"; return 0; fi
  gh issue comment "$1" --repo "$REPO" --body-file "$2" >/dev/null
}

tracker_set_stage() { # <issue> <new label> [<old label>]
  if [[ "$DRY_RUN" == true ]]; then echo "  would set label on #$1: $2"; return 0; fi
  if [[ -n "${3:-}" ]]; then
    gh issue edit "$1" --repo "$REPO" --add-label "$2" --remove-label "$3" >/dev/null
  else
    gh issue edit "$1" --repo "$REPO" --add-label "$2" >/dev/null
  fi
}

tracker_close() { # <issue>
  if [[ "$DRY_RUN" == true ]]; then echo "  would close #$1"; return 0; fi
  gh issue close "$1" --repo "$REPO" >/dev/null
}

# ── Rendering ─────────────────────────────────────────────────────────────────

# Artifacts of one task, oldest first. Filenames start with the type, so they do
# not sort by time: sort on the timestamp, break same-second ties by lifecycle
# order, then by name.
type_rank() {
  case "$1" in
    card) echo 0 ;; assigned) echo 1 ;; progress) echo 2 ;; drift) echo 3 ;;
    signal) echo 4 ;; review) echo 5 ;; merge) echo 6 ;; moved) echo 7 ;;
    done) echo 8 ;; *) echo 9 ;;
  esac
}

list_artifacts() { # <task id> -> "<timestamp>|<rank>|<name>|<path>"
  local dir="$CONDUCTOR_DIR/work/$1" f name type ts
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    type="$(fm_field "$f" type)"
    ts="$(fm_field "$f" timestamp)"
    [[ -n "$ts" ]] || { ts="${name#*-}"; ts="${ts%.md}"; }
    printf '%s|%s|%s|%s\n' "$ts" "$(type_rank "$type")" "$name" "$f"
  done | sort
}

render_issue_body() { # <task id> <task file> <blocked-by text>
  local created
  created="$(list_artifacts "$1" | head -1 | cut -d'|' -f1)"
  printf "> Imported from the swarm's \`.conductor\` log. Task \`%s\` · type: %s · created %s\n" \
    "$1" "$(fm_field "$2" type)" "${created:-unknown}"
  printf '<!-- conductor-import: %s -->\n\n' "$1"
  fm_body "$2"
  if [[ -n "$3" ]]; then printf '\nBlocked by %s\n' "$3"; fi
}

render_comment() { # <artifact file>
  local f="$1" head type body files
  type="$(fm_field "$f" type)"
  head="**${type}** · $(fm_field "$f" timestamp)"
  [[ "$type" == "moved" ]] && head+=" → $(fm_field "$f" to)"
  [[ -n "$(fm_field "$f" outcome)" ]] && head+=" · outcome: $(fm_field "$f" outcome)"
  [[ -n "$(fm_field "$f" worker-type)" ]] && head+=" · $(fm_field "$f" worker-type)"
  printf '%s\n' "$head"
  [[ -n "$(fm_field "$f" branch)" ]] && printf "\nbranch: \`%s\`\n" "$(fm_field "$f" branch)"
  files="$(fm_list "$f" files-changed | sed "s/.*/\`&\`/" | paste -sd, - | sed 's/,/, /g')"
  [[ -n "$files" ]] && printf '\nfiles: %s\n' "$files"
  body="$(fm_body "$f")"
  [[ -n "$body" ]] && printf '\n%s\n' "$body"
  return 0
}

# ── Import ────────────────────────────────────────────────────────────────────

IDS=()
for f in "$CONDUCTOR_DIR"/tasks/*.md; do
  [[ -f "$f" ]] && IDS+=("$(basename "$f" .md)")
done
(( ${#IDS[@]} > 0 )) || { echo "No tasks found in $CONDUCTOR_DIR/tasks" >&2; exit 1; }

ISSUES_CREATED=0
COMMENTS_POSTED=0

# Pass 1: create issues. A task is created once every task it depends on has an
# issue number, so "Blocked by #n" is known at creation time.
remaining=()
for id in "${IDS[@]}"; do
  [[ -n "$(issue_of "$id")" ]] || remaining+=("$id")
done

while (( ${#remaining[@]} > 0 )); do
  deferred=()
  progressed=false
  for id in "${remaining[@]}"; do
    task_file="$CONDUCTOR_DIR/tasks/$id.md"
    blocked=""
    unmet=false
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if [[ -f "$CONDUCTOR_DIR/tasks/$dep.md" ]]; then
        dep_issue="$(issue_of "$dep")"
        if [[ -z "$dep_issue" ]]; then unmet=true; break; fi
        blocked+="${blocked:+, }#$dep_issue"
      else
        blocked+="${blocked:+, }$dep (not imported)"
      fi
    done < <(fm_list "$task_file" depends-on)
    if [[ "$unmet" == true ]]; then deferred+=("$id"); continue; fi

    title="$(fm_field "$task_file" title)"
    render_issue_body "$id" "$task_file" "$blocked" | scrub > "$WORKTMP/body.md"
    printf '%s' "$title" | scrub > "$WORKTMP/title.txt"
    tracker_issue_create "$id" "$(cat "$WORKTMP/title.txt")" "$WORKTMP/body.md"
    map_put "$id" "$NEW_ISSUE" "" "" "no"
    echo "task $id -> #$NEW_ISSUE  $title"
    ISSUES_CREATED=$(( ISSUES_CREATED + 1 ))
    progressed=true
  done
  if [[ "$progressed" == false ]]; then
    echo "Cannot order tasks, dependency cycle among: ${deferred[*]}" >&2
    exit 1
  fi
  remaining=()
  if (( ${#deferred[@]} > 0 )); then remaining=("${deferred[@]}"); fi
done

# Pass 2: per task, post new artifacts as comments, then sync stage and state.
for id in "${IDS[@]}"; do
  IFS=$'\t' read -r _ issue last stage closed <<< "$(map_get "$id")"
  [[ "$last" == "-" ]] && last=""
  [[ "$stage" == "-" ]] && stage=""
  want_stage="$stage"
  saw_done=false

  while IFS='|' read -r ts rank name path; do
    key="$ts|$rank|$name"
    if [[ -n "$last" && ! "$key" > "$last" ]]; then continue; fi
    render_comment "$path" | scrub > "$WORKTMP/comment.md"
    tracker_comment "$issue" "$WORKTMP/comment.md" "$name"
    COMMENTS_POSTED=$(( COMMENTS_POSTED + 1 ))
    last="$key"
    case "$(fm_field "$path" type)" in
      moved) want_stage="$(fm_field "$path" to)" ;;
      done)  saw_done=true ;;
    esac
    map_put "$id" "$issue" "$last" "$stage" "$closed"
  done < <(list_artifacts "$id")

  if [[ "$want_stage" != "$stage" ]]; then
    tracker_label_ensure "stage: $want_stage"
    tracker_set_stage "$issue" "stage: $want_stage" "${stage:+stage: $stage}"
    stage="$want_stage"
    map_put "$id" "$issue" "$last" "$stage" "$closed"
  fi
  if [[ "$closed" != "yes" && ( "$stage" == "done" || "$saw_done" == true ) ]]; then
    tracker_close "$issue"
    closed="yes"
    map_put "$id" "$issue" "$last" "$stage" "$closed"
  fi
done

REDACTIONS=$(awk '{s+=$1} END{print s+0}' "$SCRUB_COUNT_FILE")
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: would import $ISSUES_CREATED issue(s) and $COMMENTS_POSTED comment(s) into $REPO; $REDACTIONS redaction(s) applied"
else
  echo "Imported $ISSUES_CREATED issue(s) and $COMMENTS_POSTED comment(s) into $REPO; $REDACTIONS redaction(s) applied. Map: $MAP_FILE"
fi
