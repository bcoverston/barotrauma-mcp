# Agent Bridge — repo guide

A file-based control plane for Barotrauma: an in-game Lua mod writes game state to
disk and reads commands; an external agent does the reverse. See `docs/HANDOFF.md`
for the full design and `README.md` for install + the file contract.

## Layout
- `BarotraumaAgentBridge/` — the mod. Drop this folder into Barotrauma's `LocalMods/`.
  - `filelist.xml` — content package manifest (near-empty; LuaCs auto-runs `Lua/Autorun/`).
  - `Lua/Autorun/agent_bridge.lua` — the entire v0 mod: tick loop, JSON state writer,
    line-based command reader with dedup + ack.
- `docs/` — design notes (`HANDOFF.md`, verified API facts).

## The boundary (do not cross)
The **mod is the sole authority on game state and the only thing allowed to call
game APIs.** The agent never touches the game directly — it only reads/writes the
bridge files. New capabilities are **new verbs in the Lua**, not the agent reaching
into the game. Preserve this as the command set grows.

## Conventions
- Wrap every game-API call in `safe()` (pcall). Degrade to a default over throwing —
  a binding mismatch should surface as `oxygen: -1`, not a crashed round.
- State fields are **additive**. Changing/removing a field or the command grammar is
  breaking: bump `schemaVersion` in `state.json` and update the contract in `README.md`.
- Version-sensitive APIs (`Character.Speak` signature, `OxygenAvailable`/`Bloodloss`
  field names, `File.CreateDirectory`) must be verified against the installed LuaCs
  build. See `docs/API_VERIFICATION.md` once generated.

## Iterating in-game
The mod runs server-side (singleplayer uses an integrated server). Type `reloadlua`
in the LuaCs console to re-run scripts without restarting the round — use it for fast
iteration. `[AgentBridge] loaded.` in the console confirms load.

## Build phases (see HANDOFF §6)
- M0 prove the loop (in-game) · M1 agent driver · M2 `order` verb · M3 `console` verb (gated).
