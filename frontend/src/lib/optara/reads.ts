import type { Address, Hex, PublicClient } from "viem";
import { optaraCoreAbi, optaraConfigAbi, oracleRegistryAbi, erc20Abi } from "./abi.ts";
import type { Manifest } from "../../config/networks.ts";
import type { PositionView, RiskStateView, SeriesView } from "./types.ts";

/**
 * Read helpers with the names planned for @optara/sdk (getSeries, listSeries, getAccountRiskState, previewWrite...).
 * Every number is read from the authoritative core views; nothing is recomputed locally (DD-025, PROTOCOL_SPEC 2.1).
 */

const symbolCache = new Map<string, string>();
const decimalsCache = new Map<string, number>();

async function assetMeta(client: PublicClient, m: Manifest, asset: Address): Promise<{ symbol: string; decimals: number }> {
  const key = asset.toLowerCase();
  if (!symbolCache.has(key)) {
    const [symbol, decimals] = await Promise.all([
      client.readContract({ address: m.contracts.OptaraConfig, abi: optaraConfigAbi, functionName: "assetSymbol", args: [asset] }),
      client.readContract({ address: asset, abi: erc20Abi, functionName: "decimals" }),
    ]);
    symbolCache.set(key, symbol);
    decimalsCache.set(key, decimals);
  }
  return { symbol: symbolCache.get(key)!, decimals: decimalsCache.get(key)! };
}

async function underlyingSymbol(client: PublicClient, m: Manifest, u: Address): Promise<string> {
  const key = `u:${u.toLowerCase()}`;
  if (!symbolCache.has(key)) {
    const [, symbol] = await client.readContract({ address: m.contracts.OptaraConfig, abi: optaraConfigAbi, functionName: "underlyingInfo", args: [u] });
    symbolCache.set(key, symbol);
  }
  return symbolCache.get(key)!;
}

export async function getSeries(client: PublicClient, m: Manifest, seriesId: Hex): Promise<SeriesView> {
  const core = m.contracts.OptaraCore;
  const s = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "getSeries", args: [seriesId] });
  const [status, stalled, group, asset, uSym, tokenSymbol] = await Promise.all([
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "seriesStatus", args: [seriesId] }),
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "isOracleStalled", args: [s.groupId] }),
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "getGroup", args: [s.groupId] }),
    assetMeta(client, m, s.settlementAsset),
    underlyingSymbol(client, m, s.underlying),
    client.readContract({ address: s.optionToken, abi: erc20Abi, functionName: "symbol" }),
  ]);
  const payoff = group.finalized
    ? await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "seriesPayoffPerUnderlying", args: [seriesId] })
    : undefined;
  return {
    seriesId,
    groupId: s.groupId,
    optionToken: s.optionToken,
    underlying: s.underlying,
    underlyingSymbol: uSym,
    settlementAsset: s.settlementAsset,
    assetSymbol: asset.symbol,
    assetDecimals: asset.decimals,
    optionType: s.optionType as 0 | 1,
    strikeWad: s.strikeWad,
    capWad: s.capWad,
    contractSizeWad: s.contractSizeWad,
    expiry: BigInt(s.expiry),
    oracleConfigId: s.oracleConfigId,
    quantityIncrement: s.quantityIncrement,
    status: status as 0 | 1 | 2 | 3,
    oracleStalled: stalled,
    payoffPerUnderlyingWad: payoff,
    settlementPriceWad: group.finalized ? group.settlementPriceWad : undefined,
    tokenSymbol,
  };
}

/** Series catalog straight from the core's on-chain enumeration (works without an indexer). */
export async function listSeries(client: PublicClient, m: Manifest): Promise<SeriesView[]> {
  const n = await client.readContract({ address: m.contracts.OptaraCore, abi: optaraCoreAbi, functionName: "seriesCount" });
  const ids = await Promise.all(
    Array.from({ length: Number(n) }, (_, i) =>
      client.readContract({ address: m.contracts.OptaraCore, abi: optaraCoreAbi, functionName: "seriesIdAt", args: [BigInt(i)] })),
  );
  const all = await Promise.all(ids.map((id) => getSeries(client, m, id)));
  return all.sort((a, b) =>
    Number(a.expiry - b.expiry) || a.underlyingSymbol.localeCompare(b.underlyingSymbol) || a.optionType - b.optionType ||
    (a.strikeWad < b.strikeWad ? -1 : a.strikeWad > b.strikeWad ? 1 : 0));
}

export async function getAccountRiskState(client: PublicClient, m: Manifest, account: Address, asset: Address): Promise<RiskStateView> {
  const core = m.contracts.OptaraCore;
  const [r, [, rho], meta] = await Promise.all([
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "accountRiskState", args: [account, asset] }),
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "assetStatus", args: [asset] }),
    assetMeta(client, m, asset),
  ]);
  return {
    asset,
    assetSymbol: meta.symbol,
    assetDecimals: meta.decimals,
    cash: r.cash,
    effectiveCash: r.effectiveCash,
    requiredMargin: r.requiredMargin,
    freeCollateral: r.freeCollateral,
    deficit: r.deficit,
    hasUnsyncedMaturedGroups: r.hasUnsyncedMaturedGroups,
    assetStatus: r.assetStatus,
    rhoWad: rho,
  };
}

export async function getPositions(client: PublicClient, m: Manifest, account: Address): Promise<PositionView[]> {
  const core = m.contracts.OptaraCore;
  const groups = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "accountGroups", args: [account] });
  const out: PositionView[] = [];
  for (const groupId of groups) {
    const ids = await client.readContract({ address: core, abi: optaraCoreAbi, functionName: "accountGroupSeries", args: [account, groupId] });
    const positions = await Promise.all(ids.map((id) => client.readContract({ address: core, abi: optaraCoreAbi, functionName: "positionOf", args: [account, id] })));
    ids.forEach((seriesId, i) => out.push({ seriesId, groupId, shortQty: positions[i]!.shortQty, lockedQty: positions[i]!.lockedQty }));
  }
  return out;
}

export interface WritePreview {
  requiredAfter: bigint;
  additionalCollateral: bigint;
  maxPayoutNative: bigint;
}

/** Advisory preview (SDK-005). The core recomputes everything at execution; a stale preview cannot bypass it. */
export async function previewWrite(client: PublicClient, m: Manifest, account: Address, s: SeriesView, quantity: bigint): Promise<WritePreview> {
  const core = m.contracts.OptaraCore;
  const [requiredAfter, additionalCollateral] = await Promise.all([
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "requiredMarginAfter", args: [account, s.seriesId, quantity, 0n] }),
    client.readContract({ address: core, abi: optaraCoreAbi, functionName: "additionalCollateralForWrite", args: [account, s.seriesId, quantity] }),
  ]);
  const d = 10n ** BigInt(54 - s.assetDecimals);
  const n = s.capWad * s.contractSizeWad * quantity;
  return { requiredAfter, additionalCollateral, maxPayoutNative: (n + d - 1n) / d };
}

export interface SettlementSchedule {
  observationStart: bigint;
  observationEnd: bigint;
  earliestFinalization: bigint;
  /** expiry + maxFinalizationDelay: ORACLE_STALLED from here on. An escalation deadline, not a payout date. */
  escalationDeadline: bigint;
}

/** The series' precommitted observation rule and deadlines, read from its immutable oracle config (USER_FLOWS 50). */
export async function getSettlementSchedule(client: PublicClient, m: Manifest, s: SeriesView): Promise<SettlementSchedule> {
  const registry = m.contracts.OracleRegistry;
  const [[observationStart, observationEnd], [minDelay, maxDelay]] = await Promise.all([
    client.readContract({ address: registry, abi: oracleRegistryAbi, functionName: "observationWindow", args: [s.oracleConfigId, s.expiry] }),
    client.readContract({ address: registry, abi: oracleRegistryAbi, functionName: "finalizationDelays", args: [s.oracleConfigId] }),
  ]);
  return {
    observationStart: BigInt(observationStart),
    observationEnd: BigInt(observationEnd),
    earliestFinalization: s.expiry + BigInt(minDelay),
    escalationDeadline: s.expiry + BigInt(maxDelay),
  };
}

export async function previewRedeem(client: PublicClient, m: Manifest, seriesId: Hex, quantity: bigint): Promise<{ payout: bigint; paid: bigint }> {
  const [payout, paid] = await client.readContract({ address: m.contracts.OptaraCore, abi: optaraCoreAbi, functionName: "previewRedeem", args: [seriesId, quantity] });
  return { payout, paid };
}

export async function tokenBalance(client: PublicClient, token: Address, holder: Address): Promise<bigint> {
  return client.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
}

export async function allowance(client: PublicClient, token: Address, owner: Address, spender: Address): Promise<bigint> {
  return client.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [owner, spender] });
}
