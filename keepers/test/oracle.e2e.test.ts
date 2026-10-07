/** The spot updater / surface pusher (INDEXER_AND_KEEPERS.md §2). */
import { createServer, type Server } from "node:http";
import { afterAll, beforeAll, describe, expect, inject, it } from "vitest";
import { liveSpotOracleAbi, RestampMockPythSource, SeriesCatalog, toJson, volSurfaceOracleAbi, type OracleUpdate } from "@optara/sdk";
import { freshOracleUpdate, increaseTime, mint, openAccount, pushOracles, stackProduct, startLocalStack, walletFor, type LocalStack } from "@optara/sdk/testing";
import { OraclePusher } from "../src/oraclePusher.ts";

let s: LocalStack;
let server: Server;
let served: OracleUpdate | undefined;

beforeAll(async () => {
  const { statePath, manifestPath } = inject("stack");
  s = await startLocalStack(statePath, manifestPath);
  // A stand-in publisher serving whatever report the test sets.
  server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    res.setHeader("content-type", "application/json");
    if (!served) return res.writeHead(404).end("{}");
    if (url.pathname.endsWith("/latest")) return res.end(toJson({ report: served.reports[0], signatures: served.reportSignatures[0] }));
    if (url.pathname.endsWith("/nodes")) return res.end(toJson(served.nodes));
    res.writeHead(404).end("{}");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
});
afterAll(async () => {
  await new Promise((r) => server?.close(r));
  await s?.anvil.stop();
});

describe("oracle pusher", () => {
  it("pushes spot at maxSpotAge / 2 for products with open interest, and newer reports with their leaves", { timeout: 300_000 }, async () => {
    const p = stackProduct(s.manifest);
    const catalog = new SeriesCatalog(s.test, s.manifest.proxies.OptionSeriesRegistry.proxy, 0n, 1000n);
    const pusher = new OraclePusher(
      { client: s.test, wallet: walletFor(s, 4), log: () => {} },
      { manifest: s.manifest, products: [p.productId], spot: new RestampMockPythSource(s.test, p.pyth), catalog, publisherUrl: `http://127.0.0.1:${(server.address() as { port: number }).port}` },
    );
    const spotTime = async () =>
      (await s.test.readContract({ address: s.manifest.proxies.LiveSpotOracle.proxy, abi: liveSpotOracleAbi, functionName: "spotPrice", args: [p.productId] }))[1];

    // No open interest: nothing to keep fresh.
    expect((await pusher.tick()).spot).toEqual([]);

    await pushOracles(s, 4, await freshOracleUpdate(s, { price: 4000 }));
    const a = await openAccount(s, 5, 10_000n * 10n ** 6n);
    await mint(s, 5, a, p.seriesIds[4]!, 10n ** 18n, await freshOracleUpdate(s, { price: 4000, surface: false }));

    // Fresh spot: nothing to do.
    expect((await pusher.tick()).spot).toEqual([]);

    // Half of maxSpotAge (60 s) later: pushed.
    await increaseTime(s.anvil.rpcUrl, 31);
    const r = await pusher.tick();
    expect(r.spot).toEqual([p.productId]);
    expect(await spotTime()).toBe((await s.test.getBlock()).timestamp);

    // The publisher has a newer report: pushed with its leaves.
    served = await freshOracleUpdate(s, { price: 4000, iv: 0.62 });
    const seq = served.reports[0]!.surfaceSeq;
    const r2 = await pusher.tick();
    expect(r2.reports).toEqual([{ productId: p.productId, seq }]);
    const h = await s.test.readContract({ address: s.manifest.proxies.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "header", args: [p.productId] });
    expect(h.surfaceSeq).toBe(seq);
    const n = served.nodes[served.nodes.length - 1]!;
    const [proven] = await s.test.readContract({ address: s.manifest.proxies.VolSurfaceOracle.proxy, abi: volSurfaceOracleAbi, functionName: "nodeValue", args: [p.productId, n.tenorIndex, n.nodeIndex] });
    expect(proven).toBe(true);

    // Same report again: nothing new.
    expect((await pusher.tick()).reports).toEqual([]);
  });
});
