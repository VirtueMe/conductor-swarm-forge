# Skill: Strategist — Check the Plan, Write the Strategy, Release

The architect says the plan is complete. Nothing has started: the plan is held.

## Steps

### 1. Read what there is

```bash
task-list.sh
plan-check.sh
```
Read `.conductor/brief.md` and every task file in `.conductor/tasks/`.

### 2. Judge the plan

`plan-check.sh` has already covered the mechanical faults (missing dependencies, cycles, a feature with no tests). You judge what a script cannot:

- **Covers the brief?** Walk the brief's requirements one by one and find the task that delivers each. A requirement with no task is a gap.
- **Too large?** A task with more than one coder session of work.
- **Tests really there?** A feature whose description says "tests" in passing but does not ask the coder to write them with the code.
- **Order:** work that must come first does come first.

### 3. If the plan is wrong, send it back

```bash
plan-revision.sh reject "<what is wrong, task by task or requirement by requirement, and what you would change>"
```
It writes your note to the architect (and to the person). Then stop. The plan stays held. The architect fixes it and tells you again with a new `plan-ready` file. A plan can be sent back **2** times (`max-plan-rejections` in `config.md`): after that the call fails, a person has been told, and the plan stays held for them. Do not release a plan you judge wrong to get round the cap.

### 4. Write each task's strategy

For each task that should not run the default way, write `.conductor/strategy/<task>.json` (see the strategy file in your briefing). Most tasks need no file. Examples of a task that does:
- a `chore` that only edits documentation: skip `validation`, reason "docs only: no test applies"
- a large integration task: reviewer on a stronger model
- a trivial task: coder on a cheaper model

Check each file: `task-strategy.sh validate <task>`.

### 5. Release

```bash
plan-hold.sh release
```
It checks the plan and every strategy file, and releases nothing if anything is wrong; fix what it names and run it again. When it succeeds the conductor starts the tasks that have no dependencies.

### 6. Announce

Write a short summary: what you changed from the default and why, and anything you noticed but left to the architect. This becomes part of the project record.
