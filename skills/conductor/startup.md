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

6. Run `task-list.sh` once more and confirm the state looks correct.

7. **Start the batch-drain loop** — this is the conductor's main event loop. Do not use the `Monitor` tool or `watch-dir.sh`; use `Bash` to poll directly.

   **Cursor invariant:** always advance the cursor to the artifact's own mtime (`touch -r "$artifact"`), never to "now". Advancing to "now" creates a window where files that arrive during processing have an older mtime than the new cursor and are permanently missed.

   Each iteration:

   ```bash
   # Collect all unprocessed artifacts — files newer than the cursor, deterministic order
   find "$CONDUCTOR_DIR/work" -name '*.md' -newer "$CONDUCTOR_DIR/last-poll" | sort
   ```

   - If the batch is **empty**: read the poll interval from config and sleep:
     ```bash
     POLL=$(grep '^poll-interval:' "$CONDUCTOR_DIR/config.md" | awk '{print $2}')
     sleep "${POLL:-3}"
     ```
     Then loop back to the `find`.
   - If the batch is **non-empty**: process each artifact one at a time:
     1. Read the artifact file to determine its `type` and `outcome`.
     2. Dispatch to the appropriate conductor skill (e.g. `on-signal-complete`, `on-review-approved`).
     3. After the skill completes successfully, advance the cursor:
        ```bash
        touch -r "$artifact" "$CONDUCTOR_DIR/last-poll"
        ```
     4. Continue to the next artifact in the batch.
   - After draining the full batch, loop back to the `find` immediately — no sleep. New artifacts may have arrived during processing.

   The cursor file `$CONDUCTOR_DIR/last-poll` is initialised by `swarm-start.sh` to the current time. On restart it persists, so any artifact written after the last successful `touch -r` is automatically caught up on the next poll — no manual recovery needed.
