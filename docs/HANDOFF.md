# Agent Bridge — Handoff & High-Level Design

**Status:** v0 scaffold drafted, not yet run in-game.
**Audience:** a Claude Code agent (or engineer driving one) picking this up to build, run, and extend.
**One-line goal:** the smallest Barotrauma mod that lets an external agent both *observe* game state and *issue commands*, with the simplest possible IPC.

---

## 1. What we're building and why

Barotrauma singleplayer puts you in command of a crew of AI bots. Coordinating
them under cascading failures (fire + hull breach + reactor + flooding at once)
is a real-time orchestration problem with a bad interface: you imperatively
click between characters. The idea here is to expose a clean machine-readable
surface so an external agent can read the situation and act on it.

**Design stance: minimal first.** v0 is not a smart agent and not a rich command
set. It is the *thinnest end-to-end loop that proves the architecture*: state
out, one trivial action in, acknowledged. Everything else is an extension on a
stable contract.

**Non-goals (v0):** networking, a real planner, multiplayer, rich orders,
performance tuning. Explicitly deferred.

---

## 2. Architecture

A **file-based control plane**. Two processes, two-to-three files, both sides poll.

```
   in-game (Lua mod, runs on the tick loop)        host machine (agent process)
   ┌─────────────────────────────┐                 ┌──────────────────────────┐
   │ every ~0.5s:                │   state.json ──►│ read state               │
   │   1. write state.json       │                 │ decide                   │
   │   2. read `command`         │ ◄── command ────│ write command            │
   │   3. run it once (deduped)  │                 │                          │
   │   4. write ack.json         │   ack.json   ──►│ confirm seq advanced     │
   └─────────────────────────────┘                 └──────────────────────────┘
```

Why files instead of a socket/HTTP/MCP server:
- **Zero infrastructure.** No ports, no auth, no lifecycle to manage alongside the game.
- **Crash-isolated.** Either side can die/restart; the other just keeps polling the last file.
- **Trivially inspectable.** You can `cat state.json` and hand-write a `command` to test.
- **Easy to upgrade later.** The contract is the files; the transport can become a socket or a real MCP server behind the same schema without touching game logic.

The mod is the authority on game state and the only thing allowed to call game
APIs. The agent never touches the game directly — it only reads/writes files.
This boundary is deliberate and should be preserved as the command set grows.

---

## 3. Runtime environment (verified facts — don't re-derive)

These were confirmed against the current (2026) LuaCsForBarotrauma docs.

- **Vanilla Barotrauma cannot run Lua.** The mod requires **LuaCsForBarotrauma**
  (community patch). The **client** patch is required for singleplayer.
- **Mod layout:** `LocalMods/<AnyName>/` containing:
  - `filelist.xml` — a valid (can be near-empty) content package manifest.
  - `Lua/Autorun/*.lua` — scripts here auto-run when the package is enabled.
- **Tick hook:** `Hook.Add("think", "<id>", fn)` fires every frame. Throttle with
  a frame counter (v0 uses 30 frames ≈ 0.5s).
- **Disk I/O:** a `File` class provides `File.Write(path, text)`, `File.Read(path)`,
  `File.Exists(path)`, and (build-dependent) `File.DirectoryExists` /
  `File.CreateDirectory`. **Paths are sandboxed to the game directory.** IO files
  land in `<Barotrauma>/AgentBridge/`.
- **State read APIs:** `Character.CharacterList` (iterate with `pairs`),
  `Character.Controlled`, and per-character fields including `Name`,
  `JobIdentifier`, `IsBot`, `IsOnPlayerTeam`, `IsHuman`, `IsDead`,
  `HealthPercentage`, `Bloodloss`, `OxygenAvailable`, `CurrentHull`.
- **Action APIs:** `Character.Speak(...)` (v0 uses this), and for the next phase
  `Character.SetOrder` / `Character.GetCurrentOrder` / `Order` / `OrderPrefab.Prefabs`.
- **Broad reach (later, gated):** Barotrauma console commands via
  `DebugConsole.ExecuteCommand`.

**Version-sensitive — verify on the installed build (all pcall-guarded so a
mismatch yields a default, not a crash):**
- exact `Character.Speak(...)` argument signature,
- whether `OxygenAvailable` / `Bloodloss` are the field names this build exposes,
- whether `File.CreateDirectory` exists (else create `AgentBridge/` by hand once).

---

## 4. File contract (the stable interface)

### `state.json` — mod → agent, rewritten every tick
```json
{
  "t": 132.44,
  "roundStarted": true,
  "controlled": "Camille Idris",
  "crew": [
    { "name": "Camille Idris", "job": "captain",  "isBot": false, "isControlled": true,
      "health": 100, "bleeding": 0,   "oxygen": 100, "dead": false, "room": "Command" },
    { "name": "Bjorn Vade",    "job": "engineer", "isBot": true,  "isControlled": false,
      "health": 71,  "bleeding": 2.1, "oxygen": 88,  "dead": false, "room": "Engine Room" }
  ]
}
```

### `command` — agent → mod, line-based (no JSON needed)
First token = verb; everything after the first line = argument.
```
say
Reactor is climbing — moving to engineering.
```
Deduped on exact file contents (each distinct command runs once). To repeat an
identical command, change the file at all (e.g. append `# 2`).

### `ack.json` — mod → agent, after each executed command
```json
{ "ok": true, "did": "say", "text": "Reactor is climbing...", "seq": 7 }
```
`seq` increments per executed command so the agent can confirm consumption.

**Compatibility rule:** state may gain fields freely (additive). Changing or
removing a field, or changing the command grammar, is a breaking change — bump a
`schemaVersion` in `state.json` when that happens.

---

## 5. Current status

Already drafted in this folder:
- `filelist.xml` — minimal content package.
- `Lua/Autorun/agent_bridge.lua` — full v0: tick loop, JSON state writer,
  line-based command reader with dedup + ack. Verbs: `ping`, `say`. Everything
  game-facing wrapped in `safe()` (pcall).
- `README.md` — install + contract + driving instructions.
- `CLAUDE.md` — protocol notes for an agent dropped in the IO folder *(create if absent)*.

Not done: never executed in-game; `order`/`console` verbs not implemented; no
agent-side driver written.

---

## 6. Build plan (phased, with acceptance criteria)

**M0 — Prove the loop (highest priority).**
Install LuaCs client patch, drop the mod in `LocalMods/`, enable, start a SP game.
- *Accept:* console prints `[AgentBridge] loaded.`; `AgentBridge/state.json`
  appears and updates; writing `ping` to `AgentBridge/command` yields
  `ack.json` with `did: "pong"`; writing a `say` command produces an in-game
  speech bubble.
- *Likely fixups:* `File` sandbox path, `Speak` signature, field names. Use the
  `oxygen: -1` style defaults to spot what didn't bind.

**M1 — Minimal agent driver.**
A standalone watcher process (any language) that polls `state.json`, prints a
human summary on change, and can write a `command`.
- *Accept:* round-trips a `say` end-to-end and reads back the matching `seq` from `ack.json`.

**M2 — `order` verb (the real capability).**
Implement issuing a crew order to a bot via `Character.SetOrder`. Start with one
or two concrete orders (e.g. operate reactor, fix leaks). Resolve a target
character by name or job from the command argument.
- *Accept:* `order` command visibly retasks the named bot; `ack` reports success;
  failures (unknown bot/order) ack `ok:false` with a reason.

**M3 — `console` verb, gated.**
Pass-through to `DebugConsole.ExecuteCommand`, behind an explicit enable flag,
for broad experimentation (`heal`, `spawnitem`, etc.).
- *Accept:* disabled by default; when enabled, a known command runs and is acked.

**Optional — symmetric JSON-in.**
Swap the line parser for a small JSON decoder so `command` is JSON like the
others. Bump `schemaVersion`. Everything else unchanged.

---

## 7. Working notes for the agent

- Preserve the **mod-is-sole-game-authority** boundary: new capabilities are new
  verbs in the Lua, not the agent reaching into the game.
- Keep new game calls inside `safe()`; prefer degrading to a default over throwing.
- When adding a state field, add it additively and update the README contract block.
- The mod runs server-side (singleplayer uses an integrated server); `reloadlua`
  in the console re-runs scripts without restarting the round — use it for fast iteration.

## 8. References (for verifying APIs)
- LuaCsForBarotrauma (repo): https://github.com/evilfactory/LuaCsForBarotrauma
- Lua docs home: https://evilfactory.github.io/LuaCsForBarotrauma/lua-docs/
- Getting started: https://evilfactory.github.io/LuaCsForBarotrauma/lua-docs/manual/getting-started/
- Hooks: https://evilfactory.github.io/LuaCsForBarotrauma/lua-docs/manual/how-to-use-hooks/
- Manual install (client patch): https://evilfactory.github.io/LuaCsForBarotrauma/lua-docs/manual/installing-lua-for-barotrauma-manually/
- API reference (Character, File, etc.): browse the "Code" section of the lua-docs site.
