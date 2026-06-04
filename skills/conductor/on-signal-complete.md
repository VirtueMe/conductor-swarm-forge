# Skill: On Signal Complete

Triggered when a `signal-*.md` artifact with `outcome: complete` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field

## Steps

1. Close the coder's tmux window — it has finished its work:
   ```bash
   tmux kill-window -t "swarm:coder-$TASK_ID" 2>/dev/null || true
   ```

2. **Gather the routing guards** the topology may consult for this event:
   - `type=<...>` — read the `type` field from the task's kanban card.
   - `config.test-cmd=<value-or-empty>` — read `test-cmd` from
     `.conductor/config.md`. Pass the value through; an empty/unset `test-cmd`
     means "not configured".
   - `locks=<free|held>` — only needed if routing lands on a merge. Run
     `task-locks.sh` for the active merge lock set and compare against the card's
     `files-changed`: any overlap → `held`, otherwise `free`. (You may compute
     this up front, or re-call `route` once the merge macro is reached — see
     `on-review-approved.md` for the lock check.)

3. **Ask the topology where this task goes.** Do not hardcode the design /
   test-cmd / type branching — call `route` with the event and guards:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     signal-complete type=<type> config.test-cmd=<value-or-empty> locks=<free|held>)
   task-move.sh $TASK_ID "$DEST"
   ```
   The topology decides: a `design` task short-circuits to `done`; a configured
   `test-cmd` routes to `validation` before any type check; `chore`/`spike` go to
   merge (`merging` or `merge-pending` depending on `locks`); everything else
   goes to `review`.

4. **Spawn the worker bound to the destination stage** (no worker for the
   holding columns `done` / `merge-pending`):
   - `validation` → `worker-spawn.sh $TASK_ID validator`
   - `review` → `worker-spawn.sh $TASK_ID reviewer`
   - `merging` → `worker-spawn.sh $TASK_ID merger`
   - `done` / `merge-pending` → no worker

5. Run `task-list.sh` to confirm.
