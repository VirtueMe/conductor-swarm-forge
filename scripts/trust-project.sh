#!/usr/bin/env bash
set -euo pipefail
# Whether Claude Code trusts a project directory, and an opt-in to record that it does.
#
# Usage: trust-project.sh check <dir>
#        trust-project.sh grant <dir>
# Env:   CLAUDE_JSON_FILE  Claude Code's state file (default ~/.claude.json)
#
# Claude Code asks "do you trust this folder?" the first time it starts in a new directory, and
# records the answer in its state file as projects["<path>"].hasTrustDialogAccepted. An interactive
# window that nobody answers is a stalled swarm, so swarm-start.sh says so up front (check) and
# offers --trust-project (grant). The key is the physical path of <dir>, as the dialog writes it.
#
# check   prints trusted, untrusted or unknown (no state file, or one that is not JSON). Exit 0.
# grant   sets hasTrustDialogAccepted to true for <dir>, creating the entry if there is none, and
#         keeps everything else in the file. The file also holds the account and settings and is
#         rewritten by running Claude Code sessions, so it: refuses a file that does not parse (exit
#         1, untouched) and a file that does not exist (exit 1: run claude once first, this does not
#         invent one), copies the file to <file>.swarm-backup-<timestamp> first, writes a temp file
#         beside it and renames it over the original, and prints nothing from the file. The race with
#         a session that writes at the same moment is made small, not removed.
#         Trust lets the project's .claude/settings.json and hooks run without the prompt, which is
#         why this is something a person asks for.

STATE="${CLAUDE_JSON_FILE:-$HOME/.claude.json}"

die() { echo "trust-project.sh: $*" >&2; exit 1; }

physical() { # <dir>
  [[ -d "${1:-}" ]] || die "not a directory: ${1:-}"
  (cd "$1" && pwd -P)
}

cmd_check() {
  local dir; dir="$(physical "${1:?Usage: trust-project.sh check <dir>}")"
  python3 -I - "$STATE" "$dir" << 'PYEOF'
import json, sys
state, d = sys.argv[1], sys.argv[2]
try:
    with open(state) as f:
        data = json.load(f)
    p = (data.get("projects") or {}).get(d) or {}
    print("trusted" if p.get("hasTrustDialogAccepted") is True else "untrusted")
except Exception:
    print("unknown")
PYEOF
}

cmd_grant() {
  local dir; dir="$(physical "${1:?Usage: trust-project.sh grant <dir>}")"
  [[ -f "$STATE" ]] || die "no Claude Code state file at $STATE: start claude once first, this does not create one"
  python3 -I - "$STATE" "$dir" << 'PYEOF'
import json, os, shutil, sys, time
state, d = sys.argv[1], sys.argv[2]
try:
    with open(state) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("not an object")
except Exception:
    sys.stderr.write(f"trust-project.sh: {state} is not JSON that can be read; left as it was\n")
    sys.exit(1)
projects = data.setdefault("projects", {})
entry = projects.setdefault(d, {})
if entry.get("hasTrustDialogAccepted") is True:
    print(f"already trusted: {d}")
    sys.exit(0)
backup = f"{state}.swarm-backup-{time.strftime('%Y%m%dT%H%M%S')}"
shutil.copy2(state, backup)
entry["hasTrustDialogAccepted"] = True
tmp = f"{state}.new.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
try:
    with open(tmp) as f:
        json.load(f)
    os.chmod(tmp, os.stat(state).st_mode & 0o777)
    os.replace(tmp, state)
except Exception as e:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.stderr.write(f"trust-project.sh: could not write {state}: {e}\n")
    sys.exit(1)
print(f"trusted: {d} (backup: {backup})")
PYEOF
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  grant) shift; cmd_grant "$@" ;;
  -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "Usage: trust-project.sh check|grant <dir>" >&2; exit 1 ;;
esac
