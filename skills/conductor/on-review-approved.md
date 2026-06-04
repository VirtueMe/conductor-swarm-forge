# Skill: On Review Approved

Triggered when a `review-*.md` artifact with `outcome: approved` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the reviewer's tmux window:
   ```bash
   tmux kill-window -t "swarm:reviewer-$TASK_ID" 2>/dev/null || true
   ```

2. **Compute the `locks` guard.** Get the set of files currently locked by active
   merges, then compare against this task's changed files:
   ```bash
   task-locks.sh
   ```
   Read the `files-changed` list from `kanban/review/$TASK_ID.md`. If any file in
   `files-changed` appears in the locked set → `locks=held`; otherwise →
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

4. **Spawn the worker bound to the destination stage** (no worker for the
   `merge-pending` holding column):
   - `merging` → `worker-spawn.sh $TASK_ID merger`
   - `merge-pending` → no worker

5. Run `task-list.sh` to confirm.
