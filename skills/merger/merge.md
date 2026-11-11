# Skill: Merger

You rebase the feature branch onto the base branch and report the outcome cleanly.

## Steps

1. Read the base branch (`main` unless the project configured another), then fetch it if a remote exists:
   ```bash
   BASE=$(grep '^base-branch:' "$CONDUCTOR_DIR/config.md" | awk '{print $2}'); BASE=${BASE:-main}
   git fetch origin "$BASE" 2>/dev/null || true
   ```

2. Note the tip of the base branch, then rebase onto it with `attribution-rebase.sh` — use `origin/$BASE` if remote exists, otherwise local `$BASE`:
   ```bash
   BASE_SHA=$(git rev-parse --verify -q "origin/$BASE" || git rev-parse "$BASE")
   $SCRIPTS_DIR/attribution-rebase.sh "$BASE_SHA" --task $TASK_ID
   ```
   It is the plain rebase that also stamps each of the task's commits with the trailers the project
   asked for (`attribution:` in `config.md`; nothing for `none`). Do not assemble trailers yourself and
   do not run `git rebase` in its place. Its exit status says what happened:
   - **0** — rebased. Go on to step 3.
   - **4** — the stamp could not be worked out (the message is on stderr, usually a bad `attribution:`
     value in `config.md`). Nothing was rebased. This is not a conflict: do not abort anything and do not
     signal `conflict`. Signal blocked and stop:
     ```bash
     $SCRIPTS_DIR/task-signal.sh \
       --task $TASK_ID \
       --type signal \
       --outcome blocked \
       --notes "attribution-rebase.sh exited 4: <the stderr message>"
     ```
   - **anything else** — git stopped. Look at whether a rebase is in progress:
     ```bash
     [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
     ```
     If one is, it is a conflict: go to step 4. If none is, git failed before it began (a worktree with
     uncommitted changes, a base that is not there). It is not a conflict and there is nothing to abort:
     signal blocked, as for 4, with git's message in `--notes "attribution-rebase.sh failed before
     rebasing: <the stderr message>"`, and stop.

   `BASE_SHA` is the commit the task's work is rebased onto, so `BASE_SHA..HEAD` is exactly the
   task's commits once the fast-forward lands. It is how the task's size is measured afterwards
   (`task-record.sh`), after the branch may be gone. Take it again on every retry: the rebase that
   succeeds is the one whose base counts. A retry runs the same command: the stamp adds only what is
   missing, so a second run changes nothing.

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
     --base-sha "$BASE_SHA" \
     --head-sha "$(git rev-parse HEAD)" \
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
- Rebase with `attribution-rebase.sh`, never with a bare `git rebase`, and never write trailers by hand.
- Never force-push.
- Retry a failed fast-forward at most 3 times — never loop indefinitely.
- Never merge a branch that has not been rebased onto the base, and never create merge commits. The fast-forward in step 3 is the only way work lands on the base branch.
- Never push or fast-forward `main` unless `main` is the base branch. When the base is another branch, `main` stays untouched.
- Signal once, then stop.
