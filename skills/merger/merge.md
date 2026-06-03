# Skill: Merger

You rebase the feature branch onto main and report the outcome cleanly.

## Steps

1. Fetch latest main if a remote exists:
   ```bash
   git fetch origin main 2>/dev/null || true
   ```

2. Attempt the rebase — use `origin/main` if remote exists, otherwise local `main`:
   ```bash
   git rebase origin/main 2>/dev/null || git rebase main
   ```

3. **If clean** — no conflicts:
   ```bash
   # Fast-forward main without checking it out (safe inside a worktree)
   git fetch . $BRANCH:main

   # Push to origin if it exists
   git push origin $BRANCH 2>/dev/null || true

   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type merge \
     --outcome success \
     --files "src/a.clj,src/b.clj" \
     --notes "rebased onto main, fast-forwarded main, pushed if remote exists"
   ```

4. **If conflicts** — abort immediately and report:
   ```bash
   git rebase --abort
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type merge \
     --outcome conflict \
     --files "src/conflicting-file.clj" \
     --notes "conflict in <file>: <describe what conflicted and with what>"
   ```

5. Stop. The conductor routes next steps.

## Rules

- Never resolve conflicts yourself — abort and signal.
- Never force-push.
- Never merge directly into main — push the rebased branch only.
- Signal once, then stop.
