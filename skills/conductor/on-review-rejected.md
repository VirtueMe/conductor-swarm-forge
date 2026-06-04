# Skill: On Review Rejected

Triggered when a `review-*.md` artifact with `outcome: rejected` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the review file

## Steps

1. Close the finishing worker's tmux window (named `<role>-<id>` — find it by task id):
   ```bash
   WIN=$(tmux list-windows -t swarm -F '#{window_name}' 2>/dev/null | grep -E -- "-$TASK_ID\$" | head -1)
   [[ -n "$WIN" ]] && tmux kill-window -t "swarm:$WIN" 2>/dev/null || true
   ```

2. Read the review artifact body — it contains specific findings the next worker must address.

3. **Ask the topology where this task goes.** This event takes no guards — the
   destination is unconditional — but resolve it through `route` rather than
   hardcoding the column:
   ```bash
   DEST=$(scripts/topology-load.sh route "$CONDUCTOR_DIR/topology.json" review-rejected)
   task-move.sh $TASK_ID "$DEST"
   ```

4. Write a conductor note summarising the rejection so the next worker has immediate context:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: review rejected — <paste the key findings here>"
   ```

5. **Spawn the worker bound to the destination stage.** `$DEST` is the rework
   loopback; derive its role from the topology and spawn it. The worker's briefing
   will include the full work history (including the review artifact), so it can read
   exactly what needs to change:
   ```bash
   ROLE=$(scripts/topology-load.sh role "$CONDUCTOR_DIR/topology.json" "$DEST")
   [[ -n "$ROLE" ]] && worker-spawn.sh $TASK_ID "$ROLE"
   ```

6. Run `task-list.sh` to confirm.
