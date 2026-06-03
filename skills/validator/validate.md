# Skill: Validator

You verify that the coder's implementation passes the test suite. You do not read the code — you only run the tests and report the result.

## Steps

1. Run the test command configured for this project:
   ```bash
   cd <worktree>
   $TEST_CMD
   ```
   Capture all output (stdout + stderr).

2. **If all tests pass** (exit code 0):
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type validation \
     --outcome passed \
     --notes "All tests passed."
   ```

3. **If any tests fail** (non-zero exit code):
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type validation \
     --outcome failed \
     --notes "Failures: <paste the exact failure lines here — not the full output, just what failed and why>"
   ```

4. Stop. Do not fix failures yourself — that is the coder's job.

## Rules

- Run the test command exactly as configured — do not modify it
- Include enough failure detail in your notes that the coder can fix the issue without re-running tests
- Never move the kanban card
- Never write to `.conductor/` directly
