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
| `on-validation-failed` | summary only | "paste key failure lines" into a progress note |
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
check would move every existing swarm onto the loop at once. The loop also does not run the
startup reconcile (`startup.md` steps 1 to 6: register untracked tasks, unblock ready ones,
respawn workers whose window was lost, re-notify a waiting human). A fresh swarm does not need
it, since new tasks arrive as events. A restart with work in flight does. Until that is split
out and run by the loop (#89), `swarm-start.sh -hc` prints a warning when it finds cards in a
working stage, and the default stays interactive.

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

**Contract**, called as `adapter_dispatch <skill_content> <artifact>`:

| | |
| --- | --- |
| Environment | `CONDUCTOR_DIR` (absolute), `PATH` with the scripts (from `conductor_env`), `TASK_ID`, `TASK_FILE`, `ARTIFACT`, `DISPATCH_DEADLINE` (seconds), `DISPATCH_USAGE_FILE` |
| Exit 0 | the handler finished |
| Exit 2 | the event cannot be handled; the loop does not retry |
| Any other exit | the handler failed; the loop retries |
| Usage | the adapter may write one JSON line to `$DISPATCH_USAGE_FILE`: `harness`, `model`, `input_tokens` (input that was neither read from nor written to a cache), `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_usd` (null when the harness reports none, as Codex does) and `turns`. Write it even when the run fails, because the spend happened, unless the harness reported none (a killed Codex run) |

`turns` is each harness's own count, so compare it within one harness and not across them:
Claude Code reports `num_turns` (model round trips), Pi the number of assistant messages,
and Codex the number of completed model and tool steps in the event stream. The token fields
mean the same everywhere; `input_tokens` excludes anything read from or written to a cache.

`scripts/dispatch-prompt.sh` builds the prompt for all three adapters: the static
briefing first so caching can hit it, then the rules for a dispatched run, the skill,
and the event last. `dispatch_final_exit` turns a final line starting with
`HANDLER-FAILED:` into a failed dispatch.

**What the loop does when something goes wrong**

| Case | Behavior |
| --- | --- |
| Handler exits non-zero or hangs past the deadline | Retry up to `CONDUCTOR_MAX_ATTEMPTS` (3), `CONDUCTOR_RETRY_DELAY` (5 s) apart, then halt. The event stays unprocessed. |
| Adapter exits 2, the handler cannot be resolved, the skill file is missing, or the artifact has no type | Halt at once. Retrying cannot help. |
| The artifact has no handler (`assigned`, `progress`, `moved`, ...) | Record it as processed without a dispatch, so it is never listed again. |
| Crash or kill between "handler done" and `mark` | The event runs again on restart. Moves and spawns are safe to replay (the spawn guard). A replayed `progress` note is duplicated, which is noise, not damage. |
| Loop killed during a dispatch | The dispatch is stopped, the event is not recorded, the lock is released. |
| A second loop on the same conductor dir | Refused (exit 4). A lock left by a dead process is taken over. |
| First start, no ledger yet | The ledger is seeded with the artifacts that exist, so history is not replayed. It is written whole or not at all. |
| A new task | A `card` artifact is mapped to `conductor/on-new-task` by the loop. `conductor-skill` itself is unchanged, so the interactive conductor sees nothing different. |
| Project complete | `conductor-shutdown.sh` closes the architect window and the kanban server and, under the loop, only writes a flag. The loop exits after recording the event; closing its own window from inside the handler would kill it before the `mark`. |

A halt writes `$CONDUCTOR_DIR/conductor-loop.halted`, tells the human and the architect, and
exits 1. The usage log is #86 and the live log is #87.

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

**Known limits**

- A model can ignore a failing guard script and carry on (the spike saw this). The
  `HANDLER-FAILED:` rule in the prompt is a mitigation that depends on the model
  following it. Phase 2 makes the guards code that fails closed.
- The briefing the dispatch uses is the whole of `conductor.prompt`, including its
  interactive Startup and Watch loop sections, which the dispatch rules tell the
  model to ignore. Splitting the prompt would remove that.
- The banner is lost if the conductor window closes when the loop exits, which tmux does by
  default for a window whose command ends. The inbox files survive. `swarm-start.sh -hc` keeps
  the window open by running the loop as `loop; exec $SHELL`.
- `startup.md` mixes the startup reconcile and the poll loop, so the loop cannot yet
  dispatch the reconcile as its first event (#89).
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
   because it could not determine the guard. In Phase 2 the lock check
   should be code that fails closed. While a handler stays a skill, a failing
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
