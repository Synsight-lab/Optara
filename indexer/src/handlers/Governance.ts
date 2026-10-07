/**
 * Markets, trades and governance activity (INDEXER_AND_KEEPERS.md §1.1 `markets`; SECURITY.md §5 "Governance":
 * any UpgradeScheduled, publisher change or parameter change is alerted on by the API).
 */
import { indexer } from "envio";
import { logId } from "../lib.ts";

const json = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x));

indexer.onEvent({ contract: "VenueRegistry", event: "MarketRegistered" }, async ({ event, context }) => {
  const id = `${event.params.venueId}-${event.params.seriesId}`;
  context.Market.set({ id, venueId: event.params.venueId, seriesId: event.params.seriesId, market: event.params.market, status: 0 });
});

indexer.onEvent({ contract: "VenueRegistry", event: "MarketStatusSet" }, async ({ event, context }) => {
  const m = await context.Market.get(`${event.params.venueId}-${event.params.seriesId}`);
  if (m) context.Market.set({ ...m, status: Number(event.params.status) });
});

indexer.onEvent({ contract: "VenueRouter", event: "VenueTrade", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.Trade.set({
    id: logId(event),
    venueId: e.venueId,
    seriesId: e.seriesId,
    trader: e.trader,
    recipient: e.recipient,
    isBuy: e.isBuy,
    qty: e.qty,
    premium: e.premium,
    buyerFee: e.buyerFee,
    venueFee: e.venueFee,
    timestamp: BigInt(event.block.timestamp),
  });
});

indexer.onEvent({ contract: "ProtocolControl", event: "ProductCloseOnlySet", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, closeOnly: event.params.closeOnly });
  context.GovernanceEvent.set({ id: logId(event), kind: "CLOSE_ONLY", contract: "ProtocolControl", detail: json(event.params), timestamp: BigInt(event.block.timestamp) });
});

for (const [contract, name, kind] of [
  ["ProtocolControl", "RoleGranted", "ROLE_GRANTED"],
  ["ProtocolControl", "RoleRevoked", "ROLE_REVOKED"],
  ["ProtocolControl", "Paused", "PAUSED"],
  ["ProtocolControl", "Unpaused", "UNPAUSED"],
  ["UpgradeAdmin", "UpgradeScheduled", "UPGRADE_SCHEDULED"],
  ["UpgradeAdmin", "UpgradeExecuted", "UPGRADE_EXECUTED"],
  ["UpgradeAdmin", "UpgradeCancelled", "UPGRADE_CANCELLED"],
  ["UpgradeAdmin", "ImplementationAllowed", "IMPLEMENTATION_ALLOWED"],
  ["UpgradeAdmin", "GovernanceTransferred", "GOVERNANCE_TRANSFERRED"],
] as const) {
  indexer.onEvent({ contract, event: name, fields: { block: ["timestamp"] } } as any, async ({ event, context }: any) => {
    context.GovernanceEvent.set({ id: logId(event), kind, contract, detail: json(event.params), timestamp: BigInt(event.block.timestamp) });
  });
}
