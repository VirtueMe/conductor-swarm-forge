#!/usr/bin/env bash
set -euo pipefail

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
MERGING_DIR="$CONDUCTOR_DIR/kanban/merging"

[[ -d "$MERGING_DIR" ]] || exit 0

# Print all files currently locked by active merges, one per line, deduplicated
while IFS= read -r card; do
  [[ -f "$card" ]] || continue
  awk 'BEGIN{f=0; found=0} /^---$/{f++; next} f==1 && /^files-changed:/{found=1; next} found && /^  - /{sub(/^  - /,""); print; next} found && !/^  /{exit}' "$card"
done < <(ls "$MERGING_DIR"/*.md 2>/dev/null || true) | sort -u
