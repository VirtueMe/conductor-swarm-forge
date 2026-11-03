# Skill: On Review Approved

Triggered when a `review-*.md` artifact with `outcome: approved` appears in `work/<id>/`.

> A script handler (the file of this name under `scripts/handlers/`) does these steps without a
> model. The loop runs it when it exists and is executable, and dispatches this skill otherwise.
> This file stays as the documentation of what the script must do, as the fallback when the
> script is absent, and as what `handler-replay.sh --record` runs to produce a fixture's
> expectation.

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
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     review-approved locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: `locks=free` clears to `merging`; `locks=held` parks on
   `merge-pending` (another merge is touching the same files — it will be re-
   evaluated by `on-merge-success.md` when the blocking merge resolves).

4. **Start the destination stage** — `stage-start.sh` spawns the stage's worker,
   notifies the human if the stage is manual, and does nothing for a holding column
   (such as `merge-pending`):
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

5. Run `task-list.sh` to confirm.
