/** User actions on the local stack for service tests: accounts, deposits, mints, oracle pushes. */
import { erc20Abi, parseEventLogs, type TransactionReceipt, type Abi, type Address, type ContractFunctionArgs, type ContractFunctionName, type Hex, type LocalAccount } from "viem";
import { liveSpotOracleAbi, optionClearingAbi, optionSeriesRegistryAbi, portfolioRiskManagerAbi, subAccountsAbi, volSurfaceOracleAbi } from "../abi.ts";
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

function makerSizeForProduct(p: ReturnType<typeof stackProducts>[number], override?: bigint): bigint {
  if (override !== undefined) return override;
  const symbol = p.underlyingSymbol.toUpperCase();
  if (symbol === "MON" || symbol === "WMON") return 1_000_000n * 10n ** 18n;
  if (symbol === "BTC" || symbol === "WBTC") return 20n * 10n ** 18n;
  return 200n * 10n ** 18n;
}

/**
 * A market maker (stack account 0) quotes the mock Kuru books of the stack's series (all, or `indices`) `spreadBps`
 * around the protocol's mark (`priceOf`), `size` options each side: bids funded with USDC, asks with options it
 * writes straight into the book (each mint with a fresh spot update at `price`). Returns the maker's account id.
 */
export async function quoteBooks(
  s: LocalStack,
  opts: { price?: number; indices?: number[]; size?: bigint; spreadBps?: bigint; includeKuru?: boolean } = {},
): Promise<bigint> {
  const products = stackProducts(s.manifest);
  const px = s.manifest.proxies;
  const mm = stackAccount(0);
  const spread = opts.spreadBps ?? 500n;
  const maxSeriesPerAccount = Number(
    await s.test.readContract({ address: px.SubAccounts.proxy, abi: subAccountsAbi, functionName: "maxSeriesPerAccount" }),
  );
  const chunkSize = Math.max(1, maxSeriesPerAccount);
  let firstAccount = 0n;
  for (const p of products) {
    const now = (await s.test.getBlock()).timestamp;
    const livePrice = productSpotPrice(p, products.length === 1 ? opts.price : undefined);
    const size = makerSizeForProduct(p, opts.size);
    const indices = (opts.indices ?? p.seriesIds.map((_, i) => i)).filter((i) => p.expiries[Math.floor(i / 8)]! > now + MIN_SEED_TIME_REMAINING);
    if (indices.length === 0) continue;
    // a fresh surface too: on a fork with real Kuru this runs after listing every Kuru market, which takes minutes
    await pushOracles(s, 4, await freshOracleUpdateForProduct(s, p, { price: livePrice }));
    await send(s, mm, { address: p.settlementAsset as Address, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, 2n ** 256n - 1n] });
    for (let start = 0; start < indices.length; start += chunkSize) {
      const chunk = indices.slice(start, start + chunkSize);
      await send(s, mm, { address: p.settlementAsset as Address, abi: mintableAbi, functionName: "mint", args: [mm.address, 150_000_000_000_000n] });
      const account = await createAccountForAsset(s, 0, p.settlementAsset as Address);
      if (firstAccount === 0n) firstAccount = account;
      await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [account, 100_000_000_000_000n] });
      for (const i of chunk) {
        if (p.expiries[Math.floor(i / 8)]! <= (await s.test.getBlock()).timestamp + MIN_SEED_TIME_REMAINING) continue;
        const id = p.seriesIds[i]! as Hex;
        let mid: bigint;
        try {
          [mid] = await s.test.readContract({ address: px.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "priceOf", args: [id] });
        } catch {
          continue;
        }
        const price = (mid * 10_000n) / 10n ** 18n; // the mock books' price precision: 1e4 per whole option
        // With real Kuru (a fork) the Kuru books aren't mocks and are quoted by quoteRealKuru; their slots here are zero.
        const books = [
          ...(opts.includeKuru === false ? [] : [p.kuruBooks[i]]),
          ...(p.optaraDirectBooks?.[i] ? [p.optaraDirectBooks[i]] : []),
        ].filter((b) => b && !/^0x0{40}$/i.test(b)) as Address[];
        for (const book of books) {
          await send(s, mm, { address: p.settlementAsset as Address, abi: erc20Abi, functionName: "transfer", args: [book, 50_000_000_000n] });
          const u = await freshOracleUpdateForProduct(s, p, { price: livePrice, surface: false });
          try {
            await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "mintExternalLong", args: [account, id, size, book, 2n ** 255n, u], value: await spotFee(s, u) });
          } catch {
            continue;
          }
          const sizeUnits = (size * 10n ** 16n) / 10n ** 18n; // size precision 1e16 per whole option
          await send(s, mm, { address: book, abi: mockBookAbi, functionName: "setBid", args: [(price * (10_000n - spread)) / 10_000n || 1n, sizeUnits] });
          await send(s, mm, { address: book, abi: mockBookAbi, functionName: "setAsk", args: [(price * (10_000n + spread)) / 10_000n + 1n, sizeUnits] });
        }
      }
    }
  }
  return firstAccount;
}

// ------------------------------------------------------------------ real Kuru on a mainnet fork

/** Kuru's Router on Monad mainnet (deployments/config/monad-mainnet.json; verified by test/fork/KuruAdapter.fork.t.sol). */
export const KURU_MAINNET_ROUTER: Address = "0xd651346d7c789536ebf06dc72aE3C8502cd695CC";

const kuruRouterAbi = [
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "marginAccountAddress", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "deployProxy",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_type", type: "uint8" },
      { name: "_baseAssetAddress", type: "address" },
      { name: "_quoteAssetAddress", type: "address" },
      { name: "_sizePrecision", type: "uint96" },
      { name: "_pricePrecision", type: "uint32" },
      { name: "_tickSize", type: "uint32" },
      { name: "_minSize", type: "uint96" },
      { name: "_maxSize", type: "uint96" },
      { name: "_takerFeeBps", type: "uint256" },
      { name: "_makerFeeBps", type: "uint256" },
      { name: "_kuruAmmSpread", type: "uint96" },
    ],
    outputs: [{ name: "proxy", type: "address" }],
  },
] as const;
const kuruBookAbi = [
  { type: "function", name: "addBuyOrder", stateMutability: "nonpayable", inputs: [{ type: "uint32" }, { type: "uint96" }, { type: "bool" }], outputs: [] },
  { type: "function", name: "addSellOrder", stateMutability: "nonpayable", inputs: [{ type: "uint32" }, { type: "uint96" }, { type: "bool" }], outputs: [] },
] as const;
const kuruMarginAbi = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }], outputs: [] },
] as const;
const venueRegistryWriteAbi = [
  { type: "function", name: "registerMarket", stateMutability: "nonpayable", inputs: [{ type: "bytes32" }, { type: "address" }, { type: "bytes32" }, { type: "bytes" }], outputs: [] },
] as const;
const venueIdAbi = [{ type: "function", name: "VENUE_ID", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] }] as const;

const wrapperOf = async (s: LocalStack, seriesId: Hex) =>
  (await s.test.readContract({ address: s.manifest.proxies.OptionSeriesRegistry.proxy as Address, abi: optionSeriesRegistryAbi, functionName: "getSeries", args: [seriesId] })).wrapper as Address;

export interface RealKuruMarket {
  seriesId: Hex;
  market: Address;
  /** Price units per 1 settlement-asset unit of price (Kuru's uint32 price = price × pricePrecision). */
  pricePrecision: bigint;
  /** Size units per whole option (Kuru's uint96 size = options × sizePrecision). */
  sizePrecision: bigint;
}

/** Size: 0.01 option steps, matching the ledger's minimum position. */
const KURU_SIZE_PRECISION = 10n ** 16n;
const MIN_SEED_TIME_REMAINING = 15n * 60n;
/**
 * Price steps per product: Kuru prices are uint32, so precision must fit the dearest option (in-the-money BTC calls
 * reach ~$20k) while resolving the cheapest (MON options are fractions of a cent).
 */
const kuruPricePrecision = (spot: number) => (spot < 10 ? 1_000_000n : 10_000n);

/**
 * Lists every live series on REAL Kuru (a mainnet fork): impersonates Kuru's router owner to deploy one genuine
 * order book per option token (market deployment is owner-gated), then registers it with Optara's VenueRegistry
 * (account 1 holds VENUE_ADMIN locally).
 */
export async function listOnRealKuru(s: LocalStack, router: Address = KURU_MAINNET_ROUTER): Promise<RealKuruMarket[]> {
  const t = s.test;
  const owner = await t.readContract({ address: router, abi: kuruRouterAbi, functionName: "owner" });
  await t.impersonateAccount({ address: owner });
  await t.setBalance({ address: owner, value: 10n ** 21n });
  const kuruVenue = await t.readContract({ address: s.manifest.kuruAdapter as Address, abi: venueIdAbi, functionName: "VENUE_ID" });
  const now = (await t.getBlock()).timestamp;
  const out: RealKuruMarket[] = [];
  try {
    for (const p of stackProducts(s.manifest)) {
      const pricePrecision = kuruPricePrecision(productSpotPrice(p));
      for (let i = 0; i < p.seriesIds.length; i++) {
        if (p.expiries[Math.floor(i / 8)]! <= now + MIN_SEED_TIME_REMAINING) continue;
        const seriesId = p.seriesIds[i]! as Hex;
        const wrapper = await wrapperOf(s, seriesId);
        const args = [0, wrapper, p.settlementAsset as Address, KURU_SIZE_PRECISION, Number(pricePrecision), 1, 10n ** 14n, 10n ** 27n, 30n, 10n, 100n] as const;
        const { result: market } = await t.simulateContract({ account: owner, address: router, abi: kuruRouterAbi, functionName: "deployProxy", args });
        const hash = await t.writeContract({ account: owner, chain: t.chain, address: router, abi: kuruRouterAbi, functionName: "deployProxy", args });
        await t.waitForTransactionReceipt({ hash });
        if (!(await t.getCode({ address: market }))) throw new Error(`Kuru did not deploy a market for ${seriesId}`);
        await send(s, stackAccount(1), { address: s.manifest.proxies.VenueRegistry.proxy as Address, abi: venueRegistryWriteAbi, functionName: "registerMarket", args: [kuruVenue, market, seriesId, "0x"] });
        out.push({ seriesId, market, pricePrecision, sizePrecision: KURU_SIZE_PRECISION });
      }
    }
  } finally {
    await t.stopImpersonatingAccount({ address: owner });
  }
  return out;
}

/**
 * Market making on real Kuru: account 0 writes options into its wallet, deposits them and the quote token into Kuru's
 * MarginAccount, and rests one ask and one bid per book `spreadBps` around Optara's fair value (resting orders on
 * Kuru are funded from the MarginAccount, unlike the mocks, which hold inventory themselves).
 */
export async function quoteRealKuru(s: LocalStack, markets: RealKuruMarket[], opts: { router?: Address; size?: bigint; spreadBps?: bigint } = {}): Promise<number> {
  const t = s.test;
  const px = s.manifest.proxies;
  const mm = stackAccount(0);
  const spread = opts.spreadBps ?? 500n;
  const margin = await t.readContract({ address: opts.router ?? KURU_MAINNET_ROUTER, abi: kuruRouterAbi, functionName: "marginAccountAddress" });
  const bySeries = new Map(markets.map((m) => [m.seriesId.toLowerCase(), m]));
  const maxSeriesPerAccount = Number(await t.readContract({ address: px.SubAccounts.proxy, abi: subAccountsAbi, functionName: "maxSeriesPerAccount" }));
  let quoted = 0;
  for (const p of stackProducts(s.manifest)) {
    const now = (await t.getBlock()).timestamp;
    const indices = p.seriesIds
      .map((id, i) => [id, i] as const)
      .filter(([id, i]) => bySeries.has(id.toLowerCase()) && p.expiries[Math.floor(i / 8)]! > now + MIN_SEED_TIME_REMAINING)
      .map(([, i]) => i);
    if (indices.length === 0) continue;
    const price = productSpotPrice(p);
    const size = makerSizeForProduct(p, opts.size);
    const asset = p.settlementAsset as Address;
    const decimals = await t.readContract({ address: asset, abi: erc20Abi, functionName: "decimals" });
    await send(s, mm, { address: asset, abi: erc20Abi, functionName: "approve", args: [px.OptionClearing.proxy, 2n ** 256n - 1n] });
    await send(s, mm, { address: asset, abi: erc20Abi, functionName: "approve", args: [margin, 2n ** 256n - 1n] });
    for (let start = 0; start < indices.length; start += Math.max(1, maxSeriesPerAccount)) {
      const chunk = indices.slice(start, start + Math.max(1, maxSeriesPerAccount));
      // fresh spot AND volatility surface: listing every market first can outlast the deploy-time surface
      await pushOracles(s, 4, await freshOracleUpdateForProduct(s, p, { price }));
      await send(s, mm, { address: asset, abi: mintableAbi, functionName: "mint", args: [mm.address, 150_000_000_000_000n] });
      const account = await createAccountForAsset(s, 0, asset);
      await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "depositCollateral", args: [account, 100_000_000_000_000n] });
      for (const i of chunk) {
        if (p.expiries[Math.floor(i / 8)]! <= (await t.getBlock()).timestamp + MIN_SEED_TIME_REMAINING) continue;
        const id = p.seriesIds[i]! as Hex;
        const m = bySeries.get(id.toLowerCase())!;
        let mid: bigint;
        try {
          [mid] = await t.readContract({ address: px.PortfolioRiskManager.proxy, abi: portfolioRiskManagerAbi, functionName: "priceOf", args: [id] });
        } catch {
          continue;
        }
        const units = (mid * m.pricePrecision) / 10n ** 18n;
        const ask = (units * (10_000n + spread)) / 10_000n + 1n;
        const bid = (units * (10_000n - spread)) / 10_000n;
        const sizeUnits = (size * m.sizePrecision) / 10n ** 18n;
        const wrapper = await wrapperOf(s, id);
        // write the ask inventory into the maker's wallet, then fund both sides in Kuru's MarginAccount
        const u = await freshOracleUpdateForProduct(s, p, { price, surface: false });
        await send(s, mm, { address: px.OptionClearing.proxy, abi: optionClearingAbi, functionName: "mintExternalLong", args: [account, id, size, mm.address, 2n ** 255n, u], value: await spotFee(s, u) });
        await send(s, mm, { address: wrapper, abi: erc20Abi, functionName: "approve", args: [margin, 2n ** 256n - 1n] });
        await send(s, mm, { address: margin, abi: kuruMarginAbi, functionName: "deposit", args: [mm.address, wrapper, size] });
        await send(s, mm, { address: m.market, abi: kuruBookAbi, functionName: "addSellOrder", args: [Number(ask), sizeUnits, false] });
        if (bid > 0n) {
          const quoteNeeded = (bid * size * 10n ** BigInt(decimals)) / m.pricePrecision / 10n ** 18n + 1n;
          await send(s, mm, { address: margin, abi: kuruMarginAbi, functionName: "deposit", args: [mm.address, asset, quoteNeeded] });
          await send(s, mm, { address: m.market, abi: kuruBookAbi, functionName: "addBuyOrder", args: [Number(bid), sizeUnits, false] });
        }
        quoted++;
      }
    }
  }
  return quoted;
}
