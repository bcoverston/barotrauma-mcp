# Agent Bridge (Barotrauma)

The smallest mod that lets an external agent both *observe* and *drive* a
Barotrauma game. The entire IPC layer is two files on disk.

```
   in-game (Lua mod)                         your machine (agent)
   ┌────────────────────┐                    ┌────────────────────┐
   │ every ~0.5s tick:  │   state.json  ───► │ read state          │
   │  • write state.json│                    │ decide              │
   │  • read command    │ ◄─── command  ──── │ write command       │
   │  • run it once     │   ack.json    ───► │ read ack            │
   │  • write ack.json  │                    │ loop                │
   └────────────────────┘                    └────────────────────┘
```

No sockets, no server. The mod polls; the agent polls. That's it.

---

## Prerequisites

This mod requires **LuaCsForBarotrauma** (the community modding patch — vanilla
Barotrauma can't run Lua). Install the **client** patch; client-side is required
for singleplayer.

- Steam Workshop: search "LuaCsForBarotrauma", subscribe, follow its client-side
  install steps (it patches the game's executable/DLLs).
- Or install manually: https://evilfactory.github.io/LuaCsForBarotrauma/lua-docs/manual/installing-lua-for-barotrauma-manually/

## Install this mod

1. Copy the `BarotraumaAgentBridge/` folder into your Barotrauma `LocalMods/`
   directory (rename the folder if you like — the name doesn't matter).
2. Launch the game, open the mod manager, enable **Agent Bridge**, restart.
3. Start a singleplayer game. In the LuaCs console you should see
   `[AgentBridge] loaded.` and then `ran '...'` lines as commands fire.
   (You can also type `reloadlua` in the console to re-run scripts after edits.)

The IO files appear in `LocalMods/AgentBridgeIO/` under the Barotrauma working
directory (on macOS, `Barotrauma.app/Contents/MacOS/`). Point your agent there.

> The LuaCs `File` API only permits **writes** under a few roots (`LocalMods/`,
> `WorkshopMods/`, the save folder) — writing to the game root itself throws, so
> the bridge lives under `LocalMods/`. The mod prints `write probe OK -> …` at
> load to confirm the path is writable; a `WRITE PROBE FAILED` line means pick a
> different root.

---

## The file contract

### `state.json` (mod → agent, rewritten every tick)

```json
{
  "t": 132.44,
  "roundStarted": true,
  "controlled": "Camille Idris",
  "crew": [
    {
      "name": "Camille Idris", "job": "captain", "isBot": false,
      "isControlled": true, "health": 100, "bleeding": 0,
      "oxygen": 100, "dead": false, "room": "Command", "order": "none"
    },
    {
      "name": "Bjorn Vade", "job": "engineer", "isBot": true,
      "isControlled": false, "health": 71, "bleeding": 2.1,
      "oxygen": 88, "dead": false, "room": "Engine Room", "order": "operatereactor"
    }
  ]
}
```

### `command` (agent → mod, line-based, no JSON needed)

First token is the verb; everything after the first line is the argument.

```
say
Reactor is climbing — moving to engineering.
```

Deduped on exact file contents: the mod runs each distinct command once. To
re-issue an identical command, change the file at all (e.g. append `# 2`).

Verbs:
- `ping` — liveness check; acks `pong`.
- `say <text>` — the currently controlled character speaks `<text>` in game.
- `order <orderId> <bot name|job>` — issue a crew order to a bot. The order id
  is the first token; the rest of the line is the target, resolved by name or
  job. Target-less orders (`fixleaks`, `extinguishfires`, …) let the bot AI find
  its own target; `operatereactor` is item-targeted automatically. Acks
  `{ok, did:"order", order, target}`; unknown order/target acks `ok:false`.

### `ack.json` (mod → agent, after each command)

```json
{ "ok": true, "did": "say", "text": "Reactor is climbing...", "seq": 7 }
```

`seq` increments per executed command, so the agent can confirm its last write
was consumed.

---

## Driving it from Claude Code

Drop a Claude Code agent in the `AgentBridge/` folder (a `CLAUDE.md` with the
protocol is included) and the loop is just:

1. Read `state.json`.
2. Reason about the crew/sub.
3. Write a `command` file.
4. Read `ack.json` to confirm `seq` advanced.
5. Repeat.

A bare-bones watcher in any language is ~15 lines: poll `state.json`, on change
print it / decide, write `command`. The point of v0 is that the *contract* is
dead simple, so you can grow the agent without touching the mod much.

---

## Extending further

- **`order`** — ✅ implemented (`Character.SetOrder` + `Order` /
  `OrderPrefab.Prefabs`, with `force=true` to bypass the hearing-gate). Each crew
  member's current order is also surfaced in `state.json` as an additive `order`
  field. See `docs/API_VERIFICATION.md` §4 for the verified API and order ids.
- **`console <cmd>`** — the next verb: run a Barotrauma console command for broad
  reach (`heal`, `spawnitem`, etc.) via `DebugConsole.ExecuteCommand`, gated
  behind a flag — powerful and easy to footgun.

If you'd rather have a symmetric JSON-in contract, swap the line parser in
`readAndRunCommand()` for a small JSON decoder; the rest is unchanged.

Two things worth verifying against your installed LuaCs build, since method
bodies vary slightly by version: the exact `Character.Speak(...)` signature and
whether `OxygenAvailable` / `Bloodloss` are the field names your version
exposes. Everything is pcall-guarded, so a mismatch shows up as a default value
(e.g. `oxygen: -1`) rather than a crash — easy to spot and fix.
