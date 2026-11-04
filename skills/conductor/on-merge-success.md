# Skill: On Merge Success

Triggered when a `merge-*.md` artifact with `outcome: success` appears in `work/<id>/`.

> A script handler (the file of this name under `scripts/handlers/`) does these steps without a
> model. The loop runs it when it exists and is executable, and dispatches this skill otherwise.
> This file stays as the documentation of what the script must do, as the fallback when the
> script is absent, and as what `handler-replay.sh --record` runs to produce a fixture's
> expectation. The script checks that the project is done task by task, where step 6 compares counts.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the finishing worker's tmux window and record what the worker spent (the script finds
   the window, named `<role>-<id>`, by task id):
   ```bash
   worker-close.sh "$TASK_ID"
   ```

2. **Ask the topology where this task goes, then close it.** This event takes no
   guards — the destination is unconditional — but resolve it through `route`
   rather than hardcoding the column:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" merge-success)
   task-move.sh $TASK_ID "$DEST"
   ```
   The destination is a holding column (`done`), so no worker is spawned. The
   `then`-effects below (`unblock-dependents`, `release-merge-pending`,
   `check-project-done`) are conductor logic that fire on this transition — they
   are NOT part of `route`'s output, so run them here.

3. **Unblock dependents** (`then: unblock-dependents`) — find all tasks in
   `kanban/backlog/` whose `depends-on` includes `$TASK_ID`. A kanban card does not
   carry `depends-on`; it is only in the task file, `$CONDUCTOR_DIR/tasks/<id>.md`
   (a `depends-on:` list in its frontmatter, one `- <id>` line per task). Read it
   from there for every card in `kanban/backlog/`, not from the card:
   - For each candidate, read its `depends-on` list from `tasks/<id>.md`
   - Check whether every listed ID now has a card in `kanban/done/`
   - If all dependencies are satisfied, move it to `ready` and start the entry
     stage — `stage-start.sh` spawns an agent if the entry stage is auto, and
     notifies the human if it is manual:
     ```bash
     task-move.sh <dependent-id> ready
     stage-start.sh <dependent-id> ready
     ```

4. **Release merge-pending tasks** (`then: release-merge-pending`) — for each card
   in `kanban/merge-pending/`:
   - Run `task-locks.sh` to get the updated lock set (now that `$TASK_ID` is done)
   - Read the card's `files-changed` list
   - If no overlap with the lock set:
     ```bash
     task-move.sh <pending-id> merging
     stage-start.sh <pending-id> merging
     ```

5. Run `task-list.sh` to confirm.

6. **Check if the entire project is done** (`then: check-project-done`) — if every
   task file in `tasks/` has a matching card in `kanban/done/`:
   ```bash
   total=$(ls "$CONDUCTOR_DIR/tasks/" | wc -l | xargs)
   done=$(ls "$CONDUCTOR_DIR/kanban/done/" | wc -l | xargs)
   ```
   If `total == done`, the project is complete. Shut the swarm down:
   ```bash
   conductor-shutdown.sh
   ```
   It closes the architect window and stops the kanban server. In an interactive
   conductor it then closes the conductor's own window. Under `conductor-loop.sh` it
   only asks the loop to exit after this event, because closing the window would kill
   the loop before it recorded the event as done.
