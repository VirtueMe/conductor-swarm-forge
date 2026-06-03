# Skill: Coder — Fix After Review Rejection

A reviewer rejected this task. You are here to address their findings.

## Steps

1. Read the `review-*.md` artifact in `$CONDUCTOR_DIR/work/$TASK_ID/` — it contains specific findings you must address.
2. Read the current state of the code (use `git diff main`).
3. Signal that you understand the findings and have a fix plan:
   ```bash
   $SCRIPTS_DIR/task-signal.sh --task $TASK_ID --type progress --notes "addressing review: ..."
   ```
4. Fix only what the review identified. Do not refactor, do not add features.
5. Run existing tests.
6. Commit your work:
   ```bash
   git add -A
   git commit -m "fix: <short description>"
   ```
7. Signal completion:
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type signal \
     --outcome complete \
     --files "src/a.clj,src/b.clj" \
     --notes "addressed review findings: ..."
   ```
7. Stop.

## Rules

- Address every finding in the review — do not skip any.
- Do not change anything outside the scope of the review findings.
- If a finding is unclear or contradicts the original task, signal blocked with a specific question.
