/** FE-004: every error in PROTOCOL_SPEC.md §13 (contract/src/libraries/Errors.sol) maps to a readable message. */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, encodeErrorResult } from "viem";
import { portfolioRiskManagerAbi } from "@optara/sdk";
import { ERROR_MESSAGES, friendlyError } from "./errors.ts";

const errorsSol = readFileSync(resolve(process.cwd(), "../contract/src/libraries/Errors.sol"), "utf8");
const declared = [...errorsSol.matchAll(/^error (\w+)\(/gm)].map((m) => m[1]!);

describe("FE-004 error messages", () => {
  it("Errors.sol declares the protocol's errors", () => {
    expect(declared.length).toBeGreaterThan(80);
  });

  it("every protocol error has a plain message", () => {
    const missing = declared.filter((e) => !ERROR_MESSAGES[e]);
    expect(missing).toEqual([]);
    for (const e of declared) {
      const m = ERROR_MESSAGES[e]!;
      expect(m.length).toBeGreaterThan(10);
      expect(m).not.toMatch(/0x|uint|bytes32|revert/i); // people words, not ABI words
    }
  });

  it("uses the FRONTEND.md §9 wording", () => {
    expect(ERROR_MESSAGES.NotHealthy).toBe("Not enough margin for this. Deposit more or reduce size.");
    expect(ERROR_MESSAGES.StaleSpot).toBe("Price data is out of date. Refresh and try again.");
    expect(ERROR_MESSAGES.RatioNotSet).toBe("Payouts aren't open yet.");
  });

  it("decodes a revert from the ABI, a revert from another module, and a wallet rejection", () => {
    const viaAbi = new ContractFunctionRevertedError({
      abi: portfolioRiskManagerAbi,
      functionName: "requireHealthy",
      data: encodeErrorResult({ abi: portfolioRiskManagerAbi, errorName: "NotHealthy", args: [1n, 2n] }),
    });
    expect(friendlyError(new BaseError("call failed", { cause: viaAbi }))).toMatchObject({
      name: "NotHealthy",
      message: ERROR_MESSAGES.NotHealthy,
    });

    // StaleSpot surfaces through OptionClearing from the spot oracle; decoded against every module's errors.
    const raw = encodeErrorResult({
      abi: [{ type: "error", name: "StaleSpot", inputs: [{ type: "bytes32" }, { type: "uint64" }] }],
      errorName: "StaleSpot",
      args: [`0x${"11".repeat(32)}`, 181n],
    });
    const foreign = new ContractFunctionRevertedError({ abi: [], functionName: "mintExternalLong", data: raw });
    expect(friendlyError(new BaseError("call failed", { cause: foreign })).message).toBe(ERROR_MESSAGES.StaleSpot);

    const rejected = new BaseError("x", { cause: new UserRejectedRequestError(new Error("denied")) });
    expect(friendlyError(rejected)).toMatchObject({ rejected: true, message: "You cancelled in your wallet." });
  });
});
