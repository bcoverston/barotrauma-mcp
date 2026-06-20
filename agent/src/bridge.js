// Core access to the file-based control plane. The MCP server (next phase)
// wraps this same module, so all knowledge of the on-disk contract lives here.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// The mod writes its IO folder under LocalMods/ (the LuaCs File sandbox blocks
// game-root writes). On macOS Steam the game root is the .app's MacOS folder,
// so the files land at .../Contents/MacOS/LocalMods/AgentBridgeIO. Unverified
// until M0 — override with BRIDGE_DIR once the real path is confirmed in-game.
const DEFAULT_BRIDGE_DIR = join(
  homedir(),
  "Library/Application Support/Steam/steamapps/common/Barotrauma",
  "Barotrauma.app/Contents/MacOS/LocalMods/AgentBridgeIO",
);

export const BRIDGE_DIR = process.env.BRIDGE_DIR || DEFAULT_BRIDGE_DIR;
export const STATE_PATH = join(BRIDGE_DIR, "state.json");
export const CMD_PATH = join(BRIDGE_DIR, "command");
export const ACK_PATH = join(BRIDGE_DIR, "ack.json");

function readJSON(path) {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null; // half-written during the mod's tick; caller retries next poll
  }
}

export const readState = () => readJSON(STATE_PATH);
export const readAck = () => readJSON(ACK_PATH);

// The mod's grammar: first line is the verb, everything after is the argument.
// We prepend a unique "@<nonce>" line so otherwise-identical commands are still
// distinct on disk — the mod keys its dedup on exact file contents and strips
// this line before parsing. Without it, re-issuing the same say/order silently
// no-ops (the mod sees identical content and produces no fresh ack).
let cmdNonce = 0;
export function writeCommand(verb, arg = "") {
  const tag = `@${Date.now()}.${cmdNonce++}`;
  const body = arg ? `${verb}\n${arg}` : `${verb}\n`;
  writeFileSync(CMD_PATH, `${tag}\n${body}`);
}

// Resolve once the ack seq advances past `fromSeq`; null on timeout.
export async function waitForAck(fromSeq, { timeoutMs = 4000, pollMs = 200 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ack = readAck();
    if (ack && typeof ack.seq === "number" && ack.seq > fromSeq) return ack;
    await sleep(pollMs);
  }
  return null;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
