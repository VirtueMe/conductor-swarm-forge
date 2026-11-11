# Commit attribution

Status: **in progress**, for #130. The rebase-and-stamp script and the resolver are built; the merger skill runs it; the claude-code launch switches Claude's own attribution off. It unblocks #137.

## The problem

A swarm member commits its work, and what the commit says about who wrote it depends on which
adapter ran the task. Checked on 2026-11-11 against claude-code 2.1.322, codex 0.166.0 and pi 1.4.0:

| Adapter | What it adds to a commit | Per-launch switch |
|---|---|---|
| claude-code | `Co-Authored-By: <model> <noreply@anthropic.com>` (and a PR body line) | `--settings '{"attribution":{"commit":"","pr":""}}'`, no file edit. The adapter already passes `--settings`. |
| codex (`exec`) | Nothing, in a throwaway repo, with `commit_attribution_enabled` unset, `false` and `true`. | `-c commit_attribution_enabled=<bool>` is accepted, but changed nothing in `exec`. |
| codex (interactive) | Not tested. The binary carries an instruction to end commits with `Co-authored-by: Codex <noreply@openai.com>`, gated by `commit_attribution_enabled`. | as above |
| pi | Nothing. | none needed |

The instruction in Codex is text given to the model, not git configuration. A line in the briefing
cannot override it, and a member cannot be relied on to report its own model. Which model did the
work is already recorded: `dispatch_write_usage` logs adapter, model and tokens per event.

The swarm creates no pull requests: nothing in the skills, scripts or docs runs `gh pr create`.
Its output is commits and a branch push. This document is about commits only.

## Decision

Do not ask each tool to behave. The conductor stamps the commits itself, after the member is done
and before anything leaves the worktree, so the result is the same whatever the adapter did.

One setting, `attribution:` in `.conductor/config.md` (next to `base-branch` and `test-cmd`, which the merger
already reads there; `swarm-start.sh` writes it from `CONDUCTOR_ATTRIBUTION`, default `trailer`, and refuses any other value
than `trailer` or `none` before it starts anything):

- `trailer` (the default): the conductor adds the trailers below to every commit of the task.
- `none`: the conductor adds nothing.

There is no mode that leaves each tool's own attribution on: its output differs per adapter and
cannot be enforced.

## The trailers

Added with `git commit --amend --no-edit`, one `--trailer` per line. Both are always added in
`trailer` mode, because they answer different questions:

```
Co-Authored-By: <agent> <agent url>
Assisted-by: <adapter>:<model>
```

- `Co-Authored-By` names the tool (`Claude Code`, `Codex`, `Pi`), with a fixed URL per adapter. Forges
  show it as a co-author.
- `Assisted-by` names the adapter and the model, taken from the conductor, not from the member.

## Where it runs

The merger (`skills/merger/merge.md`, step 2) rebases the task's commits onto the base. Nothing has
been pushed before that: its push in step 3 is the only one in the swarm. So the rebase can carry
the stamp at no extra cost, with `git rebase --exec` over `BASE_SHA..HEAD`, which is exactly the
task's commits.

Why here and not earlier: a handler on `signal-complete` runs before review and conflict rework,
which add more commits, and a trailer added there would miss them. The rebase gives one rewrite,
every commit covered, and no force-push.

**The rebase and the stamp are one command, in two layers.**

- The core, `scripts/attribution-rebase.sh <base-sha> [<trailer-line>...]` (built): rebases onto
  `<base-sha>` and stamps each replayed commit with the given lines. With no lines it is the plain
  rebase. A line has to look like `Key: value`; anything else is refused before a commit is touched, so
  a mistyped flag cannot end up in the history.
- The resolver, `scripts/attribution-trailer.sh <task>` (built): reads the setting, the coder's adapter
  and the model, and prints the lines for that task, or nothing for `none`.

`attribution-rebase.sh <base-sha> --task <id>` joins them (built): it takes the lines from the resolver
and rebases with them. That is the merger's one command, in place of `git rebase "$BASE_SHA"` (`skills/merger/merge.md`,
step 2). If it has nothing to give, the rebase is the plain one. If the resolver fails (a bad
`attribution:` value, no `jq`) the command exits **4** before it rebases anything. It does not pass the
resolver's own code on, because git's rebase exits 1 on a conflict and the merger has to tell the two
apart: a 4 is signalled as `blocked` with the stderr message, with nothing to abort. Any other failure
is told by state, not by code: if a rebase is in progress it is a conflict, aborted and signalled as
`conflict`; if none is, git failed before it began (uncommitted changes, a missing base), and that is
signalled as `blocked` too.

The policy is then in code: a test drives each layer and the two together, and a model cannot run the
rebase and skip the stamp, because it never assembles the lines.

### The stamp skips what is already there

The merger retries the rebase up to three times, so the stamp must be idempotent. It is by exact
line (and it adds with `--no-verify`, so a project's commit-msg hook or signing cannot fail the
rebase and be mistaken for a conflict): for each trailer, the stamp reads the commit's trailers (`git interpret-trailers --parse`) and
adds the line only if that exact line is missing. It never removes or rewrites a trailer. A human's
`Co-Authored-By` is kept, and a second run changes nothing.

Git's own `trailer.ifexists` options do not give this. The default duplicates lines when more than one
trailer is added (tested on git 2.47.3: a second run doubled both). `replace` avoids that by deleting
every trailer with the same key, which would also delete a human co-author.

## What the conductor needs to know

The resolver reads it all, for the `coder`, the role whose commits these are. That name is fixed in the
resolver: the merger exists only in the `software-dev` topology, and its roles are the ones that commit.
A topology with another committing role would need the resolver told which one.

- the model: the workforce's `params.model`, with the task's strategy over it (`task-strategy.sh params`);
- the adapter: the workforce's `adapter`;
- the agent name and URL: `adapter_attribution` in `adapters/<adapter>.sh`, one line, tab-separated.

What it cannot find (no `workforce.json`, no coder, an adapter with no file) costs the lines it would
have given, with a warning on stderr: the stamp is metadata, and a merge must not stop for it. The price is that such a task's commits go
unstamped, with the warning as the only sign; this was chosen over stopping the merge. A
`attribution:` value that is neither `trailer` nor `none` is an error, so a typo does not pass for off.

## Claude Code is launched with its attribution off (built)

Because the stamp only adds missing lines, a commit that carries Claude Code's own
`Co-Authored-By: <model> <noreply@anthropic.com>` would end up with that line and ours. So an
interactive claude-code window (`adapter_launch`) is started with Claude's own attribution off,
`{"attribution":{"commit":"","pr":""}}`, whenever `attribution` is not `none`. This is part of the
decision, not an option.

It goes in the same `--settings` that already carries the project's allow list. Whether a repeated
`--settings` merges is not documented, so there is one. With the setting on, the adapter reads the
project's `.claude/settings.json`, puts the attribution keys over it, and writes the result to
`$CONDUCTOR_DIR/claude-settings.json`, readable only by its owner. That path is what `--settings`
gets. With `none` the project's own file is passed by path, as before, and Claude's attribution is
left alone.

**Why a file and not inline JSON.** Inline would have worked and kept the adapter function free of
side effects. But a project's settings can hold `env` entries, an `apiKeyHelper` and hook commands, and
inline they would sit on the command line, where `ps` and the tmux window's command show them to every
local user. A path shows nothing. The cost is that the function that builds the flags writes a file; it
writes beside the target and renames, so two windows starting together never read half of it.

**Where it is written, and where it is not.** Not into the project's own `.claude/settings.json`, which
is the user's: it would also switch attribution off in their own Claude Code sessions in that
repository. The merged file lives in the swarm's state dir and is rewritten at each launch.

**A bad value.** `attribution-trailer.sh` refuses an `attribution:` that is neither `trailer` nor `none`
(a typo should not pass for off), and `swarm-start.sh` refuses it before anything starts. A launch cannot
refuse, so a window that finds such a value in `config.md` (it was edited by hand) says so on stderr and
goes on as `trailer`, the default: Claude's own attribution off, as the stamp expects. The merge then
stops on the bad value, with a message that names it. So for a bad value both treat the stamp as on;
they do not share a rule (see Open).

**When it falls back.** If the project's file is not a JSON object, or the merged file cannot be written,
the project's file is passed as it is, with a warning on stderr, and attribution is then not turned
off. The launch goes on: a settings problem must not stop a worker.

**What it does not cover.**

- The headless dispatch (`claude -p`, the conductor's handlers): it does not write the task's commits.
- Managed settings. An organisation's managed `attribution` outranks `--settings`, so Claude's own line
  would still be added and the commit would carry both.
- The windows that do not commit. See Open.

Not verified against a real `claude`: that an empty `commit` and `pr` really produce no trailer. The
docs the check was made against did not say, and the test stubs `claude`. A live commit in a throwaway
repository would settle it.

## Tests

Through the stub adapter, with a private `TMUX_TMPDIR` and the real CLIs off `PATH`, as for the rest
of the suite:

- `trailer`: every commit in `BASE_SHA..HEAD` has both lines, including a commit added after review.
- Running the script twice leaves one of each line.
- A human's `Co-Authored-By` on a commit is still there afterwards.
- `none`: the messages are unchanged and the script is the plain rebase.
- The commits' trees are unchanged (only messages rewrite).
- The claude-code adapter's launch has the attribution settings with `trailer`, and does not with `none`.

## Open

- The set of valid `attribution:` values is written in three places: `swarm-start.sh`,
  `attribution-trailer.sh` and `adapter_settings_flag`, each with its own copy of the line that reads the
  key. A third mode needs all three edited, and nothing fails if one is missed. A shared reader would
  remove the copies.
- Which windows commit. `adapter_launch` serves every interactive window (coder, architect, validator,
  reviewer), so Claude's own attribution is off for all of them, while the stamp covers only the task's
  commits through the merger's rebase. A commit made by another role outside that path would carry
  neither. If any role does that, the launch has to learn the role, and the switch be limited to the coder.
- Whether interactive Codex adds a trailer of its own. If it does, the stamp would add ours beside it
  and the result has two lines. Test an interactive session before enabling `trailer` for Codex.
