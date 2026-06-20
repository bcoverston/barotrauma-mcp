#!/usr/bin/env node
// MCP server over the Agent Bridge file contract: exposes get_state / ping /
// say / order as MCP tools so an agent (Claude Desktop / Claude Code) can pilot
// the crew directly. Transport is stdio; all bridge access reuses bridge.js.
//
// IMPORTANT: stdout is the JSON-RPC channel — never console.log here (use
// console.error for diagnostics).
import { existsSync, statSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  BRIDGE_DIR, STATE_PATH, readState, readAck, writeCommand, waitForAck,
} from "./bridge.js";

const STALE_MS = 3000; // state.json older than this ⇒ the mod likely isn't ticking

const stateAgeMs = () =>
  existsSync(STATE_PATH) ? Date.now() - statSync(STATE_PATH).mtimeMs : null;

const text = (v) => ({
  content: [{ type: "text", text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }],
});
const fail = (msg) => ({ content: [{ type: "text", text: msg }], isError: true });

// Write a command, wait for its ack, and map the result to an MCP tool result.
// Guards on state freshness first so "mod not running" is a clear error, not a
// silent 4s timeout.
async function sendCommand(verb, arg) {
  const age = stateAgeMs();
  if (age === null) {
    return fail(`No state.json at ${BRIDGE_DIR}. Enable the mod and start a round.`);
  }
  if (age > STALE_MS) {
    return fail(`state.json is ${Math.round(age)}ms stale — the mod isn't ticking (game paused or no round?).`);
  }
  const before = readAck()?.seq ?? 0;
  writeCommand(verb, arg);
  const ack = await waitForAck(before);
  if (!ack) return fail(`No ack within timeout for '${verb}'. Is the round running and the mod loaded?`);
  return ack.ok ? text(ack) : fail(`'${verb}' failed: ${ack.error ?? "unknown"} (seq ${ack.seq}).`);
}

const server = new McpServer({ name: "barotrauma-agent-bridge", version: "0.1.0" });

server.registerTool("get_state", {
  title: "Get game state",
  description:
    "Read the current Barotrauma crew/sub snapshot: each crew member's name, job, " +
    "health, oxygen, bleeding, room, current order, and which one is player-controlled. " +
    "Call this before deciding what to do. Includes a _bridge.live flag (false ⇒ the mod " +
    "isn't currently ticking).",
  inputSchema: {},
}, async () => {
  const age = stateAgeMs();
  if (age === null) return fail(`No state.json at ${BRIDGE_DIR}. Enable the mod and start a round.`);
  const state = readState();
  if (!state) return fail("state.json present but unreadable (mid-write) — try again.");
  return text({ ...state, _bridge: { ageMs: Math.round(age), live: age <= STALE_MS } });
});

server.registerTool("ping", {
  title: "Ping the mod",
  description: "Liveness check — sends a ping and expects a 'pong' ack from the in-game mod.",
  inputSchema: {},
}, async () => sendCommand("ping", ""));

server.registerTool("say", {
  title: "Speak as the controlled character",
  description: "Make the currently player-controlled character say a line in-game (crew chat).",
  inputSchema: { text: z.string().min(1).describe("The line to speak in-game.") },
}, async ({ text: line }) => sendCommand("say", line));

const ORDER_IDS =
  "operatereactor, fixleaks, extinguishfires, fightintruders, steer, repairmechanical, " +
  "repairelectrical, repairsystems, cleanupitems, reportbrokendevices, follow, wait, " +
  "dismissed (clears the bot's order)";
server.registerTool("order", {
  title: "Order a crew bot",
  description:
    "Issue a crew order to a bot, resolved by name or job. `operatereactor` auto-targets the " +
    "reactor; most others (fixleaks, extinguishfires, …) are target-less — the bot AI finds its " +
    `own target. Use \`dismissed\` to clear an order. Known order ids: ${ORDER_IDS}.`,
  inputSchema: {
    order: z.string().min(1).describe("Order id, e.g. operatereactor, fixleaks, dismissed."),
    target: z.string().min(1).describe("Bot to order: a crew member's name (e.g. 'Keneth') or job (e.g. 'engineer')."),
  },
}, async ({ order, target }) => sendCommand("order", `${order} ${target}`));

server.registerTool("console", {
  title: "Run a debug console command (gated)",
  description:
    "Passthrough to Barotrauma's debug console (e.g. `spawnitem crowbar cursor`, `fire`, " +
    "`heal`). GATED: the mod refuses this unless the operator has created the sentinel file " +
    "LocalMods/AgentBridgeIO/console.enabled. The console returns no value, so a successful ack " +
    "means the command was dispatched without error, not that it took effect. Powerful and easy " +
    "to footgun — prefer say/order for normal play.",
  inputSchema: {
    command: z.string().min(1).describe("Full console command line, e.g. 'spawnitem crowbar cursor'."),
  },
}, async ({ command }) => sendCommand("console", command));

server.registerTool("report", {
  title: "Report a problem to the crew",
  description:
    "Issue a crew-wide REPORT (like the in-game 'Report …' buttons). Unlike `order`, it binds no " +
    "specific bot — the nearest suitable idle bot self-assigns, which routes more surgically than a " +
    "blanket order. The reporter is the player-controlled character (must be inside the sub). " +
    "what ∈ breach | fire | intruders (aliases for reportbreach / reportfire / reportintruders).",
  inputSchema: {
    what: z.string().min(1).describe("What to report: breach (hull/water), fire, or intruders."),
  },
}, async ({ what }) => sendCommand("report", what));

server.registerTool("control", {
  title: "Take control of a crew member",
  description:
    "Switch the locally-controlled character to a named or job-resolved crew member (e.g. take the " +
    "captain). Afterwards `say` speaks as them and `report` reports from their location. Resolves by " +
    "name (e.g. 'Sara') or job (e.g. 'captain'); can't control a dead character.",
  inputSchema: {
    target: z.string().min(1).describe("Crew member to control: a name or job."),
  },
}, async ({ target }) => sendCommand("control", target));

await server.connect(new StdioServerTransport());
