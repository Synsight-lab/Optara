import { indexer, type Product, type Series, type SettlementGroup } from "envio";
import { ZERO32 } from "../lib.ts";

indexer.onEvent({ contract: "OptionSeriesRegistry", event: "ProductApproved" }, async ({ event, context }) => {
  const existing = await context.Product.get(event.params.productId);
  const p: Product = {
    id: event.params.productId,
    underlying: event.params.underlying,
    settlementAsset: event.params.settlementAsset,
    underlyingSymbol: event.params.config.underlyingSymbol,
    assetSymbol: event.params.config.assetSymbol,
    enabled: true,
    closeOnly: existing?.closeOnly ?? false,
    emergency: existing?.emergency ?? false,
    spotPriceWad: existing?.spotPriceWad ?? 0n,
    spotPublishTime: existing?.spotPublishTime ?? 0n,
    surfaceSeq: existing?.surfaceSeq ?? 0n,
    surfaceValidAfter: existing?.surfaceValidAfter ?? 0n,
    surfaceExpiresAt: existing?.surfaceExpiresAt ?? 0n,
    surfaceLowConfidence: existing?.surfaceLowConfidence ?? false,
    shortCapUnderlyingWad: existing?.shortCapUnderlyingWad ?? 0n,
    riskParameterSetId: existing?.riskParameterSetId ?? ZERO32,
  };
  context.Product.set(p);
});

indexer.onEvent({ contract: "OptionSeriesRegistry", event: "ProductEnabled" }, async ({ event, context }) => {
  const p = await context.Product.get(event.params.productId);
  if (p) context.Product.set({ ...p, enabled: event.params.enabled });
});

indexer.onEvent({ contract: "OptionSeriesRegistry", event: "GroupCreated" }, async ({ event, context }) => {
  const g: SettlementGroup = {
    id: event.params.groupId,
    underlying: event.params.underlying,
    settlementAsset: event.params.settlementAsset,
    expiry: event.params.expiry,
    settlementOracleConfigId: event.params.settlementOracleConfigId,
    participants: 0n,
    finalized: false,
    finalizedAt: 0n,
    priceWad: 0n,
    observationTime: 0n,
    participantsAtFinalization: 0n,
    stalled: false,
    ratioSet: false,
    ratioWad: 0n,
    grossClaim: 0n,
    collected: 0n,
    insurance: 0n,
    dustSwept: 0n,
  };
  context.SettlementGroup.set(g);
});

// The wrapper's own events are indexed from its creation on (same-block coverage).
indexer.contractRegister({ contract: "OptionSeriesRegistry", event: "SeriesCreated" }, async ({ event, context }) => {
  context.chain.ExternalOptionWrapper.add(event.params.wrapper);
});

indexer.onEvent({ contract: "OptionSeriesRegistry", event: "SeriesCreated", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const t = event.params.terms;
  const s: Series = {
    id: event.params.seriesId,
    group_id: event.params.groupId,
    productId: t.volSurfaceProductId,
    underlying: t.underlying,
    settlementAsset: t.settlementAsset,
    wrapper: event.params.wrapper,
    optionType: Number(t.optionType),
    strikeWad: t.strikeWad,
    contractSizeWad: t.contractSizeWad,
    expiry: t.expiry,
    settlementOracleConfigId: t.settlementOracleConfigId,
    riskParameterSetId: t.riskParameterSetId,
    createdAt: BigInt(event.block.timestamp),
    wrapperSupply: 0n,
    internalLong: 0n,
    internalShort: 0n,
  };
  context.Series.set(s);
});
