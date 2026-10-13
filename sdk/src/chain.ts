import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Account,
  type Chain,
  type HttpTransportConfig,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";

/** Multicall3: the canonical deployment, live on Monad mainnet and testnet (lets viem merge reads into one eth_call). */
const multicall3 = { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } as const;

export const monadMainnet = defineChain({
  id: 143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
  contracts: { multicall3 },
});

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet-rpc.monad.xyz"] } },
  contracts: { multicall3 },
  testnet: true,
});

export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export function chainFor(chainId: number, rpcUrl?: string): Chain {
  const known = [monadMainnet, monadTestnet, anvil].find((c) => c.id === chainId);
  const base =
    known ??
    defineChain({
      id: chainId,
      name: `chain-${chainId}`,
      nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [rpcUrl ?? ""] } },
    });
  return rpcUrl ? { ...base, rpcUrls: { default: { http: [rpcUrl] } } } : base;
}

export interface Clients {
  chain: Chain;
  public: PublicClient<Transport, Chain>;
  wallet?: WalletClient<Transport, Chain, Account>;
}

/** True for an RPC refusal caused by rate limiting (anywhere in the error's cause chain). */
export function isRateLimited(e: unknown): boolean {
  for (let x: any = e, depth = 0; x && depth < 8; x = x.cause, depth++) {
    // -32011: Monad's public RPC ("requests limited to 25/sec"); -32005: the standard "limit exceeded"; 429: HTTP.
    if (x.code === -32011 || x.code === -32005 || x.status === 429) return true;
    if (typeof x.message === "string" && /requests limited|rate limit|too many requests/i.test(x.message)) return true;
  }
  return false;
}

/**
 * `http(rpcUrl)` that waits and retries requests refused for rate limiting (viem does not retry Monad's -32011), so
 * a long log scan on a shared public RPC slows down instead of failing. Other errors are thrown at once.
 */
export function patientHttp(rpcUrl: string, maxRetries = 8, baseDelayMs = 250, config?: HttpTransportConfig): Transport {
  const base = http(rpcUrl, config);
  return ((opts: Parameters<Transport>[0]) => {
    const t = base(opts);
    const request: typeof t.request = async (args, options) => {
      for (let attempt = 0; ; attempt++) {
        try {
          return await t.request(args, options);
        } catch (e) {
          if (attempt >= maxRetries || !isRateLimited(e)) throw e;
          await new Promise((r) => setTimeout(r, baseDelayMs * 2 ** attempt + Math.random() * baseDelayMs));
        }
      }
    };
    return { ...t, request };
  }) as Transport;
}

/**
 * A public client (and a wallet client when an account is given) for `rpcUrl`. Checks the RPC's chain id against
 * the expected one, so a service never acts on the wrong network.
 */
export async function connect(rpcUrl: string, expectedChainId: number, account?: Account): Promise<Clients> {
  const chain = chainFor(expectedChainId, rpcUrl);
  const pub = createPublicClient({ chain, transport: patientHttp(rpcUrl) });
  const actual = await pub.getChainId();
  if (actual !== expectedChainId) throw new Error(`RPC ${rpcUrl} is chain ${actual}, expected ${expectedChainId}`);
  const wallet = account ? createWalletClient({ chain, transport: patientHttp(rpcUrl), account }) : undefined;
  return { chain, public: pub, wallet };
}

/**
 * Gas limit for a transaction: the estimate plus a buffer. Execution gas depends on the block timestamp (the pricing
 * math), so a transaction mined a second after its estimate can need slightly more than `eth_estimateGas` returned
 * (observed: +~80 gas on a 1.13M mint) and run out of gas with an exact estimate. Monad charges the full gas limit,
 * so keep the buffer modest. Default 10%.
 */
export const withGasBuffer = (estimate: bigint, bufferBps = 1000n): bigint => estimate + (estimate * bufferBps) / 10_000n;
