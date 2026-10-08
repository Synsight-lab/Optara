/**
 * Reads (FRONTEND.md §3). Every margin, price and payout comes from contract views; lists come from the indexer
 * when one is configured (VITE_INDEXER_URL), otherwise from on-chain events.
 */
import { encodeAbiParameters, erc20Abi, keccak256, maxUint256, type Address, type Hex } from "viem";
import {
  LedgerLogDirectory,
  SeriesCatalog,
  optionClearingAbi,
  liveSpotOracleAbi,
  optionSeriesRegistryAbi,
  portfolioRiskManagerAbi,
  settlementWindowAbi,
  subAccountsAbi,
  venueRegistryAbi,
  volSurfaceOracleAbi,
  feeControllerAbi,
  insuranceFundAbi,
  liquidationModuleAbi,
  type ListedSeries,
} from "@optara/sdk";
import { INDEXER_URL, IS_LOCAL } from "../../config/network.ts";
import { ADDR, DEPLOYED_AT_BLOCK, KURU_VENUE, publicClient as c } from "./client.ts";
import { GROUP_STATES, HEALTH_STATES, SURFACE_STATUS, type GroupState, type Health, type Position, type Quote, type Series, type SurfaceStatus } from "./types.ts";

const LOG_CHUNK = IS_LOCAL ? 50_000n : 100n; // Monad's public RPC: eth_getLogs over at most 100 blocks

// ------------------------------------------------------------------ products and series

const productCache = new Map<Hex, Promise<{ underlyingSymbol: string; assetSymbol: string; assetDecimals: number }>>();
function productInfo(productId: Hex, asset: Address) {
  let p = productCache.get(productId);
  if (!p) {
    p = (async () => {
      const [product, decimals] = await Promise.all([
        c.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "getProduct", args: [productId] }),
        c.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "settlementAssetDecimals", args: [asset] }),
      ]);
      return { underlyingSymbol: product.config.underlyingSymbol, assetSymbol: product.config.assetSymbol, assetDecimals: decimals };
    })();
    productCache.set(productId, p);
  }
  return p;
}

const catalog = new SeriesCatalog(c, ADDR.registry, DEPLOYED_AT_BLOCK, LOG_CHUNK);

async function listedSeries(): Promise<ListedSeries[]> {
  if (INDEXER_URL) {
    const rows = (await (await fetch(`${INDEXER_URL}/series`)).json()) as any[];
    return rows.map((r) => ({
      seriesId: r.id,
      groupId: r.group_id,
      productId: r.productId,
      underlying: r.underlying,
      settlementAsset: r.settlementAsset,
      settlementOracleConfigId: r.settlementOracleConfigId,
      wrapper: r.wrapper,
      optionType: Number(r.optionType),
      strikeWad: BigInt(r.strikeWad),
      contractSizeWad: BigInt(r.contractSizeWad),
      expiry: BigInt(r.expiry),
    }));
  }
  await catalog.sync();
  return catalog.all();
}

/** Every listed series, by expiry, type and strike. */
export async function getSeriesList(): Promise<Series[]> {
  const listed = await listedSeries();
  const order = new Map<Hex, number>(listed.map((s, i) => [s.seriesId.toLowerCase() as Hex, i]));
  const out = await Promise.all(
    listed.map(async (s) => ({
      id: s.seriesId,
      listedAt: order.get(s.seriesId.toLowerCase() as Hex),
      groupId: s.groupId,
      productId: s.productId,
      underlying: s.underlying,
      settlementAsset: s.settlementAsset,
      wrapper: s.wrapper,
      optionType: s.optionType,
      strikeWad: s.strikeWad,
      contractSizeWad: s.contractSizeWad,
      expiry: s.expiry,
      settlementOracleConfigId: s.settlementOracleConfigId,
      ...(await productInfo(s.productId, s.settlementAsset)),
    })),
  );
  return out.sort((a, b) => (a.expiry !== b.expiry ? (a.expiry < b.expiry ? -1 : 1) : a.optionType !== b.optionType ? a.optionType - b.optionType : a.strikeWad < b.strikeWad ? -1 : 1));
}

// ------------------------------------------------------------------ market data

export interface ProductMarket {
  productId: Hex;
  spotWad: bigint;
  spotPublishTime: bigint;
  spotFresh: boolean;
  surface: SurfaceStatus;
  surfaceStaleSeconds: bigint;
  closeOnly: boolean;
}

export async function getProductMarket(productId: Hex): Promise<ProductMarket> {
  const [[spotWad, publishTime], spotFresh, [status, stale], closeOnly] = await Promise.all([
    c.readContract({ address: ADDR.spot, abi: liveSpotOracleAbi, functionName: "spotPrice", args: [productId] }),
    c.readContract({ address: ADDR.spot, abi: liveSpotOracleAbi, functionName: "isSpotFresh", args: [productId] }),
    c.readContract({ address: ADDR.surface, abi: volSurfaceOracleAbi, functionName: "surfaceStatus", args: [productId] }),
    c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "isProductCloseOnly", args: [productId] }),
  ]);
  return { productId, spotWad, spotPublishTime: BigInt(publishTime), spotFresh, surface: SURFACE_STATUS[status] ?? "NONE", surfaceStaleSeconds: BigInt(stale), closeOnly };
}

export interface SeriesMarket {
  /** Model mid / short / long marks per contract (WAD); undefined when the series can't be priced now. */
  mark?: bigint;
  iv?: bigint;
  quote?: Quote;
  state: GroupState;
}

const kuruBookAbi = [
  { type: "function", name: "bestBidAsk", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }, { type: "uint256" }] },
] as const;

/** The Kuru book's best bid and ask (prices per contract, WAD), or undefined without a tradable market. */
export async function getQuote(seriesId: Hex): Promise<Quote | undefined> {
  try {
    const [, market] = await c.readContract({ address: ADDR.venues, abi: venueRegistryAbi, functionName: "tradableMarket", args: [KURU_VENUE, seriesId] });
    const [bid, ask] = await c.readContract({ address: market, abi: kuruBookAbi, functionName: "bestBidAsk" });
    return { market, bid: bid === 0n ? undefined : bid, ask: ask === maxUint256 ? undefined : ask };
  } catch {
    return undefined;
  }
}

export async function getSeriesMarket(s: Series): Promise<SeriesMarket> {
  const [price, iv, quote, state] = await Promise.all([
    c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "priceOf", args: [s.id] }).catch(() => undefined),
    c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "ivOf", args: [s.id] }).catch(() => undefined),
    getQuote(s.id),
    getGroupState(s.groupId),
  ]);
  return { mark: price?.[0], iv: iv?.[0], quote, state };
}

export async function getGroupState(groupId: Hex): Promise<GroupState> {
  const st = await c.readContract({ address: ADDR.settlement, abi: settlementWindowAbi, functionName: "groupState", args: [groupId] });
  return GROUP_STATES[st] ?? "ACTIVE";
}

// ------------------------------------------------------------------ accounts

/** Subaccounts owned by `owner` (indexer, or SubAccountCreated events filtered by the indexed owner). */
export async function getAccounts(owner: Address): Promise<bigint[]> {
  if (INDEXER_URL) {
    const rows = (await (await fetch(`${INDEXER_URL}/accounts/${owner}`)).json()) as { accountId: string }[];
    return rows.map((r) => BigInt(r.accountId));
  }
  const head = await c.getBlockNumber();
  const ids: bigint[] = [];
  for (let from = DEPLOYED_AT_BLOCK; from <= head; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n > head ? head : from + LOG_CHUNK - 1n;
    const logs = await c.getContractEvents({ address: ADDR.ledger, abi: subAccountsAbi, eventName: "SubAccountCreated", args: { owner }, fromBlock: from, toBlock: to, strict: true });
    ids.push(...logs.map((l) => l.args.accountId));
  }
  return ids;
}

export async function getHealth(accountId: bigint): Promise<Health> {
  const [state, equity, initialMargin, maintenanceMargin, fresh] = await c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "healthOf", args: [accountId] });
  return { state: HEALTH_STATES[state] ?? "HEALTHY", equity, initialMargin: BigInt(initialMargin), maintenanceMargin: BigInt(maintenanceMargin), fresh };
}

export interface AccountView {
  id: bigint;
  cash: bigint; // native
  health: Health;
  positions: Position[];
  maxWithdrawable: bigint; // native
}

export async function getAccount(accountId: bigint, seriesById: Map<Hex, Series>): Promise<AccountView> {
  const [cash, health, raw, maxWithdrawable] = await Promise.all([
    c.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "cashOf", args: [accountId] }),
    getHealth(accountId),
    c.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "positionsOf", args: [accountId] }),
    c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "maxWithdrawable", args: [accountId] }).catch(() => 0n),
  ]);
  const positions = raw
    .filter((p) => p.balance !== 0n && seriesById.has(p.seriesId))
    .map((p) => ({ seriesId: p.seriesId, balance: p.balance, series: seriesById.get(p.seriesId)! }));
  return { id: accountId, cash, health, positions, maxWithdrawable };
}

/** Wrapper (long) balances in a wallet, non-zero only. */
export async function getWalletWrappers(owner: Address, series: Series[]): Promise<{ series: Series; balance: bigint }[]> {
  const balances = await Promise.all(series.map((s) => c.readContract({ address: s.wrapper, abi: erc20Abi, functionName: "balanceOf", args: [owner] })));
  return series.map((s, i) => ({ series: s, balance: balances[i]! })).filter((x) => x.balance > 0n);
}

export const getTokenBalance = (token: Address, owner: Address) => c.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [owner] });
export const getAllowance = (token: Address, owner: Address, spender: Address) => c.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] });

// ------------------------------------------------------------------ previews

export const previewMint = (accountId: bigint, seriesId: Hex, qty: bigint) =>
  c.readContract({ address: ADDR.clearing, abi: optionClearingAbi, functionName: "previewMint", args: [accountId, seriesId, qty] });
export const previewWithdraw = (accountId: bigint, amount: bigint) =>
  c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "previewWithdraw", args: [accountId, amount] });
export const previewWrap = (accountId: bigint, seriesId: Hex, qty: bigint) =>
  c.readContract({ address: ADDR.risk, abi: portfolioRiskManagerAbi, functionName: "previewWrap", args: [accountId, seriesId, qty] });
export const previewBuyerFee = (premium: bigint) => c.readContract({ address: ADDR.fees, abi: feeControllerAbi, functionName: "previewBuyerFee", args: [premium] });
export const previewSellerFee = (seriesId: Hex, qty: bigint) => c.readContract({ address: ADDR.fees, abi: feeControllerAbi, functionName: "previewSellerFee", args: [seriesId, qty] });
export const previewRedeem = (seriesId: Hex, qty: bigint) => c.readContract({ address: ADDR.settlement, abi: settlementWindowAbi, functionName: "previewRedeem", args: [seriesId, qty] });
export const kuruTakerFee = (market: Address, premiumIn: bigint) =>
  c.readContract({ address: ADDR.kuruAdapter, abi: KURU_ADAPTER_QUOTE_ABI, functionName: "quoteBuy", args: [market, premiumIn] });
export const kuruSellFee = (market: Address, proceeds: bigint) =>
  c.readContract({ address: ADDR.kuruAdapter, abi: KURU_ADAPTER_QUOTE_ABI, functionName: "quoteSell", args: [market, proceeds] });
const KURU_ADAPTER_QUOTE_ABI = [
  { type: "function", name: "quoteBuy", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "quoteSell", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;

// ------------------------------------------------------------------ liquidation spot estimate (FRONTEND.md §5)

/** LiveSpotOracle's ERC-7201 storage: `prices` is the 4th member (pyth, registry, sources, prices). */
const SPOT_STORAGE_SLOT = 0x1e07571fbc3d561cc37286352e4623f43c8c4ec4de392362411e8d2df9c7b700n;
const pricesSlot = (productId: Hex) =>
  keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [productId, SPOT_STORAGE_SLOT + 3n]));

/** `healthOf` with the product's stored spot replaced by `spotWad` (fresh): what the account would look like there. */
async function healthAt(accountId: bigint, productId: Hex, spotWad: bigint, now: bigint): Promise<Health> {
  const value = `0x${((now << 192n) | spotWad).toString(16).padStart(64, "0")}` as Hex;
  const [state, equity, initialMargin, maintenanceMargin, fresh] = await c.readContract({
    address: ADDR.risk,
    abi: portfolioRiskManagerAbi,
    functionName: "healthOf",
    args: [accountId],
    stateOverride: [{ address: ADDR.spot, stateDiff: [{ slot: pricesSlot(productId), value }] }],
  });
  return { state: HEALTH_STATES[state] ?? "HEALTHY", equity, initialMargin: BigInt(initialMargin), maintenanceMargin: BigInt(maintenanceMargin), fresh };
}

/**
 * The nearest spots above and below today's at which equity would fall to MM, searching up to ×3 and down to ×0.2
 * (an estimate: volatility held as it is). Where the views can't price further out (volatility leaves not proven
 * that far from today's spot), the search stops and reports how far it got (`upTo` / `downTo`).
 */
export async function estimateLiquidationSpots(
  accountId: bigint,
  productId: Hex,
  spotWad: bigint,
): Promise<{ up?: bigint; down?: bigint; upTo?: bigint; downTo?: bigint }> {
  const now = (await c.getBlock()).timestamp;
  /** true / false, or undefined when the views can't evaluate that spot. */
  const below = async (s: bigint) => {
    try {
      const h = await healthAt(accountId, productId, s, now);
      return h.equity < h.maintenanceMargin;
    } catch {
      return undefined;
    }
  };
  const at = await below(spotWad);
  if (at === undefined) return {};
  if (at) return { up: spotWad, down: spotWad };
  const search = async (factorBps: bigint[]): Promise<{ hit?: bigint; reached: bigint }> => {
    let safe = spotWad;
    for (const f of factorBps) {
      const s = (spotWad * f) / 10_000n;
      const b = await below(s);
      if (b === undefined) return { reached: safe };
      if (b) {
        let [lo, hi] = safe < s ? [safe, s] : [s, safe];
        for (let i = 0; i < 16; i++) {
          const mid = (lo + hi) / 2n;
          const m = await below(mid);
          if (m === undefined) break;
          if (safe < s ? m : !m) hi = mid;
          else lo = mid;
        }
        return { hit: safe < s ? hi : lo, reached: s };
      }
      safe = s;
    }
    return { reached: safe };
  };
  const [up, down] = await Promise.all([
    search([10_500n, 11_000n, 11_500n, 12_000n, 13_000n, 14_000n, 15_500n, 17_000n, 19_000n, 21_000n, 25_000n, 30_000n]),
    search([9_500n, 9_000n, 8_500n, 8_000n, 7_000n, 6_000n, 5_000n, 4_000n, 3_000n, 2_000n]),
  ]);
  return { up: up.hit, down: down.hit, upTo: up.reached, downTo: down.reached };
}

// ------------------------------------------------------------------ settlement, liquidation, system

export async function getGroup(groupId: Hex) {
  const [state, acct, participants] = await Promise.all([
    getGroupState(groupId),
    c.readContract({ address: ADDR.settlement, abi: settlementWindowAbi, functionName: "groupAccounting", args: [groupId] }),
    c.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "participants", args: [groupId] }),
  ]);
  return { state, accounting: acct, participants };
}

export const getAuction = async (accountId: bigint, underlying: Address) => {
  const [start, [bonusBps, wholeBucket]] = await Promise.all([
    c.readContract({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "auctionStart", args: [accountId, underlying] }),
    c.readContract({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "currentBonus", args: [accountId, underlying] }),
  ]);
  return { start, bonusBps, wholeBucket };
};

export const getLiquidationParams = () => c.readContract({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "liquidationParams" });
export const previewSlice = (accountId: bigint, underlying: Address, sliceBps: number) =>
  c.readContract({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "previewSlice", args: [accountId, underlying, sliceBps] });

export async function getInsurance(asset: Address) {
  const [balance, cfg, keeperReserve] = await Promise.all([
    c.readContract({ address: ADDR.insurance, abi: insuranceFundAbi, functionName: "balanceOf", args: [asset] }),
    c.readContract({ address: ADDR.fees, abi: feeControllerAbi, functionName: "assetConfig", args: [asset] }),
    c.readContract({ address: ADDR.fees, abi: feeControllerAbi, functionName: "keeperReserve", args: [asset] }),
  ]);
  return { balance, minimumSeed: cfg.minimumInsuranceSeed, keeperReserve, minimumKeeperReserve: cfg.minimumKeeperReserve, finalizeReward: cfg.finalizeRewardNative, settleReward: cfg.settleRewardNative };
}

/** All accounts with positions (indexer, or the ledger's BalanceUpdated events). */
export async function getAccountsWithPositions(): Promise<bigint[]> {
  if (INDEXER_URL) {
    const rows = (await (await fetch(`${INDEXER_URL}/positions`)).json()) as { accountId: string }[];
    return [...new Set(rows.map((r) => BigInt(r.accountId)))];
  }
  const d = new LedgerLogDirectory(c, ADDR.ledger, DEPLOYED_AT_BLOCK, LOG_CHUNK);
  await d.sync();
  return d.withPositions();
}

/** Accounts with a position in any of these series (a settlement group's participants). */
export async function getHolders(seriesIds: Hex[]): Promise<bigint[]> {
  const d = new LedgerLogDirectory(c, ADDR.ledger, DEPLOYED_AT_BLOCK, LOG_CHUNK);
  await d.sync();
  return d.holders(seriesIds);
}
