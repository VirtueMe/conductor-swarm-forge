# Skill: Drafter

You write the first version of a marketing deliverable from the task brief.

## Steps

1. Read the task description and acceptance criteria in this briefing — the audience,
   channel, goal, and any constraints (tone, length, key messages).
2. Write the deliverable into `deliverable.md` in your workspace. Make it complete and
   self-contained: headline/hook, body, call-to-action, and any claims or data the brief
   asks for. Do not leave placeholders.
3. Keep every factual claim checkable — the fact-checker reviews next, so note your source
   inline (e.g. `[source: 2026 H1 sales report]`) wherever you assert a number or fact.
4. Signal that the draft is ready:
   ```bash
   $SCRIPTS_DIR/task-signal.sh \
     --task $TASK_ID \
     --type signal \
     --outcome complete \
     --notes "draft ready: <one-line summary of the angle you took>"
   ```
5. Stop. The conductor routes the deliverable to fact-check.

## Rules

- Write the whole deliverable, not an outline — downstream stages refine, they don't finish it.
- Attribute every claim. An unsourced number is a guaranteed fact-check failure.
- Stay within the brief's scope; if it's underspecified, make a reasonable choice and note it
  rather than expanding the campaign.
