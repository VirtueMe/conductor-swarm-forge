# Skill: On New Task

Triggered when a new file appears in `tasks/`.

## Context

- `$TASK_FILE` — the new file path, e.g. `tasks/0003.md`
- `$TASK_ID` — the ID extracted from the filename, e.g. `0003`

## Steps

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
