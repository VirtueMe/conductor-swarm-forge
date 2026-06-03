# Skill: On New Task

Triggered when a new file appears in `tasks/`.

## Context

- `$TASK_FILE` — the new file path, e.g. `tasks/0003.md`
- `$TASK_ID` — the ID extracted from the filename, e.g. `0003`

## Steps

1. Read `$TASK_FILE` and extract the `depends-on` field.

2. **If `depends-on` is empty or `[]`** — no dependencies, task is immediately ready:
   ```bash
   task-move.sh $TASK_ID ready
   worker-spawn.sh $TASK_ID coder
   ```

3. **If `depends-on` has entries** — check each listed ID:
   - If every ID has a card in `kanban/done/`:
     ```bash
     task-move.sh $TASK_ID ready
     worker-spawn.sh $TASK_ID coder
     ```
   - If any ID is not yet in `done/`:
     ```bash
     task-move.sh $TASK_ID backlog
     ```
     The task will be unblocked by `on-merge-success.md` when its dependencies complete.

4. Run `task-list.sh` to confirm placement.
