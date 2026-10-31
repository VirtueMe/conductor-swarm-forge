# Skill: On Validation Passed

Triggered when a `validation-*.md` artifact with `outcome: passed` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the finishing worker's tmux window (named `<role>-<id>` — find it by task id):
   ```bash
   WIN=$(tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null | grep -E -- "-$TASK_ID\$" | head -1)
   [[ -n "$WIN" ]] && tmux kill-window -t "swarm:$WIN" 2>/dev/null || true
   ```

2. **Gather the routing guards** for this event:
   - `type=<...>` — read the `type` field from the task's kanban card.
   - `locks=<free|held>` — only needed if routing lands on a merge. Run
     `task-locks.sh` and compare the active lock set against the card's
     `files-changed`: any overlap → `held`, otherwise `free` (see
     `on-review-approved.md` for the lock check).

3. **Ask the topology where this task goes.** Do not hardcode the type branching
   — call `route` with the event and guards:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     validation-passed type=<type> locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: `chore`/`spike` go straight to merge (`merging` or
   `merge-pending` depending on `locks`); everything else goes to `review`.

4. **Start the destination stage** — `stage-start.sh` spawns the stage's worker,
   notifies the human if the stage is manual, and does nothing for a holding column:
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

5. Run `task-list.sh` to confirm.
