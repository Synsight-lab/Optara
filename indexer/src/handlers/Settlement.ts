/** Settlement groups (INDEXER_AND_KEEPERS.md §1.1 `groups`; SETTLEMENT.md). */
import { indexer } from "envio";
import { logId, ZERO32, ZERO_ADDRESS } from "../lib.ts";

indexer.onEvent({ contract: "SettlementWindow", event: "GroupFinalized", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const g = await context.SettlementGroup.getOrThrow(event.params.groupId);
  context.SettlementGroup.set({
    ...g,
    finalized: true,
    finalizedAt: BigInt(event.block.timestamp),
    priceWad: event.params.priceWad,
    observationTime: event.params.observationTime,
    participantsAtFinalization: event.params.participants,
  });
});

indexer.onEvent({ contract: "SettlementWindow", event: "OracleStalled" }, async ({ event, context }) => {
  const g = await context.SettlementGroup.getOrThrow(event.params.groupId);
  context.SettlementGroup.set({ ...g, stalled: true });
});

indexer.onEvent({ contract: "SettlementWindow", event: "RecoveryRatioSet" }, async ({ event, context }) => {
  const g = await context.SettlementGroup.getOrThrow(event.params.groupId);
  context.SettlementGroup.set({
    ...g,
    ratioSet: true,
    ratioWad: event.params.ratioWad,
    grossClaim: event.params.grossClaim,
    collected: event.params.collected,
    insurance: event.params.insuranceContribution,
  });
});

indexer.onEvent({ contract: "SettlementWindow", event: "DustSwept" }, async ({ event, context }) => {
  const g = await context.SettlementGroup.getOrThrow(event.params.groupId);
  context.SettlementGroup.set({ ...g, dustSwept: event.params.amount });
});

const blank = { accountId: 0n, seriesId: ZERO32, holder: ZERO_ADDRESS, netNumerator: 0n, amount: 0n, unpaid: 0n };

indexer.onEvent({ contract: "SettlementWindow", event: "AccountSettled", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.SettlementEvent.set({
    id: logId(event),
    kind: "SETTLED",
    groupId: e.groupId,
    ...blank,
    accountId: e.accountId,
    netNumerator: e.netNumerator,
    amount: e.collected,
    unpaid: e.unpaid,
    timestamp: BigInt(event.block.timestamp),
  });
});

indexer.onEvent({ contract: "SettlementWindow", event: "SettlementClaimed", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.SettlementEvent.set({
    id: logId(event),
    kind: "CLAIMED",
    groupId: e.groupId,
    ...blank,
    accountId: e.accountId,
    amount: e.amount,
    timestamp: BigInt(event.block.timestamp),
  });
});

indexer.onEvent({ contract: "SettlementWindow", event: "WrapperRedeemed", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  const series = await context.Series.get(e.seriesId);
  context.SettlementEvent.set({
    id: logId(event),
    kind: "REDEEMED",
    groupId: series?.group_id ?? ZERO32,
    ...blank,
    seriesId: e.seriesId,
    holder: e.holder,
    amount: e.payout,
    netNumerator: e.qty,
    timestamp: BigInt(event.block.timestamp),
  });
});
