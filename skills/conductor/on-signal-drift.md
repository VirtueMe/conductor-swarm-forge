# Skill: On Signal Drift

Triggered when a `drift-*.md` artifact appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the drift file

## Steps

1. Read the drift artifact body — it describes what changed from the original scope and why.

2. **Assess the drift to pick the `assess` guard value.** This is a conductor
   judgement call — read the artifact and decide:
   - **Task invalidation** — the drift reveals the original task no longer makes
     sense (`assess=invalidation`).
   - **Scope expansion** — the coder is doing significantly more than the task
     asked (`assess=scope`).
   - **Minor drift** — a small, justified deviation within the spirit of the task
     (e.g. `assess=minor`). Anything other than `invalidation`/`scope` stays put.

3. **Ask the topology where this task goes.** Do not hardcode the invalidation /
   scope / minor branching — call `route` with the event and the `assess` guard:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" \
     signal-drift assess=<invalidation|scope|minor|...>)
   ```

4. **Act on the destination:**
   - **A concrete stage** (e.g. `done`, for an invalidation) — move the card and
     note why. The destination is a holding column, so no worker is spawned:
     ```bash
     task-signal.sh --task $TASK_ID --type progress \
       --notes "conductor: task invalidated by drift — <reason>"
     task-move.sh $TASK_ID "$DEST"
     ```
   - **`@escalate`** (scope expansion) — do not move the card; escalate to the
     architect by writing the inbox file, then write a note to the coder to pause
     the extra work until the architect responds:
     ```bash
     mkdir -p "$CONDUCTOR_DIR/architect-inbox"
     cat > "$CONDUCTOR_DIR/architect-inbox/${TASK_ID}-drift.md" << EOF
     ---
     type: drift
     task-id: $TASK_ID
     ---
     $(cat $ARTIFACT)
     EOF
     ```
   - **`@stay`** (minor drift) — no column change; write a note and let the coder
     continue:
     ```bash
     task-signal.sh --task $TASK_ID --type progress \
       --notes "conductor: drift acknowledged — <brief summary>"
     ```

5. Run `task-list.sh` to confirm.
