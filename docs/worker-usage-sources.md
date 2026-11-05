# What each harness leaves behind for a worker

A spike for #111 (gap 1: workers are not metered), run on 2026-11-04. The workers (coder,
validator, reviewer, merger) run as interactive sessions in tmux windows started by
`worker-spawn.sh`, and they write no usage record. This finds out what each harness leaves on disk
that a reader could use, so the worker slice (#135) is written against facts.

**Method.** For each harness one real interactive session was started the way its adapter's
`adapter_launch` starts a worker (same flags, a working directory inside a worktree, a one-word
prompt, a private tmux server), left running, read, and then killed. Claude Code was killed three
ways: `kill-window` (SIGHUP), `kill-server` (SIGHUP) and `kill -9`. Codex and Pi were killed with
`kill -9`. The whole spike cost about $0.07, almost all of it three Haiku sessions. Trimmed copies of
the sessions are under `tests/worker-usage/`, and `scripts/test-worker-usage-fixtures.sh` runs
the reading recipes below against them, so none of this needs a model to re-check.

| | claude-code | codex | pi |
| --- | --- | --- | --- |
| Version checked | 2.1.318 | codex-cli 0.166.0 | 1.4.0 (session format 3) |
| Tokens | yes, per API message | yes, cumulative per turn | yes, per message |
| Cost | on exit only | none | yes, per message |
| Model that answered | yes | yes | yes |
| Start and end | yes | yes | start, and a time per message |
| Window or task name in it | the window name, from `-n` | no | no |
| Worktree path in it | yes (`cwd`) | yes (`cwd`) | yes (`cwd`) |
| Readable while running | yes | yes | yes |
| After SIGKILL | tokens yes, cost no | everything completed | everything completed |
| Format documented | no | no | yes |

## Finding the session that belongs to a worker

All three record the working directory, and a worker's working directory is its task's worktree,
which is unique to the task, so `cwd` is the key. Only Claude Code also records the window name
(`custom-title`, from the `-n` the adapter passes), and neither Codex nor Pi takes one from the
adapter today.

A worktree can have several sessions: a task sent back for rework gets a new worker in the same
worktree and with the same window name. Filter by start time (the spawn time, below), not by name.

## claude-code

- **Where.** `~/.claude/projects/<cwd with every / and . replaced by ->/<session-id>.jsonl`. Better
  to read the `cwd` field inside than to rebuild the directory name.
- **What.** One JSON object per line. `assistant` lines carry `message.model` and
  `message.usage`: `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens` (the four counts of a usage record, already disjoint). There is
  no cost on them.
- **A message can appear twice.** The same API message (same `message.id` and `requestId`, different
  `uuid`) was written twice with identical usage. A reader has to deduplicate on `message.id`
  or it doubles the count. Tool use is likely to write one message once per content block; this was
  not tested.
- **Cost.** A `cost-state` line is appended when the process exits: `totalCostUSD`, a `modelUsage`
  block with `costUSD` per model and the `cacheCreationEphemeral1hInputTokens` split,
  `totalDuration` and `startTime`. It was written after `kill-window` and `kill-server` (SIGHUP) and
  was **not** written after `kill -9`. The cost is exactly what the usage and the 1-hour cache-write
  rate give, checked by hand.
- **Killed.** After SIGKILL the assistant lines are all there, so tokens and model are known and the
  cost is not. The price table can estimate it, with the caveat below.
- **Documented.** Not in anything installed with the CLI or in `--help`. It is the harness's own
  format, so treat it as unstable and pin the version it was checked on.
- **Time.** `timestamp` on each line, `durationMs` on the `turn_duration` line, `startTime` and
  `totalDuration` on `cost-state`.

## codex

- **Where.** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`. Date sharded
  and not keyed by directory, so a reader finds candidates by modification time and reads the first
  line (`session_meta`) for the `cwd`.
- **What.** `event_msg` lines of type `token_count` carry `info.total_token_usage`, cumulative for
  the thread: `input_tokens` (**including** the cached part), `cached_input_tokens`,
  `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`. The last one is the total.
  The model is in `turn_context.payload.model`, not in `session_meta`. This is the same basis the
  Codex adapter already uses for headless runs: subtract the cached part from `input_tokens`.
- **The model is the account's default** when the adapter passes none, which it does not unless the
  workforce sets `params.model`. Here it was `gpt-6.1-sol`, which the price table now has (#149).
- **Cost.** None. A cost has to come from the price table.
- **The allowance.** Each `token_count` also carries `rate_limits`: the 5-hour and the weekly
  `used_percent` with their reset times, the plan type and credits. That is the data the Codex
  subscription slice (#112) wants, and it comes with every worker session at no extra cost.
- **Killed.** The file is appended as events happen, so SIGKILL left it as it was and every
  completed turn is in it. Not tested: a kill in the middle of a turn, where that turn's counts
  are probably lost.
- **Documented.** No.
- **Time.** `session_meta.payload.timestamp`, and `task_started` and `task_complete`, with
  `duration_ms`.

## pi

- **Where.** `~/.pi/agent/sessions/--<cwd with / replaced by ->--/<timestamp>_<session-id>.jsonl`.
  The leading dot of `.worktrees` is kept, unlike Claude Code's.
- **What.** Each `message` line with role `assistant` carries `model`, `provider` and `usage`:
  `input`, `output`, `cacheRead`, `cacheWrite` and `cost.total`, with the cost split by kind. The
  `session` line has the `cwd` and the format `version`. A session's usage is the sum over its
  assistant messages.
- **Cost.** Pi's own figure, per message, from its own price table. For the fixture it equals what
  `usage-prices.json` gives, to the millionth of a dollar.
- **Killed.** Appended per message; SIGKILL left every completed message. A message in flight is
  lost.
- **Documented.** Yes: `docs/session-format.md` in the package, and a session `version` field
  (3 here). A newer Pi (1.5.0 was available) could change it, so read the version.
- **Time.** `ts` on the session line and on each message, and a `timestamp` inside the message.

## Findings that change the price table

- **Claude Code's cache write was billed at the 1-hour rate** (`cacheCreationEphemeral1hInputTokens`
  was the whole write). The table held only the 5-minute rate, so the estimate for this
  session was $0.0156 against a reported $0.0231. Fixed in #149: the record carries
  `cache_write_1h_tokens` (from the session's `cache_creation.ephemeral_1h_input_tokens`, and from
  `modelUsage.*.cacheCreationEphemeral1hInputTokens` in `claude -p`'s JSON) and the table has a
  `cache_write_1h` price, so the estimate now equals the reported cost.
- **Codex's default model was not in the table**, so its worker lines were `unknown`. `gpt-6.1-sol`
  was added in #149 at its short-context standard rate, with its date and source.

## Recommendation

This is what the worker slice (#135) was built from; "Worker usage" in
`docs/event-driven-conductor.md` describes what it does.

**All three can be metered now**, none of them only partly:

| Harness | Tokens | Model | Cost |
| --- | --- | --- | --- |
| pi | session file | session file | reported by Pi |
| claude-code | session file | session file | reported on exit; estimated after a hard kill |
| codex | session file | session file | estimated from the price table (once the model is priced) |

**The one place in `worker-spawn.sh`** is the line after `adapter_launch` (the last step before the
`Spawned ...` message). Nothing exists to read at spawn time, so it should only write a small spawn
record under `$CONDUCTOR_DIR`: role, task, adapter, the worktree's absolute path, `params` and the
start time in UTC. That record is what lets a later reader pick the right session out of a
worktree's several.

**The reading belongs where the window closes**, not at spawn: `close_worker_window` in
`scripts/handler-steps.sh`, which every script handler already calls. Two details matter. Close the
window first and read after, with a wait of a couple of seconds, because Claude Code writes its
`cost-state` line only when it exits. And the skill handlers that still call `tmux kill-window`
inline (`skills/conductor/on-*.md`) have to be moved onto `close_worker_window`, or they would
leave unmetered workers.

**Split the worker slice per harness?** Not into separate issues. What the three share is the larger
part: the spawn record, the hook at close, and writing a line in the same `usage.jsonl` shape (with
`role` set to the worker's role, which #131 prepared). What differs is the reader, about twenty
lines of `jq` each, and the recipes in `scripts/test-worker-usage-fixtures.sh` are those readers.
Build the slice once with three small readers behind one function, in the order Pi, Claude Code,
Codex: Pi is documented and reports its own cost, Claude Code needs the deduplication and the
exit wait, Codex needs a priced model.

## Not tested

- A Claude Code session that used tools, subagents (sidechains), `/compact` or `--resume`: the
  message duplication, and whether subagent usage is in the same file, are unknown.
- A Codex or Pi kill in the middle of a turn.
- A clean `/exit` for any harness, as against a kill.
- Several sessions in one worktree (rework): the time filter is reasoned, not tried.
- Windows and macOS paths; everything here ran on Linux.
