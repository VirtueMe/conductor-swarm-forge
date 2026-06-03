# Skill: On Validation Passed

Triggered when a `validation-*.md` artifact with `outcome: passed` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the validator's tmux window:
   ```bash
   tmux kill-window -t "swarm:validator-$TASK_ID" 2>/dev/null || true
   ```

2. Read the task's kanban card to get its `type` field.

2. **If type is `chore` or `spike`** — skip review, go straight to merge:
   - Run the file lock check (see `on-review-approved.md`)
   - Either `task-move.sh $TASK_ID merging` → `worker-spawn.sh $TASK_ID merger`
   - Or `task-move.sh $TASK_ID merge-pending` if files are locked

3. **If type is `feature`, `test`, or anything else** — send to review:
   ```bash
   task-move.sh $TASK_ID review
   worker-spawn.sh $TASK_ID reviewer
   ```

4. Run `task-list.sh` to confirm.
