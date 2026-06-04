# Skill: On Validation Failed

Triggered when a `validation-*.md` artifact with `outcome: failed` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the validation file

## Steps

1. Close the validator's tmux window:
   ```bash
   tmux kill-window -t "swarm:validator-$TASK_ID" 2>/dev/null || true
   ```

2. Read the validation artifact body — it contains the test failure output.

3. Write a conductor note summarising the failures so the coder has immediate context:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: validation failed — <paste key failure lines here>"
   ```

4. **Ask the topology where this task goes.** This event takes no guards — the
   destination is unconditional — but resolve it through `route` rather than
   hardcoding the column:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" validation-failed)
   task-move.sh $TASK_ID "$DEST"
   ```

5. **Spawn the worker bound to the destination stage.** The destination is the
   coding loopback, so spawn a coder; its briefing will include the full work
   history including the validation artifact:
   ```bash
   worker-spawn.sh $TASK_ID coder
   ```

6. Run `task-list.sh` to confirm.
