/**
 * OptionClearing: every write (ExternalLongMinted), kept as history for profit and loss. Balances themselves come from
 * the ledger (SubAccounts.BalanceUpdated); this only adds the quantity, recipient and fee of each write.
 */
import { indexer } from "envio";
import { logId } from "../lib.ts";

indexer.onEvent({ contract: "OptionClearing", event: "ExternalLongMinted", fields: { block: ["timestamp"] } }, async ({ event, context }) => {
  const e = event.params;
  context.Mint.set({
    id: logId(event),
    accountId: e.accountId,
    seriesId: e.seriesId,
    qty: e.qty,
    recipient: e.recipient,
    fee: e.fee,
    timestamp: BigInt(event.block.timestamp),
  });
});
