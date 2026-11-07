# Skill: On Signal Complete

Triggered when a `signal-*.md` artifact with `outcome: complete` appears in `work/<id>/`.

> A script handler (the file of this name under `scripts/handlers/`) does these steps without a
> model. The loop runs it when it exists and is executable, and dispatches this skill otherwise.
> This file stays as the documentation of what the script must do, as the fallback when the
> script is absent, and as what `handler-replay.sh --record` runs to produce a fixture's
> expectation.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the finishing worker's tmux window and record what the worker spent. The script
   finds the window, named `<role>-<id>`, by task id rather than assuming which role just
   finished:
   ```bash
   worker-close.sh "$TASK_ID"
   ```

2. **Gather the routing guards** the topology may consult for this event:
   - `type=<...>` — read the `type` field from the task's kanban card.
   - `config.test-cmd=<value-or-empty>` — read `test-cmd` from
     `.conductor/config.md`. Pass the value through; an empty/unset `test-cmd`
     means "not configured".
   - `locks=<free|held>` — only needed if routing lands on a merge. Run
     `task-locks.sh` for the active merge lock set and compare against the card's
     `files-changed`: any overlap → `held`, otherwise `free`. (You may compute
     this up front, or re-call `route` once the merge macro is reached — see
     `on-review-approved.md` for the lock check.)

3. **Ask the topology where this task goes.** Do not hardcode the design /
   test-cmd / type branching — call `route` with the event and guards:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     signal-complete type=<type> config.test-cmd=<value-or-empty> locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: a `design` task short-circuits to `done`; a configured
   `test-cmd` routes to `validation` before any type check; `chore`/`spike` go to
   merge (`merging` or `merge-pending` depending on `locks`); everything else
   goes to `review`.

4. **Start the destination stage.** `stage-start.sh` reads the role and mode from
   the topology: it spawns the stage's worker, notifies the human if the stage is
   manual, and does nothing for a holding column:
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

5. **If the task went to `done`** (a `design` task does, with no validation, review or merge), unblock
   the tasks that were waiting on it, as `on-merge-success.md` does for a merged task (its step 3: read
   each `kanban/backlog/` card's `depends-on` from `tasks/<id>.md`; if every listed ID now has a card in
   `kanban/done/`, `task-move.sh <id> ready` and `stage-start.sh <id> ready`). Without this the
   dependents stay in backlog until the next startup reconcile. Do not check whether the project is done
   here: a design task is usually the first of several tasks.

6. Run `task-list.sh` to confirm.
