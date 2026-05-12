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
//  REST commands (require Authorization: Bearer <FC_TOKEN>):
//    POST /islands/:id/altitude   body: { "target": 250 }
//    POST /islands/:id/shutdown
// ============================================================

import { Database }  from "bun:sqlite";
import type { ServerWebSocket } from "bun";
import readline from "readline";

// ── Config ───────────────────────────────────────────────────

const TOKEN = process.env.FC_TOKEN;
if (!TOKEN) throw new Error("FC_TOKEN environment variable is required.");

const PORT = Number(process.env.PORT ?? 8080);

// ── Logging ──────────────────────────────────────────────────

function ts() {
  return new Date().toLocaleTimeString("en-GB");
}

function log(tag: "WS" | "AUTH" | "HTTP" | "CMD" | "ERR", msg: string) {
  const color = {
    WS:   "\x1b[36m",
    AUTH: "\x1b[33m",
    HTTP: "\x1b[90m",
    CMD:  "\x1b[32m",
    ERR:  "\x1b[31m",
  }[tag];
  console.log(`${ts()}  ${color}${tag.padEnd(4)}\x1b[0m  ${msg}`);
}

// ── Database ─────────────────────────────────────────────────

const db = new Database("islands.db");

db.exec(`
  CREATE TABLE IF NOT EXISTS islands (
    id        TEXT    PRIMARY KEY,
    last_seen INTEGER NOT NULL,
    altitude  REAL,
    target    REAL,
    velocity  REAL,
    mode      TEXT,
    pressure  REAL
  );

  CREATE TABLE IF NOT EXISTS status_log (
    rowid     INTEGER PRIMARY KEY AUTOINCREMENT,
    island_id TEXT    NOT NULL,
    ts        INTEGER NOT NULL,
    altitude  REAL,
    target    REAL,
    velocity  REAL,
    mode      TEXT,
    pressure  REAL
  );

  CREATE INDEX IF NOT EXISTS idx_log_island ON status_log (island_id, ts DESC);
`);

const stmtUpsert = db.prepare(`
  INSERT INTO islands (id, last_seen, altitude, target, velocity, mode, pressure)
  VALUES ($id, $ts, $alt, $target, $vel, $mode, $pres)
  ON CONFLICT(id) DO UPDATE SET
    last_seen = excluded.last_seen,
    altitude  = excluded.altitude,
    target    = excluded.target,
    velocity  = excluded.velocity,
    mode      = excluded.mode,
    pressure  = excluded.pressure
`);

const stmtLog = db.prepare(`
  INSERT INTO status_log (island_id, ts, altitude, target, velocity, mode, pressure)
  VALUES ($id, $ts, $alt, $target, $vel, $mode, $pres)
`);

const stmtAll  = db.prepare(`SELECT * FROM islands ORDER BY id`);
const stmtOne  = db.prepare(`SELECT * FROM islands WHERE id = $id`);
const stmtHist = db.prepare(`
  SELECT * FROM status_log WHERE island_id = $id ORDER BY ts DESC LIMIT $limit
`);

// ── Connection registry ───────────────────────────────────────

type WSData = {
  ip:       string;
  islandId: string | null;
  lastMode: string | null;
};

const connections = new Map<string, ServerWebSocket<WSData>>();

// ── Command dispatch (server → island) ───────────────────────

function sendToIsland(islandId: string, cmd: object): "ok" | "offline" {
  const ws = connections.get(islandId);
  if (!ws) return "offline";
  ws.send(JSON.stringify(cmd));
  return "ok";
}

function cmdSetAltitude(islandId: string, target: number): "ok" | "offline" | "invalid" {
  if (!Number.isFinite(target)) return "invalid";
  if (islandId === "all") {
    if (connections.size === 0) return "offline";
    for (const id of connections.keys()) sendToIsland(id, { cmd: "SET_ALTITUDE", target });
    log("CMD", `SET_ALTITUDE ${target}m → all (${connections.size} island(s))`);
    return "ok";
  }
  const result = sendToIsland(islandId, { cmd: "SET_ALTITUDE", target });
  if (result === "ok") log("CMD", `SET_ALTITUDE ${target}m → ${islandId}`);
  return result;
}

function cmdShutdown(islandId: string): "ok" | "offline" {
  if (islandId === "all") {
    if (connections.size === 0) return "offline";
    for (const id of connections.keys()) sendToIsland(id, { cmd: "SHUTDOWN" });
    log("CMD", `SHUTDOWN → all (${connections.size} island(s))`);
    return "ok";
  }
  const result = sendToIsland(islandId, { cmd: "SHUTDOWN" });
  if (result === "ok") log("CMD", `SHUTDOWN → ${islandId}`);
  return result;
}

// ── Auth helper for write endpoints ──────────────────────────

function isAuthorized(req: Request): boolean {
  const auth = req.headers.get("authorization") ?? "";
  return auth.startsWith("Bearer ") && auth.slice(7) === TOKEN;
}

// ── Status handler (island → server) ─────────────────────────

interface StatusMsg {
  type:      "status";
  island:    string;
  altitude?: number;
  target?:   number;
  velocity?: number;
  mode?:     string;
  pressure?: number;
}

function handleStatus(ws: ServerWebSocket<WSData>, msg: StatusMsg): string | null {
  if (typeof msg.island !== "string" || !msg.island) return "Missing island field";

  const { data } = ws;
  const isNew = data.islandId === null;

  if (isNew) {
    data.islandId = msg.island;
    connections.set(msg.island, ws);
    log("WS", `${msg.island} (${data.ip}) — identified`);
  }

  if (msg.mode && msg.mode !== data.lastMode) {
    if (!isNew) {
      log("WS", `${msg.island} — ${data.lastMode ?? "?"} → ${msg.mode}  (alt: ${msg.altitude?.toFixed(1) ?? "?"}m, target: ${msg.target ?? "?"}m)`);
    }
    data.lastMode = msg.mode;
  }

  stmtUpsert.run({
    $id:     msg.island,
    $ts:     Date.now(),
    $alt:    msg.altitude ?? null,
    $target: msg.target   ?? null,
    $vel:    msg.velocity ?? null,
    $mode:   msg.mode     ?? null,
    $pres:   msg.pressure ?? null,
  });
  stmtLog.run({
    $id:     msg.island,
    $ts:     Date.now(),
    $alt:    msg.altitude ?? null,
    $target: msg.target   ?? null,
    $vel:    msg.velocity ?? null,
    $mode:   msg.mode     ?? null,
    $pres:   msg.pressure ?? null,
  });

  return null;
}

// ── Server ───────────────────────────────────────────────────

const server = Bun.serve<WSData>({
  port: PORT,

  async fetch(req, server) {
    const url    = new URL(req.url);
    const path   = url.pathname;
    const ip     = req.headers.get("x-forwarded-for") ?? "unknown";
    const method = req.method;

    // ── WebSocket upgrade ──
    if (path === "/ws") {
      const auth  = req.headers.get("authorization") ?? "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (token !== TOKEN) {
        log("AUTH", `${ip} — rejected (bad token)`);
        return new Response("Unauthorized", { status: 401 });
      }
      const ok = server.upgrade(req, { data: { ip, islandId: null, lastMode: null } });
      return ok ? undefined : new Response("WebSocket upgrade failed", { status: 500 });
    }

    // ── Read-only REST ──
    if (method === "GET") {
      log("HTTP", `GET ${path} — ${ip}`);

      if (path === "/islands") {
        return Response.json(stmtAll.all());
      }

      const m = path.match(/^\/islands\/([^/]+)(\/history)?$/);
      if (m) {
        const id = m[1];
        if (m[2]) {
          const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 1000);
          return Response.json(stmtHist.all({ $id: id, $limit: limit }));
        }
        const row = stmtOne.get({ $id: id });
        return row ? Response.json(row) : new Response("Island not found", { status: 404 });
      }
    }

    // ── Write REST (require auth) ──
    if (method === "POST") {
      if (!isAuthorized(req)) {
        log("AUTH", `${ip} — rejected POST ${path} (bad token)`);
        return new Response("Unauthorized", { status: 401 });
      }

      log("HTTP", `POST ${path} — ${ip}`);

      // POST /islands/:id/altitude   { "target": 250 }
      const altMatch = path.match(/^\/islands\/([^/]+)\/altitude$/);
      if (altMatch) {
        const id   = altMatch[1];
        const body = await req.json().catch(() => null);
        if (typeof body?.target !== "number") {
          return new Response('Body must be { "target": <number> }', { status: 400 });
        }
        const result = cmdSetAltitude(id, body.target);
        if (result === "offline") return new Response("Island not connected", { status: 503 });
        if (result === "invalid") return new Response("Invalid target value", { status: 400 });
        return new Response("OK");
      }

      // POST /islands/:id/shutdown
      const shutMatch = path.match(/^\/islands\/([^/]+)\/shutdown$/);
      if (shutMatch) {
        const id     = shutMatch[1];
        const result = cmdShutdown(id);
        if (result === "offline") return new Response("Island not connected", { status: 503 });
        return new Response("OK");
      }
    }

    return new Response("Not found", { status: 404 });
  },

  websocket: {
    open(ws) {
      log("WS", `${ws.data.ip} — connected`);
    },

    message(ws, raw) {
      let msg: any;
      try {
        msg = JSON.parse(typeof raw === "string" ? raw : raw.toString());
      } catch {
        log("ERR", `${ws.data.islandId ?? ws.data.ip} — invalid JSON`);
        ws.send(JSON.stringify({ ok: false, error: "Invalid JSON" }));
        return;
      }

      if (msg.type !== "status") {
        log("ERR", `${ws.data.islandId ?? ws.data.ip} — unknown type "${msg.type}"`);
        ws.send(JSON.stringify({ ok: false, error: `Unknown type: ${msg.type}` }));
        return;
      }

      const err = handleStatus(ws, msg as StatusMsg);
      if (err) {
        log("ERR", `${ws.data.islandId ?? ws.data.ip} — ${err}`);
        ws.send(JSON.stringify({ ok: false, error: err }));
      } else {
        ws.send(JSON.stringify({ ok: true }));
      }
    },

    close(ws) {
      const { islandId, ip } = ws.data;
      if (islandId) connections.delete(islandId);
      log("WS", `${islandId ? `${islandId} (${ip})` : ip} — disconnected`);
    },
  },
});

// ── Console input ─────────────────────────────────────────────

function printHelp() {
  console.log("  list                          — show connected islands");
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
    if (connections.size === 0) {
      console.log("  No islands connected.");
    } else {
      for (const id of connections.keys()) console.log(`  • ${id}`);
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
