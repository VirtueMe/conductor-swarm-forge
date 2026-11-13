# Design: Event-Driven Conductor Loop

**Status:** proposal · **Date:** 2026-10-31 · **Issue:** #46

## Summary

Today the conductor *is* a model. Its main loop (`skills/conductor/startup.md`,
step 7) is instructions that an LLM follows: run `find`, sleep, run `find` again.
On an idle swarm every tick wakes the model to conclude "nothing to do".

This note works out how to make the loop **event-driven**: a deterministic
script drains new artifacts and invokes a model only when there is real work.

Findings that shape the recommendation:

1. **The loop mechanics belong in code.** The cursor-mtime invariant is an
   instruction to the LLM today. It should be enforced code. This is a
   correctness win on its own, independent of cost.
2. **Most conductor handlers do not need a model.** Of the 11 event handlers,
   only 2 need judgment (`on-signal-blocked`, `on-signal-drift`: the `assess`
   guard). 6 are pure compositions of script calls, and 3 write a summary note
   that could be a deterministic copy of the artifact text. This goes beyond the
   issue's proposal (call a model per event) and is the larger saving.
3. **A warm session barely beats a cold start.** Measured on a trivial prompt,
   process startup is about 0.2 to 0.3 s of a roughly 2 s call. For real
   handlers that take many seconds, latency does not justify an RPC-only design.
   What a warm RPC session adds is control (`new_session`, `abort`,
   `set_model`) and a much smaller fixed context, not speed.
4. **At-least-once processing needs one precondition.** `worker-spawn.sh` has no
   guard against spawning twice for the same task. A crash between "handler ran"
   and "cursor advanced" would replay the event and double-spawn.

**Recommendation** (details below): ship it in phases.

- **Phase 0:** a duplicate-spawn guard and one shared spawn-or-notify helper.
- **Phase 1:** a shared `scripts/conductor-loop.sh` and one optional adapter
  primitive, `adapter_dispatch`. This takes idle cost to zero.
- **Phase 2:** convert the mechanical handlers to code one at a time, so the
  model runs only for `assess` and, optionally, summaries.

Before committing to phases 1 and 2, a short spike was run (see
[Spike results](#spike-results)); it found all three harnesses can run a real
handler. It covered one handler on its easy path, so some cases are still open
(see [What is not verified](#what-is-not-verified)). The appendix measurements
used trivial prompts.

## Today: a model-driven loop

`prompts/conductor.prompt` sets the conductor up once. `startup.md` reconciles
state (steps 1 to 6), then step 7 starts the loop:

- `find "$CONDUCTOR_DIR/work" -name '*.md' -newer "$CONDUCTOR_DIR/last-poll" | sort`
- empty batch: `sleep "${POLL:-3}"` and loop
- non-empty batch: for each artifact, resolve the handler
  (`topology-load.sh conductor-skill`), run it, then `touch -r "$artifact"
  "$CONDUCTOR_DIR/last-poll"` and continue

The cursor is advanced to the artifact's own mtime, never to "now", so a file
that arrives during processing is never skipped. `scripts/test-drain.sh` covers
the mechanics and documents one known edge: on filesystems with 1 s mtime
resolution, two files in the same second compare equal and `find -newer` misses
the second.

Two costs follow from the loop being the model:

- **Idle cost.** Each tick is at least one model call that carries the whole
  conductor conversation (in practice a `find` call, then a `sleep` call). With a
  3 s interval that is on the order of 700 calls an hour, doing nothing.
- **An invariant held by instruction.** Nothing but the prompt stops the model
  from advancing the cursor to "now" or skipping a step of a handler.

## What the handlers actually do

Every handler follows the same template: close the finishing worker's window,
gather routing guards, ask `topology-load.sh route` for the destination, move the
card, then spawn a worker or notify a human, then `task-list.sh`.

| Handler | Judgment needed? | Notes |
| --- | --- | --- |
| `on-new-task` | no | guard `deps` from a done-check |
| `on-signal-complete` | no | guards `type`, `config.test-cmd`, `locks` |
| `on-validation-passed` | no | guards `type`, `locks` |
| `on-review-approved` | no | guard `locks` |
| `on-merge-success` | no | `then`-effects: unblock dependents, release merge-pending, check project done; ends by closing the conductor's own window |
| `on-human-decision` | no | the decision is read from the artifact |
| `on-validation-failed` | summary only | "paste key failure lines" into a progress note; counts the failures in a row for the `count` guard |
| `on-review-rejected` | summary only | "paste the key findings" into a progress note |
| `on-merge-conflict` | summary only | note, plus `release-merge-pending` |
| `on-signal-blocked` | **yes** | picks the `assess` guard (`hard-dependency` vs anything else) |
| `on-signal-drift` | **yes** | picks the `assess` guard (`invalidation`, `scope`, `minor`) |

Every routing guard except `assess` is computed from files and scripts:

- `type` comes from the task card.
- `config.test-cmd` comes from `config.md`.
- `locks` comes from `task-locks.sh`.
- `deps` comes from the done column.

The routing itself is already code: `topology-load.sh route`.

## Questions from the issue

### L1 / L2 split

The clean line is **mechanical drain (L1)** versus **handler execution (L2)**.

- **L1** is the cursor, the batch order, the poll sleep, one-handler-at-a-time,
  and handler resolution through the topology. It is fully deterministic and
  should be one shared script.
- **L2** is the handler. The audit above shows L2 is *itself* mostly
  deterministic. Only `assess` (2 handlers) is real judgment, and summaries
  (3 handlers) are light. So L2 divides again into "code" and "needs a model".

### Statelessness

Per-event invocation is stateless, and the handlers already are. Each one reads
everything from files (cards, artifacts, `config.md`, the topology) plus
`$TASK_ID` and `$ARTIFACT`. Nothing relies on carried conversation. This matches
`conductor.prompt`: "All state is managed through scripts."

Hidden dependencies to fix or carry across:

- **Environment.** Skills mix `scripts/...` and `$SCRIPTS_DIR`. Today
  `adapter_write_briefing` seds the values in once. A per-event dispatch must
  inject `CONDUCTOR_DIR` and `SCRIPTS_DIR` on every call, preferably as process
  environment rather than text substitution.
- **tmux names.** Seven handlers hardcode the session `swarm` and the window
  convention `<role>-<id>` to close the finishing worker's window.
- **Self-termination.** `on-merge-success` ends by closing the conductor's own
  window. A loop script must own that exit.
- **Confirmation steps.** `task-list.sh` at the end of each handler only helps an
  LLM check its work. It changes no state.
- **Duplication.** The "derive role and mode from the destination, then spawn or
  notify" block is repeated in five handlers, and a shorter spawn call appears in
  four more. It is the same shape as the
  duplication #44 removed, and a prerequisite for converting handlers to code.

### Briefing model shift

Today the conductor gets one static briefing at launch through
`adapter_write_briefing` and a long-lived interactive session. Per-event dispatch
replaces that with a prompt assembled for each event:

1. static prefix: `conductor.prompt` (scripts API, rules)
2. the resolved handler skill, expanded
3. the event: `$TASK_ID`, `$ARTIFACT`

Put the static prefix first so prompt caching can hit it. Workers keep their
current path (write a briefing file, launch an interactive session in a tmux
window). The conductor would use a second, headless path. Adapters would
therefore have two modes: *launch* (interactive) and *dispatch* (one bounded run
per event).

A cost to be explicit about: a headless conductor loses the interactive window.
Today a human can attach to the conductor and talk to it. The replacement is a
log of events and decisions. The architect window stays interactive.

### "One invocation" means one bounded agentic run

A handler such as `on-merge-conflict` needs several tool-use turns, then
terminates. All three harnesses document support for this, but each bounds it
differently:

| Harness | Mode | How the run ends | How to bound it |
| --- | --- | --- | --- |
| Claude Code | `claude -p` | when the agent stops | outer timeout, `--max-budget-usd`; no turn-limit flag found in `claude --help` on 2.1.316 |
| Codex | `codex exec` | when the agent stops; `--json` events, `-o` last message | outer timeout |
| Pi | `pi --mode rpc` | `agent_settled` event (not `agent_end`, which can be followed by retries and follow-up work) | `abort` command |

So the **loop** must own the deadline in every case. The harness does not.

### Warm vs cold

Measured with one trivial prompt per mode (Appendix). The relevant result:

- Process startup is small. A warm Pi RPC session answered in about 1.9 s; cold
  `pi -p` took about 2.1 s; cold `claude -p` about 2.0 s.
- The saving from a warm session, about 0.2 to 0.3 s per event, is negligible
  against a real handler run that takes many seconds of model and tool time.
- The larger difference is **fixed context**. In this environment each
  `claude -p` call carried about 23k tokens (default system prompt, tools and
  user-level instructions, mostly served from cache), against about 2k for Pi.
  Cost per trivial call on Haiku 4.5: Claude Code $0.0183, $0.0111, then $0.0025
  as the cache warmed. The Claude Code figure depends heavily on the machine's
  configuration and can be trimmed.

Conclusion: **a print mode is worth shipping.** RPC does not earn a rewrite on
latency. What earns it is removing idle ticks and enforcing the invariant in
code, and both work with any one-shot mode. What Pi RPC adds is control: a fresh
context per event (`new_session`), per-event `set_model` and
`set_thinking_level`, a deadline (`abort`), and cost accounting
(`get_session_stats`).

### Reliability

Moving the cursor rule from instruction to code is a correctness win:
1. The cursor can no longer be advanced to "now" by a model slip.
2. For the 6 mechanical handlers, converting them to code also removes the
   chance of a skipped step (for example a forgotten `release-merge-pending`).
This note has no data on how often the model gets these wrong today, so it does
not claim a rate.

### Restart and failure semantics

- **Cursor persistence.** `last-poll` is a file, so a restarted loop resumes from
  it. Advancing only *after* a handler succeeds gives **at-least-once**
  processing.
- **Replay is not safe today.** `worker-spawn.sh` has no guard against an
  existing worker. The workspace step is idempotent (an existing worktree is
  reused), but a replay still writes a second `assigned` artifact, rewrites the
  briefing file that a running worker already loaded, and opens a second tmux
  window with the same name. This is a Phase 0 precondition: skip the spawn
  when a window for `<role>-<id>` exists. It also protects today's model-driven
  loop.
- **Handler failure.** On a non-zero exit or timeout, do not advance the cursor.
  Retry a bounded number of times, then **halt the loop loudly** rather than
  skipping the artifact. Skipping an event can strand a task silently, which is
  worse than stopping.
- **Mid-event crash.** The same rule covers it: the cursor did not move, the
  event replays on restart, and the Phase 0 guard makes the replay safe.
- **Clock resolution.** The 1 s mtime edge that `test-drain.sh` documents applies
  to the cursor. The processed-artifact ledger (`scripts/artifact-ledger.sh`)
  lets a loop read the stream without it: `unprocessed` lists artifacts by what
  is recorded, not by mtime, and orders them by the timestamp in the file name.
  It does not fix the write side: `task-signal.sh` names an artifact
  `<type>-<YYYYMMDD-HHMMSS>.md`, so two artifacts of one type for one task in the
  same second share a name and the second overwrites the first.

### Ledger and cursor (decision)

The ledger at `$CONDUCTOR_DIR/processed.log` sits **next to** `last-poll`; it does
not replace it.

- The ledger decides what is processed. A handler that finishes is followed by
  `artifact-ledger.sh mark <artifact>`.
- `last-poll` stays as a cheap pre-filter. `unprocessed` scans the whole work tree,
  which grows with every artifact ever written; a loop that cares about scan cost
  can narrow the scan with the cursor, as long as it keeps the cursor behind real
  progress so a same-second file cannot hide.
- The ledger does not replace the spawn guard. A crash between "handler finished"
  and `mark` still replays the event, so handlers must stay safe to replay.
- The script is not wired into `startup.md` yet. That belongs with the Phase 1 loop.

### Backward compatibility and fallback

`swarm-start.sh` sources the conductor's adapter and then launches the conductor. The loop
is **opt-in**, with `--headless-conductor` (`-hc`):

- without the flag, nothing changes, for any adapter: an interactive conductor following
  `startup.md`;
- with the flag and an adapter that defines `adapter_dispatch`: `scripts/conductor-loop.sh`
  runs in the conductor window;
- with the flag and an adapter that does not: a warning, and the interactive conductor.

An adapter that only supports interactive sessions simply does not implement the function.

**Why opt-in, not a plain capability check.** All three adapters now define
`adapter_dispatch`, and the default workforce uses `claude-code` for the conductor, so a plain
check would move every existing swarm onto the loop at once. The loop has run on scratch swarms
and stub harnesses, not yet on a long real one, so the default stays interactive until that
changes. It also reconciles on every start (below), so a restart resumes interrupted work.

**What `-hc` does:**

- passes `--conductor-loop` to the preflight check, so a missing GNU `timeout` or `jq` is
  reported at start;
- skips the conductor's briefing, because the loop builds its own prompt and the file would
  be unused;
- starts the loop in the `conductor` window with the `CONDUCTOR_*` and `PI_ABORT_GRACE`
  variables from the environment written on the command line, since tmux gives a new window
  the server's environment, not the caller's;
- runs it as `loop; exec $SHELL`, so when the loop exits the window becomes a shell instead of
  closing. A halt's banner stays on screen, and a restart is running
  `scripts/conductor-loop.sh` in that window.

### Why not a separate `drivers/` axis

Two modes (interactive launch, headless dispatch) are one optional function on
the existing adapter, not a new dimension of configuration. A `drivers/`
directory would add a third concept to explain and a third file to wire up for
something an existence check already expresses. Revisit it if a mode appears
that changes the *loop* rather than the invocation, for example a push-based
event source (webhooks or inotify) replacing the poll, or a conductor running on
another machine.

## Options

**A. Shared loop plus a model per event** (the issue's proposal). Add
`conductor-loop.sh` and `adapter_dispatch`. Every event still goes to a model.
Idle cost drops to zero; per-event cost is unchanged.

**B. Print mode only.** `claude -p` and `codex exec` as the only dispatch.
Simplest, but gives up Pi's per-event control, and Pi is where a fresh context
and small fixed prompt are cheapest.

**C. Handlers as code, model only for judgment.** Implement the mechanical
handlers as scripts that compute guards and call `route`. Call a model only for
`assess` (and optionally summaries). Largest saving and the strongest
determinism, but it moves orchestration logic out of markdown skills into code,
which must stay in step with the topology. It is also the most work.

## Recommendation

A then C, incrementally; B's one-shot harnesses are just the first
implementations of `adapter_dispatch`.

1. **Phase 0, independent and small.**
   - A duplicate-spawn guard in `worker-spawn.sh`.
   - One shared "spawn or notify for a destination stage" helper replacing the
     block repeated across handlers.
2. **Phase 1, the seam.**
   - `scripts/conductor-loop.sh`: cursor, drain, poll, handler resolution,
     deadline, retry and halt.
   - Optional `adapter_dispatch(skill_content, artifact)` on `claude-code`,
     `codex` and `pi`.
   - The `swarm-start.sh` capability branch with the fallback.
   - Tests in the style of `test-drain.sh`.
3. **Phase 2, convert.** Replace mechanical handlers one at a time with scripts,
   each independently shippable and testable. Start with `on-review-approved` and
   `on-validation-passed`, the simplest.
4. **Spike first.** Done (#73): one real handler ran end to end under each of the
   three harnesses. See [Spike results](#spike-results) for the findings and what
   they leave open.

## The loop and the `adapter_dispatch` contract

`scripts/conductor-loop.sh` is the headless conductor. It drains
`artifact-ledger.sh unprocessed` one event at a time, resolves the handler with
`topology-load.sh conductor-skill`, calls the conductor adapter's `adapter_dispatch`,
and records the event as processed only after the handler succeeds.

**Contract**, called as `adapter_dispatch <skill_content> <event>`, where `<event>` is an artifact path or the word `startup` (the reconcile, which has no artifact or task):

| | |
| --- | --- |
| Environment | `CONDUCTOR_DIR` (absolute), `PATH` with the scripts (from `conductor_env`), `TASK_ID`, `TASK_FILE`, `ARTIFACT` (these three only for an artifact event; unset for the startup reconcile), `DISPATCH_DEADLINE` (seconds), `DISPATCH_USAGE_FILE` |
| Exit 0 | the handler finished |
| Exit 2 | the event cannot be handled; the loop does not retry |
| Any other exit | the handler failed; the loop retries |
| Answer | the adapter may write the model's last non-empty line to `$DISPATCH_ANSWER_FILE`; `dispatch_finish` does it for all three adapters, so the loop can show what the model said it did |
| Usage | the adapter may write one JSON line to `$DISPATCH_USAGE_FILE`: `harness`, `model`, `input_tokens` (input that was neither read from nor written to a cache), `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cache_write_1h_tokens` (the part of the write billed at the 1-hour rate, as Claude Code does; 0 when there is none), `cost_usd` (null when the harness reports none, as Codex does) and `turns`. Write it even when the run fails, because the spend happened, unless the harness reported none (a killed Codex run) |

`turns` is each harness's own count, so compare it within one harness and not across them:
Claude Code reports `num_turns` (model round trips), Pi the number of assistant messages,
and Codex the number of completed model and tool steps in the event stream. The token fields
mean the same everywhere; `input_tokens` excludes anything read from or written to a cache.

`scripts/dispatch-prompt.sh` builds the prompt for all three adapters: the static
briefing first so caching can hit it, then the rules for a dispatched run, the skill,
and the event last. `dispatch_final_exit` turns a final line starting with
`HANDLER-FAILED:` into a failed dispatch.

**Script handlers (Phase 2).** A handler can be a script instead of a skill. For the skill
`conductor/on-x` the loop looks for `scripts/handlers/on-x.sh` (or
`$CONDUCTOR_HANDLERS_DIR/on-x.sh`); if it exists and is executable it runs, and if not the skill
goes to the model as before. The script gets the same environment as a dispatch (`CONDUCTOR_DIR`,
`PATH` with the scripts, `TASK_ID`, `TASK_FILE`, `ARTIFACT`, `CONDUCTOR_LOOP`) and the same
rules: exit 0 finished, exit 2 cannot be handled (halt, no retry), any other exit failed (retried,
then halt), all under the same deadline, with its last stderr line in the halt notice. It costs no
model call, so it writes no line to `usage.jsonl`, and the window shows `(script)`. The startup
reconcile is still always the model's.

A script handler is checked against the skill it replaces before it ships. `scripts/handler-replay.sh`
runs it against a recorded situation (a fixture in `tests/handler-replay/`) with the workers and
the lock check stubbed, and compares the moves, the spawns and the final stage with what the skill
did; `--record` produces that expectation from a live run of the skill, which you run by hand. See
`tests/handler-replay/README.md`.

`on-review-approved`, `on-validation-passed`, `on-validation-failed`, `on-review-rejected`, `on-new-task`, `on-signal-complete` and `on-merge-success` are converted (`scripts/handlers/`). CI
replays every fixture in `tests/handler-replay/` against its script. The skill file stays: it
documents what the script must do, the loop dispatches it when the script is absent, and
`--record` runs it.

Handlers share their steps through `scripts/handler-steps.sh`, which a script sources:

| Function | What it does |
| --- | --- |
| `close_worker_window <task>` | closes the finishing worker's `<role>-<task>` window and records what the worker spent (`worker-close.sh`); a missing window is not an error |
| `locks_guard <task>` | prints `free` or `held` for the task's `files-changed` against `task-locks.sh`. **Fails closed**: with no card, or a failing `task-locks.sh`, it prints nothing, says why on stderr and returns 1, so the handler stops. A card with no `files-changed` has nothing to clash with and is `free` |
| `route_task <task> <event> [guard=value...]` | asks the topology for the destination, moves the task and starts the stage; sets `ROUTED_DEST`. No route is a failure and moves nothing; a failed move does not start the stage |

**What the loop does when something goes wrong**

| Case | Behavior |
| --- | --- |
| The startup reconcile fails or its skill file is missing | Same as any event: retry, then halt, with `startup` as the artifact. No event is handled until it succeeds. |
| Handler exits non-zero or hangs past the deadline | Retry up to `CONDUCTOR_MAX_ATTEMPTS` (3), `CONDUCTOR_RETRY_DELAY` (5 s) apart, then halt. The event stays unprocessed. |
| Adapter exits 2, the handler cannot be resolved, the skill file is missing, or the artifact has no type | Halt at once. Retrying cannot help. |
| The artifact has no handler (`assigned`, `progress`, `moved`, ...) | Record it as processed without a dispatch, so it is never listed again. |
| Crash or kill between "handler done" and `mark` | The event runs again on restart. Moves and spawns are safe to replay (the spawn guard). A replayed `progress` note is duplicated, which is noise, not damage. |
| Loop killed during a dispatch | The dispatch is stopped, the event is not recorded, the lock is released. |
| A second loop on the same conductor dir | Refused (exit 4). A lock left by a dead process is taken over. |
| First start, no ledger yet | The ledger is seeded with the artifacts that exist, so history is not replayed. It is written whole or not at all. |
| A new task | A `card` artifact resolves to `conductor/on-new-task` through `conductor-skill`, the same rule the interactive conductor uses, so a task created mid-run is started by either. The handler's `TASK_ID` and `TASK_FILE` come from the artifact's task id. |
| Project complete | `conductor-shutdown.sh` closes the architect window and the kanban server and, under the loop, only writes a flag. The loop exits after recording the event; closing its own window from inside the handler would kill it before the `mark`. |

A halt writes `$CONDUCTOR_DIR/conductor-loop.halted`, tells the human and the architect, and
exits 1. The live log is #87.

**The halt notice** (`scripts/loop-halt-notify.sh`). A halt stops the loop for every task, so
the notice is not tied to a task or a stage and does not reuse `task-notify.sh`, which needs
a task file and a manual stage with decisions to wait for. It uses the same places a person
already looks:

- a banner on the loop's stdout, which is the conductor window;
- `human-inbox/loop-halt-<timestamp>.md`;
- `architect-inbox/loop-halt-<timestamp>.md` with `type: halt`, which the architect's inbox
  watch dispatches to `skills/architect/on-halt.md` (tell the human, do not try to fix the
  loop). The watcher reports new file names, not overwrites, hence the timestamp;
- a desktop notification on macOS when `config.md` has `notify-channel: push`
  (`CONDUCTOR_NOTIFY_CHANNEL=push` at `swarm-start.sh`).

Each names the kind of halt, the artifact, the handler, why, and the last error the adapter
printed. The notice is best effort: a step that fails (an unwritable inbox) never changes the
halt or its exit status. The next start of the loop removes the notices with the halt file, so
a fixed problem leaves no old alarm. A requested shutdown (project complete) is not a halt and
leaves none.

**Restarting.** The ledger, the board and the usage log are files, so running the loop again resumes
the swarm: the startup reconcile picks up work that is unblocked, and the event that halted the loop is
retried first. Each notice, the banner and the halt file print the command that does it, ready to paste:
`cd <project> && env CONDUCTOR_DIR=<dir> <the settings the loop was started with> <scripts>/conductor-loop.sh`
(built by `scripts/restart-command.sh`, the same code that builds the window `swarm-start.sh` opens). The
conductor window prints it too when the loop exits.

**A script handler that fails without a message.** The log and the halt report the last line the script
wrote to stderr. When a script exits non-zero and wrote nothing, they say "the handler exited N and wrote
nothing to stderr" instead of leaving a bare status. A handler that sources `scripts/handler-steps.sh`
(all of them do) also prints the command that failed, through an ERR trap, so the last error is usually
the step: `on-signal-complete.sh: "stage-start.sh 0002 validation" exited 1`. A failure the handler
handles itself (`|| true`, an `if`) prints nothing.

**Known limits**

- A model can ignore a failing guard script and carry on (the spike saw this). The
  `HANDLER-FAILED:` rule in the prompt is a mitigation that depends on the model
  following it. A script handler's guards fail closed (`locks_guard`); a skill's still depend
  on the model.
- The briefing the dispatch uses is the whole of `conductor.prompt`, including its
  interactive Startup section, which the dispatch rules tell the model to ignore.
  Splitting the prompt would remove that.
- The banner is lost if the conductor window closes when the loop exits, which tmux does by
  default for a window whose command ends. The inbox files survive. `swarm-start.sh -hc` keeps
  the window open by running the loop as `loop; exec $SHELL`.
- `unprocessed` scans the whole work tree for every event.
- The loop needs GNU `timeout` (`gtimeout` on macOS, from `brew install coreutils`). It exits 3 with a message if neither exists; `preflight-check.sh --conductor-loop` checks for it.

## Claude Code dispatch

`adapter_dispatch` in `adapters/claude-code.sh` runs `claude -p --output-format json
--no-session-persistence` with the conductor's model and effort from the workforce, a
budget cap (`CONDUCTOR_MAX_BUDGET_USD`, default 1), and the loop's outer `timeout` as its
only deadline: `claude -p` has no turn limit or timer. It needs `jq` (it exits 2 with a
message if `jq` is missing, and `preflight-check.sh --conductor-loop` checks for it), and
keeps the last result in `$CONDUCTOR_DIR/dispatch-result.json` and `.err`, overwritten
by each dispatch. It reads the result object like this, because the obvious fields are
not reliable:

- `subtype` alone is wrong. A rejected model reports `subtype: "success"` with
  `is_error: true`. The adapter checks `is_error` and `terminal_reason: "completed"`.
- On an error result the `usage` block is all zeros. The real figures are in
  `modelUsage`, so the usage record is built from that.
- Exit 2 (not retried): the request was rejected (HTTP 400, 401, 403 or 404), the budget
  was reached, or `claude` is not installed. Exit 1 (retried): everything else, including
  an overloaded API, a run that did not complete, a denied tool, and a final
  `HANDLER-FAILED:` line.
- A budget stop is not a hard ceiling: with a $0.001 cap one run still cost $0.175,
  because the first call is charged before the cap is checked.

**Fixed context.** The same handler (`on-review-approved`, `locks=free`, model
`claude-opus-4-8`), one run each:

| Flags added to `-p` | Time | Turns | Cost | Cache write | Cache read |
| --- | --- | --- | --- | --- | --- |
| none | 25 s | 8 | $0.289 | 17.9k | 153k |
| `--tools Bash,Read --strict-mcp-config --setting-sources project` | 14 s | 6 | $0.143 | 10.1k | 37k |
| the same plus a one-line `--system-prompt` | 12 s | 4 | $0.102 | 7.4k | 20k |

The adapter uses the last row. These are single runs and the turn counts vary, so read
them as a direction, not a benchmark. `--bare` was not tried: it reads credentials only
from `ANTHROPIC_API_KEY` or `apiKeyHelper`, never OAuth or the keychain, so it would fail
for anyone logged in the usual way. The baseline run also called `stage-start.sh` twice,
as Pi did in the spike; the spawn guard absorbs it.

## Pi dispatch

`adapter_dispatch` in `adapters/pi.sh` runs one event through `pi --mode rpc --no-session
--no-context-files --tools bash,read`, with the model and thinking level from the
workforce. The conversation is in `scripts/pi-rpc-run.py` (python3, standard library
only); the adapter builds the prompt, reads the client's result file with `jq`, and picks
the exit code, as the Claude Code adapter does.

**One `pi` process per event.** The design note first proposed a warm session with
`new_session` between events. The loop runs every dispatch in a fresh `bash -c` child, so
a warm process would need an owner that outlives the dispatch, for a saving of about 0.2 s.
A fresh process already gives per-event stats, so `new_session` is not used.

**What the protocol does** (measured on real runs):

- A failed model call is not a protocol error. The prompt is accepted (`success: true`),
  the run settles with `aborted: false`, and the failure is in the last assistant
  message: `stopReason: "error"` and an `errorMessage` that begins with the HTTP status.
  The client reads it from `agent_end.messages`, and the adapter maps 400, 401, 403 and 404
  to exit 2 (not retried) and anything else to exit 1.
- Pi retries transient errors itself (`auto_retry_start`, `auto_retry_end`). `agent_settled`
  arrives only after that, so the loop's own retry sits on top of Pi's.
- `abort` works at once: a `sleep 40` tool call stopped in about a second with
  `agent_settled` and `aborted: true`. The `abort` response comes after the settle, and
  `get_session_stats` still answers afterwards.
- `new_session` zeroes the stats and changes the session id. A trivial prompt carries
  about 2.3k input tokens, a third of the trimmed Claude Code prompt.
- Tools run with no permission prompts, so the adapter allows only `bash` and `read`.
- There is no per-run budget flag. The deadline is the only bound on a Pi run.

**Deadline.** The client sends `abort` when `DISPATCH_DEADLINE` passes and waits
`PI_ABORT_GRACE` seconds (5) for the run to settle, then stops `pi`. That finishes inside
the loop's grace period, so the loop's outer `timeout` is only a backstop. A run that
hits the deadline exits 1, and its usage is still recorded.

**Usage record** from `get_session_stats` (tokens, cost, assistant messages as `turns`) and
`get_state` (the model id), in the same shape as the other adapters.

**Real runs through the loop** (`on-review-approved`, `locks=free`, `claude-opus-4-8`): the
card moved to `merging` with one spawn, in 24 s over 6 turns, $0.080, 6.2k cache-write
tokens. With a 3 s deadline on the same event the client aborted after 3 s, `pi` was gone
afterwards, the card was untouched, and the $0.033 spent was recorded. Model names have to
be written `provider/id`, or Pi asks which provider and nothing can answer.

## Codex dispatch

`adapter_dispatch` in `adapters/codex.sh` runs `codex exec --json --ephemeral
--skip-git-repo-check` with the conductor's model and effort from the workforce, reads
the JSON event stream with `jq`, and relies on the loop's `timeout` for the deadline.

**What the stream looks like** (measured):

- A finished run: `thread.started`, `turn.started`, one `item.completed` per message or
  tool call, then `turn.completed` with `usage`. A command that exits non-zero is just a
  `command_execution` item with `exit_code: 1`; the run still completes.
- A failed run exits 1 with an `error` event and `turn.failed`. There is no HTTP status,
  only text, so the adapter treats "not supported", "not found", "unauthorized", "not logged
  in", "invalid api key", "authentication" and "forbidden" as exit 2 (not retried) and
  everything else as exit 1. That is a heuristic on message text.
- An `item.completed` of type `error` is a warning (Codex emits one for an unknown model
  name even on a failed run), not a failure.
- A run killed by the loop's timeout has no `turn.completed`, so **its spend is not
  reported** and no usage record is written. No child process survived the kill.
- `codex exec` **waits for stdin to end when stdin is a pipe**, even with the prompt given
  as an argument. The adapter closes stdin (`< /dev/null`); without it a run hangs until the
  timeout.

**Usage.** `turn.completed` carries tokens only. Codex's `input_tokens` includes the cached
part, so the record subtracts `cached_input_tokens` to match the other adapters, and sums
over turns. There is no cost field, and `cost_usd` stays null: with a ChatGPT login there is
no per-token bill to compute, and a price table for API use would go stale. `turns` counts
the completed model and tool steps. The model is the one requested in the workforce, because
the events do not name it.

**Sandbox.** The issue asked for `workspace-write`. It cannot run a swarm: the sandbox
blocks the tmux socket (`error connecting to /tmp/tmux-1000/... (Operation not permitted)`),
and `--add-dir` for the socket directory does not change that. Handlers close and open
worker windows through tmux, and the spawn guard's `tmux list-windows` would fail quietly
and stop protecting against duplicates. So the default is **`danger-full-access`**, set with
`CONDUCTOR_CODEX_SANDBOX` (`read-only`, `workspace-write` or `danger-full-access`). That puts
Codex on par with the other two adapters, which also run shell commands unsandboxed: Claude
Code is given `Bash`, Pi runs its tools with no permission prompts. It is still the widest
grant of the three. A conductor whose handlers never touch tmux can set `workspace-write`.

**Real run through the loop** (`on-review-approved`, `locks=free`, the account's default
model, the default sandbox): the card moved to `merging` with one spawn, in 16 s over 6 steps
(5.8k fresh input, 80k cached, 344 output tokens, no cost), and no process was left behind.
Two earlier runs under `workspace-write`, where the handler's tmux calls fail quietly, were
used to check the event parsing and the usage record.

**Stricter than the others.** On a card with no `files-changed`, the live run stopped with
`HANDLER-FAILED: ... the required locks guard could not be determined` where Claude Code and
Pi had carried on with `locks=free`. The adapter did its job: the event halted the loop
instead of guessing. Cards that went through a coder have a `files-changed` list.

**Fixed context** is about 15k input tokens for a trivial prompt, most of it Codex's own.
`--ignore-user-config` saved 549 tokens on one config and would drop the user's provider
settings; `--ignore-rules` exited 2. Neither is used.

## Shared dispatch code

Three adapters read three different results, so how each one finds an error stays in the
adapter. What they share is in `scripts/dispatch-result.sh`: `dispatch_write_usage` writes the
usage record, so the field names live in one place, and `dispatch_finish` applies the
`HANDLER-FAILED:` check on the model's last line. The prompt and the final-line parser are in
`dispatch-prompt.sh`. Not extracted: the tool checks and the model-flag handling at the top of
each adapter, which differ in what they require and are short.

## Live log

The conductor window of a headless swarm used to show the loop's own messages, with no time on
them and nothing about how an attempt ended. The loop now prints every line with a timestamp, in
the window and in `$CONDUCTOR_DIR/conductor.log`, the same text in both:

- the start (`started`, `ledger created`, `nothing to reconcile`) and the stop;
- each event and the handler chosen: `0001/review-….md -> conductor/on-review-approved (attempt 1 of 3)`;
- **how each attempt ended**: `… finished in 13s, $0.107 — Moved 0001 to merging.` The duration,
  the cost (`no cost reported` for a harness that has none, `no usage record` when there is no
  record, never a silent zero) and the model's own last line. A failure says
  `… failed with exit 1 after 9s, no usage record: <what the adapter printed>`;
- events with no handler, which were marked processed without a word before:
  `0001/progress-….md: no handler for progress, skipped`;
- a halt, with the last error, and the halt notice's banner;
- `idle: nothing to do (N events handled since start)` every `CONDUCTOR_HEARTBEAT` seconds (default
  600, 0 turns it off) while there is nothing to do, so that a quiet loop can be told from a hung
  one. A dispatch that is running shows its `->` line and no `finished` line yet.

**What the model said.** The loop sets `DISPATCH_ANSWER_FILE`; `dispatch_finish`, which all three
adapters call with the model's final answer, writes its last non-empty line there (before it checks
for `HANDLER-FAILED:`, so that line is kept too). No adapter changed. A run that fails before it
has an answer shows the adapter's error instead.

**One window.** `swarm-start.sh -hc` keeps the loop in the foreground of the conductor window, as
before, so the halt banner and a restart stay in the window you are looking at. When the window is
new (after a halt and a restart) it first prints the last 20 lines of `conductor.log` between
`--- earlier in conductor.log:` and `--- now:`, so you see where the last run left off. Any other
window can follow the file with `tail -F .conductor/conductor.log`. The issue described the window
as tailing the log; that would have meant running the loop out of sight in a second window.

**Control characters are removed** from every line before it is printed or written, from the adapter's
error output shown in the window, and from the halt notice. The model's last line and an adapter's
error can contain text from a task or a file that nobody trusts, and a terminal obeys escape
sequences: left in, they could clear the screen, retitle the window or draw over a halt.

`usage.jsonl` is the machine-readable sibling, one object per attempt; `conductor.log` is the one
to read. A line that cannot be written to the log never changes what the loop does.

## Usage log

Each `adapter_dispatch` leaves a usage record in `$DISPATCH_USAGE_FILE`, but the loop deletes it
before the next attempt, so only the last one survives. The loop now appends every dispatch
attempt to `$CONDUCTOR_DIR/usage.jsonl` before that happens: one JSON object per line, so
`jq` reads it directly and an append is atomic.

The log holds the conductor's own dispatches and the workers' sessions (see "Worker usage" below).

| Field | Meaning |
| --- | --- |
| `ts` | UTC time the attempt ended |
| `event`, `task` | the artifact path (or `startup` for the reconcile) and its task id (null for the reconcile) |
| `handler` | the skill that ran, for example `conductor/on-review-approved`. Null on a worker's line |
| `role` | who spent it: `conductor` for a line the loop writes, the worker's own role (`coder`, `reviewer`, ...) for a worker's. A line from before this field existed has none |
| `attempt`, `outcome`, `rc`, `duration_s` | which attempt of the event; `finished`, `failed`, `timeout`, `unusable` or `interrupted`; the exit status; how long it took. A worker's line has no attempt or exit status (both null), and its outcome is `finished` or `interrupted`; its duration runs from the spawn to the close |
| `harness`, `model` | from the record; `harness` falls back to the adapter's name when there is none |
| `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cache_write_1h_tokens`, `cost_usd`, `turns` | from the record, as defined under the adapter contract |
| `estimated_cost_usd` | the cost computed from the price table (`scripts/usage-prices.json`) and the four token counts, or null when it cannot be: the model is not in the table, is null, is a `+` joined list of models, or the attempt has no record. Never a guess, never zero. Kept next to `cost_usd`, so the two can be compared |
| `cost_source` | how the line's cost is known: `reported` (the harness gave `cost_usd`; the estimate, if any, sits beside it), `estimated` (no reported cost, but `estimated_cost_usd` is set, as for Codex on a priced model) or `unknown` (neither: an unpriced model, or an attempt with no record). A line from before this field existed has none, and a reader treats a null `cost_usd` as unknown |
| `usage` | `reported` if the adapter left a record, `none` if not |
| `pool`, `billing` | what the line was billed to. `pool` is `<billing>:<vendor>` (`api:anthropic`, `subscription:anthropic`, `api:openai`, `subscription:openai`) or `unknown`; `billing` is `api`, `subscription` or `unknown`. The harness's sign-in settles it (`scripts/billing-mode.sh`); with none found, the pool the workforce declared for the member stands; with neither it is `unknown`. On a `subscription` line `cost_usd` and `estimated_cost_usd` are notional, what the plan was used for rather than what was billed, and a reader must not add them to `api` dollars. A line from before these fields existed has neither, and a reader treats it as `unknown` |

- **One line per attempt, not per event.** A retried event costs money each time, and so does an
  attempt that fails.
- **Unknown is not free.** An attempt with no record (a Codex run killed by the timeout, a
  harness that returned nothing parseable) is logged with `usage: none`, `cost_source: unknown`
  and null tokens, cost and estimate. Codex's records always have a null `cost_usd`; on a priced
  model its `cost_source` is `estimated`, on any other it is `unknown` while the tokens are real.
  Both mean "not known", never zero.
- **Fields that can be null:** `task` (the reconcile), `model`, the four token counts and
  `cost_usd` and `turns` (an attempt with no record), `cost_usd` alone for a harness that has no
  cost, and `estimated_cost_usd` whenever the price table cannot price the line. A line from before
  `estimated_cost_usd` existed has none; read it as null. `role`, `cost_source`, `usage` and the fields of the attempt itself are always there.
- **A sign-in beats a declaration, and says so.** If the workforce declares `api:anthropic` and Claude
  Code is signed in with a login, the line is `subscription:anthropic`, and a record of its own,
  `{"record": "pool_mismatch", "declared": ..., "detected": ..., "rejected": false}`, goes in the log just
  before it. A declaration that is not a pool (or not that harness's vendor's) is set aside the same way,
  with `rejected: true`, so a typo in a workforce is not invisible. A declaration that fills a gap (nothing
  could be detected) is not a mismatch. The usage line itself carries `pool` and `billing`, not the
  declaration.
- **A Pi line also says where its messages went.** Pi names the provider on every assistant message and a
  session can mix them, so a Pi line has `message_pools`: the messages per pool, e.g.
  `{"subscription:openai": 3, "api:anthropic": 2}`, each provider's pool from `billing-mode.sh pi-pool`
  against Pi's `auth.json` as it is when the window closes. A message with no provider, or a pairing nobody
  has seen, counts under `unknown`, so the counts add up to `turns`. Other harnesses have `null`. The
  line's own `pool` and `pool_check` are untouched: they are what the spawn settled. When messages were billed to a
  known pool other than the line's, one `pool_mismatch` record per such pool goes in the log before the line, with
  `declared` the line's pool, `detected` the messages' pool, `source: "messages"` and `messages` their number.
  A line whose own pool is `unknown`, and messages whose pool is `unknown`, contradict nothing.
  **A mixed session is still read as one pool by the summary, the budgets and `allowance.sh vendor`:** all
  three read the line's `pool`, and `message_pools` and the mismatch records are how a mix shows. Splitting a
  line's cost over its pools would need a per-pool cost the log does not have (Pi's cost is one sum), so
  that is left until a mixed run is common enough to matter. The summary lists these records apart from
  the sign-in ones ("messages said", counted in messages). A mismatch of this kind can also come from `auth.json`
  changing between the spawn, which settled the line's pool, and the close, which counted the messages. `auth.json` is the best guess, not proof: a runtime
  `--api-key` outranks it and leaves no trace.
- **A worker's pool is settled when it is spawned.** `worker-usage.sh spawned` asks
  `billing-mode.sh pool --json` once, against the sign-in as it is then, and keeps the decision in the
  worker's record (`pool_check`). The line written when the window closes says what the worker was billed
  to, not what the closing process can see. The conductor's own lines are decided when they are written.
- **A login is not always what pays.** `billing-mode.sh` reports `unknown` for Claude Code when
  `CLAUDE_CODE_USE_BEDROCK`, `_VERTEX` or `_FOUNDRY` is set, or an `ANTHROPIC_AUTH_TOKEN` is, because the run
  is then billed to a provider or gateway and a login on disk is not what pays for it.
- **A stopped loop leaves a line.** If the loop is stopped with `TERM` or `INT` mid-dispatch, the
  cleanup writes an `interrupted` line for the attempt in flight, so its spend is not invisible.
  Whatever the harness had already spent is not known. A loop killed with `KILL`, or a machine
  that loses power, leaves no line, because nothing runs afterwards.
- **The log is a convenience.** A line that cannot be written never changes what the loop does.
  The loop needs `jq` for it and exits 3 with a message if it is missing.

### Task record

When a task reaches `done`, `on-merge-success.sh` runs `scripts/task-record.sh`, which appends one line of its
own to the usage log: `{"record": "task", ...}`. It is a record and not an attempt, so the summary's attempt
totals do not count it twice. It is what lets a step's cost be read against the size of the task it was spent on.

| Field | Meaning |
| --- | --- |
| `task`, `title`, `type`, `merged_at` | which task, from its file and its merge artifact |
| `weight` | the planned weight, from `weight:` in the task file; null until the strategist (#188) writes one. Every comparison by cost has to carry it: a cheaper model given easier tasks looks good |
| `steps`, `steps_by_role` | the worker steps that ran for the task (the conductor's own dispatches are in the cost, not in the steps) |
| `rework` | `review_rejected`, `validation_failed` and their sum, `rounds`: how often the task was sent back |
| `cost` | one row per pool, never added across them: `pool`, `billing`, `steps`, `reported_usd`, `estimated_usd` (only for a line with no reported cost) and `unknown` (lines with neither: not free). On a `subscription` pool the dollars are notional and the allowance points are the real cost; they are on the step lines and are not summed here |
| `git` | `commits`, `lines_added`, `lines_removed`, `files`, and the two shas it was read from; or `{"unknown": <why>}` when it could not be: never zero |
| `files` | the files the task touched |

**Why two shas.** The merger rebases the branch onto the base and then fast-forwards the base onto it, so once
the merge has landed `base...branch` is empty. The merger therefore notes, on its `merge` artifact, `base-sha`
(the tip of the base it rebased onto, taken again on every retry) and `head-sha` (the branch tip after the
rebase). `base-sha..head-sha` is exactly the task's commits, and they stay reachable after the branch is deleted.
A merge artifact without them (a merger from before this) gives `git: {"unknown": ...}`.

Lines changed measure size and not difficulty, so read them next to `files` and `rework`. A few rows say little:
treat them as a hint until there are dozens of runs, and key anything you keep by the exact model ID, since a new
version makes old rows stale.

**Across runs.** `scripts/usage-combine.sh` copies a finished run's usage log into one combined file
(`~/.conductor/usage-combined.jsonl`, or `USAGE_COMBINED`, or `--into`), adding a `run` field to every line and
changing nothing else. A run already in the file is not added twice. `usage-summary.sh --file <combined>` reads it
as it reads one run's. Every run numbers its tasks from 0001, so `--by task` labels a task `<run>/<id>` when more
than one run is in range (#213); with one run it prints the plain id. `--by weight` groups the attempts by the planned weight of their task, next to the existing
`--by role` and `--by model`; `--by tasks` lists the task records by weight: tasks, steps, rework rounds, lines
changed, files, and how many had no size.

### Price table

`scripts/usage-prices.json` holds dollars per million tokens for each model: `input`, `cache_read`,
`cache_write` and `output`, with the date (`as_of`) and `source` of every price. The estimate is
computed on one basis, stated in the file's `basis`: the four counts of a usage record do not
overlap, so a harness that reports input including the cached part subtracts it first (Codex does,
in its adapter). `cache_write` is the 5-minute write price; `gpt-5` has no charge for cache writes, so its
`cache_write` equals `input`. A Claude model also has `cache_write_1h`: Claude Code bills its
writes at the 1-hour rate, the record carries the part of the write billed there as
`cache_write_1h_tokens` (a subset of `cache_write_tokens`; a record without the field counts as 0),
and that part is priced at `cache_write_1h` instead. A record claiming more 1-hour tokens than
it wrote is not priced. `gpt-6.1-sol` is the short-context standard rate (up to 272K input tokens)
and its `cache_write` is OpenAI's 30-minute write price; the long-context rate is not modelled,
so a run above 272K input tokens is under-estimated. Prices change: add a model or update a price
together with its date and source, and `scripts/test-usage-price.sh` checks that every entry has
both and that the default workforce's models are priced.

- `scripts/usage-price.sh estimate` prices one record on stdin; the loop calls it for every line.
  A missing or unreadable table gives no estimate and never stops a line from being written.
- `scripts/usage-price.sh unknown [--file F]` lists the models in a log that the table does not
  price, and how many attempts used each.
- `scripts/usage-price.sh compare [--file F]` lists the attempts with both a reported and an
  estimated cost and the difference. The estimate ignores things a harness may charge for that
  the record does not carry (a long-prompt tier, a fast or batch tier), so a gap is expected;
  a large one means a price is out of date.

`scripts/usage-summary.sh [--file F] [--since TIMESTAMP] [--by GROUPING]...` totals it: the period,
tokens, the spend on attempts that did not finish, and the same split by harness, handler, task,
role and model. Cost is kept in three kinds and never merged:

- **reported**: the harness gave a cost (`cost_usd`);
- **estimated**: no reported cost, but the price table priced the tokens (`estimated_cost_usd`);
- **unknown**: neither. These are counted, and are not in either total.

The kind is read from those two fields, so lines from before `role`, `cost_source` or
`estimated_cost_usd` existed read as they always did (a role of "(no role)", a cost that is
reported or unknown). The reported and estimated totals are a floor, not the bill, and the summary
says so.

The last section, **Across harnesses**, compares the harnesses on estimated cost: every attempt
that has an estimate counts, whether or not the harness also reported a cost, so Codex and Claude
Code are priced by the same table on the same token basis. It shows the estimate, how many
attempts were priced, how many were not, and the estimate per priced attempt, which is the number
to compare when the harnesses ran different amounts of work. Attempts with no estimate are not
counted as free; the summary says how many there were.

**Real and notional dollars.** Once any line has a `billing`, the headline totals are split into
`api`, `subscription` and `unknown`, each with its reported and estimated dollars, and are never added
across billing: a subscription line's dollars are what the plan was used for, not a bill (marked
"notional" wherever they appear). A line from before pools existed has no billing and reads as
`unknown`, never as `api`. A log with no billing at all prints the headline as before. The **By pool**
section lists each pool apart (`subscription:anthropic (notional)`, `api:anthropic`, ...) with
`unknown` for lines without one, and the `pool_mismatch` records under it: a workforce that declared
one pool while the sign-in said another. The groupings by harness, handler, task, role and model can
span billing within a group, and the summary says so; `--by pool` keeps them apart.

`--by` limits the output to the groupings named (`harness`, `handler`, `task`, `role`, `model`, `pool`,
`adapters` for the cross-harness view, `allowance`, `budget`), and can be repeated. With none, all are printed. Before
#134 the summary counted an attempt as unknown whenever `cost_usd` was null, which put every
Codex attempt there even when the table could price it.

Measured so far, all single runs on `claude-opus-4-8`, so a direction and not a price list: a
handler $0.07 to $0.11, a reconcile $0.09 to $0.19 (it runs on every start with any task on the
board), Pi about $0.08; Codex reports tokens only. One real loop start on a two-card board, a
reconcile and one handler, logged $0.23 in total. The log exists so that these numbers come from
a real swarm instead of from test runs.

### Budgets

A budget is a number a pool is measured against, so that "what did it cost" reads as "how much of what I
allowed". It is **report only**: nothing pauses a run or refuses a dispatch (enforcement stays out of
scope, see #111).

- **Declared in the workforce** (`budgets`, see [workforce-schema.md](workforce-schema.md#budgets)): per
  pool, with an optional cap per role, adapter or model inside it. The unit follows the pool: `usd` for an
  `api:` pool, `percent` for a `subscription:` pool. `period` is `run` (everything in the usage log, the
  default) or `week` (the last seven days).
- **A brief can tighten, never raise.** Its frontmatter lists `budget:` entries as `<pool> <amount>`.
  `swarm-start.sh` merges them with the workforce's (`scripts/budget.sh merge`) into
  `$CONDUCTOR_DIR/budgets.json`, the budgets in effect. A brief entry that is higher than the workforce's,
  or for a pool the workforce has no budget for, is ignored and said on stderr: the workforce is the ceiling.
  A brief that requires an adapter does not exist yet (a brief is free text), so there is nothing that
  names a pool that way.
- **What counts as spent.** On an api pool, the cost of the pool's lines (reported, else estimated): a floor,
  a line with no cost is counted as `unmeasured` and never as free. On a subscription pool, the **rise of the
  weekly window** over the period (#174): the last minus the first live allowance reading (`source:
  "endpoint"`) of one window in the usage log. It covers the whole swarm, needs no attribution and survives
  overlapping workers, which the sum of per-run points did not (in the first real run it said 1% of 8% where
  the window had risen 3 points and almost every run was marked a batch). It is the account's rise, so it also
  counts what a person did by hand in the same window; the summary and the warning say so. It cannot be
  measured with fewer than two live readings, or when the window reset between them (the readings belong to
  different windows): spent is then the floor of the runs' own weekly points, as before, and the row says
  why (`basis: "runs"`, `reason`). A role, adapter or model cap is always on the runs' points (a window has
  no roles). Five-hour points are not budgeted: that window resets many times in a run. A line whose pool is
  `unknown` (no declaration, no sign-in) is in no budget: it is in the totals, and `--by pool` shows it.
- **Where it shows.** `usage-summary.sh` prints **Budgets**: one row per pool and per cap, with spent, budget,
  percent and state. After each dispatch the loop runs `budget.sh warn`, which writes a line to
  `conductor.log` for a budget at its `warn_at` percent (default 80) or over (100), once: it appends
  `{"record": "budget_warning", "pool", "scope", "state", ...}` to the usage log, and does not warn again
  for the same pool, scope and state in the same period. The log is the memory; a `warn` and later an
  `over` are two warnings. Workers write their lines outside the loop, so a worker's spend is counted in
  the next dispatch's check, not at the moment it is written.

Open: a budget in notional dollars on a subscription (the user would calibrate it) is not offered. The
Claude allowance is readable now (#147, #155), so percent is the unit, and a dollar figure for a plan
would be a number nothing checks.

### Worker usage

Coder, validator, reviewer and merger run as interactive sessions in tmux windows, so there is no
result to read when they finish. What each harness leaves on disk, and how that was found, is in
`docs/worker-usage-sources.md`. Workers are metered from that:

- **At spawn**, `worker-spawn.sh` calls `worker-usage.sh spawned`, which writes
  `$CONDUCTOR_DIR/workers/<role>-<task>.json`: the role, the harness, the worktree and the start time.
  Nothing can be read yet; the record is what lets a reader pick the worker's session out of
  everything the harness has written. The `assigned` artifact holds the role, worktree and time
  too, but it cannot say which workers have been read, which `sweep` has to know, so the record
  is kept and removed when the worker is read.
- **At close**, `worker-close.sh <task>` (called by `close_worker_window` and by the skills) closes
  the window first, then runs `worker-usage.sh read`. Claude Code writes its cost only when it
  exits, which the closed window causes, so the read waits a few seconds (`WORKER_CLOSE_WAIT`) for
  it. The read finds the harness's sessions in that worktree written since the spawn, adds them up
  and appends one line to `usage.jsonl` with the worker's `role` and `task`, in the shape above.
  The record is then removed.
- **A worker closed by hand** leaves its record behind. The next `worker-close.sh`, and the project's
  shutdown, read such a worker as `interrupted` (`worker-usage.sh sweep`). A swarm that crashes
  before either leaves the record unread.

- **The planning windows** (architect and strategist, #198) are metered the same way. Their windows
  are named for the role alone, so `swarm-start.sh` records each as `plan-architect` / `plan-strategist`
  with a `window` field (the record is found by its task, so each role has its own id, and `sweep`
  checks the declared window instead of `<role>-<task>`). The project's shutdown closes them and reads
  them as `finished`: a shutdown is how a planning window ends. A usage line has the role `architect`
  or `strategist` and shows in `usage-summary.sh` under "By role" and, as `plan-architect` and
  `plan-strategist`, under "By task". In the second real strategist run these two came to about $1.28
  on top of the $2.49 the workers cost. A swarm that stops without a shutdown leaves them for `sweep`.
  They take no allowance reading: a window that lives for the whole swarm overlaps every worker, so its
  share of the allowance could not be told apart from theirs. If the tmux session is lost and the swarm
  started again, the new record's start time replaces the old one and the earlier session's cost is not
  counted, as for a worker spawned twice.

Each harness gives what it gives: Pi's own cost per message, Claude Code's cost from the line it
writes on exit, Codex tokens only. A session killed with `SIGKILL` has its tokens but no Claude Code
cost, so `cost_usd` is null and `cost_source` is `estimated`. Unknown is never zero: a worker whose
session cannot be found, whose harness has no reader, or that closed before the model replied gets
a line with null tokens, `usage: none` and `cost_source: unknown`, so the gap is in the log. A
worker with no spawn record (one spawned before this existed) gets such a line too, with the role
from its window name.

### Codex allowance

Codex on a ChatGPT Plus account is limited by allowance, not cost: a five-hour window and a weekly
one, each reported as a percentage. Tokens and dollars do not say how much of that a run used.
Codex writes the allowance into its own session logs: every `token_count` event in
`$CODEX_HOME/sessions/**/rollout-*.jsonl` (default `~/.codex/sessions`) has a `payload.rate_limits`
with each window's `used_percent`, `window_minutes` and `resets_at`, and the `plan_type`. No model
call and no screen scraping is involved.

`scripts/codex-usage.sh [--sessions DIR] [--now EPOCH] [--text]` reads it and prints one JSON
object: the snapshot time, the Codex version it came from, the plan, and for each of `five_hour`
and `weekly` a `state` (`known` or `unknown`), `used_percent`, when the window `opened_at` and
`resets_at`, and a `reason` when it is unknown.

- **The newest event wins, and nothing older is read.** It takes the newest session file by
  modification time and the newest event with a `rate_limits` in it, and stops. It never fills a
  window from an older event.
- **Windows are found by length**, 300 and 10080 minutes, not by the names `primary` and
  `secondary`.
- **A window it cannot trust is unknown, never zero and never 100 %.** That is a window missing from
  the reading, with no `used_percent`, with no `resets_at` to tell whether it is stale, outside 0
  to 100, or with a `resets_at` that is not in the future. The last one is the common case: the
  reading is only as fresh as the last Codex event, and once the window has reset the stored
  percentage no longer applies. With no `rate_limits` in any session both windows are unknown and
  the exit status is still 0.
- **The format is Codex's own**, not a documented interface. The `cli_version` of the session is in
  the output, and a shape the reader does not know turns windows unknown, not guessed.

Tested against the real session taken for #132 and against the cases in `tests/codex-usage/`.

**Readings in the usage log.** `scripts/allowance.sh` writes the reader's output to `usage.jsonl` as
a record of its own, `{"record": "allowance", "pool": "subscription:openai", "moment": ..., "ts": ...}`
followed by the reading. A line with no `record` field is an attempt, as before; `usage-summary.sh`
and `usage-price.sh` leave the records out of the attempts. A reading is taken when the swarm starts
(`swarm-start.sh`, if the workforce has a member on the `codex` adapter) and around every Codex run.
`allowance.sh` takes a `--vendor codex|claude`; Claude Code is the second vendor, see
[Claude allowance](#claude-allowance).

**What a run used.** When a Codex run starts (a dispatch by the loop, or a worker spawned by
`worker-spawn.sh`) `allowance.sh begin` takes a reading, and when it ends `allowance.sh end` takes
another and puts the difference in an `allowance` object on the run's usage line (null on lines
of other harnesses): `five_hour` and `weekly` each have `points`, the percentage points the window
rose, or null with a `reason`; `attributed_to` is `run` or `batch`. Points are null, never zero,
when a reading was unknown, when Codex wrote nothing new in between (the reading is only as fresh as
the last Codex event), when the window reset during the run, or when runs overlapped. Resets are
compared with a two-minute tolerance, because Codex moves a window's `resets_at` by a few seconds
between events in the same window.

- **Overlapping runs belong to the batch.** Runs are live while their dispatch process or their tmux
  window is. If two or more are live at once, every live run is marked, and its points are null with
  `attributed_to: "batch"`. The batch's change is in the readings the runs appended. If tmux cannot
  say whether a worker is live, it is taken as live: the doubt leaves a run unattributed, never
  wrongly attributed.
- **A run that never ended** (a crash) is forgotten at the next `begin`, and does not make later
  runs overlap.
- **The log reports whole percents**, so one small run often shows 0 or 1 points. A measured 0 is
  "under one step", not "nothing": three small reviews in a real run moved neither window. The summary
  writes it `+0 (<1)`, and writes `-` where no run of a role could be attributed, so an unattributed run is
  never shown as free. The numbers mean something added up over several runs.
- **The conductor's own dispatches are not measured while they run `--ephemeral`.** `adapters/codex.sh`
  runs `codex exec --ephemeral`, which writes no session file ("Run without persisting session files to
  disk"), so there is no event to read: a dispatch's `allowance` is null with the reason "Codex wrote
  nothing new since the run began", and its `answered_model` is null. Workers are interactive and do write
  sessions, so they are measured. The reading records still show the pool's movement over any period.
  `scripts/codex-allowance-run.sh` runs real Codex without `--ephemeral` to check the readers.
- **A Pi run on a ChatGPT plan is registered, but the window is read from Codex's logs.** Registering it
  (#159) is what marks a Codex run beside it as a batch (`attributed_to: batch`) instead of giving the
  Codex run the whole rise. The reading itself still comes from `codex-usage.sh`, which reads Codex's own
  session logs; Pi's session logs hold tokens, cost and the provider, and no `rate_limits`. So a swarm
  with Codex and Pi measures both, and a swarm with only Pi on the plan has no fresh reading: both windows
  are `unknown` with the reason, and a Pi run's points are null, never zero. A reading that does not
  depend on Codex logs is not built (it needs a source of its own, and may raise the terms question
  that #156 settled for Anthropic).
- **Pi's sign-in is not read.** Pi's session log names the provider (`openai`) and not the sign-in;
  that is in Pi's `auth.json` (`type`: `api_key` or `oauth` per provider; a stored credential beats the
  environment variable), which is not read here. The pool of a Pi member is what the workforce declares.

`usage-summary.sh` shows each subscription pool in its own allowance section ("Codex allowance",
"Claude allowance"), apart from tokens and dollars, because it is a percentage of a window and not a
cost: the latest reading of each window with when it resets and where it stood at the first reading
in the same window, and the points that runs used, by role, with the runs that could not be
attributed counted. With more than one pool a total of runs comes first (attributed, in a batch,
unknown): a count, because points of different pools are not the same budget and are never added.
`--by allowance` shows only that.

**Codex on a subscription or on an API key.** The allowance above only means something if Codex is
signed in with a ChatGPT account. On an API key its work is billed per token instead, outside what
the allowance measures, and the swarm no longer refuses it: its estimated dollars on the usage line
are real spend, and the line's `pool` is `api:openai` (see `pool` and `billing` in the usage log
table). `scripts/billing-mode.sh detect codex` reads the sign-in from `auth.json` (an `auth_mode` of
`chatgpt` is a subscription; one that names an API key, or, with no `auth_mode`, a stored key, is
`api`) and never prints a key. On `api` there is no allowance to measure, so `allowance.sh` takes no
readings (at swarm start, or around a dispatch or a worker) and the line's `allowance` is null. `begin`
makes that decision once and leaves a marker for `end`, so a sign-in that changes mid-run cannot leave a run
half-measured. When
the sign-in cannot be read the readings are taken: doubt is not a reason to skip them, and a reading
is what could settle it. The format of `auth.json` is Codex's own, so a shape it does not recognise
is `unknown`, never a guess.

`scripts/codex-billing.sh check` still refuses an API key, and a newest reading with no `plan_type`,
but only `scripts/codex-allowance-run.sh` asks it: that script runs real Codex to check the
allowance readers, which have nothing to read on an API key.

**The model that answered.** `codex exec --json` does not name the model, so a dispatch's record says
the model it was asked for. The session log does say which answered (`turn_context.model`), for a
worker and for a dispatch alike. Codex lines carry `requested_model` (the workforce's `params.model`,
or null if none was set) and `answered_model` (from the session, or null if it named none). When both
are known and differ, a record of its own is appended: `{"record": "model_mismatch", "role", "task",
"event", "harness", "requested", "answered"}`, for example a fallback to a lighter model near the cap.
The names are compared as they are, so an alias that Codex reports under another id also shows up, with
both names in the record for a person to judge; a run with no model asked for is never a mismatch.
The session is found by directory and time (for a worker its worktree, for a dispatch the project root), so a Codex session a person runs by hand in the same directory during a run can be read as its answer. `usage-summary.sh` lists the pairs, counted, in its Codex section. Any line with a `record` field is a
record about the log and not an attempt, and the summary and `usage-price.sh` leave it out.

### Claude allowance

Claude Code on a Claude subscription is limited the same way: a five-hour window, a week, a week per
model class, and usage credits (dollars drawn once a plan window is used up). The spike behind it,
with the capture and what was and was not tested, is `docs/worker-usage-sources.md`, "The Claude Code
allowance". None of it is a documented interface; it was checked on Claude Code 2.1.318.

`scripts/claude-usage.sh [--now EPOCH] [--text]` reads it and prints one JSON object in the shape of
the Codex reader: `snapshot_at`, `source`, `age_seconds`, `checked_version`, `note`, then `five_hour` and
`weekly` (a `state`, `used_percent`, `opened_at`, `resets_at`, `reason`), `weekly_by_model`
(`{state, reason, models: [{model, used_percent, resets_at, resets_at_source}]}`) and `credits`
(`{state, reason, currency, used, limit}`, dollars).

- **Three sources, the first that answers wins, never mixed.** First `GET /api/oauth/usage` with the
  OAuth token from `~/.claude/.credentials.json`: not a model call, so it costs no tokens and does not
  move the allowance, and it is read live. Failing that, the status line payload (below). Failing that,
  `cachedUsageUtilization` in `~/.claude.json`: the same shape, no token and no network, but a copy from
  whenever Claude Code last fetched, with its age in `age_seconds`. `note` says why the endpoint was not
  used (no login, an expired token, a 401, unreachable, a shape it does not know).
- **A swarm reads in bursts, and the endpoint answers 429 to that** (#173: in the first real swarm 56
  of 87 readings fell back to a 70-hour-old copy). So `claude-usage.sh` keeps what the endpoint last
  said in `~/.claude/usage-endpoint-state.json` (`CLAUDE_USAGE_STATE_FILE`). An answer is reused for a
  minute (`CLAUDE_USAGE_FRESH_SECONDS`) by every caller, still as `source: "endpoint"` with its own
  `snapshot_at` and `age_seconds`; callers take turns on a lock next to the file, so a burst of
  readings costs one request. After a 429 nobody asks until its `Retry-After` has passed (seconds;
  default 120, capped at 900; `CLAUDE_USAGE_BACKOFF_SECONDS`), and the fallbacks stand in with the note
  `the endpoint answered 429; not asking again for N s; using ...`. `usage-summary.sh` says how many
  of a pool's readings were live (`from cache, 70 h old, 1 of 87 readings live`), so a stale run is
  visible. Not known: the endpoint's real limit, and whether it sends `Retry-After` at all (the
  default covers that). A reused answer is up to a minute old, so a run shorter than that shows no
  difference, which the whole-point percentages mostly did anyway.
- **The status line payload** is the second source, `source: "statusline"`. Claude Code hands the
  configured `statusLine` command a JSON object with `rate_limits` (`five_hour` and `seven_day`, each
  `used_percentage` and `resets_at`), but only a command that saves it makes it readable later.
  `scripts/claude-statusline-save.sh [your-own-status-line-command]` is that command: it keeps the last
  non-null `rate_limits` and the time it was taken in `~/.claude/statusline-rate-limits.json`
  (`CLAUDE_STATUSLINE_FILE`, mode 600; nothing else from the payload is copied; a null payload never
  overwrites it), then runs your own command with the same payload on stdin. Set it as
  `"statusLine": {"type": "command", "command": "/path/to/scripts/claude-statusline-save.sh"}`. Reading it
  gives `five_hour` and `weekly` only; per model and credits are unknown from it, with a reason, and a
  window that has reset since it was saved is unknown; with every window reset it knows nothing, and the cached copy is used instead. It needs no token and no network, so it covers a
  machine with no OAuth login. Only an interactive session runs a status line command: `claude -p`
  (a dispatch or a worker) does not, so it saves nothing. `age_seconds` says how old it is. Its percentages are whole points, so
  `allowance.sh` does not take a before/after difference from it (that needs two endpoint readings).
- **Unknown is never zero.** A window that is missing, has no `utilization` or `resets_at`, is outside
  0 to 100, or has reset since the reading (the cached copy's usual case) is unknown with a reason.
  With no usable source every figure is unknown and the exit status is still 0.
- **The token never leaves curl's stdin.** It is not on a command line, in the output or in any log,
  and a token with a quote or a control character is refused. An expired token is not sent, and the
  reader does not refresh it: Claude Code does that when it runs.
- **Credits** are read from `spend.*.amount_minor` (minor units, converted to dollars), because the unit
  of `extra_usage.used_credits` is not documented. Whether credits are drawn only once a window is full
  is untested.
- **A model's reset time is the week's**, because the endpoint gives a model's percentage but no reset of
  its own. `resets_at_source: "weekly"` says it is an assumption, not a reading.

`allowance.sh begin/end --vendor claude` works as for Codex, with the pool `subscription:anthropic`.
`end` puts `five_hour` and `weekly` (points), `weekly_by_model` (`{reason, models: [{model, points,
reason}]}`) and `credits` (`{dollars, reason}`) on the run's usage line. Differences:

- **A difference needs two endpoint readings.** The cached copy can be days old, so a run is never
  measured against it; its difference is null with the reason. An unchanged endpoint is a real
  measured 0, since the endpoint is read live and not only when Claude Code writes something.
- **Overlap is judged within a vendor.** A Codex run and a Claude run draw on different pools and never
  mark each other; two Claude runs at once do.
- **Which runs are measured** is `allowance.sh vendor <adapter> --pool <pool>`: the vendor follows the
  pool the run is billed to. `codex` and `claude-code` each have a pool of their own, so the adapter says
  it. `pi` has none, so the pool does: a Pi run on `subscription:openai` draws on the ChatGPT plan Codex
  draws on, and is measured as the `codex` vendor; Pi on an API pool has no window and is not measured.
  Pi cannot be on `subscription:anthropic`. A Claude Code dispatch or worker is measured by
  `conductor-loop.sh` and `worker-usage.sh` like a Codex one, and `swarm-start.sh` takes a reading at
  start for each vendor the workforce uses (a Pi member on `subscription:openai` counts for the Codex
  one). On an API key (`billing-mode.sh detect claude-code` says `api`) there is no allowance to
  measure and nothing is read.

**What a difference is.** The window belongs to the account, not to the swarm: `seven_day_breakdown`
shows chats and cowork counting against the same week. So a run's points are the account's rise during
that run. Overlap is only detected between the swarm's own runs; a person using Claude by hand while a
run is live moves the window too, and the swarm cannot see it. The numbers mean something added up
over several runs, and a run under one point does not show.

## Plan check

`scripts/plan-check.sh` reads the tasks the architect created (`$CONDUCTOR_DIR/tasks/*.md`) and reports what is
wrong with the plan itself, before the conductor's retries and limits have to cope with it. The architect runs it as
step 4 of `skills/architect/on-brief.md`; a person can run it any time. It is **report only**: it moves no card and
creates no task, and nothing waits for it, so a plan can start running before anyone has read the findings. Holding a
plan until it passes is the strategist's job (#188), not this script's. `--json` prints the findings as an array; the
exit status is 1 when there is an error, 0 otherwise (warnings do not count).

| Code | Severity | Meaning |
| --- | --- | --- |
| `empty-plan` | error | there are no tasks |
| `dangling-dependency` | error | a task depends on an id that is not a task |
| `dependency-cycle` | error | tasks wait on each other (or on a cycle), so none of them can start |
| `feature-no-tests` | error | a `feature` task whose description does not contain the word "test" and that does not depend on a `test` task. It reaches validation with nothing to run (#185, #187). The message names the later test task that waits on it, which is the usual shape of the fault |
| `test-covers-nothing` | warning | a `test` task that depends on nothing and that nothing waits on |
| `task-too-large` | warning | a description longer than `PLAN_CHECK_MAX_DESCRIPTION` characters (default 1500): likely more than one coder session |

"Asks for tests" is the word `test` or `tests` in the description, in any case; `tested` does not count. That is a
heuristic and a cheap one, which is why it is an error the architect can answer by adding the sentence, not a gate.
What it cannot judge is whether the plan covers the brief: that takes a model, and is left to the strategist.

## Strategy

A task can carry a **strategy**: which steps to skip and which model each role uses for it, as data the scripted
conductor executes. The conductor stays deterministic and spends no tokens on it. Whoever writes the strategy
decides (the strategist role, #188, or a person); `scripts/task-strategy.sh` reads it, checks it and answers the
conductor's two questions. A task with no strategy runs exactly as before.

The file is `$CONDUCTOR_DIR/strategy/<task>.json`:

```json
{ "skip":    { "validation": "docs only: no test applies" },
  "workers": { "reviewer": { "model": "claude-sonnet-4-6" } },
  "weight":  3 }
```

| Key | Meaning |
| --- | --- |
| `skip` | stage → the reason. The reason is required: it is written on the card (a `progress` artifact, `conductor: skipped validation — <reason>`) before the step is skipped, and a skip that cannot be recorded is not made: the step runs |
| `workers` | role → tuning merged over the workforce's `params` for that role, for this task only. Only `model` and `effort` can be set: the adapter and the pool stay the workforce's, so what a worker is billed to does not change with a strategy |
| `weight` | the planned weight, a number. `task-record.sh` files the task's cost under it (it falls back to `weight:` in the task file). The strategist gives **every task a worker runs** one (#201), on one scale: 1 trivial, 2 small, 3 a normal coder session, 5 large. `plan-hold.sh release` names a task with no weight in a warning (a design task is not named) and releases anyway |

**The floor.** The topology decides what may be skipped, not the strategy: its `skippable` map lists the working
stages that can be skipped, each with the event that sends the task on as if the stage had passed. In
`software-dev` that is `validation` only, so **review and merging can never be skipped**: `task-strategy.sh skip`
prints nothing for them even if a file says otherwise, and `task-strategy.sh validate` rejects the file. A topology
with no `skippable` key has no skippable step. The event a skip resumes with is routed on the card's type and the
locks guard only, as `validation-passed` is.

**How the conductor uses it.**

- `route_task` (`scripts/handler-steps.sh`): when the destination it resolved is a stage the strategy skips, it
  writes the reason on the card and routes the skip event instead. A chain of skips is cut after four, and the
  step then runs.
- `worker-spawn.sh` merges the task's `workers` entry over the role's params before launching. The merged params
  are what `worker-usage.sh` records, so a usage line shows the model that was asked for.
- A strategy that is not JSON or not an object reads as no strategy: the conductor carries on, and
  `task-strategy.sh validate <task>` is where the fault shows. Commands: `show`, `validate`, `skip`, `params`, `weight`.

Defaults stay where they were: the workforce names a model per role, and a strategy overrides it only for the task
it is written for. Nothing here chooses a model from the usage data (#189); a strategist may, and treats a few rows
as a hint.

## Startup reconcile

`skills/conductor/startup.md` used to be two things: steps 1 to 6 reconciled the board with
what is on disk, and step 7 was the poll loop. The reconcile is now its own skill,
`skills/conductor/reconcile.md`, with no polling in it. `startup.md` loads it and then runs the
poll loop, so the interactive conductor behaves as before. `conductor-loop.sh` dispatches the
same skill as its first event, on every start:

- **What it does:** registers task files that have no card, unblocks backlog cards whose
  dependencies are done, respawns a worker whose window was lost (or re-notifies a human whose
  inbox file is missing), and starts the entry stage for ready cards.
- **Replay:** every step acts only when something is missing, and spawning skips a task that
  already has a live worker, so running it again is safe. The one soft spot is a manual entry
  stage: `stage-start.sh` notifies each time, so a restart notifies that human again.
- **The event is `startup`:** there is no artifact and no task, so the dispatch prompt says
  "Startup reconcile. There is no artifact and no task." and the per-event variables are unset.
- **A fresh swarm skips it:** with no task files and no cards there is nothing to reconcile, and
  no model call is made.
- **It runs before events, after the ledger is ready.** Artifacts left unprocessed by a crash are
  replayed afterwards.

Which loop does the interactive conductor follow? `startup.md` step 2 (the old step 7), which
polls `work/` only and never returns. `conductor.prompt` used to have a second, `## Watch loop`
section, with watchers on `tasks/` and `work/` that started "after startup"; startup does not
finish, so it was never reached as written, and it is removed (#98).

Live runs (#98, scratch swarm, real claude, from the checkout before the fix) showed why it
mattered. The poll saw the new task's `card` artifact and skipped it (`conductor-skill` returned
nothing for it, and the cursor moved past it), so the documented path never started a task
created while the conductor ran. The task was started anyway, but only because the model
improvised a way to see `tasks/`, each time a different one:

| Run | How the task started | Time |
|---|---|---|
| auto mode | a new file in `tasks/`, "the dispatch rules" | 36s |
| accept-edits, task created before the model had set its watchers up | not at all until a human told it | 129s |
| accept-edits | an improvised background wait loop on `tasks/` | 118s |

With `card` mapped to `conductor/on-new-task` in `conductor-skill`, the same poll starts the
task, and the headless loop shares the rule. With the fix, two runs started the task from the
`card` artifact in about 30 seconds each. They are single runs, not measurements.

The reconcile is also the most mechanical part of the conductor: a loop over cards that calls
scripts. A live run cost $0.09 to $0.19 and 8 to 11 model turns, on every start with any task on
the board, and once repeated a step. It is the first candidate for Phase 2 (a script, no model).

## The backlog check

The restart used to hide a handler that forgot to unblock a dependent: the startup reconcile moved
the waiting task on, so a missing step looked like a slow start (#165). After each event the loop
now checks one invariant: no card sits in `backlog` while every task in its `depends-on` is in
`done` (the `deps_done` test `unblock_ready` uses). `scripts/backlog-invariant.sh` finds such cards
and heals each as the reconcile would, by moving it to `ready` and starting the entry stage, so an
unattended swarm keeps going. The loop then logs it, once per task:

    invariant: 0002 was in backlog but its dependencies are done (0001); moved it to ready and started it. A handler left it behind.

The log line is the signal and the healing is never silent. A card whose task still has an
unhandled event is left alone (a new task sits in backlog until its new-task handler has run), and
so is everything once a shutdown is requested. A card whose `depends-on` cannot be read is skipped
with a message on stderr. A failing check is logged and never halts the loop; `CONDUCTOR_BACKLOG_CHECK=off`
turns it off. Unblocking itself stays explicit in the handlers, not in `task-move.sh`.

The check also runs while the loop is idle, every `CONDUCTOR_BACKLOG_INTERVAL` seconds (default 60; 0 =
every pass), so a card left behind by something that is not an event (a plan release that failed, a
person moving a card by hand) is healed without waiting for the next event or a restart (#197).

## Windows that wait for a person

A worker is an interactive window in the background. When it stops to ask something (a permission
or trust question) nothing moves and nothing says why (#168). Every `CONDUCTOR_WATCH_INTERVAL`
seconds (default 60) the loop runs `scripts/window-watch.sh`, which reads the end of each worker
window (`tmux capture-pane`, windows named `<role>-<task>` with a task file) and reports, once per
window and finding:

    window coder-0001 (task 0001) is waiting for you: Do you want to proceed?
    window coder-0002 (task 0002) has produced nothing for 20 minutes; the pane ends: ...

- **waiting**: the pane ends in a numbered menu (`❯ 1. ...`, the question is the line above it) or a
  `(y/n)` question. These are the two shapes read; any other shape is not guessed at.
- **quiet**: no new file in `work/<task>/` for `CONDUCTOR_QUIET_AFTER` minutes (default 20, `0` = off),
  with the last line of the pane in the message, so an unknown prompt still surfaces.

A finding also leaves `human-inbox/window-<window>-<timestamp>.md` (with the `tmux select-window`
command), colours the window red in the tmux status bar until it moves on, and sends a desktop
notification on macOS when `config.md` has `notify-channel: push`. A window that is no longer
flagged is forgotten, so its next stop is reported again. Report only: nothing is answered on the
person's behalf. `CONDUCTOR_WINDOW_WATCH=off` turns it off. Not verified: that these two shapes
cover every Claude Code prompt in every version (only the "numbered menu" shape is assumed, from
the permission and trust dialogs), and whether Claude Code rings the terminal bell when it waits;
the watch does not depend on either.

## A task that keeps failing validation

A failed validation sends the card back to the coder. When the failure is not the coder's to fix, it
went round for ever: in the second real run task 0002 had 11 validation failures and 24 assignments
because its tests were a later task, so validation found none and failed every time (#185). Now the
topology's `validation-failed` rule has a `count` guard first: after `gte` failed validations in a row
(3 by default; edit the project's `topology.json` to change it) the destination is `@escalate`.

`on-validation-failed` counts the failures (`failed_validations` in `handler-steps.sh`: the newest
`validation-*.md` artifacts of the task with `outcome: failed`, up to the first pass) and passes
`count.validation-failed=<n>` to the route. On `@escalate` it moves nothing and starts nothing: the card
stays in `validation` with no worker, and `escalate_validation_loop` leaves a notice in `architect-inbox/`
and `human-inbox/` (`validation-loop-<task>-<timestamp>.md`, `type: validation-loop`) saying how many
times it failed, the last failure, and how to send it back (`task-move.sh <id> in-progress &&
stage-start.sh <id> in-progress`). The loop's log shows `task 0002 parked in validation after 3 failed
validations in a row`. The architect has a skill for the notice (`skills/architect/on-validation-loop.md`)
that tells the human what it sees and creates nothing unasked. Report only: the swarm does not decide
what to do about it, and the other tasks go on. The architect briefing now says that tests belong with or
before the code (`skills/architect/on-brief.md`, #185), so a feature is not planned ahead of its tests. A
restart leaves a parked task parked (#212): the startup reconcile respawns a worker whose window is gone, but
not for a card whose newest validation failed, whose failures in a row the topology routes to `@escalate`,
and which has not been moved since (a send-back with `task-move.sh` or `plan-revision.sh resume` writes a
`moved-*.md` artifact and ends the park).

The validator no longer counts "no tests exist yet" as a failure (#185): when its working directory has no
test file at all it signals **passed** with the note `No tests exist yet in this worktree; nothing was
validated.`, so the card moves on and the reviewer sees that nothing ran. Test files that exist but are not
run (discovery or an import error) are still a failure. The loop limit above stays as the backstop for a
failure that really cannot be fixed.

### The strategist: the plan hold, and a parked task (#188)

A workforce with a `strategist` member and a brief starts with the plan **held** (`plan-hold.sh`, the file
`plan-hold` in the conductor directory). While it exists new tasks and unblocked tasks stay in backlog (a design
task still goes to done). The architect tells the strategist the plan is complete (`strategist-inbox/plan-ready-*.md`);
the strategist checks it against the brief, writes `strategy/<task>.json` where a task should not run the default
way, and runs `plan-hold.sh release`. Release is all-or-nothing: a plan error (`plan-check.sh`) or one invalid
strategy file releases nothing, and a successful release copies `strategy/` to `strategy-released/`, which is what
`task-strategy.sh` reads from then on.

The strategist is also told of a parked task: `escalate_validation_loop` writes `strategist-inbox/exception-<task>-*.md`
(only if that inbox exists) beside the notices for the architect and the person. The strategist decides code or plan
fault (`skills/strategist/on-exception.md`) and calls `plan-revision.sh propose <task> <kind> <note>`, where kind is
`fix-plan`, `split`, `add-task` or `ask-person`. The proposal is kept in `revisions/<task>-<n>.md`, and the architect
(`skills/architect/on-plan-change.md`) approves it by making the change and sending the task back with
`plan-revision.sh resume <task>`. Rounds are capped, and the count is the number of files in `revisions/`:
`max-replans` per task and `max-plan-rejections` for the plan itself (`config.md`, 2 each). Past the cap the call
changes nothing, tells the person (`human-inbox/plan-cap-*.md`) and exits 1. `ask-person` costs no round.

## Spike results

The spike (#73) ran one real handler, `on-review-approved`, under each harness
against a scratch swarm, one run each (two for Claude Code, see below).

**Setup.** A scratch git project with the `software-dev` topology and one task in
`review` with an approved review artifact written by the real `task-signal.sh`.
The scripts were the repository's own, copied next to `integrations/`,
`adapters/` and `topologies/`, except that `worker-spawn.sh` was a stub that logs
its arguments. The harness received `conductor.prompt`, the skill text with
`$TASK_ID` and `$CONDUCTOR_DIR` filled in, and the artifact path, and was asked to
run the skill. The expected result is the card in `merging` and one
`worker-spawn <id> merger` call (`locks=free`).

| | Claude Code `claude -p` | Codex `codex exec` | Pi `pi --mode rpc` |
| --- | --- | --- | --- |
| Card ended in `merging` | yes | yes | yes |
| Spawn calls | 1 | 1 | **2** |
| Wall time | 10 to 13 s | 16.7 s | 21.6 s |
| Model turns or tool calls | 3 turns | 4 commands, the first failed | 5 tool calls |
| Usage reported | tokens and cost | tokens, **no cost** | tokens and cost |
| Reported figures | 679 output, 64k cache read, 17k cache write; $0.081 | 91,236 input (83,712 cached), 427 output, 12 reasoning | 11 input, 1,441 output, 31,676 cache read, 7,511 cache write; $0.099 |
| How it was bounded | outer `timeout`, `--max-budget-usd 1` | outer `timeout`, `-s workspace-write` | 240 s deadline in the client, `abort` on expiry |
| Where usage comes from | `--output-format json`: `total_cost_usd`, `usage` | `--json`: `turn.completed.usage` | `get_session_stats` after `agent_settled` |

The models differ, so the figures are not comparable across columns. Claude Code
and Codex ran on their configured defaults; Pi ran on `claude-opus-4-8`.

**Findings**

1. **A bounded multi-turn run works in all three.** Each read the artifact, ran
   several commands, routed the card and started the stage, then stopped on its
   own. The deadline never fired.
2. **Codex reports tokens but not cost.** `codex exec --json` emits
   `turn.completed` with `input_tokens`, `cached_input_tokens`,
   `cache_write_input_tokens`, `output_tokens` and `reasoning_output_tokens`. A
   search of the whole event stream found no cost, price or USD field. The usage
   log can record Codex tokens; a dollar figure would need a price table.
3. **A model repeats steps on its own, so the spawn guard is load-bearing.** Pi
   ran the whole handler in one command and then ran `stage-start.sh` again to
   check it, which produced two spawn calls. With the guard from #68 the second is
   a no-op. Replays are not only a crash risk.
4. **A failed check can fail open.** In a first Claude Code run the scratch swarm
   was missing `integrations/`, so `task-locks.sh` errored. The model reported the
   error and carried on with `locks=free`, because the card had no `files-changed`.
   A merge went ahead on a guard that had not run. Whether a model carries on or stops
   there depends on the model, not only on the rule: on a card with no `files-changed`,
   Claude Code and Pi read that as `locks=free`, while Codex stopped with `HANDLER-FAILED`
   because it could not determine the guard. In a script handler the lock check is code that
   fails closed (`locks_guard` in `handler-steps.sh`). While a handler stays a skill, a failing
   `task-locks.sh` should stop the handler.
5. **Fixed context dominates the cost of a small handler.** Claude Code's
   17k cache-write tokens look like default system prompt and tool definitions,
   not the handler. Trimming that (for example `--system-prompt` or `--bare`) was
   not tried.
6. **Pi RPC needs a client.** It is the only harness that cannot be driven with
   one command line. The driver was about 40 lines of Python: send `get_state` and
   `prompt`, read JSONL until `agent_settled`, send `get_session_stats`.

**Go or no-go for `adapter_dispatch`**

- **Claude Code: go.** One command, a deadline from `timeout`, and usage and cost
  from the JSON output.
- **Codex: go, with tokens only.** The usage log records tokens and leaves cost
  empty, or applies a price table. Codex was the most exploratory of the three: it
  searched for files and read scripts before acting.
- **Pi: go.** It has the best control surface (`abort`, `get_session_stats`) and
  needs a small RPC client in the adapter.

These runs cover the easy path only. See the next section for what they leave
open.

## What is not verified

- **The spike covered one handler on its easy path.** `on-review-approved` with
  `locks=free`, no replay, one run per harness. Not run: the `locks=held` path, a
  replayed event, a handler that should leave the card alone, a handler that fails
  partway, and a run that hits the deadline. The trivial-prompt numbers in the
  appendix are still from a one-line prompt with no tool use.
- **The Claude Code run may have loaded user-level settings.** It was not run with
  `--bare` or a custom system prompt, so the user's own instruction files may have
  been part of the context. This was not checked.
- **No cost figure for the default conductor model.** `workforces/default.json`
  sets the conductor to `claude-opus-4-8`. The measurements used Haiku 4.5, whose
  price differs, so the idle estimate above is an order of magnitude only.
- **Timings are from one machine** with 3 runs each. Treat them as direction, not
  benchmarks.

## Appendix: measurements

One trivial prompt ("Reply with exactly: OK"), 3 runs per mode, in an empty
directory (no project instruction files). Claude Code 2.1.316, Pi 1.4.0, Codex
v0.166.0. Claude Code and Pi used the same model, Haiku 4.5
(`claude-haiku-4-5-20251001`). Codex used the signed-in ChatGPT account's default
model, so its time is not comparable to the other three.

| Mode | Run times | Notes |
| --- | --- | --- |
| `claude -p` (cold) | 2.68 s, 2.08 s, 1.98 s | cost per call $0.0183, $0.0111, $0.0025; about 23k cached input tokens |
| `pi -p` (cold) | 35.97 s, 2.22 s, 2.10 s | the 35.97 s first call is unexplained and did not reproduce (5 reruns: 2.1 to 2.2 s, plus one 0.89 s) |
| `pi --mode rpc` (warm) | 1.91 s, 1.85 s, 1.87 s | process ready in 0.17 s; `new_session` between events; about 2.1k input tokens |
| `codex exec` (cold) | 3.80 s, 4.34 s, 4.90 s | different model |

The single 36 s `pi -p` call is a reminder that a dispatcher needs a deadline
whatever the median looks like.
