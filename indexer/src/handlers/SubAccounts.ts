/**
 * The ledger (INDEXER_AND_KEEPERS.md §1.1: accounts.cash and positions are rebuilt from CashUpdated and
 * BalanceUpdated alone, DD-24). Both events carry the new absolute value, so replays are harmless; the series
 * totals move by the difference between the stored and the new balance, so they are replay-safe too.
 */
import { indexer, type Account, type Position } from "envio";
import { max0 } from "../lib.ts";

indexer.onEvent({ contract: "SubAccounts", event: "SubAccountCreated", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const a: Account = {
    id: event.params.accountId.toString(),
    accountId: event.params.accountId,
    owner: event.params.owner,
    settlementAsset: event.params.settlementAsset,
    cash: 0n,
    createdAt: BigInt(event.block.timestamp),
  };
  context.Account.set(a);
});

indexer.onEvent({ contract: "SubAccounts", event: "OperatorSet" }, async ({ event, context }) => {
  context.Operator.set({
    id: `${event.params.accountId}-${event.params.operator}`,
    account_id: event.params.accountId.toString(),
    operator: event.params.operator,
    approved: event.params.approved,
  });
});

indexer.onEvent({ contract: "SubAccounts", event: "CashUpdated" }, async ({ event, context }) => {
  const a = await context.Account.getOrThrow(event.params.accountId.toString());
  context.Account.set({ ...a, cash: event.params.cash });
});

indexer.onEvent({ contract: "SubAccounts", event: "BalanceUpdated", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const { accountId, seriesId, balance } = event.params;
  const id = `${accountId}-${seriesId}`;
  const prev = (await context.Position.get(id))?.balance ?? 0n;
  const p: Position = {
    id,
    account_id: accountId.toString(),
    accountId,
    series_id: seriesId,
    seriesId,
    balance,
    updatedAt: BigInt(event.block.timestamp),
  };
  context.Position.set(p);
  if (prev === balance) return;
  const s = await context.Series.getOrThrow(seriesId);
  context.Series.set({
    ...s,
    internalLong: s.internalLong + max0(balance) - max0(prev),
    internalShort: s.internalShort + max0(-balance) - max0(-prev),
  });
});

indexer.onEvent({ contract: "SubAccounts", event: "ParticipantsUpdated" }, async ({ event, context }) => {
  const g = await context.SettlementGroup.getOrThrow(event.params.groupId);
  context.SettlementGroup.set({ ...g, participants: event.params.participants });
});
