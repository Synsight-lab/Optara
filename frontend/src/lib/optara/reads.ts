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
  venueRouterAbi,
  upgradeAdminAbi,
  type ListedSeries,
} from "@optara/sdk";
import { legOf, payoutPerOption } from "./payoff.ts";
import { averageCost, type Fill, type HistoryEntry, type SeriesPnl } from "./pnl.ts";
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
    return {
      market,
      bid: bid === 0n || bid === maxUint256 ? undefined : bid,
      ask: ask === 0n || ask === maxUint256 ? undefined : ask,
    };
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

/** Every account's non-zero position in one series, from the indexer (GET /series/:id/positions). */
async function indexerPositions(seriesId: Hex): Promise<{ accountId: bigint; balance: bigint }[]> {
  const res = await fetch(`${INDEXER_URL}/series/${seriesId}/positions`);
  if (!res.ok) throw new Error(`indexer /series/positions: HTTP ${res.status}`);
  return ((await res.json()) as { accountId: string; balance: string }[]).map((r) => ({ accountId: BigInt(r.accountId), balance: BigInt(r.balance) }));
}

/** Accounts with a position in any of these series (a settlement group's participants). */
export async function getHolders(seriesIds: Hex[]): Promise<bigint[]> {
  if (INDEXER_URL) {
    try {
      const rows = (await Promise.all(seriesIds.map((id) => indexerPositions(id)))).flat();
      return [...new Set(rows.map((r) => r.accountId))];
    } catch {
      // indexer unreachable: fall back to the ledger's logs
    }
  }
  const d = new LedgerLogDirectory(c, ADDR.ledger, DEPLOYED_AT_BLOCK, LOG_CHUNK);
  await d.sync();
  return d.holders(seriesIds);
}

// ------------------------------------------------------------------ what backs a series (buyer view)

export interface Writer {
  accountId: bigint;
  /** Options this account has written (positive number). */
  written: bigint;
  health: Health;
}

export interface Backing {
  /** Options written in total = options held (INV-1: every long, in a wallet or an account, has a writer). */
  written: bigint;
  /** Of those, held as tokens in wallets (what buyers on the order book own). */
  inWallets: bigint;
  /** Writers, largest first. Their collateral is shared across all their positions (portfolio margin). */
  writers: Writer[];
  /** Insurance fund for the settlement asset (native units). */
  insurance: bigint;
}

export async function getBacking(s: Series): Promise<Backing> {
  const [holders, inWallets, insurance] = await Promise.all([
    INDEXER_URL ? Promise.resolve([] as bigint[]) : getHolders([s.id]),
    c.readContract({ address: s.wrapper, abi: erc20Abi, functionName: "totalSupply" }),
    c.readContract({ address: ADDR.insurance, abi: insuranceFundAbi, functionName: "balanceOf", args: [s.settlementAsset] }),
  ]);
  // With an indexer, its positions already carry the balances; otherwise read each holder's balance on-chain.
  const indexed = INDEXER_URL ? await indexerPositions(s.id).catch(() => undefined) : undefined;
  const balances = indexed
    ? indexed.map((r) => ({ id: r.accountId, bal: r.balance }))
    : await Promise.all(
        holders.map(async (id) => ({ id, bal: await c.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "balanceOf", args: [id, s.id] }) })),
      );
  const shorts = balances.filter((b) => b.bal < 0n);
  const writers = await Promise.all(shorts.map(async (b) => ({ accountId: b.id, written: -b.bal, health: await getHealth(b.id) })));
  writers.sort((a, b) => (a.written > b.written ? -1 : 1));
  return { written: writers.reduce((t, w) => t + w.written, 0n), inWallets, writers, insurance };
}

// ------------------------------------------------------------------ profit and loss (lib/optara/pnl.ts)

/** Every log in [deploy block, head], in LOG_CHUNK windows (Monad's public RPC caps eth_getLogs ranges). */
async function scanLogs<T>(fetch: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>): Promise<T[]> {
  const head = await c.getBlockNumber();
  const out: T[] = [];
  for (let from = DEPLOYED_AT_BLOCK; from <= head; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n > head ? head : from + LOG_CHUNK - 1n;
    out.push(...(await fetch(from, to)));
  }
  return out;
}

/** A log's position on the chain: (block, log index). */
type Order = [bigint, number];

/**
 * The raw history profit and loss is built from, the same shape whichever source supplies it: the indexer
 * (GET /history/:owner) on a real network, or a scan of the contracts' logs when no indexer is configured.
 * `tx` groups logs of one transaction (the indexer only keeps the block, which serves: settlement and liquidation
 * both clear positions in the same block as their own event).
 */
interface History {
  trades: { seriesId: string; isBuy: boolean; qty: bigint; premium: bigint; buyerFee: bigint; order: Order; at?: number }[];
  mints: { seriesId: string; qty: bigint; fee: bigint; recipient: string; order: Order; at?: number }[];
  redeems: { seriesId: string; qty: bigint; payout: bigint; order: Order; at?: number }[];
  balances: { accountId: bigint; seriesId: string; delta: bigint; balance: bigint; tx: string; order: Order; at?: number }[];
  settled: { accountId: bigint; groupId: string; tx: string }[];
  liquidationTxs: Set<string>;
}

async function historyFromLogs(owner: Address, accountIds: bigint[]): Promise<History> {
  const ids = accountIds.length ? accountIds : undefined;
  const none = async () => [] as never[];
  const [trades, mints, redeems, balances, settled, liquidated, liquidating] = await Promise.all([
    scanLogs((f, t) => c.getContractEvents({ address: ADDR.router, abi: venueRouterAbi, eventName: "VenueTrade", args: { trader: owner }, fromBlock: f, toBlock: t, strict: true })),
    ids ? scanLogs((f, t) => c.getContractEvents({ address: ADDR.clearing, abi: optionClearingAbi, eventName: "ExternalLongMinted", args: { accountId: ids }, fromBlock: f, toBlock: t, strict: true })) : none(),
    scanLogs((f, t) => c.getContractEvents({ address: ADDR.settlement, abi: settlementWindowAbi, eventName: "WrapperRedeemed", args: { holder: owner }, fromBlock: f, toBlock: t, strict: true })),
    ids ? scanLogs((f, t) => c.getContractEvents({ address: ADDR.ledger, abi: subAccountsAbi, eventName: "BalanceUpdated", args: { accountId: ids }, fromBlock: f, toBlock: t, strict: true })) : none(),
    ids ? scanLogs((f, t) => c.getContractEvents({ address: ADDR.settlement, abi: settlementWindowAbi, eventName: "AccountSettled", args: { accountId: ids }, fromBlock: f, toBlock: t, strict: true })) : none(),
    ids ? scanLogs((f, t) => c.getContractEvents({ address: ADDR.liquidation, abi: liquidationModuleAbi, eventName: "SliceLiquidated", args: { accountId: ids }, fromBlock: f, toBlock: t, strict: true })) : none(),
    ids ? scanLogs((f, t) => c.getContractEvents({ address: ADDR.liquidation, abi: liquidationModuleAbi, eventName: "SliceLiquidated", args: { liquidatorAccountId: ids }, fromBlock: f, toBlock: t, strict: true })) : none(),
  ]);
  const o = (l: { blockNumber: bigint; logIndex: number }): Order => [l.blockNumber, l.logIndex];
  return {
    trades: trades.map((l) => ({ seriesId: l.args.seriesId, isBuy: l.args.isBuy, qty: l.args.qty, premium: l.args.premium, buyerFee: l.args.buyerFee, order: o(l) })),
    mints: mints.map((l) => ({ seriesId: l.args.seriesId, qty: l.args.qty, fee: l.args.fee, recipient: l.args.recipient, order: o(l) })),
    redeems: redeems.map((l) => ({ seriesId: l.args.seriesId, qty: l.args.qty, payout: l.args.payout, order: o(l) })),
    balances: balances.map((l) => ({ accountId: l.args.accountId, seriesId: l.args.seriesId, delta: l.args.delta, balance: l.args.balance, tx: l.transactionHash, order: o(l) })),
    settled: settled.map((l) => ({ accountId: l.args.accountId, groupId: l.args.groupId, tx: l.transactionHash })),
    liquidationTxs: new Set([...liquidated, ...liquidating].map((l) => l.transactionHash)),
  };
}

/** The indexer's records: ids are "block_logIndex"; bigints arrive as decimal strings. */
async function historyFromIndexer(owner: Address): Promise<History> {
  const res = await fetch(`${INDEXER_URL}/history/${owner}`);
  if (!res.ok) throw new Error(`indexer /history: HTTP ${res.status}`);
  type R = Record<string, string | number | boolean>;
  const h = (await res.json()) as Record<"trades" | "mints" | "redeems" | "balances" | "settled" | "liquidations", R[]>;
  const o = (id: unknown): Order => {
    const [b, i] = String(id).split("_");
    return [BigInt(b!), Number(i)];
  };
  const big = (x: unknown) => BigInt(String(x));
  const ts = (x: unknown) => Number(x);
  return {
    trades: h.trades.map((r) => ({ seriesId: String(r.seriesId), isBuy: r.isBuy === true || r.isBuy === "true", qty: big(r.qty), premium: big(r.premium), buyerFee: big(r.buyerFee), order: o(r.id), at: ts(r.timestamp) })),
    mints: h.mints.map((r) => ({ seriesId: String(r.seriesId), qty: big(r.qty), fee: big(r.fee), recipient: String(r.recipient), order: o(r.id), at: ts(r.timestamp) })),
    // REDEEMED rows keep the quantity in netNumerator and the payout in amount (indexer handlers/Settlement.ts)
    redeems: h.redeems.map((r) => ({ seriesId: String(r.seriesId), qty: big(r.netNumerator), payout: big(r.amount), order: o(r.id), at: ts(r.timestamp) })),
    balances: h.balances.map((r) => ({ accountId: big(r.accountId), seriesId: String(r.seriesId), delta: big(r.delta), balance: big(r.balance), tx: o(r.id)[0].toString(), order: o(r.id), at: ts(r.timestamp) })),
    settled: h.settled.map((r) => ({ accountId: big(r.accountId), groupId: String(r.groupId), tx: o(r.id)[0].toString() })),
    liquidationTxs: new Set(h.liquidations.map((r) => o(r.id)[0].toString())),
  };
}

/**
 * P&L per option for a wallet and its margin accounts: buys and sells (VenueTrade), writing fees (ExternalLongMinted),
 * redemptions (WrapperRedeemed), and positions closed at settlement (the ledger's BalanceUpdated in the same
 * transaction as AccountSettled, valued at the group's fixed price). From the indexer when one is configured (fast on
 * Monad, whose public RPC scans 100 blocks per call), else from the contracts' logs.
 */
export async function getTradePnl(owner: Address, accountIds: bigint[], all: Series[]): Promise<SeriesPnl[]> {
  const byId = new Map(all.map((s) => [s.id.toLowerCase(), s]));
  const h = INDEXER_URL ? await historyFromIndexer(owner).catch(() => historyFromLogs(owner, accountIds)) : await historyFromLogs(owner, accountIds);

  type Ev = Omit<HistoryEntry, "at"> & { order: Order; at?: number };
  type Row = { paid: number; received: number; approximate: boolean; accountQty: bigint; fills: { order: Order; f: Fill }[]; otherRealized: number; wrote: boolean; events: Ev[] };
  const rows = new Map<string, Row>();
  const row = (id: string) =>
    rows.get(id) ?? (rows.set(id, { paid: 0, received: 0, approximate: false, accountQty: 0n, fills: [], otherRealized: 0, wrote: false, events: [] }), rows.get(id)!);
  const cash = (s: Series, native: bigint) => Number(native) / 10 ** s.assetDecimals;
  const qtyOf = (q: bigint) => Number(q) / 1e18;
  const before = (x: Order, y: Order) => (x[0] === y[0] ? x[1] - y[1] : x[0] < y[0] ? -1 : 1);

  for (const t of h.trades) {
    const s = byId.get(t.seriesId.toLowerCase());
    if (!s) continue;
    const r = row(s.id.toLowerCase());
    if (t.isBuy) {
      const c = cash(s, t.premium + t.buyerFee);
      r.paid += c;
      r.fills.push({ order: t.order, f: { kind: "buy", qty: qtyOf(t.qty), cash: c } });
      r.events.push({ kind: "buy", qty: qtyOf(t.qty), cash: -c, order: t.order, at: t.at });
    } else {
      const c = cash(s, t.premium); // already net of the order-book fee
      r.received += c;
      r.fills.push({ order: t.order, f: { kind: "sell", qty: qtyOf(t.qty), cash: c } });
      r.events.push({ kind: "sell", qty: qtyOf(t.qty), cash: c, order: t.order, at: t.at });
    }
  }
  for (const m of h.mints) {
    const s = byId.get(m.seriesId.toLowerCase());
    if (!s) continue;
    const r = row(s.id.toLowerCase());
    const fee = cash(s, m.fee);
    r.paid += fee;
    r.wrote = true;
    r.events.push({ kind: "write", qty: qtyOf(m.qty), cash: -fee, order: m.order, at: m.at });
    // Written straight into your wallet: those tokens carry the writing fee as their cost. Sent elsewhere: a plain cost.
    if (m.recipient.toLowerCase() === owner.toLowerCase()) r.fills.push({ order: m.order, f: { kind: "mint", qty: qtyOf(m.qty), cash: fee } });
    else r.otherRealized -= fee;
  }
  for (const d of h.redeems) {
    const s = byId.get(d.seriesId.toLowerCase());
    if (!s) continue;
    const r = row(s.id.toLowerCase());
    const c = cash(s, d.payout);
    r.received += c;
    r.fills.push({ order: d.order, f: { kind: "redeem", qty: qtyOf(d.qty), cash: c } });
    r.events.push({ kind: "redeem", qty: qtyOf(d.qty), cash: c, order: d.order, at: d.at });
  }

  // Fixed price and payout rate of every group the history touches.
  const groupIds = new Set<Hex>([...h.balances.map((b) => byId.get(b.seriesId.toLowerCase())?.groupId), ...[...rows.keys()].map((k) => byId.get(k)?.groupId)].filter((g): g is Hex => !!g));
  const groups = new Map(await Promise.all([...groupIds].map(async (g) => [g, (await getGroup(g)).accounting] as const)));

  const settleKeys = new Set(h.settled.map((x) => `${x.tx}:${x.accountId}:${x.groupId.toLowerCase()}`));
  const lastBalance = new Map<string, bigint>(); // account:series → balance after the latest update
  for (const b of [...h.balances].sort((x, y) => before(x.order, y.order))) {
    const s = byId.get(b.seriesId.toLowerCase());
    if (!s) continue;
    lastBalance.set(`${b.accountId}:${s.id.toLowerCase()}`, b.balance);
    const r = row(s.id.toLowerCase());
    if (h.liquidationTxs.has(b.tx)) r.approximate = true;
    if (!settleKeys.has(`${b.tx}:${b.accountId}:${s.groupId.toLowerCase()}`)) continue;
    // Closed at settlement: the position before was −delta; it was worth its payout at the fixed price.
    const a = groups.get(s.groupId);
    if (!a?.finalized) continue;
    const qty = Number(-b.delta) / 1e18;
    const unit = payoutPerOption(legOf(s), Number(a.priceWad) / 1e18);
    const price = Number(a.priceWad) / 1e18;
    if (qty < 0) {
      r.paid += -qty * unit;
      r.otherRealized -= -qty * unit; // a writer's debt settled: locked in
      r.events.push({ kind: "settle", qty, cash: -(-qty * unit), price, order: b.order, at: b.at });
    } else {
      const credit = qty * unit * (a.ratioSet ? Number(a.ratioWad) / 1e18 : 1);
      r.received += credit;
      r.otherRealized += credit;
      r.events.push({ kind: "settle", qty, cash: credit, price, order: b.order, at: b.at });
    }
  }
  for (const [k, bal] of lastBalance) row(k.split(":")[1]!).accountQty += bal;

  // What is still held: at the settlement payout once fixed; after expiry but before that, at its payout at today's
  // price (the fair value reads 0 once expired); before expiry, at fair value.
  const now = (await c.getBlock()).timestamp;
  // Log scans carry no time; the indexer's records do.
  const blockTimes = new Map<bigint, number>();
  const untimed = [...new Set([...rows.values()].flatMap((r) => r.events.filter((e) => e.at === undefined).map((e) => e.order[0])))];
  await Promise.all(untimed.map(async (b) => blockTimes.set(b, Number((await c.getBlock({ blockNumber: b })).timestamp))));
  return Promise.all(
    [...rows.entries()].map(async ([sid, r]): Promise<SeriesPnl> => {
      const s = byId.get(sid)!;
      const walletQty = await c.readContract({ address: s.wrapper, abi: erc20Abi, functionName: "balanceOf", args: [owner] });
      const a = groups.get(s.groupId);
      const w = Number(walletQty) / 1e18;
      const acct = Number(r.accountQty) / 1e18;
      let value = 0;
      if (w !== 0 || acct !== 0) {
        if (a?.finalized) {
          const unit = payoutPerOption(legOf(s), Number(a.priceWad) / 1e18);
          const ratio = a.ratioSet ? Number(a.ratioWad) / 1e18 : 1;
          value = (w + Math.max(acct, 0)) * unit * ratio + Math.min(acct, 0) * unit;
        } else if (s.expiry <= now) {
          const spot = (await getProductMarket(s.productId).catch(() => undefined))?.spotWad;
          if (spot !== undefined) value = (w + acct) * payoutPerOption(legOf(s), Number(spot) / 1e18);
          else r.approximate = true;
        } else {
          const mark = (await getSeriesMarket(s).catch(() => undefined))?.mark;
          if (mark !== undefined) value = (w + acct) * (Number(mark) / 1e18);
          else r.approximate = true;
        }
      }
      // Tokens in the wallet that were never bought here (received by transfer) have no cost on record.
      if (w > 0 && r.paid === 0 && r.received === 0) r.approximate = true;
      const avg = averageCost(r.fills.sort((x, y) => before(x.order, y.order)).map((x) => x.f));
      return {
        series: s,
        paid: r.paid,
        received: r.received,
        value,
        realized: avg.realized + r.otherRealized,
        costHeld: avg.costHeld,
        walletQty: w,
        accountQty: acct,
        status: w === 0 && acct === 0 ? "closed" : a?.finalized || s.expiry <= now ? "expired" : "open",
        approximate: r.approximate,
        wrote: r.wrote,
        history: r.events
          .sort((x, y) => before(x.order, y.order))
          .map(({ order, at, ...e }) => ({ ...e, at: at ?? blockTimes.get(order[0]) ?? 0 })),
        settlementPrice: a?.finalized ? Number(a.priceWad) / 1e18 : undefined,
      };
    }),
  );
}

// ------------------------------------------------------------------ running auctions

export interface RunningAuction {
  accountId: bigint;
  underlying: Address;
  startedAt: bigint;
}

/** Auctions started and not yet ended (LiquidationModule AuctionStarted / AuctionEnded). */
export async function getRunningAuctions(): Promise<RunningAuction[]> {
  if (INDEXER_URL) {
    try {
      const res = await fetch(`${INDEXER_URL}/auctions/active`);
      if (res.ok) {
        const rows = (await res.json()) as { accountId: string; underlying: Address; startTime: string }[];
        return rows.map((r) => ({ accountId: BigInt(r.accountId), underlying: r.underlying, startedAt: BigInt(r.startTime) }));
      }
    } catch {
      // indexer unreachable: fall back to the logs
    }
  }
  const [started, ended] = await Promise.all([
    scanLogs((f, t) => c.getContractEvents({ address: ADDR.liquidation, abi: liquidationModuleAbi, eventName: "AuctionStarted", fromBlock: f, toBlock: t, strict: true })),
    scanLogs((f, t) => c.getContractEvents({ address: ADDR.liquidation, abi: liquidationModuleAbi, eventName: "AuctionEnded", fromBlock: f, toBlock: t, strict: true })),
  ]);
  const key = (a: bigint, u: string) => `${a}:${u.toLowerCase()}`;
  const last = new Map<string, { at: [bigint, number]; started?: RunningAuction }>();
  const later = (x: [bigint, number], y: [bigint, number]) => x[0] > y[0] || (x[0] === y[0] && x[1] > y[1]);
  for (const l of started) {
    const k = key(l.args.accountId, l.args.underlying);
    const at: [bigint, number] = [l.blockNumber, l.logIndex];
    const prev = last.get(k);
    if (!prev || later(at, prev.at)) last.set(k, { at, started: { accountId: l.args.accountId, underlying: l.args.underlying, startedAt: l.args.startTime } });
  }
  for (const l of ended) {
    const k = key(l.args.accountId, l.args.underlying);
    const at: [bigint, number] = [l.blockNumber, l.logIndex];
    const prev = last.get(k);
    if (!prev || later(at, prev.at)) last.set(k, { at });
  }
  return [...last.values()].flatMap((v) => (v.started ? [v.started] : []));
}

/** The account value an auctioned account needs before its auction can be ended: initial margin plus the buffer. */
export async function auctionEndTarget(accountId: bigint): Promise<{ equity: bigint; target: bigint; health: Health }> {
  const [health, params] = await Promise.all([getHealth(accountId), getLiquidationParams()]);
  // Rounded up, as LiquidationModule._target does.
  const target = (health.initialMargin * (10_000n + BigInt(params.targetHealthBufferBps)) + 9_999n) / 10_000n;
  return { equity: health.equity, target, health };
}

// ------------------------------------------------------------------ upgrades (System page)

export interface ScheduledUpgrade {
  id: Hex;
  proxy: Address;
  implementation: Address;
  /** Earliest execution time, unix seconds. */
  eta: bigint;
  emergency: boolean;
  state: "PENDING" | "EXECUTED" | "CANCELLED";
}

/** Every upgrade ever scheduled, newest first, with its current state (UpgradeAdmin.getOperation). */
export async function getUpgrades(upgradeAdmin: Address): Promise<ScheduledUpgrade[]> {
  type Sched = { args: { id: Hex; proxy: Address; implementation: Address; eta: bigint; emergency: boolean } };
  let scheduled: Sched[] | undefined;
  if (INDEXER_URL) {
    try {
      const res = await fetch(`${INDEXER_URL}/upgrades`);
      if (res.ok) {
        // GovernanceEvent rows: `detail` is the event's params as JSON (bigints as strings), oldest first after reverse
        const rows = (await res.json()) as { detail: string }[];
        scheduled = rows.reverse().map((r) => {
          const d = JSON.parse(r.detail) as { id: Hex; proxy: Address; implementation: Address; eta: string; emergency: boolean };
          return { args: { id: d.id, proxy: d.proxy, implementation: d.implementation, eta: BigInt(d.eta), emergency: d.emergency } };
        });
      }
    } catch {
      // indexer unreachable: fall back to the logs
    }
  }
  scheduled ??= await scanLogs((f, t) => c.getContractEvents({ address: upgradeAdmin, abi: upgradeAdminAbi, eventName: "UpgradeScheduled", fromBlock: f, toBlock: t, strict: true }));
  const states = ["NONE", "PENDING", "EXECUTED", "CANCELLED"] as const;
  const out = await Promise.all(
    scheduled.map(async (l) => {
      const op = await c.readContract({ address: upgradeAdmin, abi: upgradeAdminAbi, functionName: "getOperation", args: [l.args.id] });
      return { id: l.args.id, proxy: l.args.proxy, implementation: l.args.implementation, eta: l.args.eta, emergency: l.args.emergency, state: states[op.state] as ScheduledUpgrade["state"] };
    }),
  );
  return out.reverse();
}

// ------------------------------------------------------------------ Kuru balances (outside Optara)

/** Kuru's mainnet Router (deployments/config/monad-mainnet.json), used when the configured router is a local mock. */
const KURU_MAINNET_ROUTER: Address = "0xd651346d7c789536ebf06dc72aE3C8502cd695CC";
const kuruAbi = [
  { type: "function", name: "kuruRouter", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "marginAccountAddress", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "getBalance", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

/**
 * Kuru's margin account: where Kuru keeps funds a user deposits to place their own orders. Read from the router the
 * KuruAdapter uses; when that is a local mock without one, from Kuru's real router (present on a mainnet fork).
 * Undefined when neither has one (e.g. a plain local chain or testnet).
 */
export async function getKuruMarginAccount(): Promise<Address | undefined> {
  const routers: Address[] = [];
  try {
    routers.push(await c.readContract({ address: ADDR.kuruAdapter, abi: kuruAbi, functionName: "kuruRouter" }));
  } catch {
    // no adapter router readable
  }
  routers.push(KURU_MAINNET_ROUTER);
  for (const r of routers) {
    try {
      const m = await c.readContract({ address: r, abi: kuruAbi, functionName: "marginAccountAddress" });
      if (m && m !== "0x0000000000000000000000000000000000000000") return m;
    } catch {
      // not a Kuru router, or no code here
    }
  }
  return undefined;
}

/** The owner's balances on Kuru for the settlement tokens and every option token (non-zero only). */
export async function getKuruBalances(owner: Address, series: Series[]) {
  const margin = await getKuruMarginAccount();
  if (!margin) return { margin, rows: [] as { label: string; amount: string; series?: Series }[] };
  const assets = [...new Map(series.map((s) => [s.settlementAsset.toLowerCase(), s])).values()];
  const reads = await Promise.all([
    ...assets.map(async (s) => ({ label: s.assetSymbol, raw: await c.readContract({ address: margin, abi: kuruAbi, functionName: "getBalance", args: [owner, s.settlementAsset] }), decimals: s.assetDecimals, series: undefined as Series | undefined })),
    ...series.map(async (s) => ({ label: "", raw: await c.readContract({ address: margin, abi: kuruAbi, functionName: "getBalance", args: [owner, s.wrapper] }), decimals: 18, series: s as Series | undefined })),
  ]);
  return {
    margin,
    rows: reads.filter((r) => r.raw > 0n).map((r) => ({ label: r.label, amount: (Number(r.raw) / 10 ** r.decimals).toLocaleString("en-US", { maximumFractionDigits: 4 }), series: r.series })),
  };
}
