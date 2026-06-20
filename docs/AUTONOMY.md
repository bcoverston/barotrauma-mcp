# Autonomy levels

The agent's authority over the game is capped by an **autonomy level** enforced
*in the mod*. This is the ceiling on what the agent may **do**; it never limits
what it may **see** (observation is low-risk and always available).

> Two orthogonal knobs. **Capability ceiling** (this doc) — enforced in the mod.
> **Drive cadence** — agent-side: manual per-turn vs. a continuous
> `get_state → decide → act` loop. The mod doesn't care about cadence; the
> ceiling caps whatever the loop attempts.

## The ladder

Each level is a superset of the one below.

| Lvl | Name         | Adds (verbs)                 | The agent can…                                            | Risk |
|-----|--------------|------------------------------|-----------------------------------------------------------|------|
| 0   | `observe`    | — (`get_state`, `ping`)      | Pure telemetry. No game effect.                           | none |
| 1   | `advise`     | `say`                        | Talk to / narrate for the crew.                           | minimal |
| 2   | `coordinate` | `order`, `report`, `control` | Retask bots, report hazards, switch controlled character. | medium — directs crew AI |
| 3   | `pilot`      | `steer`, `setdepth`, `reactor` *(planned)* | Fly the sub itself — heading / depth / reactor. | high — direct control |
| 4   | `override`   | `console`                    | Arbitrary debug console (spawn/heal/fixwalls/…).          | footgun |

`get_state` (reading `state.json`) is always available — the ladder gates
*commands*, not *state*. The additive `nav` / `mission` / `threats` sense blocks
(see Roadmap) are likewise available at every level.

## Enforcement — the agent cannot escalate itself

- The level is read live from an **operator-owned file**
  `LocalMods/AgentBridgeIO/autonomy`, whose contents are a level name, e.g.:
  ```
  coordinate
  ```
- **No bridge verb writes files**, so the agent can't raise (or lower) its own
  ceiling — only the operator can, by editing that file. No reload needed; the
  mod re-reads it on every command and tick.
- **Absent or unrecognized file ⇒ `observe`** (the safest tier).
- Level changes are **operator-only**. The agent doesn't get a verb to change the
  level, not even to de-escalate — the file is the single source of truth.

A command above the current level is refused with a clear ack:

```json
{ "ok": false, "error": "'order' needs autonomy level 'coordinate' (current 'observe')", "seq": 12, "level": "observe" }
```

Every command ack carries the acting `level` (audit trail), and `state.json`
surfaces the current level + the verbs it permits:

```json
"autonomy": { "level": "coordinate", "allows": ["ping", "say", "order", "report", "control"] }
```

So an agent reads `state.autonomy` first, then only attempts what it's allowed.

### `console` is double-gated

`console` requires level `override` **and** its own
`LocalMods/AgentBridgeIO/console.enabled` sentinel (unchanged). Both must be
present — belt and suspenders for the footgun tier.

## Roadmap (each phase ships independently)

1. **Phase 1 — the ladder itself (done).** The level file, the verb gate, the
   `autonomy` state block, and `level` on acks. No new game APIs; it formalizes
   authority over the verbs that already exist (`observe`/`advise`/`coordinate`/
   `override`) and folds `console` into the top tier.
2. **Phase 2 — richer sensing (planned).** Additive, low-risk state blocks,
   available at every level:
   - `nav` — depth, position, heading, speed (`Submarine.MainSub` + Steering).
   - `mission` — name / type / objective / state (`Game.GameSession.Mission`).
   - `threats` — hostile, non-team characters near the sub (room/distance/health)
     from `Character.CharacterList` filtered to `not IsOnPlayerTeam`.
3. **Phase 3 — the `pilot` verbs (planned).** `steer <heading|coord>`,
   `setdepth <m>`, `reactor <auto|fission%>`, operating the Steering/Reactor
   components directly. These make level 3 meaningful, and (like orders, console,
   and hazard reads) need the verify-against-source pass before implementation.

## Conventions

- All game-API reads stay `safe()`-wrapped; a binding mismatch degrades to a
  default, never a crash.
- The level file and `console.enabled` are **runtime/operator state** — they live
  in the game's `LocalMods/AgentBridgeIO/`, not in this repo.
- Adding the `autonomy` block + `schemaVersion` is reflected by `schemaVersion: 1`
  in `state.json`.
