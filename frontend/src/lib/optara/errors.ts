/**
 * FRONTEND.md §9 / FE-004: every protocol error (contract/src/libraries/Errors.sol, PROTOCOL_SPEC.md §13) maps to a
 * plain message. The test checks this table against Errors.sol, so a new error can't ship without a message.
 */
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";
import { decodeRevert } from "@optara/sdk";

export const ERROR_MESSAGES: Record<string, string> = {
  // the FRONTEND.md §9 table
  NotHealthy: "Not enough margin for this. Deposit more or reduce size.",
  StaleSpot: "Price data is out of date. Refresh and try again.",
  StaleSurface: "Price data is out of date. Refresh and try again.",
  ProductCloseOnly: "This market is closing-only right now.",
  InsuranceBelowMinimum: "New positions are paused for this asset.",
  FeeTooHigh: "The fee changed. Review and retry.",
  SlippageExceeded: "Price moved. Review and retry.",
  DeadlineExpired: "Price moved. Review and retry.",
  OpenInterestCap: "This market is at its open-interest limit.",
  PositionLimit: "Too many positions in this account. Close some or use another subaccount.",
  PositionBelowMinimum: "Positions must be at least 0.01 options.",
  NotLiquidatable: "This account is no longer liquidatable.",
  SettlementIncomplete: "Settlement is still running. Payouts open soon.",
  RatioNotSet: "Payouts aren't open yet.",
  ActionPaused: "This action is temporarily paused.",
  // accounts and inputs
  NotAuthorized: "This wallet can't act for that account.",
  ZeroAmount: "Enter an amount greater than zero.",
  ZeroAddress: "An address is missing.",
  NotAContract: "That address isn't a contract.",
  InvalidRecipient: "That recipient can't receive this.",
  LengthMismatch: "The request is malformed. Refresh and try again.",
  UnknownSeries: "This option series doesn't exist.",
  UnknownAccount: "This account doesn't exist.",
  AssetMismatch: "Both accounts must use the same settlement asset.",
  AssetNotApproved: "This asset isn't accepted as collateral.",
  UnsupportedDecimals: "This token isn't supported.",
  InsufficientCash: "Not enough cash in the account.",
  InsufficientShort: "You don't have that many short options in this account.",
  InsufficientLong: "You don't have that many long options in this account.",
  NonExactTransfer: "The token moved a different amount than requested (fee-on-transfer tokens aren't supported).",
  TokensNotReceived: "The tokens didn't arrive. Try again.",
  InsufficientTreasury: "The treasury doesn't hold that much.",
  // products, series, groups
  InvalidProductConfig: "That product configuration isn't valid.",
  ProductNotEnabled: "This market isn't open.",
  InvalidSeriesParams: "Those series terms aren't allowed.",
  SeriesExists: "This series already exists.",
  GroupFull: "No more series can be listed for this expiry.",
  SeriesNotActive: "This option has expired. Only closing and settlement are possible.",
  GroupAlreadyFinalized: "This expiry is already settled at its final price.",
  GroupNotFinalized: "This expiry has no final price yet.",
  UnknownGroup: "This expiry doesn't exist.",
  // risk and oracles
  MissingSurfaceNode: "Volatility data for this option is missing. Refresh and try again.",
  SeriesNotPriceable: "This option can't be priced right now (volatility data doesn't cover it).",
  InvalidLimits: "Those limits aren't valid.",
  InvalidRiskParams: "Those risk parameters aren't valid.",
  UnknownRiskSet: "Unknown risk parameter set.",
  RiskSetExists: "That risk parameter set already exists.",
  RiskSetAlreadyAssigned: "This market already has a risk parameter set.",
  InvalidFeeConfig: "That fee configuration isn't valid.",
  InvalidSpotSource: "That price source isn't valid.",
  InvalidSpotPrice: "The price feed returned an unusable price.",
  SpotConfidenceTooWide: "The price feed is too uncertain right now. Try again shortly.",
  InsufficientProviderFee: "The price update fee went up. Refresh and try again.",
  RefundFailed: "Your wallet couldn't receive the fee refund.",
  InvalidOracleUpdate: "The price update is malformed. Refresh and try again.",
  InvalidSurfaceReport: "The volatility update was rejected. Refresh and try again.",
  InvalidSignatures: "The volatility update isn't properly signed.",
  InvalidSurfaceConfig: "That volatility configuration isn't valid.",
  InvalidPublisher: "That publisher isn't valid.",
  // venues
  MarketNotVerified: "This market isn't verified for trading.",
  InvalidMarket: "This market isn't valid for that option.",
  InvalidAdapter: "That trading venue adapter isn't valid.",
  AdapterDisabled: "Trading on this venue is paused. You can still mint, close and settle.",
  VenueBalanceLeft: "The venue didn't settle the trade cleanly. Try again.",
  // liquidation
  EmptyBucket: "This account has no open positions in that market.",
  InvalidLiquidationParams: "Those liquidation parameters aren't valid.",
  AuctionNotActive: "There's no liquidation auction for this account.",
  AuctionActive: "A liquidation auction is already running for this account.",
  SliceOutOfBounds: "Choose a slice size within the allowed range.",
  HealthNotImproved: "That slice is too small to improve the account. Choose a larger one.",
  // settlement
  NotParticipant: "This account has nothing to settle in this expiry.",
  RatioAlreadySet: "Payouts for this expiry are already open.",
  NothingToClaim: "Nothing left to claim here.",
  OracleNotStalled: "The settlement price feed isn't late yet.",
  PayoutsOutstanding: "Some payouts are still unclaimed.",
  InvalidSettlementProof: "That settlement price proof doesn't hold. A keeper will retry.",
  FinalizationTooEarly: "It's too early to settle this expiry.",
  InvalidSettlementConfig: "That settlement price configuration isn't valid.",
  UnknownSettlementConfig: "Unknown settlement price configuration.",
  SettlementConfigExists: "That settlement price configuration already exists.",
  // governance
  InvalidScope: "That pause scope isn't valid.",
  InvalidPauseBits: "Those pause flags aren't valid.",
  InvalidDelay: "That delay isn't allowed.",
  UnknownProxy: "Unknown contract.",
  ImplementationNotAllowed: "That upgrade isn't allowlisted.",
  UnknownUpgrade: "Unknown upgrade.",
  UpgradeNotPending: "That upgrade isn't pending.",
  UpgradeNotReady: "That upgrade's timelock hasn't passed.",
  CodeHashMismatch: "The contract code doesn't match.",
  // OpenZeppelin tokens
  ERC20InsufficientBalance: "Not enough tokens in your wallet.",
  ERC20InsufficientAllowance: "Approval needed first.",
};

export interface FriendlyError {
  /** The error name when the contract gave one. */
  name?: string;
  message: string;
  rejected?: boolean;
}

/** A viem/wallet error → a message for people. */
export function friendlyError(e: unknown): FriendlyError {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return { message: "You cancelled in your wallet.", rejected: true };
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName ?? (revert?.raw ? decodeRevert(revert.raw).split("(")[0] : undefined);
    if (name && ERROR_MESSAGES[name]) return { name, message: ERROR_MESSAGES[name]! };
    if (name) return { name, message: `The transaction would fail (${name}).` };
    if (/insufficient funds/i.test(e.message)) return { message: "Not enough MON in your wallet for gas." };
    return { message: e.shortMessage };
  }
  return { message: e instanceof Error ? e.message : String(e) };
}
