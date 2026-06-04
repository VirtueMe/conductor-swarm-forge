# Conductor Swarm Forge

Orchestrate a swarm of AI coding agents to build software in parallel.

Conductor Swarm Forge takes a project brief, decomposes it into a dependency
graph of tasks, and routes each task through a kanban workflow where specialized
Claude agents — **architect, coder, validator, reviewer, merger** — pick up work,
implement it on isolated git branches, run the tests, review each other, and
rebase onto `main`. A **conductor** agent watches the whole board and routes work
as signals come in.

It's git-native, language-agnostic, and built almost entirely out of bash,
markdown skill files, and the `claude` CLI — no runtime to install, no
`package.json` to manage.

> **Credit & inspiration**
>
> Conductor Swarm Forge grew out of our own
> **[BANCS Claude Plugin](https://github.com/BANCS-Norway/bancs-claude-plugin)**,
> where we built a **mission system with swappable agent workforces** — rosters of
> role-specialized agent personas, each assigned to work by what they're `bestFor`
> and adopting their own working `style`. That workforce model is the seed this
> project is built around (see [`workforces/`](workforces/)).
>
> When we found **[SwarmForge](https://github.com/unclebob/swarm-forge)** by
> **Robert C. Martin (Uncle Bob)**, his approach resonated immediately — it was
> the natural way to take our single-session workforce idea and turn it into a
> full parallel swarm: a lightweight, self-hosted, tmux-based platform where AI
> agents collaborate as "reliable, professional software engineers," each in its
> own git worktree and terminal window, driven by role-specific prompts and a
> configuration-driven topology rather than a fixed set of roles. Huge thanks to
> Uncle Bob for the original idea and design. Go read the original. 🙏
>
> It also pairs naturally with our
> **[tmux-mcp](https://github.com/BANCS-Norway/tmux-mcp)** — an MCP server that
> bridges Claude Chat ↔ Claude Code over tmux, so you can observe and steer a
> running swarm (list sessions, read pane output, send prompts) from anywhere,
> including the Claude mobile app. See [Monitoring & control](#monitoring--control).

---

## How it works

```text
brief.md ──▶ architect ──▶ tasks (with dependencies)
                              │
        ┌─────────────────────┴──────────────────────────────┐
        ▼                                                      │
   backlog ─▶ ready ─▶ in-progress ─▶ validation ─▶ review ─▶ merge-pending ─▶ merging ─▶ done
              coder        coder        validator    reviewer                  merger
        ▲                                                      │
        └────────────── conductor routes signals ◀────────────┘
```

- **Task-driven.** Every unit of work is a task with a unique id, type
  (`feature` · `design` · `test` · `chore` · `spike`), description, and explicit
  dependencies. The conductor only releases a task to `ready` once its
  dependencies are `done`.
- **Signal-based.** Workers never talk to each other directly. They write
  artifacts (progress, completion, review verdicts, merge results) into
  `.conductor/work/<id>/`, and the conductor watches the filesystem and moves
  cards accordingly.
- **Immutable history.** Task definitions in `.conductor/tasks/` never change.
  All state transitions are append-only, timestamped artifacts — a kanban card
  can always be rebuilt from history (`task-replay.sh`).
- **Git-native.** Each task gets its own worktree and feature branch. Mergers
  rebase onto `main`; coders resolve any conflicts. File locks prevent two
  merges from touching the same files at once.
- **Quality gates.** Code passes through validation (if a test command is
  configured) and review before it's eligible to merge. Rejections and failures
  route back to the coder automatically.

Roles come in two shapes. The **conductor** and **architect** are long-lived
orchestrating roles, each launched from a **prompt** (`prompts/*.prompt`, a
persona/system prompt) at startup. The **workers** — coder, validator, reviewer,
merger — are task-scoped: each spawn is driven by a **skill**
(`skills/<role>/<event>.md`, step-by-step instructions for that specific event),
not a prompt. Every role is launched through an **adapter** (`adapters/*.sh`,
which writes the briefing and opens the tmux window); swap the adapter to run a
different agent backend — a `claude-code` and a `codex` adapter ship by default.

---

## Requirements

Always required:

- `bash`, `git`, `python3`
- [`tmux`](https://github.com/tmux/tmux) — each agent runs in its own window
- [`claude`](https://docs.claude.com/en/docs/claude-code) — the AI agent CLI

Optional, depending on flags:

- `node` — for the real-time kanban dashboard (`--kanban-server`)
- The toolchain for your target language (auto-checked from `--lang`): e.g.
  `node`/`npm`, `python3`, `cargo`, `lein`, `ruby`/`bundle`, `go`, …

`preflight-check.sh` runs automatically at startup and fails fast with a list of
anything missing.

---

## ⚠️ The conductor invents missing skills

The conductor is built to keep the development cycle moving rather than halt on
problems. Workers are spawned from **skill** files
(`skills/<role>/<event>.md` — e.g. `validator/validate`, `coder/on-rejection`),
which `worker-spawn.sh` reads when it dispatches a task.

**As it currently works, if a worker needs a skill that doesn't exist, the
conductor will write that skill itself and carry on** — instead of stopping and
asking you. It self-repairs the gap.

That makes the swarm resilient, but it also means it can **invent behavior you
never defined**:

- The generated skill is written from the conductor's own judgement, not your
  spec — it may not match what you intended that role to do.
- A self-authored skill can quietly change how a role (coder, validator,
  reviewer, merger) behaves for the rest of the run.
- The new file lands in the project's `.conductor/skills/` copy, so it persists
  for the remainder of the session.

**Recommendation:** keep `skills/` complete before you start, and **review any
skill the conductor adds to `.conductor/skills/` during a run** before trusting
its output. Treat a conductor-authored skill as a signal that something was
missing from your definition — not as an approved change.

> Note: this applies to **skills**, which are the per-task worker instructions.
> Prompts (`prompts/`) are only loaded for the conductor and architect, so a
> missing worker prompt is never referenced and never triggers this behavior.

---

## Quick start

From the directory you want to build your project in:

```bash
/path/to/conductor-swarm-forge/scripts/swarm-start.sh \
  --brief ./brief.md \
  --lang typescript \
  --test-cmd "npm test" \
  --kanban-server
```

This will:

1. Run preflight checks.
2. Initialize a git repo (if needed) and a `.conductor/` state directory.
3. Copy skills and prompts into the project so agents never read outside it.
4. Brief and launch the **conductor** (and the **architect**, if a brief was given).
5. Start the kanban dashboard and print its URL.
6. Attach you to the `swarm` tmux session.

The architect reads your brief, decomposes it into tasks, and the swarm takes it
from there. Watch the board fill up at `http://localhost:3000`.

### Flags

| Flag | Alias | Default | Description |
| --- | --- | --- | --- |
| `[target-dir]` | | current dir | Directory to build in; created if missing |
| `--brief <file>` | `-b` | none | Project brief; architect decomposes it into tasks |
| `--lang <language>` | `-l` | `typescript` | Target language; drives preflight checks |
| `--test-cmd <cmd>` | `-tc` | none | Test command. If set, all code routes through validation; if not, it skips straight to review |
| `--topology <name>` | `-tp` | `software-dev` | Workflow topology (`topologies/<name>.json`): stages, roles, transitions, integration |
| `--workforce <name>` | `-wf` | `default` | Workforce (`workforces/<name>.json`): which agent/adapter runs each role |
| `--kanban-server` | `-cbs` | off | Start the Node.js kanban dashboard |

Supported `--lang` values include `typescript`/`javascript`, `python`, `rust`,
`go`, `ruby`, `clojure`, `elixir`, `java`, and `kotlin`.

### Domain packs

The swarm is a **swarm engine**, not just a dev swarm: the workflow lives in a
declarative *topology* (see [`docs/workflow-as-topology.md`](docs/workflow-as-topology.md)).
Two packs ship today:

- **`software-dev`** (default) — coder → validator → reviewer → merger, `git` integration
  (a branch + worktree per task, merge consolidates).
- **`marketing`** — drafter → fact-checker → editor → publisher, `shared-doc` integration
  (one shared deliverable folder per task, publish consolidates; no branches, no locks).
  Run it with `--topology marketing --workforce marketing`.

The marketing pack changes no engine code — it's proof the stages, roles, routing, and
integration model are all read from the pack, not hardcoded.

---

## Writing a brief

A brief is plain markdown describing what to build and what "done" means. See
[`examples/hunt-the-wumpus/brief.md`](examples/hunt-the-wumpus/brief.md) for a
complete worked example. Good briefs state the goal, key constraints
(e.g. "terminal-only, pure functions"), and acceptance criteria the reviewer can
check against.

You can also skip the brief and create tasks by hand:

```bash
CONDUCTOR_DIR=.conductor scripts/task-create.sh \
  --title "Implement the game loop" \
  --type feature \
  --depends-on "0001,0002" \
  --description "..."
```

---

## Monitoring & control

```bash
# Full kanban state in the terminal
CONDUCTOR_DIR=.conductor scripts/task-list.sh

# Rebuild a card from its work history
CONDUCTOR_DIR=.conductor scripts/task-replay.sh <task-id>

# Stop the swarm (also auto-runs when the tmux session closes)
scripts/swarm-stop.sh [target-dir]
```

The kanban dashboard (`kanban-board.js`) streams live updates over SSE to a web
UI. When started via `--kanban-server` it auto-selects a free port from `PORT`
(default `3000`) and shuts down with the tmux session.

### Steering the swarm remotely

Because the whole swarm runs in a tmux session (`swarm`), you can observe and
drive it from outside the terminal with
**[tmux-mcp](https://github.com/BANCS-Norway/tmux-mcp)** — an MCP server that
exposes tmux over Tailscale to Claude Chat and Claude Code:

- `tmux_list_sessions` — discover the running `swarm` session and its windows
- `tmux_get_summary` — read recent output from any agent's pane (conductor,
  architect, a specific coder, …)
- `tmux_send_prompt` — send input/commands into a pane to unblock or redirect an
  agent

This lets you check in on a long-running swarm — or nudge it — from the Claude
mobile app, without being at the host machine.

---

## Layout

```text
conductor-swarm-forge/
├── scripts/         Core orchestration (swarm-start, task-*, topology-load, watch-dir, …)
├── topologies/      Declarative workflows: software-dev.json, marketing.json
├── integrations/    How finished work is consolidated: git.sh, shared-doc.sh
├── prompts/         System prompts for the orchestrating roles: conductor, architect
├── skills/          Per-role, per-event step-by-step instructions (markdown)
│   ├── conductor/   Event handlers: on-signal-complete, on-review-rejected, …
│   ├── architect/   on-brief, on-drift, on-blocked
│   ├── coder/ reviewer/ merger/ validator/      software-dev roles
│   ├── drafter/ fact-checker/ editor/ publisher/ marketing roles
├── adapters/        Agent backends: claude-code.sh, codex.sh
├── workforces/      Role → agent → adapter mapping (default.json, marketing.json)
├── examples/        Sample briefs (hunt-the-wumpus)
└── kanban-board.js  Real-time SSE kanban dashboard
```

At runtime, a `.conductor/` directory holds project state: immutable `tasks/`,
append-only `work/`, the `kanban/` columns, the architect's `architect-inbox/`,
and local copies of `skills/` and `prompts/`.

---

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONDUCTOR_DIR` | `.conductor` | Location of runtime state |
| `PORT` | `3000` | Starting port for the kanban server |
| `WORKFORCE` | `workforces/default.json` | Role/adapter assignments |

Per-project settings (`lang`, `test-cmd`) are written to `.conductor/config.md`
at startup.

### Workforce

`workforces/default.json` maps each role to an agent and an adapter. Point a role
at a different adapter to run it on a different backend:

```json
{
  "name": "default",
  "members": [
    { "role": "conductor", "agent": "claude", "adapter": "claude-code" },
    { "role": "architect", "agent": "claude", "adapter": "claude-code" },
    { "role": "coder",     "agent": "claude", "adapter": "claude-code" },
    { "role": "validator", "agent": "claude", "adapter": "claude-code" },
    { "role": "reviewer",  "agent": "claude", "adapter": "claude-code" },
    { "role": "merger",    "agent": "claude", "adapter": "claude-code" }
  ]
}
```

---

## Related projects

Conductor Swarm Forge is part of a small family of BANCS tools, plus the project
that inspired it:

- **[bancs-claude-plugin](https://github.com/BANCS-Norway/bancs-claude-plugin)** —
  the Claude Code plugin where the **workforce / mission** model originated:
  swappable rosters of role-specialized agent personas, automated git-worktree
  handling, and a per-developer mission system. This project's seed.
- **[tmux-mcp](https://github.com/BANCS-Norway/tmux-mcp)** — an MCP server bridging
  Claude Chat ↔ Claude Code over tmux/Tailscale. Pairs with the swarm so you can
  observe and steer it remotely, including from the Claude mobile app.
- **[unclebob/swarm-forge](https://github.com/unclebob/swarm-forge)** — Robert C.
  Martin's original tmux-based multi-agent platform, the inspiration for taking the
  workforce idea into a full parallel swarm.

---

## License

[MIT](LICENSE) © 2026 VirtueMe

## Author

Jan Thomas · [VirtueMe/conductor-swarm-forge](https://github.com/VirtueMe/conductor-swarm-forge)
