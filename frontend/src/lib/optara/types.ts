import type { Address, Hex } from "viem";

/** OptionSeriesRegistry.SeriesTerms plus the product's display symbols. */
export interface Series {
  id: Hex;
  groupId: Hex;
  productId: Hex;
  underlying: Address;
  settlementAsset: Address;
  wrapper: Address;
  optionType: number; // 0 call, 1 put
  strikeWad: bigint;
  contractSizeWad: bigint;
  expiry: bigint;
  settlementOracleConfigId: Hex;
  underlyingSymbol: string;
  assetSymbol: string;
  assetDecimals: number;
}

/** SettlementWindow.GroupState (STATE_MACHINE.md §1). */
export const GROUP_STATES = ["ACTIVE", "EXPIRED", "ORACLE_STALLED", "FINALIZED", "ALL_SETTLED", "REDEEMABLE"] as const;
export type GroupState = (typeof GROUP_STATES)[number];

/** PortfolioRiskManager.HealthState (STATE_MACHINE.md §2). */
export const HEALTH_STATES = ["HEALTHY", "CLOSE_ONLY", "LIQUIDATABLE", "INSOLVENT"] as const;
export type HealthState = (typeof HEALTH_STATES)[number];

export interface Health {
  state: HealthState;
  equity: bigint; // WAD
  initialMargin: bigint; // WAD
  maintenanceMargin: bigint; // WAD
  fresh: boolean;
}

export interface Position {
  seriesId: Hex;
  balance: bigint; // signed, 18 decimals
  series: Series;
}

export interface Quote {
  /** Best bid / ask in the settlement asset per contract (WAD); undefined when that side is empty. */
  bid?: bigint;
  ask?: bigint;
  market: Address;
}

/** Surface status (VolSurfaceOracle.SurfaceStatus). */
export const SURFACE_STATUS = ["NONE", "FRESH", "STALE", "EXPIRED_DATA"] as const;
export type SurfaceStatus = (typeof SURFACE_STATUS)[number];
