import type { Server, ServerWebSocket } from "bun";
import { TOKEN } from "./config";
import { log } from "./log";
import { stmtUpsert, stmtLog, stmtDisconnect, stmtAll, stmtOne, stmtHist } from "./db";

// ── Types ─────────────────────────────────────────────────────

export type WSData = {
  ip:       string;
  islandId: string | null;
  lastMode: string | null;
};

interface StatusMsg {
  type:       "status";
  island:     string;
  altitude?:  number;
  target?:    number;
  velocity?:  number;
  mode?:      string;
  pressure?:  number;
  pid_kp?:    number;
  pid_ki?:    number;
  pid_kd?:    number;
  pid_imax?:  number;
  hover_rsc?: number;
}

// ── Connection registry ───────────────────────────────────────

export const connections = new Map<string, ServerWebSocket<WSData>>();

// ── Auth ──────────────────────────────────────────────────────

export function isAuthorized(req: Request): boolean {
  const auth = req.headers.get("authorization") ?? "";
  return auth.startsWith("Bearer ") && auth.slice(7) === TOKEN;
}

// ── Command dispatch (server → island) ───────────────────────

function sendToIsland(islandId: string, cmd: object): "ok" | "offline" {
  const ws = connections.get(islandId);
  if (!ws) return "offline";
  ws.send(JSON.stringify(cmd));
  return "ok";
}

export function cmdSetAltitude(islandId: string, target: number): "ok" | "offline" | "invalid" {
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

export function cmdShutdown(islandId: string): "ok" | "offline" {
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

// ── Status handler (island → server) ─────────────────────────

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

  const params = {
    $id:       msg.island,
    $ts:       Date.now(),
    $alt:      msg.altitude  ?? null,
    $target:   msg.target    ?? null,
    $vel:      msg.velocity  ?? null,
    $mode:     msg.mode      ?? null,
    $pres:     msg.pressure  ?? null,
    $kp:       msg.pid_kp    ?? null,
    $ki:       msg.pid_ki    ?? null,
    $kd:       msg.pid_kd    ?? null,
    $imax:     msg.pid_imax  ?? null,
    $hover_rsc: msg.hover_rsc ?? null,
  };
  stmtUpsert.run(params);
  stmtLog.run(params);

  return null;
}

// ── WebSocket handlers ────────────────────────────────────────

export const websocket = {
  open(ws: ServerWebSocket<WSData>) {
    log("WS", `${ws.data.ip} — connected`);
  },

  message(ws: ServerWebSocket<WSData>, raw: string | Buffer) {
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

  close(ws: ServerWebSocket<WSData>) {
    const { islandId, ip } = ws.data;
    if (islandId) {
      connections.delete(islandId);
      stmtDisconnect.run({ $id: islandId });
    }
    log("WS", `${islandId ? `${islandId} (${ip})` : ip} — disconnected`);
  },
};

// ── HTTP handler ──────────────────────────────────────────────

export async function fetch(req: Request, server: Server): Promise<Response | undefined> {
  const url    = new URL(req.url);
  const path   = url.pathname;
  const ip     = req.headers.get("x-forwarded-for") ?? "unknown";
  const method = req.method;

  // WebSocket upgrade
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

  // Read-only REST
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

  // Write REST (require auth)
  if (method === "POST") {
    if (!isAuthorized(req)) {
      log("AUTH", `${ip} — rejected POST ${path} (bad token)`);
      return new Response("Unauthorized", { status: 401 });
    }

    log("HTTP", `POST ${path} — ${ip}`);

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

    const shutMatch = path.match(/^\/islands\/([^/]+)\/shutdown$/);
    if (shutMatch) {
      const id     = shutMatch[1];
      const result = cmdShutdown(id);
      if (result === "offline") return new Response("Island not connected", { status: 503 });
      return new Response("OK");
    }
  }

  return new Response("Not found", { status: 404 });
}
