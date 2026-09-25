import type { Address, Hex } from "viem";

export interface SeriesView {
  seriesId: Hex;
  groupId: Hex;
  optionToken: Address;
  underlying: Address;
  underlyingSymbol: string;
  settlementAsset: Address;
  assetSymbol: string;
  assetDecimals: number;
  optionType: 0 | 1; // CALL, PUT
  strikeWad: bigint;
  capWad: bigint;
  contractSizeWad: bigint;
  expiry: bigint;
  oracleConfigId: Hex;
  quantityIncrement: bigint;
  status: 0 | 1 | 2 | 3;
  oracleStalled: boolean;
  payoffPerUnderlyingWad?: bigint;
  settlementPriceWad?: bigint;
  tokenSymbol: string;
}

export interface RiskStateView {
  asset: Address;
  assetSymbol: string;
  assetDecimals: number;
  cash: bigint;
  effectiveCash: bigint;
  requiredMargin: bigint;
  freeCollateral: bigint;
  deficit: bigint;
  hasUnsyncedMaturedGroups: boolean;
  assetStatus: number; // 0 NORMAL, 1 RESTRICTED, 2 WIND_DOWN
  rhoWad: bigint;
}

export interface PositionView {
  seriesId: Hex;
  groupId: Hex;
  shortQty: bigint;
  lockedQty: bigint;
}
