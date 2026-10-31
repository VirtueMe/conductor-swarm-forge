# Skill: Merger

You rebase the feature branch onto the base branch and report the outcome cleanly.

## Steps

1. Read the base branch (`main` unless the project configured another), then fetch it if a remote exists:
   ```bash
   BASE=$(grep '^base-branch:' "$CONDUCTOR_DIR/config.md" | awk '{print $2}'); BASE=${BASE:-main}
   git fetch origin "$BASE" 2>/dev/null || true
   ```

2. Attempt the rebase — use `origin/$BASE` if remote exists, otherwise local `$BASE`:
   ```bash
   git rebase "origin/$BASE" 2>/dev/null || git rebase "$BASE"
   ```

3. **If clean** — no conflicts, fast-forward the base branch:
   ```bash
   # It is checked out in the main working tree, and git refuses to fetch
   # into a checked-out branch — so merge there.
   MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
   if [ "$(git -C "$MAIN_WT" symbolic-ref --short HEAD)" = "$BASE" ]; then
     git -C "$MAIN_WT" merge --ff-only "$BRANCH"
   else
     git fetch . "$BRANCH:$BASE"
   fi
   ```

   **If the fast-forward fails** because the base moved — another merger landed
   between your rebase and now (file locks do not serialise mergers on disjoint
   files) — go back to step 1: re-fetch, re-rebase onto the new tip, and retry
   the fast-forward. Make at most **3 attempts** in total. A conflict on any
   re-rebase is handled by step 4 as usual. If all 3 attempts lose the race,
   `git rebase --abort` if one is in progress and signal `conflict` with
   `--notes "base branch kept moving: fast-forward failed after 3 attempts"`.

   **Once the fast-forward succeeds:**
   ```bash
   # Push to origin if it exists
   git push origin $BRANCH 2>/dev/null || true

   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type merge \
     --outcome success \
     --files "src/a.clj,src/b.clj" \
     --notes "rebased onto $BASE, fast-forwarded $BASE, pushed if remote exists"
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
- Retry a failed fast-forward at most 3 times — never loop indefinitely.
- Never merge a branch that has not been rebased onto the base, and never create merge commits. The fast-forward in step 3 is the only way work lands on the base branch.
- Never push or fast-forward `main` unless `main` is the base branch. When the base is another branch, `main` stays untouched.
- Signal once, then stop.
