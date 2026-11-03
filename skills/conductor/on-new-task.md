# Skill: On New Task

Triggered by the new task's `card` artifact (`work/<id>/card-*.md`).

> A script handler (the file of this name under `scripts/handlers/`) does these steps without a
> model. The loop runs it when it exists and is executable, and dispatches this skill otherwise.
> This file stays as the documentation of what the script must do, as the fallback when the
> script is absent, and as what `handler-replay.sh --record` runs to produce a fixture's
> expectation. A skipped replay (step 0) is a success for the script: it exits 0 and moves nothing.

## Context

- `$TASK_ID` — the task id, the directory name of the `card` artifact, e.g. `0003`
- `$TASK_FILE` — the task file, `tasks/$TASK_ID.md`, e.g. `tasks/0003.md`

## Steps

0. **Skip a replayed event.** A restart or a crash can run this event again for a task that
   has since moved on, and step 3 would pull it back. Find the task's card:
   ```bash
   ls "$CONDUCTOR_DIR"/kanban/*/$TASK_ID.md
   ```
   If it is in any column other than the first stage
   (`topology-load.sh stages "$CONDUCTOR_DIR/topology.json" | head -1`), the task was already
   placed: log "on-new-task: $TASK_ID already placed, skipped" and stop. If it is in the first
   stage, or has no card yet, continue.

1. Read `$TASK_FILE` and extract the `depends-on` field.

2. **Determine the `deps` guard** — the only input this event's routing needs:
   - If `depends-on` is empty or `[]`, or every listed ID has a card in
     `kanban/done/`, then dependencies are satisfied → `deps=all-done`.
   - If any listed ID is not yet in `kanban/done/`, dependencies are pending →
     `deps=pending`.

3. **Ask the topology where this task goes.** Do not hardcode the column — call
   `route` with the event and the `deps` guard:
   ```bash
   DEST=$(topology-load.sh route "$CONDUCTOR_DIR/topology.json" new-task deps=<all-done|pending>)
   task-move.sh $TASK_ID "$DEST"
   ```

4. **Start the destination stage.** `stage-start.sh` reads the topology: a working
   stage gets its worker (or a notification if it is manual); the holding column
   right before the entry stage (`ready`) starts the entry stage; any other holding
   column, such as `backlog`, means wait:
   ```bash
   stage-start.sh $TASK_ID "$DEST"
   ```

5. Run `task-list.sh` to confirm placement.
