# Skill: On Signal Complete

Triggered when a `signal-*.md` artifact with `outcome: complete` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the coder's tmux window — it has finished its work:
   ```bash
   tmux kill-window -t "swarm:coder-$TASK_ID" 2>/dev/null || true
   ```

2. Read the task's kanban card to get its `type` field.

2. Check if a test command is configured:
   ```bash
   # Read test-cmd from .conductor/config.md
   ```
   If `test-cmd` is set and non-empty → route through validation.
   If not set → skip validation.

3. **With test-cmd configured:**
   ```bash
   task-move.sh $TASK_ID validation
   worker-spawn.sh $TASK_ID validator
   ```
   The validator will signal `passed` or `failed`, and the conductor handles each via the matching skill.

4. **Without test-cmd — route by type:**

   **`design`** — no coder or validator needed; the architect wrote the content directly. Move to done:
   ```bash
   task-move.sh $TASK_ID done
   ```

   **`chore` or `spike`** — skip review, go straight to merge:
   - Run the file lock check (see `on-review-approved.md`)
   - Either `task-move.sh $TASK_ID merging` → `worker-spawn.sh $TASK_ID merger`
   - Or `task-move.sh $TASK_ID merge-pending` if files are locked

   **`feature`, `test`, or anything else** — send to review:
   ```bash
   task-move.sh $TASK_ID review
   worker-spawn.sh $TASK_ID reviewer
   ```

5. Run `task-list.sh` to confirm.
