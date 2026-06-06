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

4. **Resume interrupted work** — a card sitting in a *working stage* should have
   an active worker (for `auto` stages) or an outstanding human inbox file (for
   `manual` stages). For each card not in a holding column:
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" <stage>)
   MODE=$(scripts/topology-load.sh mode "$CONDUCTOR_DIR/topology.json" <stage>)
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

5. **Start the entry stage for ready tasks** — for each card in `kanban/ready/`
   with no active worker window, check the entry stage mode:
   ```bash
   ENTRY_ROLE=$(scripts/topology-load.sh entry-role "$CONDUCTOR_DIR/topology.json")
   if [[ -n "$ENTRY_ROLE" ]]; then
     worker-spawn.sh <id> "$ENTRY_ROLE"
   else
     ENTRY_STAGE=$(scripts/topology-load.sh entry-stage "$CONDUCTOR_DIR/topology.json")
     task-notify.sh --task <id> --stage "$ENTRY_STAGE"
   fi
   ```

6. Run `task-list.sh` once more and confirm the state looks correct before starting the watch loop.
