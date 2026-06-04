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

4. **Resume interrupted work** — a card sitting in a *working stage* (a stage with a
   role bound to it; the holding columns have none) should have an active worker. The
   working stages are those `topology-load.sh role <stage>` returns a role for. For
   each card in such a stage, check whether its tmux window exists:
   ```bash
   tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null
   ```
   The window is named `<role>-<id>`. If it is missing, re-spawn the worker for that
   stage — the role comes from the topology, not a fixed list:
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" <stage>)
   worker-spawn.sh <id> "$ROLE"
   ```

5. **Spawn workers for ready tasks** — for each card in `kanban/ready/` with no active
   worker window, spawn the entry worker (the role of the first working stage):
   ```bash
   ROLE=$(scripts/topology-load.sh entry-role "$CONDUCTOR_DIR/topology.json")
   worker-spawn.sh <id> "$ROLE"
   ```

6. Run `task-list.sh` once more and confirm the state looks correct before starting the watch loop.
