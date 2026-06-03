# Skill: Architect — Respond to Blocked Escalation

The conductor has escalated a blocked signal because the worker needs architectural input to proceed.

## Context

- `$INBOX_FILE` — the escalation file in `.conductor/architect-inbox/`
- The escalation contains: the task ID, what the worker is blocked on, and what the conductor already tried

## Steps

1. Read the inbox file. Understand exactly what the worker cannot proceed without.

2. Diagnose the blocker:

   **Missing prerequisite task** — something that should have been a dependency was not created:
   ```bash
   # Create the missing task
   task-create.sh --title "<missing piece>" --type feature \
     --description "<what needs to exist>"

   # Write response for conductor to add as dependency
   cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-response.md" << EOF
   ---
   type: architect-response
   task-id: $TASK_ID
   decision: new-dependency
   unblocked-by: <new-task-id>
   ---
   Created task <id> which must complete before this task can proceed.
   EOF
   ```

   **Ambiguous task description** — the original task was not specific enough:
   - Update the task description by creating a clarification note:
     ```bash
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-response.md" << EOF
     ---
     type: architect-response
     task-id: $TASK_ID
     decision: clarify
     ---
     Clarification: <specific answer to the ambiguity>.
     The worker should interpret the task as: <restated scope>.
     EOF
     ```

   **External dependency** — blocked on something outside the swarm's control (a library, an API, a human decision):
   - This cannot be resolved programmatically. Write a response noting what is needed and from whom:
     ```bash
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-response.md" << EOF
     ---
     type: architect-response
     task-id: $TASK_ID
     decision: external-block
     ---
     Blocked on: <external thing>. Needs: <who must act and what they must do>.
     EOF
     ```

3. Remove the inbox file once handled:
   ```bash
   rm "$INBOX_FILE"
   ```
