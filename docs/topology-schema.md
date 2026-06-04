# Topology Schema

A **topology** is the declarative state machine that drives a swarm: the stages a
task moves through, the role (or human) bound to each working stage, and the
guarded transitions between them. It is the first-class structure of the system —
roles are bound to its stages. See `workflow-as-topology.md` for the rationale.

Topologies live in `topologies/<name>.json` (JSON, to stay zero-dependency and
consistent with `workforces/*.json`). The active topology is selected with
`--topology <name>` at `swarm-start` (default: `software-dev`) and recorded in
`.conductor/config.md` alongside `lang` and `test-cmd`.

## Top-level fields

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | string | Topology identifier |
| `description` | string | Human-readable summary |
| `integration` | enum | How finished work is consolidated: `git` · `shared-doc` · `none` |
| `stages` | string[] | Ordered list of kanban columns (the nodes) |
| `working_stages` | object | Stages where work happens — maps stage → executor |
| `transitions` | object | Event → ordered list of guarded rules (the edges) |
| `integration_macros` | object | Reusable rule groups specific to the integration model |

Stages listed in `stages` but absent from `working_stages` (e.g. `backlog`,
`ready`, `merge-pending`, `done`) are conductor-managed holding columns — no
executor is attached.

## Working stages

Each working stage declares a `mode`:

### `mode: auto` (default)
Spawn the bound AI role and wait for its signal.

```json
"in-progress": {
  "mode": "auto",
  "role": "coder",
  "skill": {
    "default": "coder/fresh-start",
    "rules": [
      { "when": { "last_artifact": "merge:conflict" },  "skill": "coder/on-conflict" },
      { "when": { "last_artifact": "review:rejected" }, "skill": "coder/on-rejection" }
    ]
  }
}
```

- `role` — workforce role to spawn (resolved to an adapter via the workforce).
- `skill` — either a string (single skill) or `{ default, rules[] }` where the
  first matching `when` guard selects the skill (this replaces `select_skill()`).

### `mode: manual` (human-in-the-loop — see #7)
Notify a human and wait for a *human* signal. No agent is spawned. The line
genuinely halts until the human responds (or the timeout fires).

```json
"legal-signoff": {
  "mode": "manual",
  "notify": { "channel": "push", "message": "Task {id} needs sign-off: {reason}" },
  "await":  ["approved", "rejected", "changes-requested"],
  "timeout": { "after": "4h", "on_expiry": "rejected" }
}
```

- `notify.channel` — where to alert the human (e.g. push / tmux-mcp).
- `await` — the set of human decisions accepted at this stage; each arrives as a
  `human:<decision>` signal routed through `transitions`.
- `timeout` (optional) — `after` duration and the `on_expiry` decision used as a
  fallback when no human responds.

> The default `software-dev` topology uses only `auto` stages. `manual` is part of
> the schema seam so human gates can be added later (#7) without re-cutting it.

## Transitions

`transitions` maps an **event** to an **ordered list of rules**. Rules are
evaluated top-to-bottom; the **first match wins**.

```json
"signal-complete": [
  { "when": { "type": ["design"] },        "to": "done" },
  { "when": { "config": "test-cmd" },       "to": "validation" },
  { "when": { "type": ["chore", "spike"] }, "to": "@merge" },
  { "to": "review" }
]
```

A rule has:

| Key | Meaning |
| --- | --- |
| `when` | Guard object (omitted = always matches; use as the final fallback) |
| `to` | Destination stage, or a `@macro` / special destination |
| `then` | Optional list of named engine side-effects to run on transition |
| `reason` | Optional human-readable note (surfaced in logs / notifications) |

**Spawn is derived, not declared.** A rule only names a destination stage; the
executor comes from that stage's `working_stages` entry. So a loopback `to:
in-progress` spawns a coder automatically — one source of truth.

### Events
Worker/system signals: `new-task`, `signal-complete`, `validation-passed`,
`validation-failed`, `review-approved`, `review-rejected`, `merge-success`,
`merge-conflict`, `signal-blocked`, `signal-drift`. Human signals (manual
stages): `human:<decision>`.

This event set is **fixed** (the conductor maps each artifact `type`+`outcome` to
one of these). A non-software pack reuses them as generic stage-completion
channels rather than inventing its own — e.g. `marketing.json` maps its drafter to
`signal-complete`, its fact-checker to `validation-passed`/`failed`, its editor to
`review-approved`/`rejected`, and its publisher to `merge-success`. So
`merge-success` in a `shared-doc` pack means "the publish stage finished," not a git
merge. A pack omits the events it doesn't use (marketing has no `merge-conflict`).

### Guard vocabulary (`when`)

| Guard | Matches when | Decided by |
| --- | --- | --- |
| `deps: all-done` | every dependency has a card in `done` | engine |
| `type: [..]` | task type ∈ list (design/chore/spike/feature/test/…) | engine |
| `config: <key>` | a project config key is set & non-empty (e.g. `test-cmd`) | engine |
| `locks: free \| held` | file-lock state for the task's changed files | engine (git) |
| `last_artifact: <kind>:<outcome>` | most recent work artifact matches | engine |
| `count: { signal, gte }` | a signal has occurred ≥ N times (loop detection) | engine |
| `assess: <label>` | a conductor judgement call (hard-dependency, invalidation, scope, low-confidence) | conductor |

`assess` guards enumerate the *possible* outcomes and their destinations; the
conductor still makes the call by reading the artifact.

### Named side-effects (`then`)
The topology says *when* these fire; the *how* stays in the conductor's engine /
skills: `unblock-dependents`, `release-merge-pending`, `check-project-done`.

Some `then`-effects are **integration-specific**, not generic — e.g.
`release-merge-pending` only has meaning in a lock-based (`git`) integration. These
are marked with an `_integration` note in the topology and will be partitioned
behind the integration boundary (alongside `@merge`) in #5. Treat the inline
`then` list as the `git` model's definition until then.

### Special destinations
- `@<macro>` — expands to the rules in `integration_macros` (e.g. `@merge`).
- `@escalate` — write to `architect-inbox` (or, for a `manual` escalation stage, notify a human).
- `@stay` — no column change (e.g. minor drift).

## Integration macros

Integration-specific routing is quarantined here so the rest of the topology is
domain-agnostic. The `git` model's `@merge` splits on file-lock state:

```json
"@merge": {
  "rules": [
    { "when": { "locks": "free" }, "to": "merging" },
    { "to": "merge-pending" }
  ]
}
```

For `integration: shared-doc` or `none`, `@merge` collapses to a direct
`{ "to": "done" }` and the `merge-pending` / `merging` stages drop out.

## Integration adapters

The `integration` field selects an **integration adapter** — a sourced-bash file
`integrations/<integration>.sh`, mirroring the agent adapters in `adapters/*.sh`.
The adapter owns the parts of the integration model that live in bash (the rest —
which skills run, how `@merge`/transitions route — is already declared in the
topology itself). Contract:

Both functions return through **stdout** (one output convention for the contract):

- `integration_prepare_workspace <task_id> <worker_type> <title>` — ensure the
  task's workspace exists; print `<workspace>\t<branch>` (branch empty for
  branchless models). Called by `worker-spawn.sh`.
- `integration_locks` — print the resource ids currently locked by in-flight
  consolidations, one per line (empty ⇒ `@merge` stays `free`). Called by
  `task-locks.sh`.

Two adapters ship today. `integrations/git.sh`: worktree + `feature/…` branch per
task, file locks derived from the `merging` cards. `integrations/shared-doc.sh`:
a branchless model — each task's deliverable lives in one shared `deliverables/<id>`
folder that every stage-worker contributes to, the `publish` stage consolidates it
in place of a merge, and nothing is ever locked (`integration_locks` prints nothing).
The marketing pack (`topologies/marketing.json`) uses it. `swarm-start` fails fast
if a topology names an integration with no matching adapter; a `none` adapter (fully
independent work, no consolidation step) is still future work.
