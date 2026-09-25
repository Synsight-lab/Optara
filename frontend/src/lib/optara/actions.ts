import type { Address, Hex } from "viem";
import { optaraCoreAbi, erc20Abi } from "./abi.ts";
import type { Manifest } from "../../config/networks.ts";

/**
 * Transaction builders with the names planned for @optara/sdk. They only construct calldata for the user's own
 * wallet to sign; recipients are always explicit and approvals are exact amounts (SECURITY.md sections 66-67).
 */

export const CloseSource = { EXTERNAL: 0, LOCKED: 1 } as const;

const core = (m: Manifest) => ({ address: m.contracts.OptaraCore, abi: optaraCoreAbi });

export const buildApprove = (token: Address, spender: Address, amount: bigint) =>
  ({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount] }) as const;

export const buildDeposit = (m: Manifest, asset: Address, amount: bigint) =>
  ({ ...core(m), functionName: "deposit", args: [asset, amount] }) as const;

export const buildWithdraw = (m: Manifest, asset: Address, amount: bigint, recipient: Address) =>
  ({ ...core(m), functionName: "withdraw", args: [asset, amount, recipient] }) as const;

export const buildWrite = (m: Manifest, seriesId: Hex, quantity: bigint, recipient: Address) =>
  ({ ...core(m), functionName: "write", args: [seriesId, quantity, recipient] }) as const;

export const buildCloseShort = (m: Manifest, seriesId: Hex, quantity: bigint, source: 0 | 1) =>
  ({ ...core(m), functionName: "closeShort", args: [seriesId, quantity, source] }) as const;

export const buildCancelUnfinalizedShort = (m: Manifest, seriesId: Hex, quantity: bigint, source: 0 | 1) =>
  ({ ...core(m), functionName: "cancelUnfinalizedShort", args: [seriesId, quantity, source] }) as const;

export const buildLockLong = (m: Manifest, seriesId: Hex, quantity: bigint) =>
  ({ ...core(m), functionName: "lockLong", args: [seriesId, quantity] }) as const;

export const buildUnlockLong = (m: Manifest, seriesId: Hex, quantity: bigint, recipient: Address) =>
  ({ ...core(m), functionName: "unlockLong", args: [seriesId, quantity, recipient] }) as const;

export const buildRedeem = (m: Manifest, seriesId: Hex, quantity: bigint, recipient: Address) =>
  ({ ...core(m), functionName: "redeem", args: [seriesId, quantity, recipient] }) as const;

export const buildSyncRiskGroup = (m: Manifest, account: Address, groupId: Hex) =>
  ({ ...core(m), functionName: "syncRiskGroup", args: [account, groupId] }) as const;

export const buildSyncAccount = (m: Manifest, account: Address, asset: Address) =>
  ({ ...core(m), functionName: "syncAccount", args: [account, asset] }) as const;

export const buildFinalizeRiskGroup = (m: Manifest, groupId: Hex, oracleData: Hex) =>
  ({ ...core(m), functionName: "finalizeRiskGroup", args: [groupId, oracleData] }) as const;

export const buildCheckAndRestrict = (m: Manifest, account: Address, asset: Address) =>
  ({ ...core(m), functionName: "checkAndRestrict", args: [account, asset] }) as const;

export const buildRecapitalize = (m: Manifest, asset: Address, amount: bigint) =>
  ({ ...core(m), functionName: "recapitalize", args: [asset, amount] }) as const;
