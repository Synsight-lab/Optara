/**
 * Signed price packages: prices signed off-chain by a set of signers and verified on-chain by LiveSpotOracle
 * (authorized signers, a minimum of distinct ones per feed, the median). The packages use RedStone's on-chain format,
 * so they come from any service that serves it: Optara's own price node (testnet; see pricenode/) or RedStone's
 * gateways. Node only: uses RedStone's encoder, so the bytes match what the signers signed. Feeds are identified by
 * name as bytes32 (e.g. bytes32("MON")).
 */
import { RedstonePayload, SignedDataPackage } from "@redstone-finance/protocol";
import { hexToString, stringToHex, type Hex } from "viem";
import { isNamedFeedId, PROVIDER_TIMEOUT_MS, type SpotSource } from "./pyth.ts";

export interface SignedPriceOptions {
  /** Price service URLs, tried in order: Optara's price node, or RedStone gateways. */
  urls: readonly string[];
  /** Data service name in the request path (RedStone's, e.g. redstone-primary-prod; the price node ignores it). */
  dataServiceId: string;
  /** The signers to use (a subset of LiveSpotOracle.redstoneSigners); packages from anyone else are dropped. */
  authorizedSigners: readonly string[];
  /** Distinct signers to include per feed (≥ the oracle's threshold). */
  signersPerFeed: number;
  /** Limit per gateway request (default PROVIDER_TIMEOUT_MS). */
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/** RedStone's public gateways (switched off on 2026-10-29; kept for reference and for their authenticated successors). */
export const REDSTONE_PUBLIC_GATEWAYS = ["https://oracle-gateway-1.a.redstone.finance", "https://oracle-gateway-2.a.redstone.finance"];

type GatewayPackage = {
  timestampMilliseconds: number;
  signature: string;
  dataPoints: { dataFeedId: string; value: number }[];
  signerAddress: string;
  dataPackageId: string;
};

export { isNamedFeedId };

/** A named feed's on-chain id: its name as bytes32 (e.g. "MON"). */
export const namedFeedId = (name: string): Hex => stringToHex(name, { size: 32 });
const feedName = (id: Hex) => hexToString(id, { size: 32 }).replace(/\0+$/, "");

export class SignedPriceSource implements SpotSource {
  private readonly authorized: Set<string>;

  constructor(private readonly o: SignedPriceOptions) {
    this.authorized = new Set(o.authorizedSigners.map((a) => a.toLowerCase()));
  }

  /** One signed payload covering every feed (with `signersPerFeed` distinct authorized signers each). */
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
      if (!best) throw new Error(`price node: fewer than ${this.o.signersPerFeed} authorized signers for ${name}`);
      picked.push(...best[1].slice(0, this.o.signersPerFeed));
    }
    return picked;
  }

  private async fetchLatest(): Promise<Record<string, GatewayPackage[]>> {
    let last: unknown;
    for (const g of this.o.urls) {
      try {
        const res = await (this.o.fetchImpl ?? fetch)(`${g}/data-packages/latest/${this.o.dataServiceId}`, {
          signal: AbortSignal.timeout(this.o.timeoutMs ?? PROVIDER_TIMEOUT_MS),
        });
        if (!res.ok) throw new Error(`price node ${g}: ${res.status}`);
        return (await res.json()) as Record<string, GatewayPackage[]>;
      } catch (e) {
        last = e;
      }
    }
    throw last instanceof Error ? last : new Error("price node: no URL answered");
  }
}

/** Routes each feed to signed price packages (named feeds) or Pyth (Pyth ids); one update list for both. */
export class CompositeSpotSource implements SpotSource {
  constructor(
    private readonly pyth: SpotSource | undefined,
    private readonly signed: SignedPriceSource | undefined,
  ) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    const rs = feedIds.filter(isNamedFeedId);
    const py = feedIds.filter((id) => !isNamedFeedId(id));
    if (rs.length && !this.signed) throw new Error("named feeds requested but no price node is configured");
    if (py.length && !this.pyth) throw new Error("Pyth feeds requested but no Pyth source is configured");
    const [a, b] = await Promise.all([py.length ? this.pyth!.updates(py) : [], rs.length ? this.signed!.updates(rs) : []]);
    return [...a, ...b];
  }

  /** Parsed prices (price × 10^expo) per feed id, from whichever provider serves it. */
  async prices(feedIds: readonly Hex[]): Promise<Map<string, { price: bigint; expo: number; publishTime: bigint }>> {
    const rs = feedIds.filter(isNamedFeedId);
    const py = feedIds.filter((id) => !isNamedFeedId(id));
    const out = new Map<string, { price: bigint; expo: number; publishTime: bigint }>();
    const pyth = this.pyth as SpotSource & { prices?: SignedPriceSource["prices"] };
    if (py.length) {
      if (!pyth?.prices) throw new Error("the Pyth source cannot report parsed prices");
      for (const [k, v] of await pyth.prices(py)) out.set(k, v);
    }
    if (rs.length) {
      if (!this.signed) throw new Error("named feeds requested but no price node is configured");
      for (const [k, v] of await this.signed.prices(rs)) out.set(k, v);
    }
    return out;
  }
}
