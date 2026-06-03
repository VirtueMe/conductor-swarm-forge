# Skill: Architect — Decompose Project Brief

You have received a project brief. Decompose it into tasks the swarm can execute.

## Steps

### 1. Understand the domain

Read the brief fully. Identify:
- The core domain model (entities, relationships, rules)
- The distinct feature areas
- External interfaces (CLI, API, UI)
- What needs testing

### 2. Build the dependency graph mentally

Before creating any tasks, map out the dependency graph:
- What must exist before anything else can start? (usually the domain model)
- What features are independent of each other? (can run in parallel)
- What integrates multiple features? (must wait for all of them)
- What tests verify which features?

Write this out as a comment to yourself before calling any scripts.

### 3. Create tasks in dependency order

Start from the roots (no dependencies) and work outward. Use the lowest IDs for foundational work — this makes the kanban easier to read.

**Task types:**
- `design` — architectural decisions, data models, interface definitions; no coder needed, you write the content directly in the description
- `feature` — a discrete piece of implementable behaviour
- `test` — test suite for one or more features
- `chore` — setup, tooling, configuration
- `spike` — exploratory work with an unknown outcome; may generate new tasks

**Granularity rule:** a task should be completable in one focused coder session. If a feature has five distinct behaviours, split it into five tasks.

Example for Hunt the Wumpus:
```bash
# Foundation — no dependencies
task-create.sh --title "Define game model" --type design \
  --description "Define: Room (id, connections[]), Player (room, arrows), Wumpus (room), Hazard (type, room). Adjacency is bidirectional. Max 3 connections per room."

# Parallel implementation — all depend only on the model
task-create.sh --title "Implement room graph" --type feature --depends-on "0001" \
  --description "Build 20-room dodecahedron. Each room connected to exactly 3 others. Implement adjacency lookup."

task-create.sh --title "Implement player state" --type feature --depends-on "0001" \
  --description "Player position, arrow count (starts at 5), move and shoot actions."

task-create.sh --title "Implement Wumpus behaviour" --type feature --depends-on "0001" \
  --description "Wumpus starts in random room. Moves to random adjacent room when player shoots and misses."

# Integration — depends on parallel features
task-create.sh --title "Implement game loop" --type feature --depends-on "0002,0003,0004" \
  --description "Turn sequence: sense hazards, prompt action, resolve outcome, check win/lose."
```

### 4. Verify the graph

After creating all tasks, run:
```bash
task-list.sh
```

Check:
- Every foundational task is in `backlog` or `ready` (no dangling dependencies)
- The dependency IDs in each task actually exist
- Parallel groups are correct — tasks that could conflict share a dependency
- No task is doing too much

### 5. Announce completion

Write a brief summary of what you created and why the dependency structure is as it is. This becomes the project record.
