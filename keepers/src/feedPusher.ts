/**
 * TESTNET: keeps each TestnetPushFeed (a Chainlink-compatible settlement feed, contract/src/testnet) current from
 * Pyth or the signed-price source (Optara's price node; whichever serves the feed ids): price = base / quote (e.g. ETH/USD ÷ USDC/USD) at the feed's decimals, pushed once a round is
 * `intervalSeconds` old. Settlement reads the round in force at expiry, so the interval bounds its staleness.
 */
import { parseAbi, type Address, type Hex } from "viem";
import { sendTx, type Ctx } from "./tx.ts";

export const testnetPushFeedAbi = parseAbi([
  "function push(int256 answer) returns (uint80)",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);

/** Parsed prices per feed id (lower-case hex): price × 10^expo. */
export interface PriceSource {
  prices(feedIds: readonly Hex[]): Promise<Map<string, { price: bigint; expo: number; publishTime: bigint }>>;
}

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
    private readonly o: { feeds: readonly PushFeedSpec[]; prices: PriceSource; intervalSeconds: number },
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
    const pushed: Address[] = [];
    // Each feed's price is fetched separately and all at once, so a provider that fails or hangs for one feed (e.g. a
    // price node outage) never stops or delays the others. The pushes then go out one by one (one keeper nonce).
    const fetched = await Promise.allSettled(due.map((f) => this.o.prices.prices(f.quote ? [f.base, f.quote] : [f.base])));
    for (const [i, f] of due.entries()) {
      const got = fetched[i]!;
      if (got.status === "rejected") {
        this.ctx.log(`feeds: no price for ${f.label ?? f.feed}: ${((got.reason as Error)?.message ?? String(got.reason)).split("\n")[0]}`);
        continue;
      }
      const px = got.value;
      const decimals = await client.readContract({ address: f.feed, abi: testnetPushFeedAbi, functionName: "decimals" });
      const answer = ratio(px.get(f.base.toLowerCase()), f.quote ? px.get(f.quote.toLowerCase()) : undefined, decimals);
      if (answer === undefined || answer <= 0n) {
        this.ctx.log(`feeds: no price for ${f.label ?? f.feed}`);
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
