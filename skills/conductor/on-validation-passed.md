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
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     validation-passed type=<type> locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: `chore`/`spike` go straight to merge (`merging` or
   `merge-pending` depending on `locks`); everything else goes to `review`.

4. **Spawn the worker bound to the destination stage** — derive the role from
   `$DEST` (a holding column such as `merge-pending` has no role, so no worker):
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   [[ -n "$ROLE" ]] && worker-spawn.sh $TASK_ID "$ROLE"
   ```

5. Run `task-list.sh` to confirm.
