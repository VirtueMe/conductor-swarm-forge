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
| `event` | one line: the triggering artifact, relative to the conductor dir (`work/0001/review-….md`) |
| `locks` | the files `task-locks.sh` reports as locked, one per line; empty for none |
| `expect` | the outcome the skill produced (below) |
| `topology.json` | optional; the shipped `software-dev` topology when absent |

The gate never changes a fixture. The handler is found the way the loop finds it: the event's
type and outcome resolve to a skill (`topology-load.sh conductor-skill`), and the handler is
`scripts/handlers/<skill name>.sh`.

## `expect`

Plain lines, compared exactly and in this order: the moves, then the worker spawns, then the
final stage.

```
move 0001 merging          each move made (a `moved` artifact written), in order
spawn 0001 merger          each worker started, in order; `notify <task> <stage>` for a manual stage
stage 0001 merging         the stage the card ended in
```

Nothing else is compared: not the notes a handler writes, not timestamps, not artifact wording.

## What the gate stubs

The handler runs against a scratch copy of `scripts/`. `worker-spawn.sh`, `task-notify.sh` and
`task-locks.sh` are stubs that log or answer and do nothing else (`stage-start.sh` calls them by
absolute path, so a stub on `PATH` would not be reached), and `tmux` is a stub on `PATH`. The rest
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
   startup reconcile is skipped, because it is not what is being recorded, and a script handler for
   the event is ignored, so the skill runs even after it has been converted. It never replaces an
   existing `expect` unless you add `--force`, and refuses a run in which the skill made no move and
   started no worker (`--allow-empty` records one anyway), because that is almost always a skill
   that did not act. The loop runs from a scratch directory, not from where you started it, and the
   cost cap (`CONDUCTOR_MAX_BUDGET_USD`, default $1) is printed first.
3. **Read what it printed.** That is what the model did in one run. For a handler with no judgment
   in it (the mechanical ones this gate is for) record twice with `--force` and check the two agree;
   a difference means the skill is not as mechanical as thought.
4. **Commit the fixture** with the handler that it gates.

## Where `expect` comes from

The three fixtures here were written by hand from what `skills/conductor/on-review-approved.md`
says, to prove the gate works. They are not recorded, so they do not show what the skill does.
Replace them by recording (above) before relying on them for a conversion.
