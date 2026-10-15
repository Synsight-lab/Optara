import { encodeAbiParameters, hexToString, type Hex } from "viem";

/** A source of provider spot blobs for `OracleUpdate.spotUpdates` (ORACLES.md §2, INDEXER_AND_KEEPERS.md §2). */
export interface SpotSource {
  /** Signed update blobs covering every feed id given. */
  updates(feedIds: readonly Hex[]): Promise<Hex[]>;
}

/** `MockPyth` (local stack): `abi.encode(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime)`. */
export function encodeMockPyth(id: Hex, price: bigint, expo: number, publishTime: bigint, conf = 0n): Hex {
  return encodeAbiParameters(
    [{ type: "bytes32" }, { type: "int64" }, { type: "uint64" }, { type: "int32" }, { type: "uint256" }],
    [id, price, conf, expo, publishTime],
  );
}

/**
 * Local spot source: one MockPyth blob per feed at the price `priceOf(feedId)` returns (expo −8), stamped with
 * `now()` (the chain's latest block time, so the contract sees it as fresh).
 */
export class MockPythSource implements SpotSource {
  constructor(
    private readonly priceOf: (feedId: Hex) => number | Promise<number>,
    private readonly now: () => Promise<bigint>,
  ) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    const t = await this.now();
    return Promise.all(
      feedIds.map(async (id) => encodeMockPyth(id, BigInt(Math.round((await this.priceOf(id)) * 1e8)), -8, t)),
    );
  }
}

export interface HermesOptions {
  /** e.g. https://pyth.dourolabs.app/hermes */
  endpoint: string;
  /** Hermes requires an API key after Pyth Core's August 2026 upgrade. */
  apiKey?: string;
  /** How the key is sent; Pyth's documentation for the keyed endpoint decides. Default `Authorization: Bearer`. */
  apiKeyHeader?: string;
  /** Limit per request (default PROVIDER_TIMEOUT_MS). */
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/** Pyth Hermes v2: one accumulator update covering all requested feeds. */
export class HermesSource implements SpotSource {
  constructor(private readonly o: HermesOptions) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    if (feedIds.length === 0) return [];
    const q = feedIds.map((id) => `ids[]=${id}`).join("&");
    const res = await (this.o.fetchImpl ?? fetch)(`${this.o.endpoint}/v2/updates/price/latest?${q}&encoding=hex`, { headers: this.headers(), signal: AbortSignal.timeout(this.o.timeoutMs ?? PROVIDER_TIMEOUT_MS) });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = (await res.json()) as { binary: { encoding: string; data: string[] } };
    if (body.binary.encoding !== "hex") throw new Error(`Hermes encoding ${body.binary.encoding}`);
    return body.binary.data.map((d) => (d.startsWith("0x") ? d : `0x${d}`) as Hex);
  }

  /** Latest parsed prices: `price × 10^expo` per feed id (lower-case, 0x-prefixed), with their publish times. */
  async prices(feedIds: readonly Hex[]): Promise<Map<string, { price: bigint; expo: number; publishTime: bigint }>> {
    const out = new Map<string, { price: bigint; expo: number; publishTime: bigint }>();
    if (feedIds.length === 0) return out;
    const q = feedIds.map((id) => `ids[]=${id}`).join("&");
    const res = await (this.o.fetchImpl ?? fetch)(`${this.o.endpoint}/v2/updates/price/latest?${q}&parsed=true`, { headers: this.headers(), signal: AbortSignal.timeout(this.o.timeoutMs ?? PROVIDER_TIMEOUT_MS) });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = (await res.json()) as { parsed: { id: string; price: { price: string; expo: number; publish_time: number } }[] };
    for (const p of body.parsed) {
      out.set(`0x${p.id.replace(/^0x/, "").toLowerCase()}`, { price: BigInt(p.price.price), expo: p.price.expo, publishTime: BigInt(p.price.publish_time) });
    }
    return out;
  }

  private headers(): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.o.apiKey) {
      const h = this.o.apiKeyHeader ?? "Authorization";
      headers[h] = h.toLowerCase() === "authorization" ? `Bearer ${this.o.apiKey}` : this.o.apiKey;
    }
    return headers;
  }
}

const mockPythAbi = [
  {
    type: "function",
    name: "getPriceUnsafe",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          { name: "price", type: "int64" },
          { name: "conf", type: "uint64" },
          { name: "expo", type: "int32" },
          { name: "publishTime", type: "uint256" },
        ],
      },
    ],
  },
] as const;

/**
 * Local stack only: re-signs MockPyth's current price for each feed with the latest block time, so spot stays fresh
 * without moving. Tests that need a move use `MockPythSource` with explicit prices.
 */
export class RestampMockPythSource implements SpotSource {
  constructor(
    private readonly client: import("viem").PublicClient,
    private readonly pyth: import("viem").Address,
  ) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    const t = (await this.client.getBlock()).timestamp;
    return Promise.all(
      feedIds.map(async (id) => {
        const p = await this.client.readContract({ address: this.pyth, abi: mockPythAbi, functionName: "getPriceUnsafe", args: [id] });
        return encodeMockPyth(id, p.price, p.expo, t, p.conf);
      }),
    );
  }
}

/** Default limit for one price-provider request, so a hanging provider can't hold up anything else. */
export const PROVIDER_TIMEOUT_MS = 8_000;

/**
 * True for a named feed id (signed price packages: Optara's price node or RedStone): a short ASCII name, zero-padded.
 * Pyth ids are 32 random-looking bytes.
 */
export function isNamedFeedId(id: Hex): boolean {
  const b = id.toLowerCase().replace(/^0x/, "");
  if (b.length !== 64 || !/0{32}$/.test(b)) return false;
  const name = hexToString(id, { size: 32 }).replace(/\0+$/, "");
  return /^[A-Za-z0-9_./-]{1,31}$/.test(name);
}

/**
 * Spot updates for several products, so that one failing provider never blocks the others. Products are grouped by
 * the providers their feeds use (Pyth, signed price packages, or both); the groups are fetched at the same time, each group's
 * shared feeds once (e.g. USDC/USD for every Pyth product). A group that fails (a provider outage) loses only its own
 * products. Returns the blobs and the products they cover, plus the products that could not be updated and why.
 */
export async function spotUpdatesByProduct(
  spot: SpotSource,
  products: readonly { productId: Hex; feedIds: readonly Hex[] }[],
): Promise<{ updates: Hex[]; productIds: Hex[]; failed: { productId: Hex; error: string }[] }> {
  const groups = new Map<string, { productIds: Hex[]; feeds: Set<string>; feedIds: Hex[] }>();
  for (const p of products) {
    const key = [...new Set(p.feedIds.map((f) => (isNamedFeedId(f) ? "signed" : "pyth")))].sort().join("+");
    const g = groups.get(key) ?? { productIds: [], feeds: new Set<string>(), feedIds: [] };
    g.productIds.push(p.productId);
    for (const f of p.feedIds) {
      if (!g.feeds.has(f.toLowerCase())) {
        g.feeds.add(f.toLowerCase());
        g.feedIds.push(f);
      }
    }
    groups.set(key, g);
  }
  const list = [...groups.values()];
  const results = await Promise.allSettled(list.map((g) => spot.updates(g.feedIds)));
  const updates: Hex[] = [];
  const productIds: Hex[] = [];
  const failed: { productId: Hex; error: string }[] = [];
  results.forEach((r, i) => {
    const g = list[i]!;
    if (r.status === "fulfilled") {
      updates.push(...r.value);
      productIds.push(...g.productIds);
    } else {
      const error = ((r.reason as Error)?.message ?? String(r.reason)).split("\n")[0] ?? "";
      for (const productId of g.productIds) failed.push({ productId, error });
    }
  });
  return { updates, productIds, failed };
}
