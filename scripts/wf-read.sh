#!/usr/bin/env bash
# Resolve one field of a workforce member (role → adapter/params roster).
#
# The "walk members, match on role, print one field" lookup used to be copied as
# python heredocs across worker-spawn.sh and swarm-start.sh. This is its single
# source of truth, so a change in the roster shape is edited in one place.
#
# Sourced (not executed) — it defines wf_field in the caller's shell.
#
#   wf_field <workforce.json> <role> <key>
#
# Prints member[key] for the member whose `role` matches:
#   - a string value (e.g. `adapter`) is printed as-is
#   - any other value (e.g. the `params` object) is printed as a JSON string,
#     which is the contract adapters expect — they own translation to CLI flags
#   - `params` absent (member without params, or no such role) prints `{}`
#   - any other absent key exits 1 with a message on stderr
# Requires python3.
wf_field() {
  python3 - "$@" << 'EOF'
import json, sys
path, role, key = sys.argv[1:4]
wf = json.load(open(path))
for m in wf["members"]:
    if m["role"] == role:
        if key in m:
            v = m[key]
            print(v if isinstance(v, str) else json.dumps(v))
            sys.exit(0)
        break
if key == "params":
    print("{}")
    sys.exit(0)
sys.stderr.write(f"No {key} found for role: {role}\n")
sys.exit(1)
EOF
}
