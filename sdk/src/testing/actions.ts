/** User actions on the local stack for service tests: accounts, deposits, mints, oracle pushes. */
import { erc20Abi, parseEventLogs, type TransactionReceipt, type Abi, type Address, type ContractFunctionArgs, type ContractFunctionName, type Hex, type LocalAccount } from "viem";
import { liveSpotOracleAbi, optionClearingAbi, portfolioRiskManagerAbi, subAccountsAbi, volSurfaceOracleAbi } from "../abi.ts";
import type { OracleUpdate } from "../oracleUpdate.ts";
import { decodeRevert } from "../errors.ts";
import { withGasBuffer } from "../chain.ts";
import { MockPythSource } from "../pyth.ts";
import { assembleReport, signReport, sortSignatures } from "../surface.ts";
import { ivFromTotalVariance, toWad, totalVarianceFromIv, yearsBetween } from "../math.ts";
import { stackAccount, stackProduct, stackProducts, type LocalStack } from "./index.ts";

/**
 * Sends a transaction (gas: estimate plus `withGasBuffer`) and waits for it; throws with the decoded revert reason.
 * With `result`, simulates first and returns the function's return value.
 */
export async function send<const abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable" | "payable">>(
  s: LocalStack,
  account: LocalAccount,
  call: { address: Address; abi: abi; functionName: fn; args: ContractFunctionArgs<abi, "nonpayable" | "payable", fn>; value?: bigint },
  opts: { result?: boolean } = {},
): Promise<{ hash: Hex; result: unknown; receipt: TransactionReceipt }> {
  // Simulate only for a return value: estimating gas already reverts with the reason.
  const result = opts.result ? (await s.test.simulateContract({ account, ...(call as any) })).result : undefined;
  const gas = withGasBuffer(await s.test.estimateContractGas({ account, ...(call as any) }));
  const hash = await s.test.writeContract({ account, chain: s.test.chain, ...(call as any), gas });
  const receipt = await s.test.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    const trace = (await s.test.request({ method: "debug_traceTransaction" as any, params: [hash, {}] as any })) as { returnValue?: string };
    const data = (trace.returnValue ? `0x${trace.returnValue.replace(/^0x/, "")}` : "0x") as Hex;
    const tx = await s.test.getTransaction({ hash });
    throw new Error(
      `${String(call.functionName)} reverted on chain at block ${receipt.blockNumber}: ${decodeRevert(data)} (gas ${receipt.gasUsed} of ${tx.gas})`,
    );
  }
  return { hash, result, receipt };
}

/** The provider fee `updateOracles`-style calls must carry for these spot blobs. */
export const spotFee = (s: LocalStack, u: OracleUpdate) =>
  s.test.readContract({ address: s.manifest.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "updateFee", args: [u.spotUpdates] });

/** Creates a USDC subaccount for stack account `user`; the id comes from the transaction's own event (race-free). */
export async function createAccount(s: LocalStack, user: number): Promise<bigint> {
  const p = stackProduct(s.manifest);
  return createAccountForAsset(s, user, p.usdc);
}

export async function createAccountForAsset(s: LocalStack, user: number, asset: Address): Promise<bigint> {
  const { receipt } = await send(s, stackAccount(user), { address: s.manifest.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "createSubAccount", args: [asset] });
  const [created] = parseEventLogs({ abi: subAccountsAbi, eventName: "SubAccountCreated", logs: receipt.logs });
  if (!created) throw new Error("no SubAccountCreated");
  return created.args.accountId;
}

/** Creates a USDC subaccount for stack account `user` and deposits `usdc` (6 decimals). Returns its id. */
export async function openAccount(s: LocalStack, user: number, usdc: bigint): Promise<bigint> {
  const a = stackAccount(user);
  const p = stackProduct(s.manifest);
  const id = await createAccount(s, user);
  if (usdc > 0n) {
    await send(s, a, { address: p.usdc, abi: erc20Abi, functionName: "approve", args: [s.manifest.proxies.OptionClearing.proxy, usdc] });
    await send(s, a, { address: s.manifest.proxies.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [id, usdc] });
  }
  return id;
}

/** Writes `qty` of a series from `accountId` (owned by stack account `user`) with oracle update `u`. */
export async function mint(s: LocalStack, user: number, accountId: bigint, seriesId: Hex, qty: bigint, u: OracleUpdate) {
  const a = stackAccount(user);
  return send(s, a, {
    address: s.manifest.proxies.OptionClearing.proxy,
    abi: optionClearingAbi,
    functionName: "mintExternalLong",
    args: [accountId, seriesId, qty, a.address, 2n ** 255n, u],
    value: await spotFee(s, u),
  });
}

/** `OptionClearing.updateOracles` from stack account `from`. */
export async function pushOracles(s: LocalStack, from: number, u: OracleUpdate) {
  return send(s, stackAccount(from), {
    address: s.manifest.proxies.OptionClearing.proxy,
    abi: optionClearingAbi,
    functionName: "updateOracles",
    args: [u],
    value: await spotFee(s, u),
  });
}

/**
 * A complete oracle update for the stack's ETH/USDC product: spot at `price` (MockPyth, stamped with the latest
 * block time) and, unless `surface` is false, a flat-`iv` surface over the listed expiries with the next sequence,
 * signed by the stack's two publishers, with every leaf. Like Pyth, the spot oracle only takes a price newer than
 * the stored one: a second update stamped in the same second is ignored, so advance time before a price move.
 */
export async function freshOracleUpdate(s: LocalStack, opts: { price: number; iv?: number; surface?: boolean }): Promise<OracleUpdate> {
  const p = stackProduct(s.manifest);
  return freshOracleUpdateForProduct(s, p, opts);
}

const productSpotPrice = (p: ReturnType<typeof stackProducts>[number], price?: number) => price ?? Number(p.spotWad) / 1e18;
const headerIv = (h: Awaited<ReturnType<LocalStack["test"]["readContract"]>>): number | undefined => {
  const header = h as { surfaceSeq: bigint; validAfter: bigint; tenorTimestamps: readonly bigint[]; atmTotalVarianceByTenor: readonly bigint[] };
  if (header.surfaceSeq === 0n) return undefined;
  const i = header.tenorTimestamps.findIndex((t) => t > header.validAfter);
  if (i < 0) return undefined;
  const tau = yearsBetween(header.validAfter, header.tenorTimestamps[i]!);
  if (tau <= 0) return undefined;
  return ivFromTotalVariance(Number(header.atmTotalVarianceByTenor[i]!) / 1e18, tau);
};

export async function freshOracleUpdateForProduct(
  s: LocalStack,
  p: ReturnType<typeof stackProducts>[number],
  opts: { price?: number; basePrice?: number; quotePrice?: number; iv?: number; surface?: boolean },
): Promise<OracleUpdate> {
  const now = (await s.test.getBlock()).timestamp;
  const fallback = Number(p.spotWad) / 1e18;
  const zeroFeed = `0x${"0".repeat(64)}`;
  const feedIds = p.pythQuoteFeedId && p.pythQuoteFeedId !== zeroFeed ? [p.pythFeedId, p.pythQuoteFeedId] : [p.pythFeedId];
  const spotUpdates = await new MockPythSource(
    (feedId) => {
      if (feedId === p.pythFeedId) return opts.basePrice ?? opts.price ?? fallback;
      return opts.quotePrice ?? 1;
    },
    async () => now,
  ).updates(feedIds);
  const u: OracleUpdate = { spotUpdates, spotProductIds: [p.productId], reports: [], reportSignatures: [], nodes: [] };
  if (opts.surface === false) return u;
  const surface = s.manifest.proxies.VolSurfaceOracle.proxy;
  const h = await s.test.readContract({ address: surface, abi: volSurfaceOracleAbi, functionName: "header", args: [p.productId] });
  const tenors = p.expiries.filter((t) => t > now);
  const kNodes = [-1.2, -0.6, -0.3, -0.1, 0, 0.1, 0.3, 0.6, 1.2].map(toWad);
  const iv = opts.iv ?? headerIv(h) ?? 0.6;
  const w = tenors.map((t) => toWad(totalVarianceFromIv(iv, yearsBetween(now, t))));
  const { report, grid } = assembleReport({
    chainId: BigInt(s.manifest.chainId),
    verifyingContract: surface,
    productId: p.productId,
    underlying: p.underlying,
    settlementAsset: p.settlementAsset,
    seq: h.surfaceSeq + 1n,
    validAfter: now,
    lifetime: 900n,
    tenors,
    kNodes,
    w: w.map((v) => kNodes.map(() => v)),
    atm: w,
    surfaceMinIvBps: 1000,
    surfaceMaxIvBps: 50_000,
    confidenceBps: 100,
    sourceCount: 3,
  });
  const signers = [stackAccount(2), stackAccount(3)];
  const signatures = sortSignatures(await Promise.all(signers.map(async (a) => ({ signer: a.address, signature: await signReport(report, a) }))));
  const nodes = [];
  for (let t = 0; t < tenors.length; t++) for (let j = 0; j < kNodes.length; j++) nodes.push(grid.nodeProof(t, j));
  return { ...u, reports: [report], reportSignatures: [signatures], nodes };
}

const mockBookAbi = [
  { type: "function", name: "setBid", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "setAsk", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
] as const;
const mintableAbi = [{ type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] }] as const;

/**
 * A market maker (stack account 0) quotes the mock Kuru books of the stack's series (all, or `indices`) `spreadBps`
 * around the protocol's mark (`priceOf`), `size` options each side: bids funded with USDC, asks with options it
 * writes straight into the book (each mint with a fresh spot update at `price`). Returns the maker's account id.
 */
export async function quoteBooks(s: LocalStack, opts: { price?: number; indices?: number[]; size?: bigint; spreadBps?: bigint } = {}): Promise<bigint> {
  const products = stackProducts(s.manifest);
  const px = s.manifest.proxies;
  const mm = stackAccount(0);
  const size = opts.size ?? 5n * 10n ** 18n;
  const spread = opts.spreadBps ?? 500n;
  const maxSeriesPerAccount = Number(
    await s.test.readContract({ address: px.SubAccounts.proxy, abi: subAccountsAbi, functionName: "maxSeriesPerAccount" }),
  );
  const chunkSize = Math.max(1, maxSeriesPerAccount);
  let firstAccount = 0n;
  for (const p of products) {
    const now = (await s.test.getBlock()).timestamp;
    const livePrice = productSpotPrice(p, products.length === 1 ? opts.price : undefined);
    const indices = (opts.indices ?? p.seriesIds.map((_, i) => i)).filter((i) => p.expiries[Math.floor(i / 8)]! > now);
    if (indices.length === 0) continue;
    await pushOracles(s, 4, await freshOracleUpdateForProduct(s, p, { price: livePrice, surface: false }));
    await send(s, mm, { address: p.settlementAsset as Address, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, 2n ** 256n - 1n] });
    for (let start = 0; start < indices.length; start += chunkSize) {
      const chunk = indices.slice(start, start + chunkSize);
      await send(s, mm, { address: p.settlementAsset as Address, abi: mintableAbi, functionName: "mint", args: [mm.address, 150_000_000_000_000n] });
      const account = await createAccountForAsset(s, 0, p.settlementAsset as Address);
      if (firstAccount === 0n) firstAccount = account;
      await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [account, 100_000_000_000_000n] });
      for (const i of chunk) {
        const id = p.seriesIds[i]! as Hex;
        const book = p.kuruBooks[i]! as Address;
        let mid: bigint;
        try {
          [mid] = await s.test.readContract({ address: px.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "priceOf", args: [id] });
        } catch {
          continue;
        }
        const price = (mid * 10_000n) / 10n ** 18n; // the mock books' price precision: 1e4 per whole option
        await send(s, mm, { address: p.settlementAsset as Address, abi: erc20Abi, functionName: "transfer", args: [book, 50_000_000_000n] });
        const u = await freshOracleUpdateForProduct(s, p, { price: livePrice, surface: false });
        await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "mintExternalLong", args: [account, id, size, book, 2n ** 255n, u], value: await spotFee(s, u) });
        const sizeUnits = (size * 10n ** 16n) / 10n ** 18n; // size precision 1e16 per whole option
        await send(s, mm, { address: book, abi: mockBookAbi, functionName: "setBid", args: [(price * (10_000n - spread)) / 10_000n || 1n, sizeUnits] });
        await send(s, mm, { address: book, abi: mockBookAbi, functionName: "setAsk", args: [(price * (10_000n + spread)) / 10_000n + 1n, sizeUnits] });
      }
    }
  }
  return firstAccount;
}
