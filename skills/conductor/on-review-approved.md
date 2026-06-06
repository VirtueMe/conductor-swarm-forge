# Skill: On Review Approved

Triggered when a `review-*.md` artifact with `outcome: approved` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the finishing worker's tmux window (named `<role>-<id>` — find it by task id):
   ```bash
   WIN=$(tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null | grep -E -- "-$TASK_ID\$" | head -1)
   [[ -n "$WIN" ]] && tmux kill-window -t "swarm:$WIN" 2>/dev/null || true
   ```

2. **Compute the `locks` guard.** Get the set of files currently locked by active
   merges, then compare against this task's changed files:
   ```bash
   task-locks.sh
   ```
   Read the `files-changed` list from the task's current card (`kanban/*/$TASK_ID.md`).
   If any file in `files-changed` appears in the locked set → `locks=held`; otherwise →
   `locks=free`.

3. **Ask the topology where this task goes.** Do not hardcode the merge / merge-
   pending split — call `route` with the event and the `locks` guard:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     review-approved locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: `locks=free` clears to `merging`; `locks=held` parks on
   `merge-pending` (another merge is touching the same files — it will be re-
   evaluated by `on-merge-success.md` when the blocking merge resolves).

4. **Spawn the worker bound to the destination stage, or notify if manual** —
   derive role and mode from `$DEST` (a holding column has neither):
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   MODE=$(scripts/topology-load.sh mode "$CONDUCTOR_DIR/topology.json" "$DEST")
   if [[ -n "$ROLE" ]]; then
     worker-spawn.sh $TASK_ID "$ROLE"
   elif [[ "$MODE" == "manual" ]]; then
     task-notify.sh --task $TASK_ID --stage "$DEST"
   fi
   ```

5. Run `task-list.sh` to confirm.
