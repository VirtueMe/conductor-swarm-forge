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

4. **Count the failures in a row.** Look at the task's `validation-*.md` artifacts in
   `work/<id>/`, newest first: the number of consecutive ones with `outcome: failed`, up to the
   first pass, is `$FAILURES` (the current artifact counts). A task that keeps failing may not be
   the coder's to fix (the tests can be a later task), and the topology says when to stop.

5. **Ask the topology where this task goes.** Pass the count, and resolve the destination through
   `route` rather than hardcoding the column:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" validation-failed \
     "count.validation-failed=$FAILURES")
   ```
   - **A stage** (the rework loopback, `in-progress`): move the task and start it. The worker's
     briefing will include the full work history (including the validation artifact):
     ```bash
     task-move.sh $TASK_ID "$DEST"
     stage-start.sh $TASK_ID "$DEST"
     ```
   - **`@escalate`** (it has failed 3 times in a row, by default): do not move the card. Write
     the same notice to `architect-inbox/validation-loop-$TASK_ID-<timestamp>.md` and
     `human-inbox/validation-loop-$TASK_ID-<timestamp>.md` (front matter `type: validation-loop`,
     `task-id`, `failures`; the body says it failed validation $FAILURES times in a row, is parked
     in validation with no worker, the last failure, and how to send it back:
     `task-move.sh <id> in-progress && stage-start.sh <id> in-progress`). The script handler does
     this with `escalate_validation_loop`. Report only: do not decide what to do about it.

6. Run `task-list.sh` to confirm.
