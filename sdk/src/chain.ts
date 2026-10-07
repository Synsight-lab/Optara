import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Account,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";

export const monadMainnet = defineChain({
  id: 143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
});

export const monadTestnet = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet-rpc.monad.xyz"] } },
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

/**
 * A public client (and a wallet client when an account is given) for `rpcUrl`. Checks the RPC's chain id against
 * the expected one, so a service never acts on the wrong network.
 */
export async function connect(rpcUrl: string, expectedChainId: number, account?: Account): Promise<Clients> {
  const chain = chainFor(expectedChainId, rpcUrl);
  const pub = createPublicClient({ chain, transport: http(rpcUrl) });
  const actual = await pub.getChainId();
  if (actual !== expectedChainId) throw new Error(`RPC ${rpcUrl} is chain ${actual}, expected ${expectedChainId}`);
  const wallet = account ? createWalletClient({ chain, transport: http(rpcUrl), account }) : undefined;
  return { chain, public: pub, wallet };
}

/**
 * Gas limit for a transaction: the estimate plus a buffer. Execution gas depends on the block timestamp (the pricing
 * math), so a transaction mined a second after its estimate can need slightly more than `eth_estimateGas` returned
 * (observed: +~80 gas on a 1.13M mint) and run out of gas with an exact estimate. Monad charges the full gas limit,
 * so keep the buffer modest. Default 10%.
 */
export const withGasBuffer = (estimate: bigint, bufferBps = 1000n): bigint => estimate + (estimate * bufferBps) / 10_000n;
