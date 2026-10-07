/**
 * Settlement keeper (INDEXER_AND_KEEPERS.md §3, SETTLEMENT.md): for every group past expiry, finalize with the
 * round-in-force proof (never choosing a price), flag ORACLE_STALLED once due, settle every participant in batches,
 * then fix the recovery ratio. Everything is permissionless and idempotent; reverts from racing keepers are logged.
 */
import type { Hex } from "viem";
import {
  buildSettlementProof,
  settlementOracleAbi,
  settlementWindowAbi,
  subAccountsAbi,
  type AccountDirectory,
  type Manifest,
  type SeriesCatalog,
} from "@optara/sdk";
import { sendTx, type Ctx } from "./tx.ts";

export const GroupState = { ACTIVE: 0, EXPIRED: 1, ORACLE_STALLED: 2, FINALIZED: 3, ALL_SETTLED: 4, REDEEMABLE: 5 } as const;

export interface SettlementKeeperOptions {
  manifest: Manifest;
  catalog: SeriesCatalog;
  /** Participant lists: the indexer in production (IndexerDirectory), or the ledger's events. */
  directory: AccountDirectory;
  /** Accounts per settleAccountsGroup call (gas: ~N × settle cost; keep well under the block limit). */
  batchSize?: number;
}

export interface TickReport {
  finalized: Hex[];
  flaggedStalled: Hex[];
  settled: { groupId: Hex; accounts: number; batches: number }[];
  ratios: Hex[];
  errors: string[];
}

export class SettlementKeeper {
  /** Groups known to be done (REDEEMABLE), skipped on later passes. */
  private readonly done = new Set<Hex>();

  constructor(
    private readonly ctx: Ctx,
    private readonly o: SettlementKeeperOptions,
  ) {}

  async tick(): Promise<TickReport> {
    const { client } = this.ctx;
    const m = this.o.manifest;
    const sw = m.proxies.SettlementWindow.proxy;
    const out: TickReport = { finalized: [], flaggedStalled: [], settled: [], ratios: [], errors: [] };
    await this.o.catalog.sync();
    const now = (await client.getBlock()).timestamp;
    for (const g of this.o.catalog.groups()) {
      if (g.expiry > now || this.done.has(g.groupId)) continue;
      let state = await client.readContract({ address: sw, abi: settlementWindowAbi, functionName: "groupState", args: [g.groupId] });

      if (state === GroupState.EXPIRED || state === GroupState.ORACLE_STALLED) {
        if (state === GroupState.ORACLE_STALLED) {
          const acct = await client.readContract({ address: sw, abi: settlementWindowAbi, functionName: "groupAccounting", args: [g.groupId] });
          if (!acct.stalledFlagged) {
            const r = await sendTx(this.ctx, { address: sw, abi: settlementWindowAbi, functionName: "flagOracleStalled", args: [g.groupId] });
            if (r.ok) out.flaggedStalled.push(g.groupId);
          }
        }
        const earliest = await client.readContract({ address: m.proxies.SettlementOracle.proxy, abi: settlementOracleAbi, functionName: "earliestFinalization", args: [g.settlementOracleConfigId, g.expiry] });
        if (now < earliest) continue;
        const proof = await buildSettlementProof(client, m.proxies.SettlementOracle.proxy, g.settlementOracleConfigId, g.expiry);
        if (proof.error) {
          out.errors.push(`${g.groupId}: no provable price yet (${proof.error})`);
          continue;
        }
        const r = await sendTx(this.ctx, { address: sw, abi: settlementWindowAbi, functionName: "finalizeGroup", args: [g.groupId, proof.settlementData] });
        if (!r.ok) {
          out.errors.push(`${g.groupId}: finalize ${r.error}`);
          continue;
        }
        out.finalized.push(g.groupId);
        this.ctx.log(`finalized ${g.groupId} at ${proof.priceWad}`);
        state = GroupState.FINALIZED;
      }

      if (state === GroupState.FINALIZED) {
        await this.o.directory.sync();
        const seriesIds = g.series.map((s) => s.seriesId);
        const batch = this.o.batchSize ?? 50;
        let accounts = 0;
        let batches = 0;
        let before = -1n;
        for (;;) {
          const left = await client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "participants", args: [g.groupId] });
          if (left === 0n) break;
          if (left === before) {
            out.errors.push(`${g.groupId}: a batch settled nobody (${left} participant(s) left)`);
            break;
          }
          before = left;
          // Holders per the directory, confirmed against the ledger (the directory may lag or include settled ones).
          const pending: bigint[] = [];
          for (const a of this.o.directory.holders(seriesIds)) {
            const n = await client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "seriesCountInGroup", args: [a, g.groupId] });
            if (n > 0n) pending.push(a);
            if (pending.length === batch) break;
          }
          if (pending.length === 0) {
            out.errors.push(`${g.groupId}: ${left} participant(s) left but none known to the directory`);
            break;
          }
          const r = await sendTx(this.ctx, { address: sw, abi: settlementWindowAbi, functionName: "settleAccountsGroup", args: [pending, g.groupId] });
          if (!r.ok) {
            out.errors.push(`${g.groupId}: settle ${r.error}`);
            break;
          }
          accounts += pending.length;
          batches++;
        }
        if (batches > 0) {
          out.settled.push({ groupId: g.groupId, accounts, batches });
          this.ctx.log(`settled ${accounts} account(s) of ${g.groupId} in ${batches} batch(es)`);
        }
        state = await client.readContract({ address: sw, abi: settlementWindowAbi, functionName: "groupState", args: [g.groupId] });
      }

      if (state === GroupState.ALL_SETTLED) {
        const r = await sendTx(this.ctx, { address: sw, abi: settlementWindowAbi, functionName: "computeRecoveryRatio", args: [g.groupId] });
        if (r.ok) {
          out.ratios.push(g.groupId);
          state = GroupState.REDEEMABLE;
        } else out.errors.push(`${g.groupId}: ratio ${r.error}`);
      }
      if (state === GroupState.REDEEMABLE) this.done.add(g.groupId);
    }
    return out;
  }
}
