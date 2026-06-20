#!/usr/bin/env node
// The M1 driver: a thin CLI over the file bridge.
//   node src/watch.js                 → watch state.json, print crew on change
//   node src/watch.js ping            → send a command, wait for its ack
//   node src/watch.js say "moving up"  → speak as the controlled character
//   node src/watch.js order "operatereactor Keneth"  → order a bot (id then name/job)
//   node src/watch.js console "spawnitem crowbar cursor"  → debug console (gated; see README)
import { existsSync } from "node:fs";
import {
  BRIDGE_DIR, STATE_PATH, readState, readAck, writeCommand, waitForAck, sleep,
} from "./bridge.js";

const [verb, ...rest] = process.argv.slice(2);

if (verb && verb !== "watch") await sendOnce(verb, rest.join(" "));
else await watch();

async function sendOnce(verb, arg) {
  const before = readAck()?.seq ?? 0;
  writeCommand(verb, arg);
  console.log(`→ ${verb}${arg ? " " + JSON.stringify(arg) : ""}`);
  const ack = await waitForAck(before);
  if (!ack) {
    console.error(`✗ no ack within timeout — is the mod running? bridge: ${BRIDGE_DIR}`);
    console.error("  (note: identical commands are deduped by the mod — change the text to re-issue)");
    process.exit(1);
  }
  const tail = ack.error ? ` error=${ack.error}` : "";
  console.log(`← ack seq=${ack.seq} ok=${ack.ok} did=${ack.did ?? "-"}${tail}`);
}

async function watch() {
  console.log(`watching ${STATE_PATH}  (Ctrl-C to stop)`);
  if (!existsSync(STATE_PATH)) {
    console.log("(state.json not present yet — enable the mod and start a round)");
  }
  let last = "";
  for (;;) {
    const state = readState();
    if (state) {
      const json = JSON.stringify(state);
      if (json !== last) {
        last = json;
        printState(state);
      }
    }
    await sleep(500);
  }
}

function printState(s) {
  const crew = s.crew ?? [];
  console.log(`\n[t=${s.t}] round=${s.roundStarted} controlled=${s.controlled} crew=${crew.length}`);
  for (const c of crew) {
    console.log(
      `  ${c.isControlled ? "*" : " "} ${pad(c.name, 18)} ${pad(c.job, 10)}` +
      ` hp=${pad3(c.health)} o2=${pad3(c.oxygen)} bleed=${pad(c.bleeding, 4)}` +
      ` ${c.dead ? "DEAD " : "     "}${pad(c.room ?? "?", 14)} ${c.order ?? "-"}`,
    );
  }
  const sub = s.sub;
  if (sub) {
    const haz = [];
    if (sub.fires?.length) haz.push(`fires: ${sub.fires.map((f) => f.room).join(", ")}`);
    if (sub.leaks?.length) haz.push(`leaks: ${sub.leaks.map((l) => l.room + (l.toOcean ? "!" : "")).join(", ")}`);
    if (sub.flooding?.length) haz.push(`flood: ${sub.flooding.map((f) => `${f.room} ${f.pct}%`).join(", ")}`);
    const r = sub.reactor;
    if (r?.meltdown) haz.push("REACTOR MELTDOWN");
    if (haz.length) console.log(`  ⚠ ${haz.join("  |  ")}`);
    if (r) console.log(`    reactor ${r.temp}° fission=${r.fissionRate} out=${r.output} fuel=${r.fuel}`);
  }
}

function pad(v, n) { return String(v).padEnd(n); }
function pad3(v) { return String(v).padStart(3); }
