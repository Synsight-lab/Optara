/**
 * Local settlement-feed heartbeat. Real Chainlink feeds publish a round at least every heartbeat, so a round is always
 * in force inside an expiry's observation window (ORACLES.md §5.2). The local stack's MockAggregator feeds only get the
 * round pushed at deploy, so without this every group past expiry is unprovable (`InvalidSettlementProof`).
 *
 * Each call:
 *   1. backfills: for every expired, unfinalized group whose window has no round yet (the feed was silent the whole
 *      window), pushes one round stamped at the window's end — only while the feed's latest round is older than the
 *      window, so round times stay increasing;
 *   2. pushes a fresh round stamped now.
 * Local only: MockAggregator.pushRound is permissionless.
 */
import { parseAbi, type Account, type Address } from "viem";
import { settlementOracleAbi, settlementWindowAbi } from "../abi.ts";
import type { SeriesCatalog } from "../catalog.ts";
import { aggregatorV3Abi } from "../settlement.ts";
import type { LocalStack } from "./index.ts";

const mockAggregatorAbi = parseAbi([
  "function pushRound(int256 answer, uint256 updatedAt) returns (uint80)",
  "function decimals() view returns (uint8)",
]);
/** SettlementWindow.GroupState: EXPIRED = 1, ORACLE_STALLED = 2 still need a price. */
const NEEDS_PRICE = new Set([1, 2]);

export interface HeartbeatReport {
  backfilled: number;
  pushed: number;
}

/**
 * @param prices settlement price per feed (lowercased feed address → underlying priced in the settlement asset).
 *               Feeds without a price are left alone.
 */
export async function heartbeatSettlementFeeds(
  s: LocalStack,
  account: Account,
  catalog: SeriesCatalog,
  prices: Map<string, number>,
): Promise<HeartbeatReport> {
  const c = s.test;
  const oracle = s.manifest.proxies.SettlementOracle.proxy;
  const window = s.manifest.proxies.SettlementWindow.proxy;
  await catalog.sync();
  const now = (await c.getBlock()).timestamp;

  // Observation windows of groups that still need a price, per feed.
  const windows = new Map<string, { start: bigint; end: bigint }[]>();
  const configs = new Map<string, { feed: Address; start: bigint; end: bigint }>();
  for (const g of catalog.groups()) {
    if (g.expiry > now) continue;
    const state = Number(await c.readContract({ address: window, abi: settlementWindowAbi, functionName: "groupState", args: [g.groupId] }));
    if (!NEEDS_PRICE.has(state)) continue;
    let cfg = configs.get(g.settlementOracleConfigId);
    if (!cfg) {
      const raw = await c.readContract({ address: oracle, abi: settlementOracleAbi, functionName: "getConfig", args: [g.settlementOracleConfigId] });
      cfg = { feed: raw.primary.feed, start: BigInt(raw.observationStartOffset), end: BigInt(raw.observationEndOffset) };
      configs.set(g.settlementOracleConfigId, cfg);
    }
    const key = cfg.feed.toLowerCase();
    windows.set(key, [...(windows.get(key) ?? []), { start: g.expiry + cfg.start, end: g.expiry + cfg.end }]);
  }

  const push = async (feed: Address, answer: bigint, at: bigint) => {
    const hash = await c.writeContract({ account, chain: c.chain, address: feed, abi: mockAggregatorAbi, functionName: "pushRound", args: [answer, at] });
    await c.waitForTransactionReceipt({ hash });
  };
  const latestAt = async (feed: Address) =>
    (await c.readContract({ address: feed, abi: aggregatorV3Abi, functionName: "latestRoundData" }))[3];

  const report: HeartbeatReport = { backfilled: 0, pushed: 0 };
  for (const [key, price] of prices) {
    const feed = key as Address;
    const decimals = await c.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "decimals" });
    const answer = BigInt(Math.round(price * 10 ** Number(decimals)));
    if (answer <= 0n) continue;
    for (const w of (windows.get(key) ?? []).sort((a, b) => (a.end < b.end ? -1 : 1))) {
      const at = w.end > w.start ? w.end - 1n : w.end;
      if ((await latestAt(feed)) < w.start && at <= now) {
        await push(feed, answer, at);
        report.backfilled++;
      }
    }
    if ((await latestAt(feed)) < now) {
      await push(feed, answer, now);
      report.pushed++;
    }
  }
  return report;
}
