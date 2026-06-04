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
# Read-only query accessors (consumed by the de-hardcoding work in #2/#3/#4/#20):
#   topology-load.sh stages <name|path>                          # ordered stage list, one per line
#   topology-load.sh roles  <name|path>                          # working-stage roles, one per line
#   topology-load.sh entry-role <name|path>                      # role of the first working stage (the pipeline entry)
#   topology-load.sh role   <name|path> <stage>                  # the role bound to one stage (empty for holding columns)
#   topology-load.sh skill  <name|path> <stage> [last_artifact]  # resolve the skill for a working stage
#   topology-load.sh route  <name|path> <event> [guard=value...] # resolve a transition to its destination stage
#   topology-load.sh integration <name|path>                     # print the integration model (git|shared-doc|none)
#
# A bare <name> resolves to topologies/<name>.json under the tool root; a value
# containing a slash or ending in .json is treated as a path.
#
# Guards for `route` are passed as key=value pairs, e.g.:
#   topology-load.sh route software-dev signal-complete type=feature config.test-cmd=1 locks=free

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)"
TOPOLOGIES_DIR="$ROOT_DIR/topologies"

usage() {
  echo "Usage: topology-load.sh {resolve|validate|stages|roles|entry-role|role|skill|route|integration} <name|path> [args...]" >&2
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

[[ $# -ge 2 ]] || usage
CMD="$1"
REF="$2"
shift 2          # remaining args ("$@") belong to the accessor (e.g. stage, event, guards)
PATH_JSON="$(resolve_path "$REF")"

# Every command needs the file to exist.
[[ "$CMD" == "resolve" || -f "$PATH_JSON" ]] || { echo "Topology not found: $PATH_JSON" >&2; exit 1; }

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

  stages|roles|entry-role|role|skill|route|integration)
    # Read-only queries over the topology. All four share ONE rule evaluator
    # (when_matches/first_match) — skill-selection rules and transition rules are
    # the same construct (guarded, first-match), so they must not drift.
    #   stages                          → #2   roles                       → #3
    #   role <stage>                    → #20  skill <stage> [last_artifact] → #3
    #   route <event> [guard=val..]     → #4
    # Guards: type=<t> config.<key>=<v> locks=free|held deps=all-done
    #         assess=<label> last_artifact=<kind:outcome> count.<signal>=<n>
    python3 - "$PATH_JSON" "$CMD" "$@" << 'PY'
import json, sys

path, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
t = json.load(open(path))

KNOWN_WHEN_KEYS = {"type", "config", "count", "locks", "deps", "assess", "last_artifact"}

def die(msg):
    sys.stderr.write(msg + "\n"); sys.exit(1)

def config_set(v):
    # A config key is "set" iff present and non-empty — matching config.md, where
    # an empty `test-cmd:` value means "not configured". No other notion of falsiness.
    return v is not None and v != ""

def when_matches(when, guards):
    for k, v in when.items():
        if k not in KNOWN_WHEN_KEYS:
            die(f"unknown guard key in topology rule: '{k}'")   # author bug — never reroute silently
        if k == "type":
            if guards.get("type") not in v:
                return False
        elif k == "config":
            if not config_set(guards.get(f"config.{v}")):
                return False
        elif k == "count":
            try:
                if int(guards.get(f"count.{v['signal']}", "0")) < v["gte"]:
                    return False
            except (ValueError, KeyError, TypeError):
                return False
        else:  # locks, deps, assess, last_artifact — scalar equality
            if guards.get(k) != v:
                return False
    return True

def first_match(rules, guards):
    for rule in rules:
        if when_matches(rule.get("when", {}), guards):
            return rule
    return None

def parse_guards(args):
    # Validate CLI guard keys so a typo (e.g. lock=free) errors instead of
    # silently failing the match and rerouting the task.
    guards = {}
    for arg in args:
        if "=" not in arg:
            die(f"guard must be key=value: '{arg}'")
        k, val = arg.split("=", 1)
        base = k.split(".", 1)[0]
        if k not in ("type", "locks", "deps", "assess", "last_artifact") and base not in ("config", "count"):
            die(f"unknown guard '{k}'")
        guards[k] = val
    return guards

if cmd == "integration":
    print(t["integration"])

elif cmd == "stages":
    for s in t["stages"]:
        print(s)

elif cmd == "roles":
    ws = t["working_stages"]
    for stage in t["stages"]:                 # stage order = deterministic output
        spec = ws.get(stage)
        if spec and "role" in spec:
            print(spec["role"])

elif cmd == "entry-role":
    # The role that begins the pipeline = the role of the FIRST working stage in
    # stage order. The conductor spawns this for a task entering at `ready`. Named
    # so call sites don't reinvent "the entry" as `roles | head -1` (which only
    # works because `roles` emits in stage order — a contract that would otherwise
    # live invisibly at the call site).
    ws = t["working_stages"]
    for stage in t["stages"]:
        spec = ws.get(stage)
        if spec and "role" in spec:
            print(spec["role"]); break

elif cmd == "role":
    # The role bound to one stage (stage→role; the dual of `roles`). The conductor
    # uses this to spawn "the worker bound to the destination stage" without naming
    # the role — spawn is derived from working_stages, not declared in the skill.
    # A holding column (no working_stages entry) prints NOTHING and exits 0, so the
    # caller's `[[ -n "$ROLE" ]]` guard means "no worker for this column".
    if not rest:
        die("role: missing <stage>")
    spec = t["working_stages"].get(rest[0])
    if spec and "role" in spec:
        print(spec["role"])

elif cmd == "skill":
    # Map a working stage (+ optional most-recent-artifact token) to a skill.
    # The CALLER decides which artifact is most recent (mirrors select_skill()'s
    # file reads); this only evaluates the rule list, via the shared evaluator.
    if not rest:
        die("skill: missing <stage>")
    stage, last_artifact = rest[0], (rest[1] if len(rest) > 1 else None)
    ws = t["working_stages"]
    if stage not in ws:
        die(f"no working_stage '{stage}'")
    spec = ws[stage].get("skill")
    if spec is None:
        die(f"working_stage '{stage}' has no skill")
    if isinstance(spec, str):
        print(spec)
    else:
        guards = {"last_artifact": last_artifact} if last_artifact is not None else {}
        rule = first_match(spec.get("rules", []), guards)
        print(rule["skill"] if rule else spec["default"])

elif cmd == "route":
    # Resolve a transition event to its destination stage (first-match, @macros
    # expanded; @escalate/@stay pass through literally).
    if not rest:
        die("route: missing <event>")
    event, guards = rest[0], parse_guards(rest[1:])
    transitions = t["transitions"]
    macros = t.get("integration_macros", {})
    if event not in transitions:
        die(f"no transition for event '{event}'")
    rule = first_match(transitions[event], guards)
    dest = rule["to"] if rule else None
    seen = set()
    while isinstance(dest, str) and dest in macros and dest not in seen:
        seen.add(dest)
        mrule = first_match(macros[dest]["rules"], guards)
        dest = mrule["to"] if mrule else None
    if dest is None:
        die(f"event '{event}' matched no rule for the given guards")
    print(dest)
PY
    ;;

  *)
    usage
    ;;
esac
