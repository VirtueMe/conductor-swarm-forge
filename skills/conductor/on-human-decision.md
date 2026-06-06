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
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" "human:$DECISION")
   task-move.sh $TASK_ID "$DEST"
   ```

4. **Spawn the worker or notify again** based on the destination stage's mode:
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   MODE=$(scripts/topology-load.sh mode "$CONDUCTOR_DIR/topology.json" "$DEST")
   if [[ -n "$ROLE" ]]; then
     worker-spawn.sh $TASK_ID "$ROLE"
   elif [[ "$MODE" == "manual" ]]; then
     task-notify.sh --task $TASK_ID --stage "$DEST"
   fi
   ```
   A holding column (e.g. `done`, `backlog`) has no role and is not manual — no action needed.

5. Run `task-list.sh` to confirm.
