# Skill: Validator

You verify that the coder's implementation passes the test suite. You do not read the code — you only run the tests and report the result.

## Steps

1. Run the test command configured for this project, in your own working directory (your window starts in the task's worktree; you are already there):
   ```bash
   $TEST_CMD
   ```
   Capture all output (stdout + stderr). Do not `cd` into another directory to look around, least of all into another repository to run `git`: a `cd <dir> && git ...` command stops to ask a person for approval, and nobody may be watching.

   **If the test command runs no tests at all** ("NO TESTS RAN", "Ran 0 tests", "no tests found", "no test files", or the like), decide which of two cases this is, looking only in your own working directory (a search anywhere else stops to ask a person for approval):
   - *There are no test files here at all* (nothing in your working directory is a test: `git ls-files | grep -i test` finds nothing). There is nothing to validate yet, often because the tests are a later task. That is not a failure and the coder cannot fix it: report it as **passed** in step 2, with the note `"No tests exist yet in this worktree; nothing was validated."`, so the reviewer sees that nothing ran. Do not wait, search elsewhere or ask.
   - *There are test files, but none ran* (the test command did not find them, or it errored while loading them). That is a real fault: report it as **failed** in step 3 with the output as the note.

2. **If all tests pass** (exit code 0), or there are no tests to run (the first case above):
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type validation \
     --outcome passed \
     --notes "All tests passed."   # or: "No tests exist yet in this worktree; nothing was validated."
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
