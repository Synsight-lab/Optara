import { getAddress, isAddress, type Address, type Hex } from "viem";

/** Module names as written by contract/script/Manifest.sol (DEPLOYMENT.md §3.2). */
export const MODULES = [
  "ProtocolControl",
  "OptionSeriesRegistry",
  "ExternalOptionFactory",
  "SubAccounts",
  "LiveSpotOracle",
  "VolSurfaceOracle",
  "SettlementOracle",
  "PortfolioRiskManager",
  "InsuranceFund",
  "FeeController",
  "OptionClearing",
  "LiquidationModule",
  "SettlementWindow",
  "VenueRegistry",
  "VenueRouter",
] as const;
export type ModuleName = (typeof MODULES)[number];

export interface ProxyEntry {
  proxy: Address;
  implementation: Address;
  proxyAdmin: Address;
  implementationCodeHash: Hex;
}

export interface Manifest {
  network: string;
  chainId: number;
  deployedAtBlock: number;
  deployer: Address;
  upgradeAdmin: Address;
  kuruAdapter: Address;
  roles: Record<string, Address | number>;
  proxies: Record<ModuleName, ProxyEntry>;
  /** Network-specific values (local: mocks, ids, series, books, accounts). */
  extra: Record<string, unknown>;
}

function addr(v: unknown, what: string): Address {
  if (typeof v !== "string" || !isAddress(v, { strict: false })) throw new Error(`manifest: ${what} is not an address`);
  return getAddress(v);
}

export function parseManifest(raw: any): Manifest {
  if (typeof raw?.chainId !== "number") throw new Error("manifest: chainId missing");
  const proxies = {} as Record<ModuleName, ProxyEntry>;
  for (const m of MODULES) {
    const p = raw.proxies?.[m];
    if (!p) throw new Error(`manifest: proxies.${m} missing`);
    proxies[m] = {
      proxy: addr(p.proxy, `${m}.proxy`),
      implementation: addr(p.implementation, `${m}.implementation`),
      proxyAdmin: addr(p.proxyAdmin, `${m}.proxyAdmin`),
      implementationCodeHash: p.implementationCodeHash,
    };
  }
  return {
    network: String(raw.network),
    chainId: raw.chainId,
    deployedAtBlock: Number(raw.deployedAtBlock ?? 0),
    deployer: addr(raw.deployer, "deployer"),
    upgradeAdmin: addr(raw.upgradeAdmin, "upgradeAdmin"),
    kuruAdapter: addr(raw.kuruAdapter, "kuruAdapter"),
    roles: raw.roles ?? {},
    proxies,
    extra: raw.extra ?? {},
  };
}

/** The proxy address of a module (call it with that module's ABI). */
export const moduleAddress = (m: Manifest, name: ModuleName): Address => m.proxies[name].proxy;
