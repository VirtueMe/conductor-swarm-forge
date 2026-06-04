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
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" new-task deps=<all-done|pending>)
   task-move.sh $TASK_ID "$DEST"
   ```

4. **Spawn the worker bound to the destination stage.** If `$DEST` is the
   deps-satisfied entry column (`ready`), spawn the entry worker — the role of the
   first working stage. A task parked on `backlog` is a holding column with no
   worker; it is unblocked by `on-merge-success.md` when its dependencies complete:
   ```bash
   # if $DEST is ready:
   ROLE=$(scripts/topology-load.sh entry-role "$CONDUCTOR_DIR/topology.json")
   worker-spawn.sh $TASK_ID "$ROLE"
   ```

5. Run `task-list.sh` to confirm placement.
