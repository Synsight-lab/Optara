/** The read client and contract addresses for the active network. */
import { createPublicClient, http, keccak256, toHex, zeroAddress, type Address, type Hex } from "viem";
import { CHAIN, MANIFEST, RPC_URL } from "../../config/network.ts";

// cacheTime 0: log scans right after a transaction (e.g. a new account) must see the new head, not a cached one.
export const publicClient = createPublicClient({ chain: CHAIN, transport: http(RPC_URL, { batch: true }), cacheTime: 0 });
export type Client = typeof publicClient;

const P = MANIFEST.proxies;
export const ADDR = {
  registry: P.OptionSeriesRegistry.proxy,
  ledger: P.SubAccounts.proxy,
  clearing: P.OptionClearing.proxy,
  risk: P.PortfolioRiskManager.proxy,
  spot: P.LiveSpotOracle.proxy,
  surface: P.VolSurfaceOracle.proxy,
  settlementOracle: P.SettlementOracle.proxy,
  fees: P.FeeController.proxy,
  insurance: P.InsuranceFund.proxy,
  liquidation: P.LiquidationModule.proxy,
  settlement: P.SettlementWindow.proxy,
  venues: P.VenueRegistry.proxy,
  router: P.VenueRouter.proxy,
  control: P.ProtocolControl.proxy,
  kuruAdapter: MANIFEST.kuruAdapter,
  directAdapter: (MANIFEST.extra.optaraDirectAdapter as Address | undefined) ?? zeroAddress,
} as const satisfies Record<string, Address>;

/** KuruAdapter.VENUE_ID = keccak256("KURU"). */
export const KURU_VENUE: Hex = keccak256(toHex("KURU"));
export const DIRECT_VENUE: Hex = keccak256(toHex("OPTARA_DIRECT"));
export const DEPLOYED_AT_BLOCK = BigInt(MANIFEST.deployedAtBlock);
