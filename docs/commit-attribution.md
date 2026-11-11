# Commit attribution

Status: **draft**, for #130. Not implemented. It unblocks #137.

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

One setting in the workforce, `attribution`:

- `none` (the default until decided): the conductor adds nothing.
- `trailer`: the conductor adds the trailers below to every commit of the task.

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

**The rebase and the stamp are one script**, `scripts/attribution-rebase.sh "$BASE_SHA"`. The merger
skill runs that one line in place of `git rebase "$BASE_SHA"`. The policy is then in code: a test
drives the script directly, and a model cannot run the rebase and skip the stamp. With the setting
at `none` the script is the plain rebase.

### The stamp skips what is already there

The merger retries the rebase up to three times, so the stamp must be idempotent. It is by exact
line: for each trailer, the stamp reads the commit's trailers (`git interpret-trailers --parse`) and
adds the line only if that exact line is missing. It never removes or rewrites a trailer. A human's
`Co-Authored-By` is kept, and a second run changes nothing.

Git's own `trailer.ifexists` options do not give this. The default duplicates lines when more than one
trailer is added (tested on git 2.47.3: a second run doubled both). `replace` avoids that by deleting
every trailer with the same key, which would also delete a human co-author.

## What the conductor needs to know

- the model: `task-strategy.sh` carries `workers.<role>.model`;
- the adapter: it belongs to the workforce;
- the agent name and URL: a new fixed field per adapter, kept next to the adapter's other settings.

## Claude Code is launched with its attribution off

Because the stamp only adds missing lines, a commit that carries Claude Code's own
`Co-Authored-By: <model> <noreply@anthropic.com>` would end up with that line and ours. So when the
setting is `trailer`, the claude-code adapter adds
`--settings '{"attribution":{"commit":"","pr":""}}'` to its launch, in the place where it already
passes `--settings`. This is part of the decision, not an option. With `none` it changes nothing.

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

- The default: `none` or `trailer`. No swarm-built repo exists yet to compare with.
- Whether interactive Codex adds a trailer of its own. If it does, the stamp would add ours beside it
  and the result has two lines. Test an interactive session before enabling `trailer` for Codex.
- The URL per adapter.
