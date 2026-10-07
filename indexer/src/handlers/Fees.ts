/** Fees and insurance (INDEXER_AND_KEEPERS.md §1.1 `fees`, `insurance`). */
import { indexer, type Insurance } from "envio";
import { logId, once, ZERO32 } from "../lib.ts";

const fresh = (asset: string): Insurance => ({ id: asset, deposited: 0n, fromFees: 0n, paid: 0n, minimumSeed: 0n, minimumKeeperReserve: 0n });

const fee = (kind: string, asset: string, amount: bigint, extra: { accountId?: bigint; payer?: string; seriesId?: string }, timestamp: bigint) => ({
  kind,
  asset,
  accountId: extra.accountId ?? 0n,
  payer: extra.payer ?? "",
  seriesId: extra.seriesId ?? ZERO32,
  amount,
  toInsurance: 0n,
  toTreasury: 0n,
  toKeeper: 0n,
  timestamp,
});

indexer.onEvent({ contract: "FeeController", event: "SellerFeeCharged", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const { accountId, seriesId, asset, fee: amount } = event.params;
  context.Fee.set({ id: logId(event), ...fee("SELLER", asset, amount, { accountId, seriesId }, BigInt(event.block.timestamp)) });
});

indexer.onEvent({ contract: "FeeController", event: "BuyerFeeCharged", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const { buyer, seriesId, asset, fee: amount } = event.params;
  context.Fee.set({ id: logId(event), ...fee("BUYER", asset, amount, { payer: buyer, seriesId }, BigInt(event.block.timestamp)) });
});

indexer.onEvent({ contract: "FeeController", event: "KeeperRewardPaid", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const { asset, keeper, amount } = event.params;
  context.Fee.set({ id: logId(event), ...fee("KEEPER_REWARD", asset, amount, { payer: keeper }, BigInt(event.block.timestamp)) });
});

indexer.onEvent({ contract: "FeeController", event: "FeeSplit", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const { asset, fee: amount, toInsurance, toTreasury, toKeeper } = event.params;
  context.Fee.set({ id: logId(event), ...fee("SPLIT", asset, amount, {}, BigInt(event.block.timestamp)), toInsurance, toTreasury, toKeeper });
  await once(context, event, async () => {
    const i = (await context.Insurance.get(asset)) ?? fresh(asset);
    context.Insurance.set({ ...i, fromFees: i.fromFees + toInsurance });
  });
});

indexer.onEvent({ contract: "FeeController", event: "MinimumsSet" }, async ({ event, context }) => {
  const i = (await context.Insurance.get(event.params.asset)) ?? fresh(event.params.asset);
  context.Insurance.set({ ...i, minimumSeed: event.params.minimumInsuranceSeed, minimumKeeperReserve: event.params.minimumKeeperReserve });
});

indexer.onEvent({ contract: "InsuranceFund", event: "InsuranceDeposited" }, async ({ event, context }) => {
  await once(context, event, async () => {
    const i = (await context.Insurance.get(event.params.asset)) ?? fresh(event.params.asset);
    context.Insurance.set({ ...i, deposited: i.deposited + event.params.amount });
  });
});

indexer.onEvent({ contract: "InsuranceFund", event: "InsurancePaid" }, async ({ event, context }) => {
  await once(context, event, async () => {
    const i = (await context.Insurance.get(event.params.asset)) ?? fresh(event.params.asset);
    context.Insurance.set({ ...i, paid: i.paid + event.params.amount });
  });
});
