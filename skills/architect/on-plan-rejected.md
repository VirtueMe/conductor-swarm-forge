# Skill: Architect — The Strategist Sent the Plan Back

The strategist judged your plan and found it wrong. The plan is still held: no task has started, so you can change it freely.

## Steps

1. Read the inbox file: it says what is wrong and what the strategist would change.
2. Decide for yourself. If the strategist is right, fix the plan. If you disagree on a point, say why in your next announcement; do not ignore it silently.
3. Fix the plan. Tasks have not started, so a wrong task can be edited in its file under `.conductor/tasks/` (and its dependency list changed); add a missing task with `task-create.sh`.
4. Run `plan-check.sh` and fix every error.
5. Tell the strategist, as in step 6 of `skills/architect/on-brief.md`: a new `plan-ready` file, saying what changed.

The strategist sends a plan back at most twice. After that the person decides.
