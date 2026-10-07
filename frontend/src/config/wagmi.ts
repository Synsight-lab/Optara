import { createConfig, createConnector, http, injected, mock } from "wagmi";
import { mnemonicToAccount } from "viem/accounts";
import { CHAIN, IS_LOCAL, RPC_URL } from "./network.ts";

/** anvil's default mnemonic: accounts 5–9 are the local stack's funded users (LocalStack.s.sol). */
const ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
export const TEST_WALLET_NAMES = ["Alice", "Bob", "Carol", "Dave", "Erin"];

/**
 * One-click test wallets on the local devnet: anvil keeps its default accounts unlocked, so the mock connector's
 * eth_sendTransaction is signed by anvil itself. Never offered on a real network.
 */
const testWallets = IS_LOCAL
  ? TEST_WALLET_NAMES.map((name, i) => {
      const address = mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: 5 + i }).address;
      const id = `test-${i}`;
      const base = mock({ accounts: [address], features: { reconnect: true, defaultConnected: true } });
      // Reconnects after a reload only if it was the wallet last chosen (a first visit starts disconnected).
      return createConnector((config) => {
        const c = base(config);
        return {
          ...c,
          id,
          name: `${name} (test wallet)`,
          type: "test",
          async connect(params: any) {
            const r = await c.connect(params);
            remember(id);
            return r as any;
          },
          async disconnect() {
            remember(undefined);
            return c.disconnect();
          },
          async isAuthorized() {
            return recalled() === id;
          },
        };
      });
    })
  : [];

const TEST_WALLET_KEY = "optara.testWallet";
function remember(id: string | undefined) {
  try {
    if (id) localStorage.setItem(TEST_WALLET_KEY, id);
    else localStorage.removeItem(TEST_WALLET_KEY);
  } catch {
    // storage unavailable: no reconnect after reload
  }
}
function recalled(): string | null {
  try {
    return localStorage.getItem(TEST_WALLET_KEY);
  } catch {
    return null;
  }
}

export const wagmiConfig = createConfig({
  chains: [CHAIN],
  connectors: [injected({ shimDisconnect: true }), ...testWallets],
  transports: { [CHAIN.id]: http(RPC_URL, { batch: true }) },
  pollingInterval: IS_LOCAL ? 500 : 2_000,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
