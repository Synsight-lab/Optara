/**
 * KPR-002: the liquidation bot starts auctions and takes profitable slices; it restarts safely (stateless: a new
 * instance picks the running auction up from the chain).
 */
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import { erc20Abi, maxUint256 } from "viem";
import {
  LedgerLogDirectory,
  MockPythSource,
  liquidationModuleAbi,
  optionClearingAbi,
  portfolioRiskManagerAbi,
  subAccountsAbi,
} from "@optara/sdk";
import {
  freshOracleUpdate,
  increaseTime,
  latestTimestamp,
  openAccount,
  pushOracles,
  send,
  spotFee,
  stackAccount,
  stackProduct,
  startLocalStack,
  walletFor,
  type LocalStack,
} from "@optara/sdk/testing";
import { LiquidationBot } from "../src/liquidationBot.ts";
import { SpotOnlyFeed } from "../src/oracleFeed.ts";

let s: LocalStack;
beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
});
afterAll(() => s?.anvil.stop());

const USDC = 10n ** 6n;

describe("KPR-002 liquidation bot", () => {
  it("starts the auction, waits for a profitable bonus, and a restarted instance slices it down", { timeout: 600_000 }, async () => {
    const p = stackProduct(s.manifest);
    const series = p.seriesIds[4]!; // 4500 call, first expiry
    const m = s.manifest;
    const pxy = m.proxies;
    let price = 4000;
    await pushOracles(s, 4, await freshOracleUpdate(s, { price }));

    // The victim writes 2 calls with just enough cash for IM.
    const victimOwner = 6;
    const victim = await openAccount(s, victimOwner, 0n);
    const [, eqAfter, imAfter] = await s.test.readContract({ address: pxy.OptionClearing.proxy, abi: optionClearingAbi, functionName: "previewMint", args: [victim, series, 2n * 10n ** 18n] });
    const need = (imAfter - eqAfter) / 10n ** 12n + USDC; // equity after is negative with no cash
    const owner = stackAccount(victimOwner);
    await send(s, owner, { address: p.usdc, abi: erc20Abi, functionName: "approve", args: [pxy.OptionClearing.proxy, maxUint256] });
    await send(s, owner, { address: pxy.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [victim, need] });
    const u = await freshOracleUpdate(s, { price, surface: false });
    await send(s, owner, { address: pxy.OptionClearing.proxy, abi: optionClearingAbi, functionName: "mintExternalLong", args: [victim, series, 2n * 10n ** 18n, owner.address, maxUint256, u], value: await spotFee(s, u) });

    // The bot's own account (user 7), well funded.
    const botKey = 7;
    const liquidator = await openAccount(s, botKey, 60_000n * USDC);

    // A 50% rally: the victim falls below MM. (A price is only taken when newer than the stored one, as on Pyth,
    // so move to the next second first.)
    await increaseTime(s.anvil.rpcUrl, 2);
    price = 6000;
    await pushOracles(s, 4, await freshOracleUpdate(s, { price }));
    const before = await s.test.readContract({ address: pxy.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "riskOf", args: [victim] });
    expect(before.equity).toBeLessThan(BigInt(before.maintenanceMargin));

    const feed = new SpotOnlyFeed(s.test, m, new MockPythSource(() => price, () => latestTimestamp(s.anvil.rpcUrl)));
    const makeBot = () =>
      new LiquidationBot(
        { client: s.test, wallet: walletFor(s, botKey), log: () => {} },
        { manifest: m, directory: new LedgerLogDirectory(s.test, pxy.SubAccounts.proxy, 0n, 1000n), liquidatorAccountId: liquidator, feed, minProfitNative: 5n * USDC },
      );

    // First instance: starts the auction; the bonus starts at 0, so no slice pays yet.
    const r1 = await makeBot().tick();
    expect(r1.started).toEqual([{ accountId: victim, underlying: p.weth }]);
    expect(r1.slices).toEqual([]);
    expect(await s.test.readContract({ address: pxy.LiquidationModule.proxy, abi: liquidationModuleAbi, functionName: "auctionStart", args: [victim, p.weth] })).not.toBe(0n);

    // Time passes (the bonus grows); a fresh surface keeps the account measurable.
    await increaseTime(s.anvil.rpcUrl, 900);
    await pushOracles(s, 4, await freshOracleUpdate(s, { price }));

    // A restarted instance continues from the chain: slices until the account is back at its target.
    const r2 = await makeBot().tick();
    expect(r2.started).toEqual([]);
    expect(r2.slices.length).toBeGreaterThan(0);
    expect(r2.slices.every((x) => x.discount > 0n)).toBe(true);
    expect(r2.ended).toEqual([{ accountId: victim, underlying: p.weth }]);
    expect(await s.test.readContract({ address: pxy.LiquidationModule.proxy, abi: liquidationModuleAbi, functionName: "auctionStart", args: [victim, p.weth] })).toBe(0n);

    const after = await s.test.readContract({ address: pxy.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "riskOf", args: [victim] });
    expect(after.equity - BigInt(after.maintenanceMargin)).toBeGreaterThan(before.equity - BigInt(before.maintenanceMargin));
    expect(await s.test.readContract({ address: pxy.SubAccounts.proxy, abi: subAccountsAbi, functionName: "balanceOf", args: [liquidator, series] })).toBeLessThan(0n); // took over shorts

    // Nothing left to do.
    const r3 = await makeBot().tick();
    expect([r3.started, r3.slices]).toEqual([[], []]);
  });
});
