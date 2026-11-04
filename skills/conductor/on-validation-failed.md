# Skill: On Validation Failed

Triggered when a `validation-*.md` artifact with `outcome: failed` appears in `work/<id>/`.

> A script handler (the file of this name under `scripts/handlers/`) does these steps without a
> model. The loop runs it when it exists and is executable, and dispatches this skill otherwise.
> This file stays as the documentation of what the script must do, as the fallback when the
> script is absent, and as what `handler-replay.sh --record` runs to produce a fixture's
> expectation. The script's progress note points at the artifact instead of summarising it.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the validation file

## Steps

1. Close the finishing worker's tmux window and record what the worker spent (the script finds
   the window, named `<role>-<id>`, by task id):
   ```bash
   worker-close.sh "$TASK_ID"
   ```

2. Read the validation artifact body — it contains the test failure output.

3. Write a conductor note summarising the failures so the next worker has immediate context:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: validation failed — <paste key failure lines here>"
   ```

4. **Ask the topology where this task goes.** This event takes no guards — the
   destination is unconditional — but resolve it through `route` rather than
   hardcoding the column:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" validation-failed)
   task-move.sh $TASK_ID "$DEST"
   ```

5. **Start the destination stage.** `$DEST` is the rework loopback;
   `stage-start.sh` spawns its worker from the topology. The worker's briefing
   will include the full work history (including the validation artifact):
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

6. Run `task-list.sh` to confirm.
