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

2. Write a conductor note summarising the failures so the coder has immediate context:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: validation failed — <paste key failure lines here>"
   ```

3. Move the task back to in-progress:
   ```bash
   task-move.sh $TASK_ID in-progress
   ```

4. Spawn a new coder. The coder's briefing will include the full work history including the validation artifact:
   ```bash
   worker-spawn.sh $TASK_ID coder
   ```

5. Run `task-list.sh` to confirm.
