// ============================================================
//  Flight Controller Hub
//  Bun WebSocket server + SQLite telemetry store.
//
//  Start: bun run index.ts
//  Env:   FC_TOKEN  — shared secret (required)
//         PORT      — listen port   (default 8080)
// ============================================================

import { Database } from "bun:sqlite";

// ── Config ───────────────────────────────────────────────────

const TOKEN = process.env.FC_TOKEN;
if (!TOKEN) throw new Error("FC_TOKEN environment variable is required.");

const PORT = Number(process.env.PORT ?? 8080);

// ── Logging ──────────────────────────────────────────────────

function ts() {
  return new Date().toLocaleTimeString("en-GB"); // HH:MM:SS
}

function log(tag: "WS" | "AUTH" | "HTTP" | "ERR", msg: string) {
  const color = { WS: "\x1b[36m", AUTH: "\x1b[33m", HTTP: "\x1b[90m", ERR: "\x1b[31m" }[tag];
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

// ── WebSocket connection state ────────────────────────────────

type WSData = {
  ip:       string;
  islandId: string | null;
  lastMode: string | null;
};

// ── Status handler ───────────────────────────────────────────

interface StatusMsg {
  type:      "status";
  island:    string;
  altitude?: number;
  target?:   number;
  velocity?: number;
  mode?:     string;
  pressure?: number;
}

function handleStatus(ws: { data: WSData }, msg: StatusMsg): string | null {
  if (typeof msg.island !== "string" || !msg.island) return "Missing island field";

  const { data } = ws;
  const isNew = data.islandId === null;

  // First message from this connection — log identification
  if (isNew) {
    data.islandId = msg.island;
    log("WS", `${msg.island} (${data.ip}) — identified`);
  }

  // Log mode changes
  if (msg.mode && msg.mode !== data.lastMode) {
    if (!isNew) {
      log("WS", `${msg.island} — ${data.lastMode ?? "?"} → ${msg.mode}  (alt: ${msg.altitude?.toFixed(1) ?? "?"}m, target: ${msg.target ?? "?"}m)`);
    }
    data.lastMode = msg.mode;
  }

  const params = {
    $id:     msg.island,
    $ts:     Date.now(),
    $alt:    msg.altitude ?? null,
    $target: msg.target   ?? null,
    $vel:    msg.velocity ?? null,
    $mode:   msg.mode     ?? null,
    $pres:   msg.pressure ?? null,
  };

  stmtUpsert.run(params);
  stmtLog.run(params);
  return null;
}

// ── Server ───────────────────────────────────────────────────

const server = Bun.serve<WSData>({
  port: PORT,

  fetch(req, server) {
    const url  = new URL(req.url);
    const path = url.pathname;
    const ip   = req.headers.get("x-forwarded-for") ?? "unknown";

    // WebSocket upgrade — auth via Bearer token in header
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

    // REST endpoints
    log("HTTP", `${req.method} ${path} — ${ip}`);

    if (path === "/islands" && req.method === "GET") {
      return Response.json(stmtAll.all());
    }

    const match = path.match(/^\/islands\/([^/]+)(\/history)?$/);
    if (match && req.method === "GET") {
      const id      = match[1];
      const history = !!match[2];

      if (history) {
        const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 1000);
        return Response.json(stmtHist.all({ $id: id, $limit: limit }));
      }

      const row = stmtOne.get({ $id: id });
      return row
        ? Response.json(row)
        : new Response("Island not found", { status: 404 });
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
      const label = ws.data.islandId
        ? `${ws.data.islandId} (${ws.data.ip})`
        : ws.data.ip;
      log("WS", `${label} — disconnected`);
    },
  },
});

log("WS",   `Listening on port ${server.port}`);
log("HTTP", `Islands: http://localhost:${server.port}/islands`);
