import { decodeEventLog, type Abi, type Log, type PublicClient, type Address } from "viem";
import { optaraCoreAbi, optaraConfigAbi, oracleRegistryAbi, optionTokenAbi } from "./abi.ts";
import type { Store } from "./db.ts";
import { DERIVED_TABLES } from "./db.ts";
import { applyEvent, type StoredEvent } from "./reducers.ts";
import type { IndexerConfig } from "./config.ts";

/** Converts decoded args to JSON-safe values: bigint -> decimal string, hex/address -> lowercase. */
export function normalizeArgs(args: unknown): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const [k, v] of Object.entries(args as Record<string, unknown>)) {
    if (typeof v === "bigint") out[k] = v.toString();
    else if (typeof v === "string") out[k] = v.toLowerCase();
    else if (typeof v === "number" || typeof v === "boolean") out[k] = v;
    else out[k] = JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x));
  }
  return out;
}

export interface SyncResult {
  fromBlock: bigint;
  toBlock: bigint;
  events: number;
  rolledBackTo?: bigint;
}

/**
 * Finality-depth log indexer with reorg rollback (SECURITY.md section 79: reorgs, duplicates, lag).
 * Only blocks at or below head - confirmations are indexed. On every tick the stored hash of the cursor block is
 * compared with the chain; on mismatch the index rolls back to the last matching block and derived tables are
 * rebuilt by replaying stored events.
 */
export class Indexer {
  private readonly abiByAddress = new Map<string, Abi>();

  constructor(
    private readonly client: PublicClient,
    private readonly store: Store,
    private readonly cfg: IndexerConfig,
  ) {
    const c = cfg.manifest.contracts;
    this.abiByAddress.set(c.OptaraCore.toLowerCase(), optaraCoreAbi as Abi);
    this.abiByAddress.set(c.OptaraConfig.toLowerCase(), optaraConfigAbi as Abi);
    this.abiByAddress.set(c.OracleRegistry.toLowerCase(), oracleRegistryAbi as Abi);
    for (const r of store.all<{ option_token: string }>("SELECT option_token FROM series")) {
      this.abiByAddress.set(r.option_token, optionTokenAbi as Abi);
    }
  }

  cursor(): bigint {
    const v = this.store.getMeta("cursor");
    return v === undefined ? this.cfg.startBlock - 1n : BigInt(v);
  }

  private watched(): Address[] {
    return [...this.abiByAddress.keys()] as Address[];
  }

  /** One indexing pass: reorg check, then catch up to the finality horizon in bounded batches. */
  async syncOnce(): Promise<SyncResult> {
    const rolledBackTo = await this.checkReorg();
    const head = await this.client.getBlockNumber();
    const target = head - this.cfg.confirmations;
    let from = this.cursor() + 1n;
    const start = from;
    let total = 0;
    while (from <= target) {
      const to = from + this.cfg.batchSize - 1n < target ? from + this.cfg.batchSize - 1n : target;
      total += await this.indexRange(from, to);
      from = to + 1n;
    }
    return { fromBlock: start, toBlock: target, events: total, rolledBackTo };
  }

  private async indexRange(from: bigint, to: bigint): Promise<number> {
    let logs = await this.client.getLogs({ address: this.watched(), fromBlock: from, toBlock: to });
    // New option tokens discovered in this range must also be scanned for their Transfer events.
    const discovered = this.discoverTokens(logs);
    if (discovered.length > 0) {
      const tokenLogs = await this.client.getLogs({ address: discovered, fromBlock: from, toBlock: to });
      logs = [...logs, ...tokenLogs];
    }
    logs.sort((x, y) =>
      x.blockNumber === y.blockNumber ? Number(x.logIndex! - y.logIndex!) : Number(x.blockNumber! - y.blockNumber!),
    );
    const toBlock = await this.client.getBlock({ blockNumber: to });
    let count = 0;
    this.store.tx(() => {
      for (const log of logs) {
        const ev = this.decode(log);
        if (!ev) continue;
        const inserted = this.insertEvent(ev);
        if (inserted) {
          applyEvent(this.store, ev);
          count++;
        }
        this.store.run("INSERT OR REPLACE INTO blocks (number, hash) VALUES (?, ?)", ev.blockNumber, ev.blockHash);
      }
      this.store.run("INSERT OR REPLACE INTO blocks (number, hash) VALUES (?, ?)", Number(to), toBlock.hash!.toLowerCase());
      this.store.setMeta("cursor", to.toString());
    });
    return count;
  }

  private discoverTokens(logs: Log[]): Address[] {
    const out: Address[] = [];
    for (const log of logs) {
      if (log.address.toLowerCase() !== this.cfg.manifest.contracts.OptaraCore.toLowerCase()) continue;
      try {
        const d = decodeEventLog({ abi: optaraCoreAbi, data: log.data, topics: log.topics });
        if (d.eventName === "SeriesCreated") {
          const token = (d.args as { optionToken: Address }).optionToken.toLowerCase();
          if (!this.abiByAddress.has(token)) {
            this.abiByAddress.set(token, optionTokenAbi as Abi);
            out.push(token as Address);
          }
        }
      } catch {
        // not a core event we know; ignored
      }
    }
    return out;
  }

  private decode(log: Log): StoredEvent | undefined {
    const abi = this.abiByAddress.get(log.address.toLowerCase());
    if (!abi) return undefined;
    try {
      const d = decodeEventLog({ abi, data: log.data, topics: log.topics });
      return {
        id: `${log.transactionHash}:${log.logIndex}`,
        blockNumber: Number(log.blockNumber),
        blockHash: log.blockHash!.toLowerCase(),
        txHash: log.transactionHash!.toLowerCase(),
        logIndex: Number(log.logIndex),
        address: log.address.toLowerCase(),
        name: String(d.eventName),
        args: normalizeArgs(d.args ?? {}),
      };
    } catch {
      return undefined; // e.g. Approval events of option tokens are decoded; anything else is skipped
    }
  }

  private insertEvent(ev: StoredEvent): boolean {
    const exists = this.store.get("SELECT 1 FROM events WHERE id = ?", ev.id);
    if (exists) return false; // idempotent under duplicate delivery
    this.store.run(
      "INSERT INTO events (id, block_number, block_hash, tx_hash, log_index, address, name, args) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ev.id,
      ev.blockNumber,
      ev.blockHash,
      ev.txHash,
      ev.logIndex,
      ev.address,
      ev.name,
      JSON.stringify(ev.args),
    );
    return true;
  }

  /** Detects a reorg below the cursor and rolls back to the last block whose stored hash still matches. */
  async checkReorg(): Promise<bigint | undefined> {
    const cursor = this.cursor();
    if (cursor < this.cfg.startBlock) return undefined;
    const stored = this.store.get<{ hash: string }>("SELECT hash FROM blocks WHERE number = ?", Number(cursor));
    if (!stored) return undefined;
    const onChain = await this.client.getBlock({ blockNumber: cursor }).catch(() => undefined);
    if (onChain && onChain.hash!.toLowerCase() === stored.hash) return undefined;

    const rows = this.store.all<{ number: number; hash: string }>("SELECT number, hash FROM blocks ORDER BY number DESC");
    let safe = this.cfg.startBlock - 1n;
    for (const r of rows) {
      const b = await this.client.getBlock({ blockNumber: BigInt(r.number) }).catch(() => undefined);
      if (b && b.hash!.toLowerCase() === r.hash) {
        safe = BigInt(r.number);
        break;
      }
    }
    this.rollbackTo(safe);
    return safe;
  }

  /** Deletes everything above `block` and rebuilds derived tables by replaying the remaining events. */
  rollbackTo(block: bigint): void {
    this.store.tx(() => {
      this.store.run("DELETE FROM events WHERE block_number > ?", Number(block));
      this.store.run("DELETE FROM blocks WHERE number > ?", Number(block));
      for (const t of DERIVED_TABLES) this.store.run(`DELETE FROM ${t}`);
      const events = this.store.all<{
        id: string; block_number: number; block_hash: string; tx_hash: string; log_index: number;
        address: string; name: string; args: string;
      }>("SELECT * FROM events ORDER BY block_number, log_index");
      for (const e of events) {
        applyEvent(this.store, {
          id: e.id, blockNumber: e.block_number, blockHash: e.block_hash, txHash: e.tx_hash,
          logIndex: e.log_index, address: e.address, name: e.name, args: JSON.parse(e.args),
        });
      }
      this.store.setMeta("cursor", block.toString());
    });
    // tokens discovered after the rollback point are forgotten until re-discovered
    for (const [addr, abi] of this.abiByAddress) {
      if (abi === (optionTokenAbi as Abi) && !this.store.get("SELECT 1 FROM series WHERE option_token = ?", addr)) {
        this.abiByAddress.delete(addr);
      }
    }
  }
}
