# Skill: On Merge Conflict

Triggered when a `merge-*.md` artifact with `outcome: conflict` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the merge file

## Steps

1. Close the merger's tmux window:
   ```bash
   tmux kill-window -t "swarm:merger-$TASK_ID" 2>/dev/null || true
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

4. Write a conductor note with the conflict context so the coder knows exactly what to fix:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: merge conflict — <paste conflicting files and description here>"
   ```

5. **Spawn the worker bound to the destination stage.** The destination is the
   coding loopback, so spawn a coder; its CLAUDE.md will include the full work
   history including the conflict artifact:
   ```bash
   worker-spawn.sh $TASK_ID coder
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
