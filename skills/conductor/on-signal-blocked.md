# Skill: On Signal Blocked

Triggered when a `signal-*.md` artifact with `outcome: blocked` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the signal file

## Steps

1. Read the signal body — it describes what the worker is blocked on.

2. Write a conductor note so the blocker is visible in the work history:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: worker blocked — <paste blocker description here>"
   ```

3. Assess the blocker:
   - **Missing dependency** — another task must complete first. Check whether that task exists in the kanban. If not, escalate to the architect.
   - **Clarification needed** — the task description is ambiguous. Escalate to the architect.
   - **Technical blocker** — something in the codebase is broken or missing. Consider whether a new `chore` or `feature` task should be created.

4. **Escalate to the architect** when the blocker requires a design decision or a missing task:
   ```bash
   mkdir -p "$CONDUCTOR_DIR/architect-inbox"
   cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-blocked.md" << EOF
   ---
   type: blocked
   task-id: $TASK_ID
   ---
   $(cat $ARTIFACT)
   EOF
   ```

5. Do not move the kanban card unless the blocker is a hard dependency — in that case:
   ```bash
   task-move.sh $TASK_ID backlog
   ```

6. Run `task-list.sh` to confirm current state.
