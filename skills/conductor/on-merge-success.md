# Skill: On Merge Success

Triggered when a `merge-*.md` artifact with `outcome: success` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the merger's tmux window:
   ```bash
   tmux kill-window -t "swarm:merger-$TASK_ID" 2>/dev/null || true
   ```

2. Close the task:
   ```bash
   task-move.sh $TASK_ID done
   ```

2. **Unblock dependents** — find all tasks in `kanban/backlog/` whose `depends-on` includes `$TASK_ID`:
   - For each candidate, read its `depends-on` list
   - Check whether every listed ID now has a card in `kanban/done/`
   - If all dependencies are satisfied:
     ```bash
     task-move.sh <dependent-id> ready
     worker-spawn.sh <dependent-id> coder
     ```

3. **Release merge-pending tasks** — for each card in `kanban/merge-pending/`:
   - Run `task-locks.sh` to get the updated lock set (now that `$TASK_ID` is done)
   - Read the card's `files-changed` list
   - If no overlap with the lock set:
     ```bash
     task-move.sh <pending-id> merging
     worker-spawn.sh <pending-id> merger
     ```

4. Run `task-list.sh` to confirm.

5. **Check if the entire project is done** — if every task file in `tasks/` has a matching card in `kanban/done/`:
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
