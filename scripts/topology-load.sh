#!/usr/bin/env bash
# Resolve and validate a topology definition.
#
# A topology is the declarative state machine that drives a swarm — stages,
# the role/human bound to each working stage, and the guarded transitions
# between them. See docs/topology-schema.md.
#
# Usage:
#   topology-load.sh resolve  <name|path>   # print absolute path to the topology JSON
#   topology-load.sh validate <name|path>   # validate structure; exit 0 on success, 1 on error
#
# A bare <name> resolves to topologies/<name>.json under the tool root; a value
# containing a slash or ending in .json is treated as a path.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
TOPOLOGIES_DIR="$ROOT_DIR/topologies"

usage() {
  echo "Usage: topology-load.sh {resolve|validate} <name|path>" >&2
  exit 2
}

resolve_path() {
  local ref="$1"
  if [[ "$ref" == *.json || "$ref" == */* ]]; then
    echo "$ref"
  else
    echo "$TOPOLOGIES_DIR/${ref}.json"
  fi
}

[[ $# -eq 2 ]] || usage
CMD="$1"
REF="$2"
PATH_JSON="$(resolve_path "$REF")"

case "$CMD" in
  resolve)
    [[ -f "$PATH_JSON" ]] || { echo "Topology not found: $PATH_JSON" >&2; exit 1; }
    echo "$PATH_JSON"
    ;;
  validate)
    [[ -f "$PATH_JSON" ]] || { echo "Topology not found: $PATH_JSON" >&2; exit 1; }
    python3 - "$PATH_JSON" << 'PY'
import json, sys

path = sys.argv[1]
errors = []

try:
    with open(path) as f:
        t = json.load(f)
except (OSError, ValueError) as e:
    print(f"Topology is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

def err(msg): errors.append(msg)

# --- Required top-level keys ------------------------------------------------
for key, typ in [("name", str), ("integration", str),
                 ("stages", list), ("working_stages", dict),
                 ("transitions", dict)]:
    if key not in t:
        err(f"missing required key: '{key}'")
    elif not isinstance(t[key], typ):
        err(f"key '{key}' must be a {typ.__name__}")

if errors:
    for e in errors: print(f"  - {e}", file=sys.stderr)
    print(f"Topology invalid: {path}", file=sys.stderr)
    sys.exit(1)

stages = t["stages"]
working = t["working_stages"]
transitions = t["transitions"]
macros = t.get("integration_macros", {})

SPECIAL_DESTS = {"@escalate", "@stay"}
INTEGRATIONS = {"git", "shared-doc", "none"}

if t["integration"] not in INTEGRATIONS:
    err(f"integration '{t['integration']}' not one of {sorted(INTEGRATIONS)}")

if not stages:
    err("stages must be a non-empty list")
if len(stages) != len(set(stages)):
    err("stages contains duplicates")

stage_set = set(stages)

# --- working_stages ⊆ stages, and well-formed -------------------------------
for stage, spec in working.items():
    if stage not in stage_set:
        err(f"working_stage '{stage}' is not in stages")
    if not isinstance(spec, dict):
        err(f"working_stage '{stage}' must be an object"); continue
    mode = spec.get("mode", "auto")
    if mode not in {"auto", "manual"}:
        err(f"working_stage '{stage}' has invalid mode '{mode}'")
    if mode == "auto" and "role" not in spec:
        err(f"working_stage '{stage}' (auto) must declare a 'role'")
    if mode == "manual" and "await" not in spec:
        err(f"working_stage '{stage}' (manual) must declare 'await'")

# --- destination resolver ---------------------------------------------------
def check_dest(to, where):
    if to in stage_set or to in SPECIAL_DESTS:
        return
    if to.startswith("@"):
        if to not in macros:
            err(f"{where}: destination '{to}' has no matching integration_macro")
        return
    err(f"{where}: destination '{to}' is not a known stage, macro, or special destination")

def check_rules(rules, where):
    if not isinstance(rules, list) or not rules:
        err(f"{where}: must be a non-empty list of rules"); return
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict) or "to" not in rule:
            err(f"{where}[{i}]: each rule must be an object with a 'to'"); continue
        check_dest(rule["to"], f"{where}[{i}]")

for event, rules in transitions.items():
    check_rules(rules, f"transitions.{event}")

for mname, macro in macros.items():
    if not isinstance(macro, dict) or "rules" not in macro:
        err(f"integration_macro '{mname}' must be an object with 'rules'"); continue
    check_rules(macro["rules"], f"integration_macros.{mname}")

# --- connectivity: no orphan working stage -----------------------------------
# Collect every concrete stage any rule can route to (resolving macros to the
# stages their own rules name; @escalate/@stay are not stage destinations).
def rule_dest_stages(rules):
    out = set()
    for rule in rules:
        if not isinstance(rule, dict): continue
        to = rule.get("to")
        if to in macros:
            out |= rule_dest_stages(macros[to].get("rules", []))
        elif isinstance(to, str) and to in stage_set:
            out.add(to)
    return out

reachable = set()
for rules in transitions.values():
    reachable |= rule_dest_stages(rules)

# A working stage that nothing ever routes to is a defined executor that can
# never run — a meaning error structural checks would otherwise bless.
for stage in working:
    if stage in stage_set and stage not in reachable:
        err(f"working_stage '{stage}' is never a transition destination (orphan — no rule routes to it)")

# NOTE: this is connectivity, not full reachability. We cannot verify the whole
# machine is connected (every stage reachable from an entry, a terminal reachable
# from every stage) because transitions are keyed by event, not by source stage —
# the data does not encode which events fire from which stage. Full reachability
# is deferred to the hand-authored-pack work in #6.

if errors:
    for e in errors: print(f"  - {e}", file=sys.stderr)
    print(f"Topology invalid: {path}", file=sys.stderr)
    sys.exit(1)

print(f"Topology OK: {t['name']} ({len(stages)} stages, integration={t['integration']})")
PY
    ;;
  *)
    usage
    ;;
esac
