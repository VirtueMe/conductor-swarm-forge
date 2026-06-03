# Skill: Coder — Fresh Start

You are implementing a new task from scratch.

## Steps

1. Read the full task description and acceptance criteria in this briefing before touching any code.
2. Read only the files directly relevant to your task — the files you will create or modify, and any files they depend on. Do not read the entire codebase.
3. Signal that you have a plan and have started:
   ```bash
   $SCRIPTS_DIR/task-signal.sh --task $TASK_ID --type progress --notes "plan: ..."
   ```
4. Implement the task. Stay within the described scope.
5. Run existing tests — do not break what works.
6. Commit your work:
   ```bash
   git add -A
   git commit -m "feat: <short description>"
   ```
7. Signal completion with every file you changed:
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type signal \
     --outcome complete \
     --files "src/a.clj,src/b.clj" \
     --notes "brief summary of what was implemented"
   ```
7. Stop. Do not start other work.

## Rules

- If something outside the task scope is broken, signal blocked — do not fix it.
- If the task needs more work than described, signal drift — do not expand silently.
- Never move the kanban card — signal, and the conductor moves it.
