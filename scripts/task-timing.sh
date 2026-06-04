#!/usr/bin/env bash
# Reports timing for all tasks in a conductor dir.
# Derives durations from the moved-*.md artifact timestamps.
#
# Usage:
#   CONDUCTOR_DIR=.conductor scripts/task-timing.sh
#   CONDUCTOR_DIR=.conductor scripts/task-timing.sh --json

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
FORMAT="${1:-}"

WORK_DIR="$CONDUCTOR_DIR/work"
TASKS_DIR="$CONDUCTOR_DIR/tasks"

[[ -d "$WORK_DIR" ]] || { echo "No work dir found at $WORK_DIR" >&2; exit 1; }

# Phase ordering comes from the active topology's stages, not a hardcoded list.
# shellcheck source=scripts/stages-resolve.sh
source "$SCRIPTS_DIR/stages-resolve.sh"
STAGES="$(topology_stages "$CONDUCTOR_DIR" | tr '\n' ',')"

python3 - "$WORK_DIR" "$TASKS_DIR" "$FORMAT" "$STAGES" << 'EOF'
import sys, os, re, json
from datetime import datetime

work_dir   = sys.argv[1]
tasks_dir  = sys.argv[2]
fmt        = sys.argv[3] if len(sys.argv) > 3 else ""
stages_arg = sys.argv[4] if len(sys.argv) > 4 else ""

COLUMNS = [s for s in stages_arg.split(',') if s]

def parse_ts(ts):
    try:
        return datetime.strptime(ts.strip(), "%Y%m%d-%H%M%S")
    except:
        return None

def yaml_field(content, field):
    for line in content.split('\n'):
        if line.startswith(f"{field}: "):
            return line[len(f"{field}: "):].strip()
    return ""

def read_artifacts(task_id):
    path = os.path.join(work_dir, task_id)
    if not os.path.isdir(path):
        return []
    arts = []
    for f in os.listdir(path):
        if not f.endswith('.md'):
            continue
        full = os.path.join(path, f)
        content = open(full).read()
        stem = f[:-3]
        m = re.match(r'^(.+)-(\d{8}-\d{6})$', stem)
        if not m:
            continue
        art_type = m.group(1)
        ts_str   = m.group(2)
        ts       = parse_ts(ts_str)
        to_col   = yaml_field(content, "to") if art_type == "moved" else ""
        outcome  = yaml_field(content, "outcome")
        arts.append({
            'type':    art_type,
            'ts':      ts,
            'ts_str':  ts_str,
            'to':      to_col,
            'outcome': outcome,
            'file':    f,
        })
    # Sort by timestamp, then by filename for stable ordering within same second
    arts.sort(key=lambda a: (a['ts'] or datetime.min, a['file']))
    return arts

def task_title(task_id):
    f = os.path.join(tasks_dir, f"{task_id}.md")
    if not os.path.isfile(f):
        return task_id
    return yaml_field(open(f).read(), "title") or task_id

def fmt_dur(secs):
    if secs is None:
        return "—"
    secs = int(secs)
    if secs < 60:
        return f"{secs}s"
    m, s = divmod(secs, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m {s:02d}s"

def analyze_task(task_id):
    arts = read_artifacts(task_id)
    if not arts:
        return None

    title = task_title(task_id)

    # Track time spent in each column via moved artifacts
    phases = {}  # col -> total seconds
    current_col = None
    entered_at  = None
    first_ts = min((a['ts'] for a in arts if a['ts']), default=None)
    last_ts  = max((a['ts'] for a in arts if a['ts']), default=None)

    for a in arts:
        if a['type'] == 'moved' and a['to'] and a['ts']:
            if current_col and entered_at:
                dur = (a['ts'] - entered_at).total_seconds()
                phases[current_col] = phases.get(current_col, 0) + dur
            current_col = a['to']
            entered_at  = a['ts']

    # Time in final column (if not done, measure to last artifact)
    if current_col and entered_at and last_ts:
        dur = (last_ts - entered_at).total_seconds()
        phases[current_col] = phases.get(current_col, 0) + dur

    total = (last_ts - first_ts).total_seconds() if first_ts and last_ts else None

    # Count retries: number of signal+complete or review+rejected after first
    rejections   = sum(1 for a in arts if a['type'] == 'review'  and a['outcome'] == 'rejected')
    conflicts    = sum(1 for a in arts if a['type'] == 'merge'   and a['outcome'] == 'conflict')

    return {
        'id':         task_id,
        'title':      title,
        'first_ts':   first_ts,
        'last_ts':    last_ts,
        'total_secs': total,
        'phases':     phases,
        'rejections': rejections,
        'conflicts':  conflicts,
    }

# Collect all tasks
task_ids = sorted(
    f for f in os.listdir(work_dir)
    if os.path.isdir(os.path.join(work_dir, f))
)

results = [r for tid in task_ids if (r := analyze_task(tid))]
results.sort(key=lambda r: r['first_ts'] or datetime.min)

if not results:
    print("No tasks found.")
    sys.exit(0)

# ── JSON output ───────────────────────────────────────────────────────────────
if fmt == '--json':
    out = []
    for r in results:
        out.append({
            'id':         r['id'],
            'title':      r['title'],
            'total_secs': r['total_secs'],
            'phases':     {k: int(v) for k, v in r['phases'].items()},
            'rejections': r['rejections'],
            'conflicts':  r['conflicts'],
        })
    print(json.dumps(out, indent=2))
    sys.exit(0)

# ── Terminal output ───────────────────────────────────────────────────────────

RESET  = '\033[0m'
BOLD   = '\033[1m'
CYAN   = '\033[0;36m'
GREEN  = '\033[0;32m'
YELLOW = '\033[0;33m'
RED    = '\033[0;31m'
MUTED  = '\033[2m'

# Per-stage colors for the known software-dev stages. Stages from another
# topology fall back to no color (.get(col, '')) — they still render, uncolored.
STAGE_COLORS = {
    'backlog':       '\033[38;5;246m',
    'ready':         '\033[38;5;39m',
    'in-progress':   '\033[38;5;214m',
    'validation':    '\033[38;5;211m',
    'review':        '\033[38;5;141m',
    'merge-pending': '\033[38;5;226m',
    'merging':       '\033[38;5;78m',
    'done':          '\033[38;5;82m',
}

def col_bar(phases, total_secs, width=30):
    if not total_secs or total_secs == 0:
        return ''
    bar = ''
    for col in COLUMNS:
        secs = phases.get(col, 0)
        if secs <= 0:
            continue
        chars = max(1, round(secs / total_secs * width))
        c = STAGE_COLORS.get(col, '')
        bar += f"{c}{'█' * chars}{RESET}"
    return bar

# Header
print(f"\n{BOLD}{'Task':<36} {'Total':>8}  {'Phases':<32}  Flags{RESET}")
print('─' * 85)

total_all  = 0
first_ever = None
last_ever  = None

for r in results:
    total = r['total_secs']
    if total:
        total_all += total
    if r['first_ts'] and (first_ever is None or r['first_ts'] < first_ever):
        first_ever = r['first_ts']
    if r['last_ts'] and (last_ever is None or r['last_ts'] > last_ever):
        last_ever = r['last_ts']

    title_str = r['title'][:34]
    dur_str   = fmt_dur(total)
    bar       = col_bar(r['phases'], total, width=28)

    flags = ''
    if r['rejections']:
        flags += f" {RED}↺{r['rejections']}rev{RESET}"
    if r['conflicts']:
        flags += f" {YELLOW}⚡{r['conflicts']}conf{RESET}"

    print(f"  {CYAN}{r['id']}{RESET} {title_str:<34} {BOLD}{dur_str:>8}{RESET}  {bar}  {flags}")

# Phase legend — iterate the active topology's stages so a non-default pack's
# stages appear too (uncolored when not in STAGE_COLORS).
print(f"\n{MUTED}  Legend: {RESET}", end='')
for col in COLUMNS:
    color = STAGE_COLORS.get(col, '')
    print(f"{color}█{RESET}{MUTED}{col} {RESET}", end='')
print()

# Summary
print(f"\n{'─' * 85}")
wall = (last_ever - first_ever).total_seconds() if first_ever and last_ever else None

# Slowest task
slowest = max(results, key=lambda r: r['total_secs'] or 0)
fastest = min((r for r in results if r['total_secs']), key=lambda r: r['total_secs'])

print(f"\n  {BOLD}Wall-clock total :{RESET}  {fmt_dur(wall)}")
print(f"  {BOLD}Sum of task time :{RESET}  {fmt_dur(total_all)}  {MUTED}(parallelism factor: {total_all/wall:.1f}x){RESET}" if wall else "")
print(f"  {BOLD}Slowest task     :{RESET}  {slowest['id']} {slowest['title'][:40]}  {fmt_dur(slowest['total_secs'])}")
print(f"  {BOLD}Fastest task     :{RESET}  {fastest['id']} {fastest['title'][:40]}  {fmt_dur(fastest['total_secs'])}")

total_rejections = sum(r['rejections'] for r in results)
total_conflicts  = sum(r['conflicts']  for r in results)
if total_rejections or total_conflicts:
    print(f"  {BOLD}Review rejections:{RESET}  {total_rejections}")
    print(f"  {BOLD}Merge conflicts  :{RESET}  {total_conflicts}")

# Per-column totals
print(f"\n  {BOLD}Time by phase:{RESET}")
col_totals = {}
for r in results:
    for col, secs in r['phases'].items():
        col_totals[col] = col_totals.get(col, 0) + secs
max_col_secs = max((col_totals.get(c, 0) for c in COLUMNS), default=1) or 1
for col in COLUMNS:
    if col in col_totals:
        pct = col_totals[col] / max_col_secs * 100
        bar = '█' * max(1, round(col_totals[col] / max_col_secs * 24))
        print(f"    {col:<16} {fmt_dur(col_totals[col]):>8}  {MUTED}{bar}{RESET}")

print()
EOF
