/** Auctions and liquidations (INDEXER_AND_KEEPERS.md §1.1 `auctions`). */
import { indexer, type Auction, type Liquidation } from "envio";
import { logId, once, ZERO32, ZERO_ADDRESS } from "../lib.ts";

const auctionId = (accountId: bigint, underlying: string) => `${accountId}-${underlying}`;

const blank = (kind: string, accountId: bigint, timestamp: bigint): Omit<Liquidation, "id"> => ({
  kind,
  accountId,
  underlying: ZERO_ADDRESS,
  seriesId: ZERO32,
  liquidatorAccountId: 0n,
  sliceBps: 0,
  qty: 0n,
  sliceMark: 0n,
  sliceMM: 0n,
  discount: 0n,
  penalty: 0n,
  cashToLiquidator: 0n,
  insurance: 0n,
  unpaid: 0n,
  timestamp,
});

indexer.onEvent({ contract: "LiquidationModule", event: "AuctionStarted" }, async ({ event, context }) => {
  const { accountId, underlying, equity, maintenanceMargin, startTime } = event.params;
  const a: Auction = {
    id: auctionId(accountId, underlying),
    accountId,
    underlying,
    active: true,
    startTime,
    startEquity: equity,
    startMaintenanceMargin: maintenanceMargin,
    slices: 0,
    wrapperLiquidations: 0,
    endedAt: 0n,
    endReason: 0,
  };
  context.Auction.set(a);
});

indexer.onEvent({ contract: "LiquidationModule", event: "SliceLiquidated", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.Liquidation.set({
    id: logId(event),
    ...blank("SLICE", e.accountId, BigInt(event.block.timestamp)),
    underlying: e.underlying,
    liquidatorAccountId: e.liquidatorAccountId,
    sliceBps: Number(e.sliceBps),
    sliceMark: e.sliceMark,
    sliceMM: e.sliceMM,
    discount: e.discount,
    penalty: e.penalty,
    cashToLiquidator: e.cashToLiquidator,
  });
  await once(context, event, async () => {
    const a = await context.Auction.get(auctionId(e.accountId, e.underlying));
    if (a) context.Auction.set({ ...a, slices: a.slices + 1 });
  });
});

indexer.onEvent({ contract: "LiquidationModule", event: "WrapperLiquidated", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  const series = await context.Series.get(e.seriesId);
  context.Liquidation.set({
    id: logId(event),
    ...blank("WRAPPER", e.accountId, BigInt(event.block.timestamp)),
    underlying: series?.underlying ?? ZERO_ADDRESS,
    seriesId: e.seriesId,
    liquidatorAccountId: e.liquidatorAccountId,
    qty: e.qty,
    penalty: e.penalty,
    cashToLiquidator: e.cashToLiquidator,
  });
  if (!series) return;
  await once(context, event, async () => {
    const a = await context.Auction.get(auctionId(e.accountId, series.underlying));
    if (a?.active) context.Auction.set({ ...a, wrapperLiquidations: a.wrapperLiquidations + 1 });
  });
});

indexer.onEvent({ contract: "LiquidationModule", event: "AuctionEnded", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const a = await context.Auction.get(auctionId(event.params.accountId, event.params.underlying));
  if (a) context.Auction.set({ ...a, active: false, endedAt: BigInt(event.block.timestamp), endReason: Number(event.params.reason) });
});

indexer.onEvent({ contract: "LiquidationModule", event: "BadDebtCovered", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.Liquidation.set({
    id: logId(event),
    ...blank("BAD_DEBT", e.accountId, BigInt(event.block.timestamp)),
    insurance: e.insuranceAmount,
    unpaid: e.unpaid,
  });
});
