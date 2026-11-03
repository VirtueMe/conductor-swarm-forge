# Handler replay fixtures

A conductor handler is converted from a skill (a model) to a script one at a time. The replay gate
(`scripts/handler-replay.sh`) is what lets a conversion ship: it runs the script against a recorded
situation and requires the same card moves and worker spawns that the skill produced. It compares
decisions only, never the wording of notes, because the skill side is a model.

`scripts/test-handler-replay.sh` checks the gate itself (it passes a right handler and fails wrong
ones) and runs in CI with no model and no tmux server. To check a converted handler, run the gate
on its fixtures:

```bash
scripts/handler-replay.sh tests/handler-replay/review-approved-locks-free
```

Exit 0 means it matches, 1 it does something else (a diff is printed), 2 the fixture is unusable,
3 there is no script handler for the fixture's event (which is the answer until that handler has
been converted).

## A fixture

One directory per situation, shaped like a `.conductor` so the gate can copy it:

| Path | What it is |
| --- | --- |
| `tasks/<id>.md` | the task file |
| `work/<id>/*.md` | the task's artifacts, including the one that triggers the handler |
| `kanban/<stage>/<id>.md` | the card, in the stage it is in when the event arrives |
| `event` | one line: the triggering artifact, relative to the conductor dir (`work/0001/review-….md`). Leave it out for the startup reconcile (below) |
| `locks` | the files `task-locks.sh` reports as locked, one per line; empty for none |
| `windows` | optional; the tmux windows that exist, one name per line (`coder-0001`). It is what `tmux list-windows` answers, so a handler sees those workers as alive. Without it no window exists |
| `human-inbox/` | optional; copied as it is, for a handler that checks whether a notification is still outstanding (`human-inbox/0001-<timestamp>.md`) |
| `config.md` | optional; the project config a handler reads (`test-cmd`, say). Without it the scratch conductor dir has none, so nothing is configured |
| `expect` | the outcome the skill produced (below) |
| `topology.json` | optional; the shipped `software-dev` topology when absent |

A fixture with no `event` is the **startup reconcile**: the handler is `scripts/handlers/reconcile.sh`
(skill `conductor/reconcile`), run with no task and no artifact (`TASK_ID`, `TASK_FILE` and `ARTIFACT`
are unset, as the loop leaves them). `work/` may be absent, since a task nobody has worked on has no
artifacts. As there is no one task, `expect` lists a `stage` line for every card, ordered by task ID.

The gate never changes a fixture. The handler is found the way the loop finds it: the event's
type and outcome resolve to a skill (`topology-load.sh conductor-skill`), and the handler is
`scripts/handlers/<skill name>.sh`.

## `expect`

Plain lines, compared exactly and in this order: the moves, then the worker spawns, then the
final stage (of every card, when the fixture has no `event`).

```
move 0001 merging          each move made (a `moved` artifact written), in order
spawn 0001 merger          each worker started, in order; `notify <task> <stage>` for a manual stage
shutdown                   the swarm was shut down (`conductor-shutdown.sh`), in order with the spawns
stage 0001 merging         the stage the card ended in
```

Nothing else is compared: not the notes a handler writes, not timestamps, not artifact wording.

## What the gate stubs

The handler runs against a scratch copy of `scripts/`. `worker-spawn.sh`, `task-notify.sh`,
`task-locks.sh` and `conductor-shutdown.sh` are stubs that log or answer and do nothing else
(`stage-start.sh` calls them by absolute path, so a stub on `PATH` would not be reached), and `tmux`
is a stub on `PATH` that answers `list-windows` from the fixture's `windows` and does nothing else.
The `task-locks.sh` stub answers with the fixture's `locks` and the files of
every card in `merging`, as the real one does, so a handler that starts several merges sees each
lock taken. The rest
is real: `task-move.sh`, `task-replay.sh`, `stage-start.sh` and `topology-load.sh` decide the moves
and spawns. A real spawn also writes an `assigned` artifact and moves the card to the working
stage; the stub does not, so `expect` records the decision to spawn, not those effects.

## Recording a fixture from a live run

`expect` should be what the skill actually did, so it is recorded, not written by hand. You run
this yourself (it calls a model, a few cents each time), for example with `!` in a session:

1. **Write the situation.** Copy a fixture directory, or build one, with everything except
   `expect`: the task, its artifacts including the triggering one, the card in its starting stage,
   `event`, and `locks`. Change `locks` or the card to make each branch of the handler its own
   fixture (files locked and free, each task `type`).
2. **Record:**

   ```bash
   scripts/handler-replay.sh --record tests/handler-replay/<name>
   ```

   It runs the **skill** for the event through the real `conductor-loop.sh` and the conductor
   adapter from the default workforce (`--adapter-file <file>` picks another), in the same stubbed
   scratch setup the gate uses, and writes `expect` from the moves, spawns and final stage. The
   loop is told every other artifact is already handled, so only the fixture's event runs. The
   startup reconcile is skipped, because it is not what is being recorded (a fixture with no `event`
   records the reconcile itself: nothing is skipped and no event is handled), and a script handler
   for the event is ignored, so the skill runs even after it has been converted. It never replaces an
   existing `expect` unless you add `--force`, and refuses a run in which the skill made no move and
   started no worker (`--allow-empty` records one anyway), because that is almost always a skill
   that did not act. The loop runs from a scratch directory, not from where you started it, and the
   cost cap (`CONDUCTOR_MAX_BUDGET_USD`, default $1) is printed first.
3. **Read what it printed.** That is what the model did in one run. For a handler with no judgment
   in it (the mechanical ones this gate is for) record twice with `--force` and check the two agree;
   a difference means the skill is not as mechanical as thought.
4. **Commit the fixture** with the handler that it gates.

## Where `expect` comes from

The three fixtures here (`review-approved-locks-free`, `-locks-held`, `-manual-merge`) were first
written by hand from what `skills/conductor/on-review-approved.md` says, to prove the gate works.
On 2026-11-03 each was recorded from a live run of the skill (`--record`, default workforce
adapter, into a temporary copy) and the recorded `expect` was identical to the hand-written one
in all three. That is one run per fixture: it shows the skill does this, not that it always does.
A fixture for a new handler should be recorded, and for a handler with any judgment in it,
recorded more than once.

The three `validation-passed-*` fixtures (`chore-locks-free`, `chore-locks-held`, `feature-review`)
were not hand-written: their `expect` was recorded from a live run of the
`on-validation-passed` skill on 2026-11-03, twice each (the second with `--force`, and the file did
not change), and the script matched all three. They cover each branch of the rule: a chore parks
or merges by `locks`, and a feature goes to review.

`validation-failed-rework` was recorded the same way from the `on-validation-failed` skill on
2026-11-03 (once, so far), and the script matches it. The route has no guards, so one fixture
covers it.

`review-rejected-rework` was recorded the same way from the `on-review-rejected` skill on
2026-11-03, and the script matches it. Its note is written before the move, where the skill writes
it between the move and the stage start; the gate does not compare notes.

The four `new-task-*` fixtures (`no-deps`, `deps-pending`, `deps-done`, `replayed`) cover the
`deps` guard and the replay guard of `on-new-task`. Their card starts in `backlog`, as
`task-create.sh` leaves it; the replayed one starts past the first stage and expects no moves and
no spawns. As the stub spawn does not advance a card, a task routed to `ready` ends there.

The five `signal-complete-*` fixtures (`design`, `test-cmd`, `chore-locks-free`, `chore-locks-held`,
`feature-review`) cover each branch of the `on-signal-complete` rule. The `test-cmd` one carries a
`config.md` with `test-cmd` set; the others have it empty, which is how `swarm-start.sh` writes an
unconfigured project.

The six `merge-success-*` fixtures cover `on-merge-success`: `unblocks-dependent`,
`dependent-blocked` (it still waits on another task), `releases-pending`, `pending-still-locked`
(`locks` holds its file), `pending-overlap` (two waiting merges that overlap, so only the first can
start) and `project-done` (the last task: the swarm is shut down).

The five `reconcile-*` fixtures have no `event`: they are the startup reconcile, so `expect` lists
a `stage` line for every card. `untracked` (a task with no card is registered and, having no
dependencies, started), `unblocks-ready` (the backlog cards whose dependencies are done move to
ready and start, one that still waits stays), `worker-missing` (a card in a working stage with no
window is respawned, one whose window is listed in `windows` is not), `manual-notify-lost` (a card
in a manual stage with no `human-inbox` file is notified again, on the manual topology of
`review-approved-manual-merge`) and `consistent` (everything has its window and dependencies:
no move, no spawn; recorded with `--allow-empty`).

All five were recorded from the `reconcile` skill on 2026-11-03, and the script matches them. Four
agreed with the script on the first run. `manual-notify-lost` did not: two live runs of the skill
said the human-inbox file was present, with no such file in the fixture (a probe around the adapter
showed no inbox before the model ran and none after), and a third run did what the skill says and
re-notified. So the skill is not reliable on this step; the recorded `expect` is the third run,
which is also what the skill's text asks for. This is the case for the script, not a difference
the gate should accept.
