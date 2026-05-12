// ============================================================
//  Flight Controller Hub
//  Bun WebSocket server + SQLite telemetry store.
//
//  Start: bun run index.ts
//  Env:   FC_TOKEN  — shared secret (required)
//         PORT      — listen port   (default 8080)
//
//  Console commands (type while running):
//    list
//    set <island> altitude <meters>
//    shutdown <island>
//    help
//
//  REST endpoints (read-only, no auth):
//    GET /islands
//    GET /islands/:id
//    GET /islands/:id/history?limit=N
//
//  REST commands (require Authorization: Bearer <FC_TOKEN>):
//    POST /islands/:id/altitude   body: { "target": 250 }
//    POST /islands/:id/shutdown
// ============================================================

import readline from "readline";
import { PORT, STALE_MS } from "./config";
import { log } from "./log";
import { stmtAll, stmtMarkStale } from "./db";
import { cmdSetAltitude, cmdShutdown, websocket, fetch, type WSData } from "./islands";

// ── Server ───────────────────────────────────────────────────

const server = Bun.serve<WSData>({ port: PORT, fetch, websocket });

// ── Stale-connection sweep ────────────────────────────────────

setInterval(() => {
  const { changes } = stmtMarkStale.run({ $cutoff: Date.now() - STALE_MS });
  if (changes > 0) log("WS", `Marked ${changes} island(s) as disconnected (stale)`);
}, STALE_MS);

// ── Console input ─────────────────────────────────────────────

function printHelp() {
  console.log("  list                          — show all islands");
  console.log("  set <island|all> altitude <n> — change target altitude");
  console.log("  shutdown <island|all>         — send shutdown command");
  console.log("  help                          — show this message");
}

function handleConsoleInput(line: string) {
  const parts = line.trim().split(/\s+/);
  const cmd   = parts[0]?.toLowerCase();

  if (!cmd) return;

  if (cmd === "help") {
    printHelp();
    return;
  }

  if (cmd === "list") {
    const rows = stmtAll.all() as Array<{ id: string; connected: number; last_seen: number }>;
    if (rows.length === 0) {
      console.log("  No islands in database.");
    } else {
      for (const row of rows) {
        const status = row.connected ? "online " : "offline";
        const ago    = Math.round((Date.now() - row.last_seen) / 1000);
        console.log(`  • ${status}  ${row.id}  (last seen ${ago}s ago)`);
      }
    }
    return;
  }

  if (cmd === "set" && parts[2] === "altitude") {
    const id     = parts[1];
    const target = Number(parts[3]);
    if (!id || isNaN(target)) { console.log("  Usage: set <island> altitude <n>"); return; }
    const result = cmdSetAltitude(id, target);
    if (result === "offline") console.log(`  ${id} is not connected.`);
    return;
  }

  if (cmd === "shutdown") {
    const id = parts[1];
    if (!id) { console.log("  Usage: shutdown <island>"); return; }
    const result = cmdShutdown(id);
    if (result === "offline") console.log(`  ${id} is not connected.`);
    return;
  }

  console.log(`  Unknown command: ${cmd}  (type "help" for commands)`);
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on("line", handleConsoleInput);

// ── Startup ───────────────────────────────────────────────────

log("WS",   `Listening on port ${server.port}`);
log("HTTP", `Islands: http://localhost:${server.port}/islands`);
console.log("");
printHelp();
console.log("");
