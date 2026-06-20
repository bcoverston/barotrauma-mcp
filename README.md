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
  ],
  "sub": {
    "fires":    [{ "room": "Engine Room", "size": 23.4 }],
    "leaks":    [{ "room": "Engine Room", "open": 0.62, "toOcean": true }],
    "flooding": [{ "room": "Engine Room", "pct": 47 }],
    "reactor":  { "temp": 78, "meltdown": false, "fissionRate": 80, "turbineOutput": 65,
                  "load": 4200, "output": 4180, "fuel": 88, "autoTemp": true, "powerOn": true }
  }
}
```

The `sub` block (additive) reports player-sub hazards: `fires` (per room; `size` =
fire spread), `leaks` (`open` 0–1; `toOcean` = hull breach to sea vs internal gap),
`flooding` (`pct` 0–100 per room), and `reactor` (`temp` 0–100; derived `meltdown`;
`fissionRate`/`turbineOutput`/`load`/`output`/`fuel`; `autoTemp`/`powerOn`). Empty
arrays mean "none"; `sub` and `reactor` are absent when there's no round/sub/reactor.

### `command` (agent → mod, line-based, no JSON needed)

First token is the verb; everything after the first line is the argument.

```
say
Reactor is climbing — moving to engineering.
```

Deduped on exact file contents: the mod runs each distinct command once. To
re-issue an identical command, change the file — drivers prepend an optional
`@<nonce>` first line (which the mod strips before parsing the verb) so repeated
`say`/`order` commands aren't swallowed.

Verbs:
- `ping` — liveness check; acks `pong`.
- `say <text>` — the currently controlled character speaks `<text>` in game.
- `order <orderId> <bot name|job>` — issue a crew order to a bot. The order id
  is the first token; the rest of the line is the target, resolved by name or
  job. Target-less orders (`fixleaks`, `extinguishfires`, …) let the bot AI find
  its own target; `operatereactor` is item-targeted automatically. Acks
  `{ok, did:"order", order, target}`; unknown order/target acks `ok:false`.
- `console <cmd>` — gated passthrough to the debug console (`spawnitem`, `fire`,
  …). Disabled unless the operator creates `LocalMods/AgentBridgeIO/console.enabled`.
  The console returns void, so an `ok` ack means "dispatched", not "succeeded".
- `report <breach|fire|intruders>` — crew-wide report (the in-game "Report …"
  buttons): binds no specific bot — the nearest suitable idle bot self-assigns,
  routing more surgically than a blanket order. Reporter is the controlled
  character, reporting from its current room. Acks `{ok, did, report, reporter}`.
- `control <name|job>` — switch the locally-controlled character to a crew member
  (e.g. `control captain`). Direct `Character.Controlled` set; can't take a dead
  character. Acks `{ok, did, target}`.

### `ack.json` (mod → agent, after each command)

```json
{ "ok": true, "did": "say", "text": "Reactor is climbing...", "seq": 7 }
```

`seq` increments per executed command, so the agent can confirm its last write
was consumed.

---

## Driving it

### MCP server (recommended)

`agent/src/mcp-server.js` exposes the bridge to Claude as native MCP tools, so an
agent pilots the crew with tool calls instead of poking files:

- `get_state` — the crew/sub snapshot (with a `_bridge.live` flag).
- `ping` — liveness; expects `pong`.
- `say <text>` — the controlled character speaks.
- `order <orderId> <name|job>` — retask a bot.

Register it (the bridge dir default already points at the macOS install):

```sh
claude mcp add barotrauma -- node "$PWD/agent/src/mcp-server.js"   # Claude Code
```

or in Claude Desktop's `claude_desktop_config.json`:

```json
{ "mcpServers": { "barotrauma": { "command": "node",
    "args": ["/abs/path/to/agent/src/mcp-server.js"] } } }
```

`npm install` in `agent/` first (deps: `@modelcontextprotocol/sdk`, `zod`).

### CLI watcher (no MCP)

`agent/src/watch.js` is a dependency-free poller over the same contract — `watch`
prints the crew on change; `ping`/`say`/`order` round-trip a command. Good for a
first end-to-end proof or scripting. The *contract* is just the files, so either
driver works without touching the mod.

---

## Extending further

- **`order`** — ✅ implemented (`Character.SetOrder` + `Order` /
  `OrderPrefab.Prefabs`, with `force=true` to bypass the hearing-gate). Each crew
  member's current order is also surfaced in `state.json` as an additive `order`
  field. See `docs/API_VERIFICATION.md` §4 for the verified API and order ids.
- **`console`** — ✅ implemented: gated passthrough to `Game.ExecuteCommand` (LuaCs's
  console wrapper) for `spawnitem`, `fire`, `heal`, … Off unless the operator creates
  the sentinel `LocalMods/AgentBridgeIO/console.enabled` — no bridge verb writes it, so
  the agent can't self-enable. Returns void, so `ok` means dispatched, not succeeded;
  cheat-gated commands need a prior `console enablecheats`.

If you'd rather have a symmetric JSON-in contract, swap the line parser in
`readAndRunCommand()` for a small JSON decoder; the rest is unchanged.

Two things worth verifying against your installed LuaCs build, since method
bodies vary slightly by version: the exact `Character.Speak(...)` signature and
whether `OxygenAvailable` / `Bloodloss` are the field names your version
exposes. Everything is pcall-guarded, so a mismatch shows up as a default value
(e.g. `oxygen: -1`) rather than a crash — easy to spot and fix.
