# Skill: Architect — Respond to Drift Escalation

The conductor has escalated a drift signal because it requires an architectural decision.

## Context

- `$INBOX_FILE` — the escalation file in `.conductor/architect-inbox/`
- The escalation contains: the task ID, the original task description, and the worker's drift notes

## Steps

1. Read the inbox file carefully. Understand:
   - What was the original task scope?
   - What did the worker discover or change?
   - Why did the conductor escalate rather than handle it directly?

2. Assess the drift:

   **Valid expansion** — the worker found something genuinely necessary that was missed in decomposition:
   - Create a new task for the additional work:
     ```bash
     task-create.sh --title "<new work>" --type feature \
       --depends-on "<appropriate deps>" \
       --description "<what needs doing and why>"
     ```
   - If the drift is already in the current task and shouldn't be split out, write a note that the conductor should let the worker proceed.

   **Scope creep** — the worker is doing more than needed:
   - Write a response file back to the conductor:
     ```bash
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-response.md" << EOF
     ---
     type: architect-response
     task-id: $TASK_ID
     decision: revert
     ---
     Worker should revert the extra work. <reason>. Created task <id> for it if needed.
     EOF
     ```

   **Design flaw discovered** — the original decomposition was wrong:
   - May require creating replacement tasks, deprecating old ones, or reordering dependencies
   - Think carefully before acting — other workers may already be in-progress on dependent tasks

3. Remove the inbox file once handled:
   ```bash
   rm "$INBOX_FILE"
   ```
