/**
 * Transaction builders (FRONTEND.md §4). An action is a list of steps: approvals first (skipped when the allowance
 * already covers it), then the call. Risk-increasing calls fetch a fresh OracleUpdate when the step runs, re-preview
 * by simulating the exact transaction with it, and only then send (FE-002).
 */
import { erc20Abi, maxUint256, parseEventLogs, type Address, type Hex, type TransactionReceipt } from "viem";
import {
  buildSettlementProof,
  liquidationModuleAbi,
  optionClearingAbi,
  optionSeriesRegistryAbi,
  settlementWindowAbi,
  subAccountsAbi,
  venueRegistryAbi,
  venueRouterAbi,
  type OracleUpdate,
} from "@optara/sdk";
import { ADDR, DIRECT_VENUE, KURU_VENUE, publicClient } from "./client.ts";
import { optaraDirectMarketAbi, optaraDirectMarketBytecode } from "./directMarket.ts";
import { ERROR_MESSAGES } from "./errors.ts";
import { fetchOracleUpdate, oracleFee } from "./oracle.ts";
import { deploy, send, type ContractCall, type Wallet } from "./tx.ts";
import type { Series } from "./types.ts";

export interface Step {
  key: string;
  label: string;
  /** Plain-language explanation shown while the step runs. */
  hint?: string;
  /** True when nothing needs doing (e.g. the approval already covers it). */
  done?: (w: Wallet) => Promise<boolean>;
  run: (w: Wallet, onSent?: (hash: Hex) => void) => Promise<TransactionReceipt>;
}

export interface OracleDeps {
  fetchOracleUpdate: (accountId: bigint | undefined, series: readonly Hex[]) => Promise<OracleUpdate>;
  oracleFee: (u: OracleUpdate) => Promise<bigint>;
}
const defaultOracle: OracleDeps = { fetchOracleUpdate, oracleFee };

export const callStep = (key: string, label: string, call: ContractCall, hint?: string): Step => ({ key, label, hint, run: (w, onSent) => send(w, call, onSent) });

/** FE-002: the update is fetched when the step runs; `send` simulates the exact call with it before sending. */
export function riskStep(
  key: string,
  label: string,
  accountId: bigint | undefined,
  series: readonly Hex[],
  build: (u: OracleUpdate) => ContractCall,
  deps: OracleDeps = defaultOracle,
): Step {
  return {
    key,
    label,
    hint: "Fetching fresh prices, checking the result, then sending.",
    run: async (w, onSent) => {
      const u = await deps.fetchOracleUpdate(accountId, series);
      const value = await deps.oracleFee(u);
      return send(w, { ...build(u), value }, onSent);
    },
  };
}

export function approveStep(token: Address, spender: Address, amount: bigint, symbol: string): Step {
  return {
    key: `approve-${token}-${spender}`,
    label: `Allow ${symbol}`,
    hint: "A one-time permission so the protocol can move this token for you.",
    done: async (w) => (await publicClient.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [w.account.address, spender] })) >= amount,
    run: (w, onSent) => send(w, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] }, onSent),
  };
}

// ------------------------------------------------------------------ accounts and collateral (F1, F3, F6)

export const createAccountStep = (asset: Address) =>
  callStep("create-account", "Create your trading account", { address: ADDR.ledger, abi: subAccountsAbi, functionName: "createSubAccount", args: [asset] }, "Optara keeps your collateral and positions in a subaccount.");

/** The id of the account a createSubAccount receipt created. */
export function createdAccountId(receipt: TransactionReceipt): bigint | undefined {
  return parseEventLogs({ abi: subAccountsAbi, eventName: "SubAccountCreated", logs: receipt.logs })[0]?.args.accountId;
}

export const depositSteps = (accountId: bigint, asset: Address, amount: bigint, symbol: string): Step[] => [
  approveStep(asset, ADDR.clearing, amount, symbol),
  callStep("deposit", `Deposit ${symbol}`, { address: ADDR.clearing, abi: optionClearingAbi, functionName: "depositCollateral", args: [accountId, amount] }),
];

export const withdrawSteps = (accountId: bigint, amount: bigint, recipient: Address, deps?: OracleDeps): Step[] => [
  riskStep("withdraw", "Withdraw", accountId, [], (u) => ({ address: ADDR.clearing, abi: optionClearingAbi, functionName: "withdrawCollateral", args: [accountId, amount, recipient, u] }), deps),
];

// ------------------------------------------------------------------ writing (F2, F7)

export const mintSteps = (accountId: bigint, s: Series, qty: bigint, maxSellerFee: bigint, recipient: Address, deps?: OracleDeps): Step[] => [
  riskStep(
    "mint",
    "Write the options",
    accountId,
    [s.id],
    (u) => ({ address: ADDR.clearing, abi: optionClearingAbi, functionName: "mintExternalLong", args: [accountId, s.id, qty, recipient, maxSellerFee, u] }),
    deps,
  ),
];

export const wrapSteps = (accountId: bigint, s: Series, qty: bigint, recipient: Address, deps?: OracleDeps): Step[] => [
  riskStep("wrap", "Move to wallet as tokens", accountId, [s.id], (u) => ({ address: ADDR.clearing, abi: optionClearingAbi, functionName: "wrapLong", args: [accountId, s.id, qty, recipient, u] }), deps),
];

// ------------------------------------------------------------------ router trades (F2 step 4, F9)

const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 600);

export const sellVenueSteps = (s: Series, venueId: Hex, venueName: string, qty: bigint, minProceeds: bigint, maxVenueFee: bigint, recipient: Address): Step[] => [
  approveStep(s.wrapper, ADDR.router, qty, "option tokens"),
  callStep("sell", `Sell on ${venueName}`, {
    address: ADDR.router,
    abi: venueRouterAbi,
    functionName: "sellThroughVenue",
    args: [{ venueId, seriesId: s.id, qty, minProceeds, maxVenueFeeNative: maxVenueFee, recipient, deadline: deadline() }, "0x"],
  }),
];

export const sellSteps = (s: Series, qty: bigint, minProceeds: bigint, maxVenueFee: bigint, recipient: Address): Step[] =>
  sellVenueSteps(s, KURU_VENUE, "Kuru", qty, minProceeds, maxVenueFee, recipient);

export const buyVenueSteps = (s: Series, venueId: Hex, venueName: string, premiumIn: bigint, minQty: bigint, maxBuyerFee: bigint, maxVenueFee: bigint, recipient: Address): Step[] => [
  approveStep(s.settlementAsset, ADDR.router, premiumIn + maxBuyerFee, s.assetSymbol),
  callStep("buy", `Buy on ${venueName}`, {
    address: ADDR.router,
    abi: venueRouterAbi,
    functionName: "buyThroughVenue",
    args: [{ venueId, seriesId: s.id, premiumIn, minQty, maxBuyerFeeNative: maxBuyerFee, maxVenueFeeNative: maxVenueFee, recipient, deadline: deadline() }, "0x"],
  }),
];

export const buySteps = (s: Series, premiumIn: bigint, minQty: bigint, maxBuyerFee: bigint, maxVenueFee: bigint, recipient: Address): Step[] =>
  buyVenueSteps(s, KURU_VENUE, "Kuru", premiumIn, minQty, maxBuyerFee, maxVenueFee, recipient);

// ------------------------------------------------------------------ positions (F4, F5, F11)

export const unwrapSteps = (accountId: bigint, s: Series, qty: bigint): Step[] => [
  callStep("unwrap", "Move tokens into your account", { address: ADDR.clearing, abi: optionClearingAbi, functionName: "unwrapLong", args: [accountId, s.id, qty] }, "Your option tokens become a long position that counts as margin."),
];

export const closeShortSteps = (accountId: bigint, s: Series, qty: bigint): Step[] => [
  callStep("close", "Close the short", { address: ADDR.clearing, abi: optionClearingAbi, functionName: "closeShortWithWrapper", args: [accountId, s.id, qty] }, "Burns option tokens from your wallet against your short; the margin is released."),
];

// ------------------------------------------------------------------ settlement (F10, F13)

export const redeemSteps = (s: Series, qty: bigint, recipient: Address): Step[] => [
  callStep("redeem", "Redeem for the payout", { address: ADDR.settlement, abi: settlementWindowAbi, functionName: "redeemWrapper", args: [s.id, qty, recipient] }),
];

export const claimSteps = (accountId: bigint, groupId: Hex): Step[] => [
  callStep("claim", "Claim into your account", { address: ADDR.settlement, abi: settlementWindowAbi, functionName: "claimSettlement", args: [accountId, groupId] }),
];

export function finalizeSteps(groupId: Hex, configId: Hex, expiry: bigint): Step[] {
  return [
    {
      key: "finalize",
      label: "Fix the settlement price",
      hint: "Proves the price feed's round in force at expiry. Pays a keeper reward.",
      run: async (w, onSent) => {
        const proof = await buildSettlementProof(publicClient, ADDR.settlementOracle, configId, expiry);
        if (proof.error) {
          const name = proof.error.split("(")[0]!;
          throw new Error(ERROR_MESSAGES[name] ?? `The settlement price can't be proven yet (${proof.error}).`);
        }
        return send(w, { address: ADDR.settlement, abi: settlementWindowAbi, functionName: "finalizeGroup", args: [groupId, proof.settlementData] }, onSent);
      },
    },
  ];
}

export const settleBatchSteps = (groupId: Hex, accounts: bigint[]): Step[] => [
  callStep("settle", `Settle ${accounts.length} account${accounts.length === 1 ? "" : "s"}`, { address: ADDR.settlement, abi: settlementWindowAbi, functionName: "settleAccountsGroup", args: [accounts, groupId] }, "Each settled account earns a keeper reward."),
];

export const ratioSteps = (groupId: Hex): Step[] => [
  callStep("ratio", "Open payouts", { address: ADDR.settlement, abi: settlementWindowAbi, functionName: "computeRecoveryRatio", args: [groupId] }),
];

// ------------------------------------------------------------------ liquidation (F12)

export const startAuctionSteps = (accountId: bigint, underlying: Address, deps?: OracleDeps): Step[] => [
  riskStep("start-auction", "Start the liquidation auction", accountId, [], (u) => ({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "startAuction", args: [accountId, underlying, u] }), deps),
];

/** Ends a running auction once the account is back above its target (or has nothing left at risk). Anyone may call. */
export const endAuctionSteps = (accountId: bigint, underlying: Address, deps?: OracleDeps): Step[] => [
  riskStep("end-auction", "End the liquidation auction", accountId, [], (u) => ({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "endAuction", args: [accountId, underlying, u] }), deps),
];

/** Liquidate by handing in option tokens: they cancel the account's written options, and the account pays you. */
export const wrapperLiquidationSteps = (accountId: bigint, s: Series, qty: bigint, liquidatorAccountId: bigint, minCash: bigint, deps?: OracleDeps): Step[] => [
  riskStep(
    "liquidate-wrapper",
    "Hand in option tokens",
    accountId,
    [s.id],
    (u) => ({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "liquidateWithWrapper", args: [accountId, s.id, qty, liquidatorAccountId, minCash, u] }),
    deps,
  ),
];

export const sliceSteps = (accountId: bigint, underlying: Address, liquidatorAccountId: bigint, sliceBps: number, minCash: bigint, maxCash: bigint, deps?: OracleDeps): Step[] => [
  riskStep(
    "slice",
    "Take the slice",
    accountId,
    [],
    (u) => ({ address: ADDR.liquidation, abi: liquidationModuleAbi, functionName: "liquidateSlice", args: [accountId, underlying, liquidatorAccountId, sliceBps, minCash, maxCash, u] }),
    deps,
  ),
];

/** F1 in one go: create an account, approve, deposit. `onCreated` receives the new id once the first step lands. */
export function setupAccountSteps(asset: Address, amount: bigint, symbol: string, onCreated: (id: bigint) => void): Step[] {
  let created: bigint | undefined;
  return [
    {
      ...createAccountStep(asset),
      run: async (w, onSent) => {
        const r = await createAccountStep(asset).run(w, onSent);
        created = createdAccountId(r);
        if (created !== undefined) onCreated(created);
        return r;
      },
    },
    approveStep(asset, ADDR.clearing, amount, symbol),
    {
      key: "deposit",
      label: `Deposit ${symbol}`,
      run: (w, onSent) => {
        if (created === undefined) throw new Error("The account wasn't created.");
        return send(w, { address: ADDR.clearing, abi: optionClearingAbi, functionName: "depositCollateral", args: [created, amount] }, onSent);
      },
    },
  ];
}

export interface SeriesParams {
  underlying: Address;
  settlementAsset: Address;
  optionType: number;
  strikeWad: bigint;
  contractSizeWad: bigint;
  expiry: bigint;
  settlementOracleConfigId: Hex;
  volSurfaceProductId: Hex;
  riskParameterSetId: Hex;
}

/** List a new option market (SERIES_CREATOR role). Terms can never change afterwards. */
export const createSeriesSteps = (params: SeriesParams): Step[] => [
  callStep("list", "List the market", { address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "createSeries", args: [params] }, "Deploys the option token and opens the market."),
];

export function createSeriesWithDirectMarketSteps(params: SeriesParams, owner?: Address): Step[] {
  let seriesId: Hex | undefined;
  let market: Address | undefined;
  return [
    {
      key: "list",
      label: "List the option series",
      hint: "Deploys the option token with the selected strike and expiry.",
      run: async (w, onSent) => {
        const receipt = await send(w, { address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "createSeries", args: [params] }, onSent);
        seriesId = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params] });
        return receipt;
      },
    },
    {
      key: "deploy-direct-book",
      label: "Create Optara Direct book",
      hint: "Deploys an in-house venue book for this option token.",
      run: async (w, onSent) => {
        if (!seriesId) seriesId = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params] });
        const terms = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "getSeries", args: [seriesId] });
        const quoteDecimals = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "settlementAssetDecimals", args: [params.settlementAsset] });
        const receipt = await deploy(w, directMarketDeployCall(terms.wrapper, params.settlementAsset, BigInt(quoteDecimals), owner ?? w.account.address), onSent);
        market = receipt.contractAddress as Address;
        return receipt;
      },
    },
    {
      key: "register-direct-book",
      label: "Attach order book",
      hint: "Registers the new book so Buy and Sell can route through Optara Direct.",
      run: async (w, onSent) => {
        if (!seriesId) seriesId = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params] });
        if (!market) throw new Error("The direct order book was not deployed.");
        return send(w, { address: ADDR.venues, abi: venueRegistryAbi, functionName: "registerMarket", args: [DIRECT_VENUE, market, seriesId, "0x"] }, onSent);
      },
    },
  ];
}

export function registerExistingDirectMarketSteps(series: Series, owner?: Address): Step[] {
  let market: Address | undefined;
  return [
    {
      key: "deploy-direct-book",
      label: "Create Optara Direct book",
      hint: "Deploys an in-house venue book for this option token.",
      run: async (w, onSent) => {
        const receipt = await deploy(w, directMarketDeployCall(series.wrapper, series.settlementAsset, BigInt(series.assetDecimals), owner ?? w.account.address), onSent);
        market = receipt.contractAddress as Address;
        return receipt;
      },
    },
    {
      key: "register-direct-book",
      label: "Attach order book",
      hint: "Registers the new book so Buy and Sell can route through Optara Direct.",
      run: (w, onSent) => {
        if (!market) throw new Error("The direct order book was not deployed.");
        return send(w, { address: ADDR.venues, abi: venueRegistryAbi, functionName: "registerMarket", args: [DIRECT_VENUE, market, series.id, "0x"] }, onSent);
      },
    },
  ];
}

function directMarketDeployCall(wrapper: Address, quote: Address, quoteDecimals: bigint, owner: Address) {
  return {
    abi: optaraDirectMarketAbi,
    bytecode: optaraDirectMarketBytecode,
    args: [wrapper, quote, 18n, quoteDecimals, 10_000n, 10n ** 16n, ADDR.directAdapter, owner],
  } as const;
}
