/** Wrapper supply and holders (INDEXER_AND_KEEPERS.md §1.1 `wrapper_supply`), from each wrapper's Transfer. */
import { indexer } from "envio";
import { once, ZERO_ADDRESS } from "../lib.ts";

indexer.onEvent({ contract: "ExternalOptionWrapper", event: "Transfer" }, async ({ event, context }) => {
  await once(context, event, async () => {
    const [series] = await context.Series.getWhere({ wrapper: { _eq: event.srcAddress } });
    if (!series) return;
    const { from, to, value } = event.params;
    let supply = series.wrapperSupply;
    if (from === ZERO_ADDRESS) supply += value;
    else {
      const id = `${event.srcAddress}-${from}`;
      const b = await context.WrapperBalance.get(id);
      context.WrapperBalance.set({ id, series_id: series.id, holder: from, balance: (b?.balance ?? 0n) - value });
    }
    if (to === ZERO_ADDRESS) supply -= value;
    else {
      const id = `${event.srcAddress}-${to}`;
      const b = await context.WrapperBalance.get(id);
      context.WrapperBalance.set({ id, series_id: series.id, holder: to, balance: (b?.balance ?? 0n) + value });
    }
    if (supply !== series.wrapperSupply) context.Series.set({ ...series, wrapperSupply: supply });
  });
});
