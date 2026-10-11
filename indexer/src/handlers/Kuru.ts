/**
 * Maker orders on Kuru order books (the in-app "My Kuru orders"): each Kuru market the VenueRegistry registers for a
 * series is indexed from that block on. Trade and OrdersCanceled carry absolute values (the order's remaining size),
 * so replays are harmless.
 */
import { indexer, type KuruOrder } from "envio";
import { keccak256, toHex } from "viem";
import { ts } from "../lib.ts";

/** KuruAdapter.VENUE_ID. */
const KURU_VENUE = keccak256(toHex("KURU"));

const orderKey = (market: string, orderId: bigint | number) => `${market.toLowerCase()}-${orderId}`;

indexer.contractRegister({ contract: "VenueRegistry", event: "MarketRegistered" }, async ({ event, context }) => {
  if (event.params.venueId.toLowerCase() === KURU_VENUE) context.chain.KuruOrderBook.add(event.params.market);
});

indexer.onEvent({ contract: "KuruOrderBook", event: "OrderCreated", fields: { block: ["timestamp"], transaction: ["hash"] } }, async ({ event, context }) => {
  const [m] = await context.Market.getWhere({ market: { _eq: event.srcAddress } });
  if (!m) return;
  const e = event.params;
  const o: KuruOrder = {
    id: orderKey(event.srcAddress, e.orderId),
    market: event.srcAddress,
    seriesId: m.seriesId,
    orderId: BigInt(e.orderId),
    owner: e.owner.toLowerCase(),
    isBuy: e.isBuy,
    priceUnits: BigInt(e.price),
    sizeUnits: BigInt(e.size),
    remainingUnits: BigInt(e.size),
    filledUnits: 0n,
    status: "OPEN",
    createdBlock: BigInt(event.block.number),
    updatedBlock: BigInt(event.block.number),
    txHash: event.transaction.hash,
    createdAt: ts(event),
    updatedAt: ts(event),
  };
  context.KuruOrder.set(o);
});

indexer.onEvent(
  { contract: "KuruOrderBook", event: "Trade", fields: { block: ["timestamp"], transaction: ["hash"] } },
  async ({ event, context }) => {
    const o = await context.KuruOrder.get(orderKey(event.srcAddress, event.params.orderId));
    if (!o || o.status === "CANCELLED") return;
    const remaining = BigInt(event.params.updatedSize);
    context.KuruOrder.set({
      ...o,
      remainingUnits: remaining,
      filledUnits: o.sizeUnits > remaining ? o.sizeUnits - remaining : 0n,
      status: remaining === 0n ? "FILLED" : remaining < o.sizeUnits ? "PARTIAL" : "OPEN",
      updatedBlock: BigInt(event.block.number),
      txHash: event.transaction.hash,
      updatedAt: ts(event),
    });
  },
);

indexer.onEvent(
  { contract: "KuruOrderBook", event: "OrdersCanceled", fields: { block: ["timestamp"], transaction: ["hash"] } },
  async ({ event, context }) => {
    for (const id of event.params.orderId) {
      const o = await context.KuruOrder.get(orderKey(event.srcAddress, id));
      if (!o || o.status === "FILLED") continue;
      context.KuruOrder.set({
        ...o,
        remainingUnits: 0n,
        status: "CANCELLED",
        updatedBlock: BigInt(event.block.number),
        txHash: event.transaction.hash,
        updatedAt: ts(event),
      });
    }
  },
);
