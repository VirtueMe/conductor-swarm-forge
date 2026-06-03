#!/usr/bin/env bash
set -euo pipefail

CONDUCTOR_DIR="${CONDUCTOR_DIR:-.conductor}"
KANBAN_DIR="$CONDUCTOR_DIR/kanban"

COLUMNS="backlog ready in-progress validation review merge-pending merging done"

yaml_field() {
  local file="$1" field="$2"
  awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^'"$field"': /{sub(/^'"$field"': /,""); print; exit}' "$file"
}

TOTAL=0

for col in $COLUMNS; do
  dir="$KANBAN_DIR/$col"
  [[ -d "$dir" ]] || continue

  cards=()
  while IFS= read -r f; do
    [[ -f "$f" ]] && cards+=("$f")
  done < <(ls "$dir"/*.md 2>/dev/null || true)

  count=${#cards[@]}
  [[ $count -eq 0 ]] && continue

  TOTAL=$(( TOTAL + count ))
  printf '\n── %s (%d)\n' "$col" "$count"

  for card in "${cards[@]}"; do
    id=$(basename "$card" .md)
    title=$(yaml_field "$card" "title")
    type=$(yaml_field "$card" "type")
    worker=$(yaml_field "$card" "worker-type")
    priority=$(yaml_field "$card" "priority")
    worker_str=${worker:+" @$worker"}
    printf '   %s  [%s] [%s]  %s%s\n' "$id" "$type" "$priority" "$title" "$worker_str"
  done
done

printf '\n── total: %d\n' "$TOTAL"
