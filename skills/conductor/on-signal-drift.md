# Skill: On Signal Drift

Triggered when a `drift-*.md` artifact appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the drift file

## Steps

1. Read the drift artifact body — it describes what changed from the original scope and why.

2. Assess the drift:
   - **Minor drift** — small, justified deviation within the spirit of the task. Write a note and let the coder continue. No column change.
     ```bash
     task-signal.sh --task $TASK_ID --type progress \
       --notes "conductor: drift acknowledged — <brief summary>"
     ```
   - **Scope expansion** — the coder is doing significantly more than the task asked. Escalate to the architect:
     ```bash
     mkdir -p "$CONDUCTOR_DIR/architect-inbox"
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-drift.md" << EOF
     ---
     type: drift
     task-id: $TASK_ID
     ---
     $(cat $ARTIFACT)
     EOF
     ```
     Write a note to the coder to pause on the extra work until the architect responds.

   - **Task invalidation** — the drift reveals the original task no longer makes sense. Move to `done` without a merge and note why:
     ```bash
     task-signal.sh --task $TASK_ID --type progress \
       --notes "conductor: task invalidated by drift — <reason>"
     task-move.sh $TASK_ID done
     ```

3. Run `task-list.sh` to confirm.
