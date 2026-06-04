# Skill: On Signal Blocked

Triggered when a `signal-*.md` artifact with `outcome: blocked` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the signal file

## Steps

1. Read the signal body — it describes what the worker is blocked on.

2. Write a conductor note so the blocker is visible in the work history:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: worker blocked — <paste blocker description here>"
   ```

3. **Assess the blocker to pick the `assess` guard value.** This is a conductor
   judgement call — read the artifact and decide:
   - **Hard dependency** — another task must complete first (`assess=hard-dependency`).
   - **Clarification needed / design decision / missing task** — anything that
     needs the architect (e.g. `assess=clarification`). Any value other than
     `hard-dependency` routes to escalation.

4. **Ask the topology where this task goes.** Do not hardcode the backlog /
   escalate split — call `route` with the event and the `assess` guard:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     signal-blocked assess=<hard-dependency|clarification|...>)
   ```

5. **Act on the destination:**
   - **A concrete stage** (e.g. `backlog`, for a hard dependency) — move the card:
     ```bash
     task-move.sh $TASK_ID "$DEST"
     ```
     `backlog` is a holding column — no worker is spawned.
   - **`@escalate`** — do not move the card; escalate to the architect by writing
     the inbox file:
     ```bash
     mkdir -p "$CONDUCTOR_DIR/architect-inbox"
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-blocked.md" << EOF
     ---
     type: blocked
     task-id: $TASK_ID
     ---
     $(cat $ARTIFACT)
     EOF
     ```

6. Run `task-list.sh` to confirm current state.
