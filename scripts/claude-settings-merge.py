#!/usr/bin/env python3
"""Merge the attribution-off keys over a project's Claude settings and write the result.

Used by adapter_settings_flag in adapters/claude-code.sh (docs/commit-attribution.md).

    claude-settings-merge.py <project settings.json> <state dir>

Reads the project's settings (a missing file is an empty object), sets "attribution" to
{"commit": "", "pr": ""}, and writes $state_dir/claude-settings.json, readable only by its owner,
moved into place so two windows starting together never read half a file. It prints the
`--settings '<path>'` flag to pass. If the project's file is not a JSON object, or the merged file
cannot be written, it warns on stderr and prints the flag for the project's file as it is (nothing
if there is none): attribution is then not turned off. The exit status is 0 in both cases.
"""
import json, os, sys, tempfile
if len(sys.argv) != 3:
    sys.exit("usage: claude-settings-merge.py <project settings.json> <state dir>")
path, state_dir = sys.argv[1], sys.argv[2]
def as_is(why):
    sys.stderr.write(f"claude-code: {why}; passing the project's settings as they are, attribution is not turned off\n")
    if os.path.isfile(path):
        print(f"--settings '{path}'")
    sys.exit(0)
settings = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            settings = json.load(f)
        if not isinstance(settings, dict):
            raise ValueError("not a JSON object")
    except (ValueError, OSError) as e:
        as_is(f"{path} is not usable settings JSON ({e})")
settings["attribution"] = {"commit": "", "pr": ""}
target = os.path.join(state_dir, "claude-settings.json")
try:
    os.makedirs(state_dir, exist_ok=True)
    # Written beside the target and moved into place, so two windows starting together never read half a file.
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".claude-settings.")
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, separators=(",", ":"))
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
except OSError as e:
    as_is(f"cannot write {target} ({e})")
print(f"--settings '{target}'")
