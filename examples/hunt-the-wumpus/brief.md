# Hunt the Wumpus

A faithful implementation of Gregory Yob's 1973 text adventure, playable in the terminal.

## The cave

20 rooms arranged in a dodecahedron — each room connects to exactly 3 others. The map is fixed, not randomised. Rooms are numbered 1–20.

## Hazards

**Wumpus** — lurks in one room. Does not move unless the player shoots and misses, at which point it moves to a random adjacent room. If the player enters the Wumpus's room, or the Wumpus moves into the player's room, the player dies.

**Bottomless pits** — 2 pits in fixed random rooms. Entering a pit kills the player.

**Super bats** — 2 bat colonies in fixed random rooms. Entering a bat room teleports the player to a random room, which may itself contain a hazard.

Hazards and the player all start in different rooms.

## Player

Starts in a random hazard-free room with 5 crooked arrows.

Each turn the player can:
- **Move** to an adjacent room
- **Shoot** — specify a path of 1–5 rooms; if the path includes a non-adjacent room the arrow flies randomly instead

Running out of arrows is game over.

## Sensing

Before each turn the player is told what they can sense from their current room:

- *"I smell a wumpus"* — Wumpus is adjacent
- *"I feel a breeze"* — a pit is adjacent
- *"I hear bats"* — bats are adjacent

## Win / lose

| Event | Outcome |
|-------|---------|
| Arrow enters Wumpus room | Player wins |
| Player or Wumpus enters same room | Player dies |
| Player enters pit | Player dies |
| Arrow enters player's room | Player dies |
| No arrows left | Player loses |
| Bats grab player | Teleported, game continues |

After each game the player is asked if they want to play again.

## Constraints

- Terminal only — no GUI
- All game logic must be pure functions, side-effect-free
- Must have a test suite covering cave topology, sensing, shooting, bat transport, and win/lose conditions
