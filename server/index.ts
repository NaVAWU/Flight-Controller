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

// ── Status handler ───────────────────────────────────────────

interface StatusMsg {
  type: "status";
  island: string;
  altitude?: number;
  target?: number;
  velocity?: number;
  mode?: string;
  pressure?: number;
}

function handleStatus(msg: StatusMsg): string | null {
  if (typeof msg.island !== "string" || !msg.island) return "Missing island field";

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

const server = Bun.serve({
  port: PORT,

  fetch(req, server) {
    const url  = new URL(req.url);
    const path = url.pathname;

    // WebSocket upgrade — auth via Bearer token in header
    if (path === "/ws") {
      const auth  = req.headers.get("authorization") ?? "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (token !== TOKEN) {
        return new Response("Unauthorized", { status: 401 });
      }
      const ok = server.upgrade(req);
      return ok ? undefined : new Response("WebSocket upgrade failed", { status: 500 });
    }

    // REST: GET /islands
    if (path === "/islands" && req.method === "GET") {
      return Response.json(stmtAll.all());
    }

    // REST: GET /islands/:id  and  GET /islands/:id/history?limit=N
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
      console.log("[WS] Island connected");
    },

    message(ws, raw) {
      let msg: any;
      try {
        msg = JSON.parse(typeof raw === "string" ? raw : raw.toString());
      } catch {
        ws.send(JSON.stringify({ ok: false, error: "Invalid JSON" }));
        return;
      }

      if (msg.type !== "status") {
        ws.send(JSON.stringify({ ok: false, error: `Unknown type: ${msg.type}` }));
        return;
      }

      const err = handleStatus(msg as StatusMsg);
      if (err) {
        ws.send(JSON.stringify({ ok: false, error: err }));
      } else {
        ws.send(JSON.stringify({ ok: true }));
      }
    },

    close(ws) {
      console.log("[WS] Island disconnected");
    },
  },
});

console.log(`[Hub] Listening on port ${server.port}`);
console.log(`[Hub] WebSocket : ws://localhost:${server.port}/ws`);
console.log(`[Hub] Islands   : http://localhost:${server.port}/islands`);
