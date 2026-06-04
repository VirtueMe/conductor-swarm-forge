# Skill: On Merge Conflict

Triggered when a `merge-*.md` artifact with `outcome: conflict` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the merge file

## Steps

1. Close the finishing worker's tmux window (named `<role>-<id>` — find it by task id):
   ```bash
   WIN=$(tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null | grep -E -- "-$TASK_ID\$" | head -1)
   [[ -n "$WIN" ]] && tmux kill-window -t "swarm:$WIN" 2>/dev/null || true
   ```

2. Read the merge artifact body — it lists which files conflicted and describes the nature of the conflict.

3. **Ask the topology where this task goes.** This event takes no guards — the
   destination is unconditional — but resolve it through `route` rather than
   hardcoding the column:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" merge-conflict)
   task-move.sh $TASK_ID "$DEST"
   ```
   The `then: release-merge-pending` effect below is conductor logic that fires on
   this transition — it is NOT part of `route`'s output, so run it here.

4. Write a conductor note with the conflict context so the next worker knows exactly what to fix:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: merge conflict — <paste conflicting files and description here>"
   ```

5. **Spawn the worker bound to the destination stage.** `$DEST` is the rework
   loopback; derive its role from the topology and spawn it. The worker's briefing
   will include the full work history (including the conflict artifact):
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   [[ -n "$ROLE" ]] && worker-spawn.sh $TASK_ID "$ROLE"
   ```

6. **Release other merge-pending tasks** (`then: release-merge-pending`) — the
   failed merge released its file locks. For each card in `kanban/merge-pending/`:
   - Run `task-locks.sh` to get the current lock set
   - Read the card's `files-changed` list
   - If no overlap:
     ```bash
     task-move.sh <pending-id> merging
     worker-spawn.sh <pending-id> merger
     ```

7. Run `task-list.sh` to confirm.
