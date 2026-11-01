# Skill: Reconcile

Bring the board in line with what is on disk. Run it once when the conductor starts or
restarts: `startup.md` runs it in the interactive conductor, and `conductor-loop.sh` runs it
as its first event in the headless one. It is safe to run again, and it does no polling.

There is no artifact and no task for this event. Everything it needs is in the kanban columns,
`tasks/` and the tmux windows.

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

4. **Resume interrupted work** — a card sitting in a *working stage* should have
   an active worker (for `auto` stages) or an outstanding human inbox file (for
   `manual` stages). For each card not in a holding column:
   ```bash
   ROLE=$(topology-load.sh role "$CONDUCTOR_DIR/topology.json" <stage>)
   MODE=$(topology-load.sh mode "$CONDUCTOR_DIR/topology.json" <stage>)
   ```
   - If `$ROLE` is set (`auto`): check whether the tmux window `<role>-<id>` exists.
     If it is missing, re-spawn:
     ```bash
     tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null
     worker-spawn.sh <id> "$ROLE"
     ```
   - If `$MODE` is `manual`: check whether a human-inbox file exists for this task.
     If not (e.g. previous notification was lost), re-notify. Use `compgen -G`
     rather than `ls` to test glob existence — `ls` exits non-zero for both
     "no match" and permission errors, which would re-notify even when the file exists:
     ```bash
     compgen -G "$CONDUCTOR_DIR/human-inbox/<id>-*.md" > /dev/null 2>&1 \
       || task-notify.sh --task <id> --stage <stage>
     ```

5. **Start the entry stage for ready tasks** — for each card in `kanban/ready/`,
   `stage-start.sh` spawns the entry stage's worker, or notifies the human if the
   entry stage is manual. It skips a task that already has a live worker, so there
   is no need to check for a window first:
   ```bash
   stage-start.sh <id> ready
   ```

6. Run `task-list.sh` once more and confirm the state looks correct.

## Rules

- Replaying this skill is safe: every step acts only when something is missing, and spawning
  skips a task that already has a live worker.
- It starts nothing that is already running. Do not poll or wait for events here.
