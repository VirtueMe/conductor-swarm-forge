# Skill: On Human Decision

Triggered when a `human-*.md` artifact appears in `work/<id>/`.
This is the response to a manual stage — the human has made a decision.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the human artifact file

## Steps

1. Read the human's decision from the artifact:
   ```bash
   DECISION=$(awk 'BEGIN{f=0} /^---$/{f++; next} f==1 && /^outcome: /{sub(/^outcome: /,""); print; exit}' "$ARTIFACT")
   ```

2. Remove the human-inbox file(s) for this task — the decision is in:
   ```bash
   rm -f "$CONDUCTOR_DIR/human-inbox/${TASK_ID}"-*.md 2>/dev/null || true
   ```

3. **Ask the topology where this task goes.** Route using the `human:<decision>` event:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" "human:$DECISION")
   task-move.sh $TASK_ID "$DEST"
   ```

4. **Start the destination stage** — `stage-start.sh` spawns its worker or notifies
   the human again if it is manual. A holding column (e.g. `done`, `backlog`)
   needs nothing, and the helper does nothing for it:
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

5. Run `task-list.sh` to confirm.
