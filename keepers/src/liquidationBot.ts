/**
 * Reference liquidation bot (INDEXER_AND_KEEPERS.md §4, LIQUIDATION.md §3). Stateless: everything it acts on is
 * read from the chain each pass (auction start times, bonuses, previews), so a restart resumes where it left off.
 *
 *   for accounts with positions: if equity < MM and a bucket has no auction → startAuction
 *   for active auctions: previewSlice at the current bonus; take it when the discount (the liquidator's gain at
 *   mark: it takes legs worth sliceMark and receives −sliceMark + discount) clears `minProfitNative`
 */
import type { Hex } from "viem";
import {
  liquidationModuleAbi,
  optionClearingAbi,
  optionSeriesRegistryAbi,
  portfolioRiskManagerAbi,
  subAccountsAbi,
  type AccountDirectory,
  type Manifest,
} from "@optara/sdk";
import { feeFor, type OracleFeed } from "./oracleFeed.ts";
import { sendTx, type Ctx } from "./tx.ts";

export interface LiquidationBotOptions {
  manifest: Manifest;
  directory: AccountDirectory;
  /** The bot's own funded subaccount (operated by the bot's key, same settlement asset). */
  liquidatorAccountId: bigint;
  feed: OracleFeed;
  /** Minimum gain per slice in the settlement asset's native units (covers hedging and gas). */
  minProfitNative?: bigint;
  /** Slice size; default the module's maxSliceBps (10,000 in whole-bucket mode). */
  sliceBps?: number;
  /** Slippage tolerance on the previewed cash, in bps. */
  slippageBps?: number;
}

export interface BotReport {
  started: { accountId: bigint; underlying: Hex }[];
  slices: { accountId: bigint; underlying: Hex; sliceBps: number; discount: bigint }[];
  ended: { accountId: bigint; underlying: Hex }[];
  skipped: string[];
}

export class LiquidationBot {
  constructor(
    private readonly ctx: Ctx,
    private readonly o: LiquidationBotOptions,
  ) {}

  async tick(): Promise<BotReport> {
    const { client } = this.ctx;
    const m = this.o.manifest;
    const lm = m.proxies.LiquidationModule.proxy;
    const out: BotReport = { started: [], slices: [], ended: [], skipped: [] };
    await this.o.directory.sync();
    const params = await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "liquidationParams" });

    for (const accountId of this.o.directory.withPositions()) {
      if (accountId === this.o.liquidatorAccountId) continue;
      const risk = await client.readContract({ address: m.proxies.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "riskOf", args: [accountId] });
      const buckets = await client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "bucketsOf", args: [accountId] });
      const positions = await client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "positionsOf", args: [accountId] });
      const products = [...new Set(positions.map((p) => p.series.productId))];

      for (const underlying of buckets) {
        let start = await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "auctionStart", args: [accountId, underlying] });
        if (start === 0n) {
          if (risk.equity >= BigInt(risk.maintenanceMargin)) continue;
          const u = await this.o.feed.forAccount(accountId, products);
          const r = await sendTx(this.ctx, { address: lm, abi: liquidationModuleAbi, functionName: "startAuction", args: [accountId, underlying, u], value: await feeFor(client, m, u) });
          if (!r.ok) {
            out.skipped.push(`start ${accountId}: ${r.error}`);
            continue;
          }
          out.started.push({ accountId, underlying });
          this.ctx.log(`auction started: account ${accountId} ${underlying}`);
          start = 1n;
        }

        // Slice while the auction runs and a slice pays.
        for (let i = 0; i < 40; i++) {
          if ((await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "auctionStart", args: [accountId, underlying] })) === 0n) break;
          const [, wholeBucket] = await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "currentBonus", args: [accountId, underlying] });
          const slice = this.o.sliceBps ?? (wholeBucket ? 10_000 : params.maxSliceBps);
          const u = await this.o.feed.forAccount(accountId, products);
          // Apply the oracle data first so the preview prices the slice exactly as execution will (PRV-004).
          await sendTx(this.ctx, { address: m.proxies.OptionClearing.proxy, abi: optionClearingAbi, functionName: "updateOracles", args: [u], value: await feeFor(client, m, u) });
          let preview: readonly [bigint, bigint, bigint, bigint, bigint];
          try {
            preview = await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "previewSlice", args: [accountId, underlying, slice] });
          } catch (e) {
            out.skipped.push(`preview ${accountId}: ${(e as Error).message.split("\n")[0]}`);
            break;
          }
          const [, , discount, , cashToLiquidator] = preview;
          const gain = discount / 10n ** BigInt(18 - (await this.decimals(accountId)));
          if (gain < (this.o.minProfitNative ?? 0n)) {
            out.skipped.push(`slice ${accountId}: gain ${gain} below minimum`);
            break;
          }
          const slip = BigInt(this.o.slippageBps ?? 100);
          const minCash = cashToLiquidator > 0n ? (cashToLiquidator * (10_000n - slip)) / 10_000n : 0n;
          const maxPay = cashToLiquidator < 0n ? (-cashToLiquidator * (10_000n + slip)) / 10_000n : 0n;
          const empty = { spotUpdates: [], spotProductIds: [], reports: [], reportSignatures: [], nodes: [] };
          const r = await sendTx(this.ctx, {
            address: lm,
            abi: liquidationModuleAbi,
            functionName: "liquidateSlice",
            args: [accountId, underlying, this.o.liquidatorAccountId, slice, minCash, maxPay, empty],
          });
          if (!r.ok) {
            // At the target the module refuses further slices; the auction is then ended.
            if (/NotLiquidatable/.test(r.error)) {
              const e = await sendTx(this.ctx, { address: lm, abi: liquidationModuleAbi, functionName: "endAuction", args: [accountId, underlying, empty] });
              if (e.ok) out.ended.push({ accountId, underlying });
            } else out.skipped.push(`slice ${accountId}: ${r.error}`);
            break;
          }
          out.slices.push({ accountId, underlying, sliceBps: slice, discount });
          this.ctx.log(`slice ${slice} bps of account ${accountId}: discount ${discount}`);
          if ((await client.readContract({ address: lm, abi: liquidationModuleAbi, functionName: "auctionStart", args: [accountId, underlying] })) === 0n) {
            out.ended.push({ accountId, underlying });
            break;
          }
        }
      }
    }
    return out;
  }

  private readonly decimalsCache = new Map<bigint, number>();
  private async decimals(accountId: bigint): Promise<number> {
    const cached = this.decimalsCache.get(accountId);
    if (cached !== undefined) return cached;
    const m = this.o.manifest;
    const asset = await this.ctx.client.readContract({ address: m.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "settlementAssetOf", args: [accountId] });
    const d = await this.ctx.client.readContract({ address: m.proxies.OptionSeriesRegistry.proxy, abi: optionSeriesRegistryAbi, functionName: "settlementAssetDecimals", args: [asset] });
    this.decimalsCache.set(accountId, d);
    return d;
  }
}
