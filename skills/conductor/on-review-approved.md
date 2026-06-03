# Skill: On Review Approved

Triggered when a `review-*.md` artifact with `outcome: approved` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the reviewer's tmux window:
   ```bash
   tmux kill-window -t "swarm:reviewer-$TASK_ID" 2>/dev/null || true
   ```

2. Get the set of files currently locked by active merges:
   ```bash
   task-locks.sh
   ```

2. Read the `files-changed` list from `kanban/review/$TASK_ID.md`.

3. **If any file in `files-changed` appears in the locked set** — another merge is touching the same files:
   ```bash
   task-move.sh $TASK_ID merge-pending
   ```
   The task will be re-evaluated by `on-merge-success.md` when the blocking merge resolves.

4. **If no overlap** — clear to merge:
   ```bash
   task-move.sh $TASK_ID merging
   worker-spawn.sh $TASK_ID merger
   ```

5. Run `task-list.sh` to confirm.
