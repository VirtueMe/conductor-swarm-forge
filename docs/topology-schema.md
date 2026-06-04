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
`{ "to": "done" }` and the `merge-pending` / `merging` stages drop out — handled
in #5.
