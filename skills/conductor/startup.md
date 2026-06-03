# Skill: Startup

Run this sequence once when the conductor starts or restarts.

## Steps

1. Run `task-list.sh` and read the full current state before doing anything else.

2. **Register untracked tasks** — for each `.md` file in `tasks/` that has no card in any kanban column, run:
   ```bash
   task-move.sh <id> backlog
   ```

3. **Unblock ready tasks** — for each card in `kanban/backlog/`, read its `depends-on` field. If every listed ID has a card in `kanban/done/`, run:
   ```bash
   task-move.sh <id> ready
   ```

4. **Resume in-progress work** — for each card in `kanban/in-progress/` or `kanban/review/` or `kanban/merging/`, check whether there is an active tmux window for it:
   ```bash
   tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null
   ```
   If the expected window `<worker-type>-<id>` is missing, re-spawn the worker:
   ```bash
   worker-spawn.sh <id> <worker-type>
   ```

5. **Spawn workers for ready tasks** — for each card in `kanban/ready/` with no active worker window, run:
   ```bash
   worker-spawn.sh <id> coder
   ```

6. Run `task-list.sh` once more and confirm the state looks correct before starting the watch loop.
