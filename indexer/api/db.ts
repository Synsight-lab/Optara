/**
 * Read-only access to the indexer's Postgres tables (Envio: one table per entity, partitioned by chainId, in schema
 * ENVIO_PG_SCHEMA). Numeric columns come back as decimal strings and are returned as bigints.
 */
import postgres from "postgres";

export interface DbOptions {
  host?: string;
  port?: number;
  user?: string;
  password?: string;
  database?: string;
  schema?: string;
  chainId: number;
}

export type Sql = ReturnType<typeof postgres>;

export class Db {
  readonly sql: Sql;
  readonly schema: string;
  readonly chainId: number;

  constructor(o: DbOptions) {
    this.schema = o.schema ?? "public";
    this.chainId = o.chainId;
    this.sql = postgres({
      host: o.host ?? "localhost",
      port: o.port ?? 5433,
      user: o.user ?? "postgres",
      password: o.password ?? "testing",
      database: o.database ?? "envio-dev",
      max: 5,
      types: { bigint: postgres.BigInt },
    });
  }

  async rows<T = Record<string, unknown>>(entity: string, where = "TRUE", params: unknown[] = [], orderLimit = ""): Promise<T[]> {
    const q = `SELECT * FROM "${this.schema}"."${entity}" WHERE "chainId" = ${Number(this.chainId)} AND (${where}) ${orderLimit}`;
    return (await this.sql.unsafe(q, params as any[])).map(normalize) as T[];
  }

  async one<T = Record<string, unknown>>(entity: string, id: string): Promise<T | undefined> {
    return (await this.rows<T>(entity, `id = $1`, [id]))[0];
  }

  /** Last block the indexer has fully processed for this chain (0 before the first batch). */
  async progressBlock(): Promise<number> {
    const r = await this.sql.unsafe(`SELECT progress_block FROM "${this.schema}".envio_chains WHERE id = ${Number(this.chainId)}`);
    return r[0] ? Number(r[0].progress_block) : 0;
  }

  close() {
    return this.sql.end();
  }
}

/** numeric → bigint (integers), everything else unchanged. */
function normalize(row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) out[k] = typeof v === "string" && /^-?\d+$/.test(v) && k !== "id" && !k.endsWith("_id") ? BigInt(v) : v;
  return out;
}

export interface PositionRow {
  id: string;
  accountId: bigint;
  seriesId: string;
  balance: bigint;
  updatedAt: bigint;
}
export interface AccountRow {
  id: string;
  accountId: bigint;
  owner: string;
  settlementAsset: string;
  cash: bigint;
  createdAt: bigint;
}
export interface SeriesRow {
  id: string;
  group_id: string;
  productId: string;
  underlying: string;
  settlementAsset: string;
  wrapper: string;
  optionType: number;
  strikeWad: bigint;
  contractSizeWad: bigint;
  expiry: bigint;
  wrapperSupply: bigint;
  internalLong: bigint;
  internalShort: bigint;
}
export interface GroupRow {
  id: string;
  underlying: string;
  settlementAsset: string;
  expiry: bigint;
  settlementOracleConfigId: string;
  participants: bigint;
  finalized: boolean;
  finalizedAt: bigint;
  priceWad: bigint;
  ratioSet: boolean;
  ratioWad: bigint;
  stalled: boolean;
}
export interface AuctionRow {
  id: string;
  accountId: bigint;
  underlying: string;
  active: boolean;
  startTime: bigint;
  slices: number;
}
