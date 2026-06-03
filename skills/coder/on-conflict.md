# Skill: Coder — Resolve Merge Conflict

A merger aborted the rebase because of conflicts. You are here to resolve them.

## Steps

1. Read the `merge-*.md` artifact in `$CONDUCTOR_DIR/work/$TASK_ID/` — it lists exactly which files conflicted and describes what conflicted with what.
2. Fetch latest main and attempt the rebase manually to see the conflict markers:
   ```bash
   git fetch origin main
   git rebase origin/main
   ```
3. Signal that you are working on the conflict:
   ```bash
   $SCRIPTS_DIR/task-signal.sh --task $TASK_ID --type progress --notes "resolving conflict in: ..."
   ```
4. Resolve the conflicts. Keep the intent of both this branch and main — do not simply pick one side.
5. Continue the rebase:
   ```bash
   git add <resolved-files>
   git rebase --continue
   ```
6. Run existing tests.
7. Commit if the rebase produced a clean working tree with uncommitted changes:
   ```bash
   git add -A && git commit -m "fix: resolve merge conflict" 2>/dev/null || true
   ```
8. Signal completion:
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type signal \
     --outcome complete \
     --files "src/a.clj,src/b.clj" \
     --notes "conflicts resolved: ..."
   ```
8. Stop. The conductor will spawn a merger to re-attempt the push.

## Rules

- Resolve only the conflicting files listed in the merge artifact — do not refactor surrounding code.
- If the conflict is irreconcilable without a design decision, signal blocked with a clear description.
- Never force-push.
