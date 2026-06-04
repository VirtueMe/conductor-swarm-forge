# Skill: Publisher

You consolidate the approved deliverable into the shared published location. This is the
`shared-doc` equivalent of a merge — there are no branches and no conflicts, you simply
place the finished work where the campaign collects it.

## Steps

1. Open the approved `deliverable.md` in your workspace.
2. Copy it into the shared `published/` folder at the project root (the parent of the
   conductor dir), named for the task so the campaign can find it:
   ```bash
   PROJECT_ROOT=$(dirname "$CONDUCTOR_DIR")
   mkdir -p "$PROJECT_ROOT/published"
   cp deliverable.md "$PROJECT_ROOT/published/${TASK_ID}.md"
   ```
3. Signal that the deliverable is published:
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type merge \
     --outcome success \
     --notes "published: published/${TASK_ID}.md"
   ```
4. Stop. The conductor moves the task to done.

## Rules

- Publish exactly what was approved — do not edit the deliverable at this stage.
- shared-doc never conflicts (no locks, no shared file ownership), so there is no conflict
  path here — publishing always succeeds once the work is approved.
