/** Shared handler helpers. */

/** A log's id on its chain (equivalent to (txHash, logIndex): unique, and rolled back with the block on a reorg). */
export const logId = (event: { block: { number: number }; logIndex: number }) => `${event.block.number}_${event.logIndex}`;

/**
 * Runs `apply` once per log: delta-based updates (wrapper supply and balances, fee and insurance tallies, counters)
 * would double on a duplicated delivery, so the first application records the log and later ones are skipped.
 */
export async function once(
  context: { ProcessedLog: { get(id: string): Promise<{ id: string } | undefined>; set(e: { id: string }): void } },
  event: { block: { number: number }; logIndex: number },
  apply: () => Promise<void> | void,
): Promise<void> {
  const id = logId(event);
  if (await context.ProcessedLog.get(id)) return;
  context.ProcessedLog.set({ id });
  await apply();
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
export const ZERO32 = `0x${"0".repeat(64)}`;
export const max0 = (x: bigint) => (x > 0n ? x : 0n);
export const ts = (event: { block: { timestamp: number } }) => BigInt(event.block.timestamp);
