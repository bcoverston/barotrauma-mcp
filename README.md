# Agent Bridge (Barotrauma)

Let an external LLM agent **observe and command a Barotrauma submarine crew** —
coordinating the AI bots through cascading failures (fire + hull breach + reactor
+ flooding) instead of frantically clicking between them.

An in-game [LuaCsForBarotrauma](https://github.com/evilfactory/LuaCsForBarotrauma)
mod is the sole game authority: it writes game state to disk and runs a small set
of commands. An [MCP server](#driving-it) exposes that to Claude as native tools
(`get_state`, `say`, `order`, `report`, `control`, gated `console`), and an
operator-set **autonomy level** caps what the agent may do. The whole transport is
a few files on disk — no sockets, no server:

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

The mod polls; the agent polls. That's it — trivially inspectable (`cat
state.json`), crash-isolated (either side can restart), and swappable for a socket
later behind the same contract.

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
2. Launch the game, open the mod manager, enable **both LuaCsForBarotrauma and
   Agent Bridge**, restart.
3. Start a singleplayer game. In the LuaCs console (F3) you should see
   `[AgentBridge] loaded.` and then `ran '...'` lines as commands fire.
   (Type `cl_reloadluacs` in the console to re-run scripts after edits — fast
   iteration without restarting the round.)

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
  "schemaVersion": 1,
  "t": 132.44,
  "roundStarted": true,
  "controlled": "Camille Idris",
  "autonomy": { "level": "coordinate", "allows": ["ping", "say", "order", "report", "control"] },
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
    "fires":    [{ "room": "Engine Room", "count": 2 }],
    "leaks":    [{ "room": "Engine Room", "open": 0.62, "toOcean": true }],
    "flooding": [{ "room": "Engine Room", "pct": 47 }],
    "reactor":  { "temp": 78, "meltdown": false, "fissionRate": 80, "turbineOutput": 65,
                  "output": 4180, "fuel": 88, "autoTemp": true, "powerOn": true }
  }
}
```

The `sub` block (additive) reports player-sub hazards: `fires` (per room; `count` =
number of fire sources), `leaks` (`open` 0–1; `toOcean` = hull breach to sea vs internal gap),
`flooding` (`pct` 0–100 per room), and `reactor` (`temp` 0–100; derived `meltdown`;
`fissionRate`/`turbineOutput`/`output`/`fuel`; `autoTemp`/`powerOn`). Empty
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
- `console <cmd>` — gated passthrough to the debug console (`spawnitem`, `fixwalls`,
  `heal`, …). Disabled unless the operator creates `LocalMods/AgentBridgeIO/console.enabled`.
  The console returns void, so an `ok` ack means "dispatched", not "succeeded".
- `report <breach|fire|intruders>` — crew-wide report (the in-game "Report …"
  buttons): binds no specific bot — the nearest suitable idle bot self-assigns,
  routing more surgically than a blanket order. Reporter is the controlled
  character, reporting from its current room. Acks `{ok, did, report, reporter}`.
- `control <name|job>` — switch the locally-controlled character to a crew member
  (e.g. `control captain`). Direct `Character.Controlled` set; can't take a dead
  character. Acks `{ok, did, target}`.

**Verbs are gated by an autonomy level** (`observe` → `advise` → `coordinate` →
`pilot` → `override`), set by the operator-owned file `LocalMods/AgentBridgeIO/autonomy`
— the agent can't raise its own ceiling. Default (no file) is `observe` (read-only);
a verb above the level acks `ok:false`. The current level + allowed verbs are in
`state.autonomy`. Full design: [`docs/AUTONOMY.md`](docs/AUTONOMY.md).

### `ack.json` (mod → agent, after each command)

```json
{ "ok": true, "did": "say", "text": "Reactor is climbing...", "seq": 7 }
```

`seq` increments per executed command, so the agent can confirm its last write
was consumed.

---

## Scope

The bridge drives **in-round crew orchestration** — the moment-to-moment order /
report system the game already has. It does **not** touch campaign / roster
management.

- **In scope:** assigning live tasks to the crew (`order` / `report`, via
  `Character.SetOrder` and the report system) — operate the reactor, fix leaks,
  extinguish fires, and so on. You pick the task and target; the bots' AI does the
  work, and their job/skill determines how well. Plus reading full crew + sub
  state, talking, body-swapping (`control`), and the gated `console`.
- **Out of scope:** hiring/firing, the crew roster, or changing a character's job,
  skills, or talents — that's between-rounds campaign management, a separate game
  system. The bridge only *reads* each member's `job`, to target orders by role.

In short: a **crisis co-pilot**, not a campaign manager.

## Driving it

### MCP server (recommended)

`agent/src/mcp-server.js` exposes the bridge to Claude as native MCP tools, so an
agent pilots the crew with tool calls instead of poking files:

- `get_state` — the crew/sub snapshot (with a `_bridge.live` flag).
- `ping` — liveness; expects `pong`.
- `say <text>` — the controlled character speaks.
- `order <orderId> <name|job>` — retask a bot (assigned to that bot).
- `report <breach|fire|intruders>` — crew-wide report; the nearest idle bot self-assigns.
- `control <name|job>` — take control of a crew member (e.g. the captain).
- `console <cmd>` — gated debug-console passthrough (`spawnitem`, `fixwalls`, …).

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

## Layout

- `BarotraumaAgentBridge/` — the mod; drop it into Barotrauma's `LocalMods/`. The
  whole thing is `Lua/Autorun/agent_bridge.lua`.
- `agent/` — host-side driver (Node, ESM): `src/bridge.js` (the file contract),
  `src/watch.js` (CLI watcher), `src/mcp-server.js` (MCP server).
- `docs/` — `HANDOFF.md` (original design), `API_VERIFICATION.md` (verified LuaCs
  APIs), `AUTONOMY.md` (the autonomy ladder).

## Status

All seven capabilities are implemented and verified against a live round
(LuaCsForBarotrauma, 2026 build): `get_state` (crew + sub hazards), `ping`,
`say`, `order`, `report`, `control`, and the gated `console`, behind the
operator-set autonomy ladder. Every game-API call is `pcall`-guarded, so a version
mismatch degrades to a default (e.g. `oxygen: -1`) rather than crashing the round.
The verified API surface — `Speak` signature, field names, order ids, hazard reads
— is documented in `docs/API_VERIFICATION.md`.

The extension rule: new capabilities are **new verbs in the Lua**, never the agent
reaching into the game — preserve that boundary as the command set grows.

## Roadmap

The autonomy ladder is built through level `coordinate`; the higher tiers and a few
extras are specced but unbuilt (details in [`docs/AUTONOMY.md`](docs/AUTONOMY.md)):

- **Richer sensing** — additive `state.json` blocks, available at any level: `nav`
  (depth/heading/speed), `mission` (objective/state), and `threats` (hostile
  creatures near the sub).
- **`pilot` verbs** (autonomy level `pilot`): `steer`, `setdepth`, `reactor` — fly
  the sub itself, not just direct the crew. Need the verify-against-source pass first.
- **Per-fire size** — fires report a `count` today; a per-fire size needs the CLR-list
  enumerator form that `pairs`/indexing don't provide in this MoonSharp build.
- **Symmetric JSON-in** — swap the line-based `command` parser for a JSON decoder.
- **Cross-platform paths** — the bridge-dir default targets macOS Steam; set
  `BRIDGE_DIR` for Windows/Linux (the contract is identical).
- **Autonomous driver loop** — the agent acts per-turn today; a continuous
  `get_state → decide → act` loop would make it self-driving (the MCP server
  already supports it).

## License

MIT — see [LICENSE](LICENSE).
