# Skill: On Review Rejected

Triggered when a `review-*.md` artifact with `outcome: rejected` appears in `work/<id>/`.

## Context

- `$TASK_ID` — the task ID from the artifact's `task-id` field
- `$ARTIFACT` — path to the review file

## Steps

1. Close the reviewer's tmux window:
   ```bash
   tmux kill-window -t "swarm:reviewer-$TASK_ID" 2>/dev/null || true
   ```

2. Read the review artifact body — it contains specific findings the coder must address.

2. Move the task back to in-progress:
   ```bash
   task-move.sh $TASK_ID in-progress
   ```

3. Write a conductor note summarising the rejection so the next coder has immediate context:
   ```bash
   task-signal.sh --task $TASK_ID --type progress \
     --notes "conductor: review rejected — <paste the key findings here>"
   ```

4. Spawn a new coder. The coder's CLAUDE.md will include the full work history, including the review artifact, so it can read exactly what needs to change:
   ```bash
   worker-spawn.sh $TASK_ID coder
   ```

5. Run `task-list.sh` to confirm.
