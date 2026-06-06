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

4. **Spawn the worker or notify for the entry stage.** Check `$DEST` using the
   topology, not by naming a column. A holding column with a role or `mode:manual`
   is a working stage — act on it directly. A holding column with neither (like
   `ready`) means start the entry stage immediately. `backlog` means wait:
   ```bash
   DEST_ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   DEST_MODE=$(scripts/topology-load.sh mode "$CONDUCTOR_DIR/topology.json" "$DEST")
   if [[ -n "$DEST_ROLE" ]]; then
     # DEST is itself a working stage (auto)
     worker-spawn.sh $TASK_ID "$DEST_ROLE"
   elif [[ "$DEST_MODE" == "manual" ]]; then
     # DEST is itself a manual stage
     task-notify.sh --task $TASK_ID --stage "$DEST"
   elif [[ "$DEST" != "backlog" ]]; then
     # DEST is the ready holding column — start the entry stage
     ENTRY_ROLE=$(scripts/topology-load.sh entry-role "$CONDUCTOR_DIR/topology.json")
     if [[ -n "$ENTRY_ROLE" ]]; then
       worker-spawn.sh $TASK_ID "$ENTRY_ROLE"
     else
       ENTRY_STAGE=$(scripts/topology-load.sh entry-stage "$CONDUCTOR_DIR/topology.json")
       task-notify.sh --task $TASK_ID --stage "$ENTRY_STAGE"
     fi
   fi
   ```
   Note: topologies that route `new-task` to a third holding column (neither
   `backlog` nor the ready column) would reach the last branch and incorrectly
   start the entry stage. Design such topologies to use `backlog` for any hold.

5. Run `task-list.sh` to confirm placement.
