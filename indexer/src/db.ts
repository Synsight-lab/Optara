import { DatabaseSync } from "node:sqlite";

/**
 * SQLite store. `events` is the append-only source of the index; every other table is derived state that can be
 * rebuilt by replaying `events` in (block, logIndex) order. Integers are stored as decimal TEXT (bigint safe).
 *
 * The index is a read model only: it is never used to authorize anything (SECURITY.md sections 78-79).
 */
export const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS blocks (number INTEGER PRIMARY KEY, hash TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  block_number INTEGER NOT NULL,
  block_hash TEXT NOT NULL,
  tx_hash TEXT NOT NULL,
  log_index INTEGER NOT NULL,
  address TEXT NOT NULL,
  name TEXT NOT NULL,
  args TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_block ON events (block_number, log_index);
CREATE INDEX IF NOT EXISTS events_name ON events (name);

CREATE TABLE IF NOT EXISTS series (
  series_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, option_token TEXT NOT NULL UNIQUE,
  underlying TEXT NOT NULL, settlement_asset TEXT NOT NULL, option_type INTEGER NOT NULL,
  strike_wad TEXT NOT NULL, cap_wad TEXT NOT NULL, contract_size_wad TEXT NOT NULL,
  expiry INTEGER NOT NULL, oracle_config_id TEXT NOT NULL, quantity_increment TEXT NOT NULL,
  minted TEXT NOT NULL DEFAULT '0', closed TEXT NOT NULL DEFAULT '0', redeemed TEXT NOT NULL DEFAULT '0',
  created_block INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS groups (
  group_id TEXT PRIMARY KEY, underlying TEXT NOT NULL, settlement_asset TEXT NOT NULL, expiry INTEGER NOT NULL,
  oracle_config_id TEXT NOT NULL, buffer_bps INTEGER NOT NULL, fixed_buffer_native TEXT NOT NULL,
  finalized INTEGER NOT NULL DEFAULT 0, settlement_price_wad TEXT, observation_ts INTEGER,
  finalized_block INTEGER, finalizer TEXT, oracle_data_hash TEXT
);
CREATE TABLE IF NOT EXISTS positions (
  account TEXT NOT NULL, series_id TEXT NOT NULL,
  short_qty TEXT NOT NULL DEFAULT '0', locked_qty TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (account, series_id)
);
CREATE TABLE IF NOT EXISTS cash (
  account TEXT NOT NULL, asset TEXT NOT NULL, amount TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (account, asset)
);
CREATE TABLE IF NOT EXISTS balances (
  token TEXT NOT NULL, holder TEXT NOT NULL, amount TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (token, holder)
);
CREATE TABLE IF NOT EXISTS asset_status (
  asset TEXT PRIMARY KEY, status TEXT NOT NULL, rho_wad TEXT NOT NULL DEFAULT '0', reference TEXT
);
CREATE TABLE IF NOT EXISTS pauses (scope TEXT PRIMARY KEY, bits TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, subject TEXT NOT NULL, detail TEXT NOT NULL,
  first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, active INTEGER NOT NULL DEFAULT 1,
  UNIQUE (kind, subject)
);
`;

/** Tables rebuilt from `events` after a reorg rollback. */
export const DERIVED_TABLES = ["series", "groups", "positions", "cash", "balances", "asset_status", "pauses"];

export type Row = Record<string, string | number | bigint | null>;

export class Store {
  readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL;");
    this.db.exec(SCHEMA);
  }

  close(): void {
    this.db.close();
  }

  tx<T>(fn: () => T): T {
    this.db.exec("BEGIN");
    try {
      const out = fn();
      this.db.exec("COMMIT");
      return out;
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }

  getMeta(key: string): string | undefined {
    const row = this.db.prepare("SELECT value FROM meta WHERE key = ?").get(key) as { value: string } | undefined;
    return row?.value;
  }

  setMeta(key: string, value: string): void {
    this.db.prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value);
  }

  all<T = Row>(sql: string, ...params: (string | number | bigint | null)[]): T[] {
    return this.db.prepare(sql).all(...params) as T[];
  }

  get<T = Row>(sql: string, ...params: (string | number | bigint | null)[]): T | undefined {
    return this.db.prepare(sql).get(...params) as T | undefined;
  }

  run(sql: string, ...params: (string | number | bigint | null)[]): void {
    this.db.prepare(sql).run(...params);
  }

  /** Adds `delta` (may be negative) to a decimal TEXT column, creating the row if needed. */
  addTo(table: string, keyCols: string[], keyVals: string[], col: string, delta: bigint): void {
    const where = keyCols.map((c) => `${c} = ?`).join(" AND ");
    const row = this.get<Record<string, string>>(`SELECT ${col} FROM ${table} WHERE ${where}`, ...keyVals);
    const next = BigInt(row?.[col] ?? "0") + delta;
    if (next < 0n) throw new Error(`negative ${table}.${col} for ${keyVals.join("/")}: ${next}`);
    if (row) {
      this.run(`UPDATE ${table} SET ${col} = ? WHERE ${where}`, next.toString(), ...keyVals);
    } else {
      this.run(
        `INSERT INTO ${table} (${[...keyCols, col].join(", ")}) VALUES (${[...keyCols, col].map(() => "?").join(", ")})`,
        ...keyVals,
        next.toString(),
      );
    }
  }

  raiseAlert(kind: string, subject: string, detail: string, now: number): void {
    this.run(
      `INSERT INTO alerts (kind, subject, detail, first_seen, last_seen, active) VALUES (?, ?, ?, ?, ?, 1)
       ON CONFLICT(kind, subject) DO UPDATE SET detail = excluded.detail, last_seen = excluded.last_seen, active = 1`,
      kind,
      subject,
      detail,
      now,
      now,
    );
  }

  clearAlertsExcept(kind: string, activeSubjects: Set<string>): void {
    for (const r of this.all<{ subject: string }>("SELECT subject FROM alerts WHERE kind = ? AND active = 1", kind)) {
      if (!activeSubjects.has(r.subject)) this.run("UPDATE alerts SET active = 0 WHERE kind = ? AND subject = ?", kind, r.subject);
    }
  }
}
