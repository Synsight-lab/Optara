/** Spot, surfaces, product risk settings (INDEXER_AND_KEEPERS.md §1.1 `spot`, `surfaces`). */
import { indexer } from "envio";
import { logId, once } from "../lib.ts";

indexer.onEvent({ contract: "LiveSpotOracle", event: "SpotUpdated" }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, spotPriceWad: event.params.priceWad, spotPublishTime: event.params.publishTime });
});

indexer.onEvent(
  { contract: "VolSurfaceOracle", event: "SurfaceAccepted", fields: { block: ["timestamp"], transaction: ["hash"] } },
  async ({ event, context }) => {
    const { productId, surfaceSeq, surfaceRoot, validAfter, expiresAt, confidenceBps, lowConfidence } = event.params;
    const id = `${productId}-${surfaceSeq}`;
    const existing = await context.Surface.get(id);
    context.Surface.set({
      id,
      productId,
      seq: surfaceSeq,
      root: surfaceRoot,
      validAfter,
      expiresAt,
      confidenceBps: Number(confidenceBps),
      lowConfidence,
      acceptedAt: BigInt(event.block.timestamp),
      acceptedBlock: BigInt(event.block.number),
      transaction: event.transaction.hash,
      nodesProven: existing?.nodesProven ?? 0,
    });
    const p = await context.Product.get(productId);
    if (p) context.Product.set({ ...p, surfaceSeq, surfaceValidAfter: validAfter, surfaceExpiresAt: expiresAt, surfaceLowConfidence: lowConfidence });
  },
);

indexer.onEvent({ contract: "VolSurfaceOracle", event: "NodeProven" }, async ({ event, context }) => {
  await once(context, event, async () => {
    const s = await context.Surface.get(`${event.params.productId}-${event.params.surfaceSeq}`);
    if (s) context.Surface.set({ ...s, nodesProven: s.nodesProven + 1 });
  });
});

indexer.onEvent({ contract: "VolSurfaceOracle", event: "EmergencyModeSet", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, emergency: event.params.enabled });
  context.GovernanceEvent.set({
    id: logId(event),
    kind: event.params.enabled ? "EMERGENCY_ON" : "EMERGENCY_OFF",
    contract: "VolSurfaceOracle",
    detail: event.params.productId,
    timestamp: BigInt(event.block.timestamp),
  });
});

for (const [name, kind] of [
  ["PublisherAdded", "PUBLISHER_ADDED"],
  ["PublisherRemoved", "PUBLISHER_REMOVED"],
  ["QuorumSet", "QUORUM_SET"],
] as const) {
  indexer.onEvent({ contract: "VolSurfaceOracle", event: name, fields: { block: ["timestamp"] } }, async ({ event, context }) => {
    context.GovernanceEvent.set({
      id: logId(event),
      kind,
      contract: "VolSurfaceOracle",
      detail: JSON.stringify(event.params, (_, v) => (typeof v === "bigint" ? v.toString() : v)),
      timestamp: BigInt(event.block.timestamp),
    });
  });
}

indexer.onEvent({ contract: "PortfolioRiskManager", event: "ProductRiskSetAssigned" }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, riskParameterSetId: event.params.riskParameterSetId });
});

indexer.onEvent({ contract: "PortfolioRiskManager", event: "ProductShortCapSet", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, shortCapUnderlyingWad: event.params.maxShortUnderlyingWad });
  context.GovernanceEvent.set({
    id: logId(event),
    kind: "SHORT_CAP_SET",
    contract: "PortfolioRiskManager",
    detail: `${event.params.productId} ${event.params.maxShortUnderlyingWad}`,
    timestamp: BigInt(event.block.timestamp),
  });
});
