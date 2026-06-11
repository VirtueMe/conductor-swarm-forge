# Workforce Schema

A **workforce** is the roster that staffs a topology: for every role the topology
spawns, it names the **agent adapter** that runs the role and the **launch-time
tuning** (model, reasoning effort, …) that adapter applies. A topology declares
*what* roles exist and *when* they run; the workforce declares *who* runs them and
*how* they are tuned. The two are swapped independently — `--topology marketing
--workforce marketing`.

Workforces live in `workforces/<name>.json` (JSON, zero-dependency, consistent
with `topologies/*.json`). The active workforce is selected with `--workforce
<name>` at `swarm-start` (default: `default`) and copied into the project as
`.conductor/workforce.json`, which `worker-spawn` reads to resolve each role.

The contract is enforced by `workforces/workforce.schema.json` (JSON Schema,
draft-07) in the `lint` workflow. This document is the human-readable companion.

## Top-level fields

| Field | Type | Purpose |
| --- | --- | --- |
| `name` | string | Workforce identifier; matches the file name and `--workforce` |
| `members` | object[] | One entry per role the active topology spawns |

No other top-level keys are allowed.

## Member

Each member binds one role to an adapter and, optionally, a tuning bag:

```json
{ "role": "architect", "adapter": "claude-code",
  "params": { "model": "claude-opus-4-8", "effort": "high" } }
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `role` | string | yes | Topology role this member runs. Must match a working-stage `role` in the active topology (`conductor` and `architect` are always present). |
| `adapter` | enum | yes | Agent backend: `claude-code` · `codex`. Resolves to `adapters/<adapter>.sh`; `swarm-start` fails fast if the file is missing. |
| `params` | object | no | Launch-time tuning bag (below). Omit it to run the adapter on its defaults. |

No other member keys are allowed — in particular there is **no `agent` field**
(it was never read; `params.model` carries the real intent).

## Params

`params` is a tuning bag the **adapter** translates into its own CLI flags. Only
the adapter knows how a key maps (`claude` takes `--effort`; `codex` takes `-c
model_reasoning_effort=…`), so translation lives in `adapter_launch`, not in the
caller. Keys the adapter doesn't recognise are ignored, so extra tuning options
can be added per pack without a schema change.

| Key | Type | claude-code | codex |
| --- | --- | --- | --- |
| `model` | string | `--model <model>` | `--model <model>` |
| `effort` | string | `--effort <level>` (`low`·`medium`·`high`·`xhigh`·`max`) | `-c model_reasoning_effort=<level>` (`minimal`·`low`·`medium`·`high`) |
| *(other)* | any | ignored | ignored |

The params object is passed to `adapter_launch` as a JSON string and parsed with
`python3` inside the adapter (consistent with how `worker-spawn` reads `adapter`),
so the workforce stays the single source of truth and the caller never builds
adapter-specific flags.

### Adapter-specific value sets

`effort` is a free string in the schema, not an enum, because the two adapters
accept **different** vocabularies — `claude-code` takes `low`·`medium`·`high`·
`xhigh`·`max`, `codex` takes `minimal`·`low`·`medium`·`high`. A global enum can't
express that split, so the schema only checks that `effort` is a string and each
**adapter** validates the value against its own closed set: an unsupported effort
fails fast at spawn (non-zero exit, clear message) rather than launching a process
that dies immediately in a detached tmux window.

`model`, by contrast, is an **open** set (aliases, full ids, fallbacks, 3rd-party
provider names) — the adapter can't enumerate it, so an unknown model id is left
to fail when the CLI starts. A key the active adapter doesn't implement at all is
never an error — it is silently dropped.

## Example

`workforces/default.json` — the software-dev roster, tuned per role:

```json
{
  "name": "default",
  "members": [
    { "role": "conductor", "adapter": "claude-code", "params": { "model": "claude-opus-4-8" } },
    { "role": "architect", "adapter": "claude-code", "params": { "model": "claude-opus-4-8" } },
    { "role": "coder",     "adapter": "claude-code", "params": { "model": "claude-sonnet-4-6" } },
    { "role": "validator", "adapter": "claude-code", "params": { "model": "claude-haiku-4-5-20251001" } },
    { "role": "reviewer",  "adapter": "claude-code", "params": { "model": "claude-opus-4-8" } },
    { "role": "merger",    "adapter": "claude-code", "params": { "model": "claude-sonnet-4-6" } }
  ]
}
```

Point a role at a different backend by changing its `adapter`; retune it by
changing its `params`. Neither touches the topology.
