# Design: Workflow as Topology

**Status:** proposal · **Date:** 2026-06-04

## Summary

Today Conductor Swarm Forge is a *software-development* swarm. Its orchestration
core — task graph, kanban, signal routing, swappable workforce — is
domain-agnostic, but the **workflow** (the stages a task moves through and the
roles attached to them) is hardcoded across bash scripts and conductor skills.

This document argues that **workflow is the first-class structure of the system**,
that roles are *bound to* its stages rather than independent of them, and that
lifting the workflow into a single declarative definition turns "a dev swarm" into
"a swarm engine" usable for other domains (e.g. a marketing strategy team).

## The insight: roles are derived from the workflow

The worker roles map 1:1 onto the working kanban stages:

| Workflow stage | Role bound to it |
| --- | --- |
| in-progress | coder |
| validation | validator |
| review | reviewer |
| merging | merger |
| backlog / ready / merge-pending / done | conductor-managed (no worker) |

A `reviewer` exists *because* there is a review stage; a `merger` exists *because*
there is a merging stage. Redefine the workflow and the roles fall out of it. So
the workflow is the spine; roles hang off its vertebrae. It is not merely as
important as roles — it is the more primary of the two.

## A workflow is two things, not one

1. **Nodes** — the stages / kanban columns.
2. **Edges** — the transition rules, including failure loopbacks:
   `complete → forward`, `review-rejected → coder`, `merge-conflict → coder`,
   `validation-failed → coder`, `blocked → architect-inbox`.

## Why it doesn't feel first-class today

The topology is real and load-bearing, but **smeared across three places**, with
no single declarative artifact:

| Concern | Lives in | Hardcoded as |
| --- | --- | --- |
| Stages (nodes) | `scripts/swarm-start.sh` | the `mkdir` of `kanban/<column>` dirs |
| Roles per stage | `scripts/worker-spawn.sh` | `VALID_TYPES="coder validator reviewer merger"` + `select_skill()` |
| Transitions (edges) | `skills/conductor/on-*.md` | one skill per event |
| Integration model | coder/merger skills + `worker-spawn.sh` | git worktree + branch + rebase/merge |

Each component keeps its own implicit copy of the workflow, which is why changing
it means editing bash, role lists, and skills in lockstep.

## Proposal: one declarative topology

Lift the state machine into a single definition that roles, kanban, and conductor
routing all *read from* instead of re-encoding:

```yaml
stages: [backlog, ready, draft, fact-check, edit, review, publish, done]

working_stages:          # stage -> role that executes it
  draft:      drafter
  fact-check: fact-checker
  edit:       editor
  review:     reviewer

transitions:             # signal -> destination (edges, incl. loopbacks)
  complete:        next-stage
  review-rejected: edit
  blocked:         architect-inbox

integration: git | shared-doc | none
```

- **Roles** come from `working_stages` instead of `VALID_TYPES`.
- **Kanban columns** come from `stages` instead of hardcoded `mkdir`s.
- **Conductor routing** reads `transitions` instead of one skill per hardcoded event.
- **Skills** stay per-role/per-event playbooks, selected by the same
  history-aware logic — just keyed off the declared roles.

## The integration model is the third axis

The current "merge" semantics are git-specific: branches, worktrees, rebase, and
conflict resolution (`skills/coder/on-conflict.md`). Other domains have no merge
concept. So a topology must also declare *how finished work is consolidated*:

- `git` — branch per task, merger rebases onto main, coder resolves conflicts (today's behavior)
- `shared-doc` — deliverables land in a shared folder/doc; consolidation replaces merge; no conflict stage
- `none` — work is independent; "done" needs no integration step

This is why "a marketing workforce.json" is not enough — the unit is a **domain
pack**: roles + workflow stages + transitions + integration model + a skill set.

## Migration sketch (not yet scheduled)

1. Introduce a topology file; default it to today's dev workflow (no behavior change).
2. De-hardcode stages in `swarm-start.sh` (read `stages`).
3. De-hardcode roles in `worker-spawn.sh` (read `working_stages`; drop `VALID_TYPES`).
4. Make conductor routing read `transitions` rather than one skill per event.
5. Abstract the integration model so `git` is one option, not an assumption.
6. Ship a second domain pack (e.g. marketing) to prove the topology is real.

## Lineage

This is the same realization behind Uncle Bob's
[swarm-forge](https://github.com/unclebob/swarm-forge): *configuration-driven
topology rather than a fixed set of roles.* See the README's
"Credit & inspiration" section.
