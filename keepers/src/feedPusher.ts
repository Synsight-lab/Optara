/**
 * TESTNET: keeps each TestnetPushFeed (a Chainlink-compatible settlement feed, contract/src/testnet) current from
 * Pyth: price = base / quote (e.g. ETH/USD ÷ USDC/USD) at the feed's decimals, pushed once a round is
 * `intervalSeconds` old. Settlement reads the round in force at expiry, so the interval bounds its staleness.
 */
import { parseAbi, type Address, type Hex } from "viem";
import type { HermesSource } from "@optara/sdk";
import { sendTx, type Ctx } from "./tx.ts";

export const testnetPushFeedAbi = parseAbi([
  "function push(int256 answer) returns (uint80)",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);

export interface PushFeedSpec {
  /** The TestnetPushFeed. */
  feed: Address;
  /** Pyth feed ids: base (e.g. ETH/USD) and optional quote (e.g. USDC/USD). */
  base: Hex;
  quote?: Hex;
  label?: string;
}

export class FeedPusher {
  constructor(
    private readonly ctx: Ctx,
    private readonly o: { feeds: readonly PushFeedSpec[]; hermes: HermesSource; intervalSeconds: number },
  ) {}

  /** One pass: pushes every feed whose latest round is at least intervalSeconds old. Returns the feeds pushed. */
  async tick(): Promise<Address[]> {
    const { client } = this.ctx;
    const now = (await client.getBlock()).timestamp;
    const due: PushFeedSpec[] = [];
    for (const f of this.o.feeds) {
      const updatedAt = await client
        .readContract({ address: f.feed, abi: testnetPushFeedAbi, functionName: "latestRoundData" })
        .then((r) => r[3])
        .catch(() => 0n); // no round yet
      if (now - updatedAt >= BigInt(this.o.intervalSeconds)) due.push(f);
    }
    if (due.length === 0) return [];
    const ids = [...new Set(due.flatMap((f) => (f.quote ? [f.base, f.quote] : [f.base])))];
    const px = await this.o.hermes.prices(ids);
    const pushed: Address[] = [];
    for (const f of due) {
      const decimals = await client.readContract({ address: f.feed, abi: testnetPushFeedAbi, functionName: "decimals" });
      const answer = ratio(px.get(f.base.toLowerCase()), f.quote ? px.get(f.quote.toLowerCase()) : undefined, decimals);
      if (answer === undefined || answer <= 0n) {
        this.ctx.log(`feeds: no Pyth price for ${f.label ?? f.feed}`);
        continue;
      }
      const r = await sendTx(this.ctx, { address: f.feed, abi: testnetPushFeedAbi, functionName: "push", args: [answer] });
      if (r.ok) pushed.push(f.feed);
      this.ctx.log(r.ok ? `feeds: pushed ${f.label ?? f.feed} = ${answer} (${decimals} dp)` : `feeds: push failed for ${f.label ?? f.feed}: ${r.error}`);
    }
    return pushed;
  }
}

type Px = { price: bigint; expo: number } | undefined;

/** base / quote at `decimals` (no quote: base alone), from Pyth's price × 10^expo, rounded down. */
export function ratio(base: Px, quote: Px, decimals: number): bigint | undefined {
  if (!base) return undefined;
  const q = quote ?? { price: 1n, expo: 0 };
  if (q.price <= 0n) return undefined;
  const e = decimals + base.expo - q.expo; // answer = base.price × 10^e / q.price
  return e >= 0 ? (base.price * 10n ** BigInt(e)) / q.price : base.price / (q.price * 10n ** BigInt(-e));
}
