# Skill: On Merge Success

Triggered when a `merge-*.md` artifact with `outcome: success` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the finishing worker's tmux window (named `<role>-<id>` — find it by task id):
   ```bash
   WIN=$(tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null | grep -E -- "-$TASK_ID\$" | head -1)
   [[ -n "$WIN" ]] && tmux kill-window -t "swarm:$WIN" 2>/dev/null || true
   ```

2. **Ask the topology where this task goes, then close it.** This event takes no
   guards — the destination is unconditional — but resolve it through `route`
   rather than hardcoding the column:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" merge-success)
   task-move.sh $TASK_ID "$DEST"
   ```
   The destination is a holding column (`done`), so no worker is spawned. The
   `then`-effects below (`unblock-dependents`, `release-merge-pending`,
   `check-project-done`) are conductor logic that fire on this transition — they
   are NOT part of `route`'s output, so run them here.

3. **Unblock dependents** (`then: unblock-dependents`) — find all tasks in
   `kanban/backlog/` whose `depends-on` includes `$TASK_ID`:
   - For each candidate, read its `depends-on` list
   - Check whether every listed ID now has a card in `kanban/done/`
   - If all dependencies are satisfied, move it to `ready` and spawn the entry
     worker (the role of the first working stage):
     ```bash
     task-move.sh <dependent-id> ready
     ROLE=$(scripts/topology-load.sh entry-role "$CONDUCTOR_DIR/topology.json")
     worker-spawn.sh <dependent-id> "$ROLE"
     ```

4. **Release merge-pending tasks** (`then: release-merge-pending`) — for each card
   in `kanban/merge-pending/`:
   - Run `task-locks.sh` to get the updated lock set (now that `$TASK_ID` is done)
   - Read the card's `files-changed` list
   - If no overlap with the lock set:
     ```bash
     task-move.sh <pending-id> merging
     worker-spawn.sh <pending-id> merger
     ```

5. Run `task-list.sh` to confirm.

6. **Check if the entire project is done** (`then: check-project-done`) — if every
   task file in `tasks/` has a matching card in `kanban/done/`:
   ```bash
   total=$(ls "$CONDUCTOR_DIR/tasks/" | wc -l | xargs)
   done=$(ls "$CONDUCTOR_DIR/kanban/done/" | wc -l | xargs)
   ```
   If `total == done`, the project is complete:
   ```bash
   echo "All $total tasks done. Shutting down swarm."
   # Close architect window if it exists
   tmux kill-window -t "swarm:architect" 2>/dev/null || true
   # Stop kanban server
   kill $(cat "$CONDUCTOR_DIR/kanban-server.pid" 2>/dev/null) 2>/dev/null || true
   # Close conductor window (self-terminate)
   tmux kill-window -t "swarm:conductor"
   ```
