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

2. Move the task back to in-progress:
   ```bash
   task-move.sh $TASK_ID in-progress
   ```

3. Write a conductor note with the conflict context so the coder knows exactly what to fix:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: merge conflict — <paste conflicting files and description here>"
   ```

4. Spawn a coder. The coder's CLAUDE.md will include the full work history including the conflict artifact:
   ```bash
   worker-spawn.sh $TASK_ID coder
   ```

5. **Release other merge-pending tasks** — the failed merge released its file locks. For each card in `kanban/merge-pending/`:
   - Run `task-locks.sh` to get the current lock set
   - Read the card's `files-changed` list
   - If no overlap:
     ```bash
     task-move.sh <pending-id> merging
     worker-spawn.sh <pending-id> merger
     ```

6. Run `task-list.sh` to confirm.
