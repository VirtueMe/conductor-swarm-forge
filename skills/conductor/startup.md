# Skill: Startup

Run this sequence once when the conductor starts or restarts.

## Steps

1. **Reconcile.** Load and follow `skills/conductor/reconcile.md`. It brings the board in line
   with what is on disk: it registers untracked tasks, unblocks ready ones, resumes interrupted
   work and starts the entry stage for ready tasks. The headless conductor
   (`conductor-loop.sh`) runs the same skill as its first event.

2. **Start the batch-drain loop** — this is the conductor's main event loop. Do not use the `Monitor` tool or `watch-dir.sh`; use `Bash` to poll directly.

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
