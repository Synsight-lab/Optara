/**
 * PUB-001: reports pass every on-chain check; the publisher refuses to sign on calendar/butterfly arbitrage or an
 * ATM move above the limit, and cosigners refuse grids that don't match the root or fail validation.
 * PUB-002: /oracle-update returns an OracleUpdate whose proofs verify on-chain for an account's positions.
 */
import type { Server } from "node:http";
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import {
  assembleReport,
  oracleUpdateFromJson,
  RestampMockPythSource,
  volSurfaceOracleAbi,
  subAccountsAbi,
  optionClearingAbi,
  toWad,
  type OracleUpdate,
} from "@optara/sdk";
import { startLocalStack, stackAccount, stackProduct, openAccount, mint, pushOracles, send, type LocalStack } from "@optara/sdk/testing";
import { SeriesCatalog } from "@optara/sdk";
import { SyntheticInputs, skewSmile } from "../src/inputs.ts";
import { Publisher, type ProductSpec, type Cosigner } from "../src/publisher.ts";
import { RemoteCosigner, startServer } from "../src/server.ts";

let s: LocalStack;
const servers: Server[] = [];
let urlA = "";
let urlB = "";
let pubA: Publisher;
let pubB: Publisher;

function spec(atm: number): ProductSpec {
  const p = stackProduct(s.manifest);
  return { symbol: "ETH/USDC", productId: p.productId, underlying: p.weth, settlementAsset: p.usdc, inputs: new SyntheticInputs(skewSmile(atm, -0.1, 0.1)) };
}

function makePublisher(signer: number, cosigners: Cosigner[], atm = 0.6) {
  const catalog = new SeriesCatalog(s.test, s.manifest.proxies.OptionSeriesRegistry.proxy, 0n, 1000n);
  const p = stackProduct(s.manifest);
  return {
    catalog,
    publisher: new Publisher({
      client: s.test,
      manifest: s.manifest,
      products: [spec(atm)],
      signers: [stackAccount(signer)],
      cosigners,
      catalog,
      spot: new RestampMockPythSource(s.test, p.pyth),
    }),
  };
}

async function serve(publisher: Publisher, catalog: SeriesCatalog) {
  const server = await startServer({ publisher, catalog, client: s.test, manifest: s.manifest, status: () => ({ ok: true }) }, 0);
  servers.push(server);
  return `http://127.0.0.1:${(server.address() as { port: number }).port}`;
}

const getJson = async (url: string) => {
  const res = await fetch(url);
  expect(res.status).toBe(200);
  return res.json();
};

beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
  const b = makePublisher(3, []); // publisher B (not independent) cosigns
  pubB = b.publisher;
  urlB = await serve(b.publisher, b.catalog);
  const a = makePublisher(2, [new RemoteCosigner(urlB)]); // publisher A (independent) leads
  pubA = a.publisher;
  urlA = await serve(a.publisher, a.catalog);
});

afterAll(async () => {
  for (const sv of servers) await new Promise((r) => sv.close(r));
  await s?.anvil.stop();
});

describe("PUB-001 reports pass every on-chain check; refusals", () => {
  it("a report signed by A and cosigned over HTTP by B is accepted with all its leaves", async () => {
    const r = await pubA.publish(spec(0.6));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const { report, grid, signatures } = r.signed;
    expect(signatures).toHaveLength(2);
    expect(report.confidenceBps).toBeLessThanOrEqual(1000);
    const nodes = [];
    for (let t = 0; t < grid.w.length; t++) for (let j = 0; j < report.kNodes.length; j++) nodes.push(grid.nodeProof(t, j));
    const spot = new RestampMockPythSource(s.test, stackProduct(s.manifest).pyth);
    const u: OracleUpdate = {
      spotUpdates: await spot.updates([stackProduct(s.manifest).pythFeedId]),
      spotProductIds: [report.productId],
      reports: [report],
      reportSignatures: [signatures],
      nodes,
    };
    await pushOracles(s, 4, u);
    const h = await s.test.readContract({ address: s.manifest.proxies.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "header", args: [report.productId] });
    expect(h.surfaceSeq).toBe(report.surfaceSeq);
    expect(h.lowConfidence).toBe(false);
    for (const n of [nodes[0]!, nodes[nodes.length - 1]!]) {
      const [proven, w] = await s.test.readContract({ address: s.manifest.proxies.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "nodeValue", args: [report.productId, n.tenorIndex, n.nodeIndex] });
      expect(proven).toBe(true);
      expect(w).toBe(n.totalVarianceWad);
    }
  });

  it("refuses an ATM move above maxIvMoveBps (60% → 90%)", async () => {
    const { publisher } = makePublisher(2, [new RemoteCosigner(urlB)], 0.9);
    const r = await publisher.publish(spec(0.9));
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.reason).toBe("violations");
    expect(r.violations!.map((v) => v.code)).toContain("IV_MOVE");
  });

  it("without a cosigner the quorum (2) is short and nothing is signed", async () => {
    const { publisher } = makePublisher(2, []);
    const r = await publisher.publish(spec(0.6));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("quorum");
  });

  it("a cosigner refuses a grid that doesn't match the root, and a rooted grid with calendar arbitrage", async () => {
    const b = await pubA.build(spec(0.6));
    expect(b.ok).toBe(true);
    if (!b.ok) return;
    const tampered = b.grid.w.map((row) => [...row]);
    tampered[0]![0] = tampered[0]![0]! + 1n;
    await expect(new RemoteCosigner(urlB).cosign(b.report, tampered)).rejects.toThrow(/surfaceRoot/);

    const arb = b.grid.w.map((row) => [...row]);
    arb[1]![0] = arb[0]![0]! - 10n ** 12n; // wing variance falls with tenor
    const { report } = assembleReport({
      chainId: b.report.chainId,
      verifyingContract: b.report.verifyingContract,
      productId: b.report.productId,
      underlying: b.report.underlying,
      settlementAsset: b.report.settlementAsset,
      seq: b.report.surfaceSeq,
      validAfter: b.report.validAfter,
      lifetime: b.report.expiresAt - b.report.validAfter,
      tenors: b.report.tenorTimestamps.filter((t) => t !== 0n),
      kNodes: b.report.kNodes,
      w: arb,
      atm: b.report.atmTotalVarianceByTenor.filter((x) => x !== 0n),
      surfaceMinIvBps: b.report.surfaceMinIvBps,
      surfaceMaxIvBps: b.report.surfaceMaxIvBps,
      confidenceBps: b.report.confidenceBps,
      sourceCount: b.report.sourceCount,
    });
    await expect(new RemoteCosigner(urlB).cosign(report, arb)).rejects.toThrow(/CALENDAR/);
  });
});

describe("PUB-002 /oracle-update", () => {
  it("returns an update whose report and proofs verify on-chain for an account's positions", async () => {
    const p = stackProduct(s.manifest);
    const series = p.seriesIds[4]!; // 4500 call, first expiry
    const user = 5;
    const account = await openAccount(s, user, 20_000n * 10n ** 6n);

    // The first trade: no positions yet, the series being traded is passed explicitly.
    const u0 = oracleUpdateFromJson(await getJson(`${urlA}/oracle-update?series=${series}`));
    expect(u0.spotProductIds).toEqual([p.productId]);
    await mint(s, user, account, series, 10n ** 18n, u0);

    // A new report the chain hasn't seen; the account's update carries it and the leaves its position needs.
    const r = await pubA.publish(spec(0.62));
    expect(r.ok).toBe(true);
    const u1 = oracleUpdateFromJson(await getJson(`${urlA}/oracle-update?account=${account}`));
    expect(u1.reports).toHaveLength(1);
    expect(u1.reports[0]!.surfaceSeq).toBe(r.ok ? r.signed.report.surfaceSeq : 0n);
    expect(u1.nodes.length).toBeGreaterThanOrEqual(4); // two tenors × two bracketing nodes, plus margin
    expect(u1.nodes.length).toBeLessThanOrEqual(2 * 4); // margin 1 on each side
    const a = stackAccount(user);
    await send(s, a, {
      address: s.manifest.proxies.OptionClearing.proxy,
      abi: optionClearingAbi,
      functionName: "withdrawCollateral",
      args: [account, 10n ** 6n, a.address, u1],
      value: 1n,
    });
    const positions = await s.test.readContract({ address: s.manifest.proxies.SubAccounts.proxy, abi: subAccountsAbi, functionName: "positionsOf", args: [account] });
    expect(positions).toHaveLength(1);

    // Everything is cached now: the next update carries spot only.
    const u2 = oracleUpdateFromJson(await getJson(`${urlA}/oracle-update?account=${account}`));
    expect(u2.reports).toHaveLength(0);
    expect(u2.nodes).toHaveLength(0);
    expect(u2.spotUpdates.length).toBeGreaterThan(0);
  });

  it("serves the latest report and per-series nodes", async () => {
    const p = stackProduct(s.manifest);
    const latest = (await getJson(`${urlA}/surface/${p.productId}/latest`)) as { report: { surfaceSeq: string }; signatures: string[] };
    expect(latest.signatures).toHaveLength(2);
    const nodes = (await getJson(`${urlA}/surface/${p.productId}/${latest.report.surfaceSeq}/nodes?series=${p.seriesIds[0]},${p.seriesIds[9]}`)) as unknown[];
    expect(nodes.length).toBeGreaterThan(0);
    const res = await fetch(`${urlA}/surface/${p.productId}/999/nodes`);
    expect(res.status).toBe(404);
    expect(toWad(1)).toBe(10n ** 18n);
  });
});
