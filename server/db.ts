import { Database } from "bun:sqlite";

export const db = new Database("islands.db");

db.exec(`
  CREATE TABLE IF NOT EXISTS islands (
    id        TEXT    PRIMARY KEY,
    last_seen INTEGER NOT NULL,
    altitude  REAL,
    target    REAL,
    velocity  REAL,
    mode      TEXT,
    pressure  REAL,
    connected INTEGER NOT NULL DEFAULT 0
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

// Migrate existing databases that predate the connected column.
try { db.exec(`ALTER TABLE islands ADD COLUMN connected INTEGER NOT NULL DEFAULT 0`); } catch {}

export const stmtUpsert = db.prepare(`
  INSERT INTO islands (id, last_seen, altitude, target, velocity, mode, pressure, connected)
  VALUES ($id, $ts, $alt, $target, $vel, $mode, $pres, 1)
  ON CONFLICT(id) DO UPDATE SET
    last_seen = excluded.last_seen,
    altitude  = excluded.altitude,
    target    = excluded.target,
    velocity  = excluded.velocity,
    mode      = excluded.mode,
    pressure  = excluded.pressure,
    connected = 1
`);

export const stmtLog = db.prepare(`
  INSERT INTO status_log (island_id, ts, altitude, target, velocity, mode, pressure)
  VALUES ($id, $ts, $alt, $target, $vel, $mode, $pres)
`);

export const stmtDisconnect = db.prepare(
  `UPDATE islands SET connected = 0 WHERE id = $id`
);

export const stmtMarkStale = db.prepare(
  `UPDATE islands SET connected = 0 WHERE connected = 1 AND last_seen < $cutoff`
);

export const stmtAll  = db.prepare(`SELECT * FROM islands ORDER BY id`);
export const stmtOne  = db.prepare(`SELECT * FROM islands WHERE id = $id`);
export const stmtHist = db.prepare(`
  SELECT * FROM status_log WHERE island_id = $id ORDER BY ts DESC LIMIT $limit
`);

export interface IslandRow {
  id:        string;
  last_seen: number;
  altitude:  number | null;
  target:    number | null;
  velocity:  number | null;
  mode:      string | null;
  pressure:  number | null;
  connected: number;
}
