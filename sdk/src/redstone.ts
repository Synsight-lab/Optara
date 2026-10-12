/**
 * RedStone pull prices (Node only: uses RedStone's own encoder, so the bytes match what its signers signed).
 * LiveSpotOracle verifies the payload on-chain: authorized signers, a minimum of distinct ones per feed, the median.
 * Feed ids on-chain are RedStone's names as bytes32 (e.g. bytes32("MON")).
 */
import { RedstonePayload, SignedDataPackage } from "@redstone-finance/protocol";
import { hexToString, stringToHex, type Hex } from "viem";
import type { SpotSource } from "./pyth.ts";

export interface RedstoneOptions {
  /** e.g. redstone-primary-prod */
  dataServiceId: string;
  /** The signers the oracle accepts (LiveSpotOracle.redstoneSigners); packages from anyone else are dropped. */
  authorizedSigners: readonly string[];
  /** Distinct signers to include per feed (≥ the oracle's threshold). */
  signersPerFeed: number;
  /** Gateways tried in order. Default: RedStone's public ones. */
  gateways?: readonly string[];
  fetchImpl?: typeof fetch;
}

const DEFAULT_GATEWAYS = ["https://oracle-gateway-1.a.redstone.finance", "https://oracle-gateway-2.a.redstone.finance"];

type GatewayPackage = {
  timestampMilliseconds: number;
  signature: string;
  dataPoints: { dataFeedId: string; value: number }[];
  signerAddress: string;
  dataPackageId: string;
};

/** True for a RedStone feed id: a short ASCII name, zero-padded (Pyth ids are 32 random-looking bytes). */
export function isRedstoneFeedId(id: Hex): boolean {
  const b = id.toLowerCase().replace(/^0x/, "");
  if (b.length !== 64 || !/0{32}$/.test(b)) return false;
  const name = hexToString(id, { size: 32 }).replace(/\0+$/, "");
  return /^[A-Za-z0-9_./-]{1,31}$/.test(name);
}

export const redstoneFeedId = (name: string): Hex => stringToHex(name, { size: 32 });
const feedName = (id: Hex) => hexToString(id, { size: 32 }).replace(/\0+$/, "");

export class RedstoneSource implements SpotSource {
  private readonly authorized: Set<string>;

  constructor(private readonly o: RedstoneOptions) {
    this.authorized = new Set(o.authorizedSigners.map((a) => a.toLowerCase()));
  }

  /** One RedStone payload covering every feed (with `signersPerFeed` distinct authorized signers each). */
  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    if (feedIds.length === 0) return [];
    const picked = await this.packages(feedIds);
    const payload = RedstonePayload.prepare(picked.map((p) => SignedDataPackage.fromObj(p as never)), "");
    return [`0x${payload}` as Hex];
  }

  /** Median price per feed id (lower-case hex), as the oracle will compute it, with its publish time. */
  async prices(feedIds: readonly Hex[]): Promise<Map<string, { price: bigint; expo: number; publishTime: bigint }>> {
    const out = new Map<string, { price: bigint; expo: number; publishTime: bigint }>();
    const picked = await this.packages(feedIds);
    for (const id of feedIds) {
      const name = feedName(id);
      const vals = picked
        .filter((p) => p.dataPoints[0]?.dataFeedId === name)
        .map((p) => BigInt(Math.round(p.dataPoints[0]!.value * 1e8)))
        .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
      if (vals.length === 0) continue;
      const n = vals.length;
      const median = n % 2 ? vals[(n - 1) / 2]! : (vals[n / 2 - 1]! + vals[n / 2]!) / 2n;
      const ts = picked.find((p) => p.dataPoints[0]?.dataFeedId === name)!.timestampMilliseconds;
      out.set(id.toLowerCase(), { price: median, expo: -8, publishTime: BigInt(Math.floor(ts / 1000)) });
    }
    return out;
  }

  /** Per feed: the latest timestamp with enough distinct authorized signers, `signersPerFeed` of them. */
  private async packages(feedIds: readonly Hex[]): Promise<GatewayPackage[]> {
    const all = await this.fetchLatest();
    const picked: GatewayPackage[] = [];
    for (const id of feedIds) {
      const name = feedName(id);
      const byTs = new Map<number, GatewayPackage[]>();
      for (const p of all[name] ?? []) {
        if (!this.authorized.has(p.signerAddress.toLowerCase())) continue;
        const list = byTs.get(p.timestampMilliseconds) ?? [];
        if (!list.some((q) => q.signerAddress.toLowerCase() === p.signerAddress.toLowerCase())) list.push(p);
        byTs.set(p.timestampMilliseconds, list);
      }
      const best = [...byTs.entries()].filter(([, l]) => l.length >= this.o.signersPerFeed).sort((a, b) => b[0] - a[0])[0];
      if (!best) throw new Error(`RedStone: fewer than ${this.o.signersPerFeed} authorized signers for ${name}`);
      picked.push(...best[1].slice(0, this.o.signersPerFeed));
    }
    return picked;
  }

  private async fetchLatest(): Promise<Record<string, GatewayPackage[]>> {
    let last: unknown;
    for (const g of this.o.gateways ?? DEFAULT_GATEWAYS) {
      try {
        const res = await (this.o.fetchImpl ?? fetch)(`${g}/data-packages/latest/${this.o.dataServiceId}`);
        if (!res.ok) throw new Error(`RedStone gateway ${g}: ${res.status}`);
        return (await res.json()) as Record<string, GatewayPackage[]>;
      } catch (e) {
        last = e;
      }
    }
    throw last instanceof Error ? last : new Error("RedStone: no gateway answered");
  }
}

/** Routes each feed to RedStone (RedStone names) or the other source (Pyth ids); one update list for both. */
export class CompositeSpotSource implements SpotSource {
  constructor(
    private readonly pyth: SpotSource | undefined,
    private readonly redstone: RedstoneSource | undefined,
  ) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    const rs = feedIds.filter(isRedstoneFeedId);
    const py = feedIds.filter((id) => !isRedstoneFeedId(id));
    if (rs.length && !this.redstone) throw new Error("RedStone feeds requested but no RedStone source is configured");
    if (py.length && !this.pyth) throw new Error("Pyth feeds requested but no Pyth source is configured");
    const [a, b] = await Promise.all([py.length ? this.pyth!.updates(py) : [], rs.length ? this.redstone!.updates(rs) : []]);
    return [...a, ...b];
  }

  /** Parsed prices (price × 10^expo) per feed id, from whichever provider serves it. */
  async prices(feedIds: readonly Hex[]): Promise<Map<string, { price: bigint; expo: number; publishTime: bigint }>> {
    const rs = feedIds.filter(isRedstoneFeedId);
    const py = feedIds.filter((id) => !isRedstoneFeedId(id));
    const out = new Map<string, { price: bigint; expo: number; publishTime: bigint }>();
    const pyth = this.pyth as SpotSource & { prices?: RedstoneSource["prices"] };
    if (py.length) {
      if (!pyth?.prices) throw new Error("the Pyth source cannot report parsed prices");
      for (const [k, v] of await pyth.prices(py)) out.set(k, v);
    }
    if (rs.length) {
      if (!this.redstone) throw new Error("RedStone feeds requested but no RedStone source is configured");
      for (const [k, v] of await this.redstone.prices(rs)) out.set(k, v);
    }
    return out;
  }
}
