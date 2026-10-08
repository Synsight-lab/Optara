import { encodeAbiParameters, type Hex } from "viem";

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
  fetchImpl?: typeof fetch;
}

/** Pyth Hermes v2: one accumulator update covering all requested feeds. */
export class HermesSource implements SpotSource {
  constructor(private readonly o: HermesOptions) {}

  async updates(feedIds: readonly Hex[]): Promise<Hex[]> {
    if (feedIds.length === 0) return [];
    const q = feedIds.map((id) => `ids[]=${id}`).join("&");
    const headers: Record<string, string> = {};
    if (this.o.apiKey) {
      const h = this.o.apiKeyHeader ?? "Authorization";
      headers[h] = h.toLowerCase() === "authorization" ? `Bearer ${this.o.apiKey}` : this.o.apiKey;
    }
    const res = await (this.o.fetchImpl ?? fetch)(`${this.o.endpoint}/v2/updates/price/latest?${q}&encoding=hex`, { headers });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = (await res.json()) as { binary: { encoding: string; data: string[] } };
    if (body.binary.encoding !== "hex") throw new Error(`Hermes encoding ${body.binary.encoding}`);
    return body.binary.data.map((d) => (d.startsWith("0x") ? d : `0x${d}`) as Hex);
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
