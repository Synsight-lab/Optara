/**
 * Surface publisher service. Environment:
 *   RPC_URL, CHAIN_ID, MANIFEST (network name or path)       required
 *   PUBLISHER_PRIVATE_KEY                                     this operator's signing key
 *   COSIGNER_URLS                                             other publishers' services, comma separated
 *   PRODUCTS                                                  JSON file: [{ symbol, underlying, settlementAsset, inputs, kNodes? }]
 *                                                             inputs: "deribit:ETH" | "synthetic:<atm iv>"
 *                                                             (default on a local manifest: ETH/USDC synthetic 0.6)
 *   SPOT_SOURCE = hermes | restamp                            /oracle-update spot blobs (restamp: local MockPyth)
 *   HERMES_URL, HERMES_API_KEY, HERMES_API_KEY_HEADER         for hermes
 *   INTERVAL_SECONDS (60; MON products: 30), PORT (8790), LOG_FILE
 */
import { readFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import { connect, HermesSource, RestampMockPythSource, optionSeriesRegistryAbi, type SpotSource } from "@optara/sdk";
import { loadManifest } from "@optara/sdk/node";
import { SeriesCatalog } from "@optara/sdk";
import { DeribitInputs, SyntheticInputs, skewSmile, type VolInputs } from "./inputs.ts";
import { Publisher, type ProductSpec, type PublishResult } from "./publisher.ts";
import { RemoteCosigner, startServer } from "./server.ts";

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`${k} is required`);
  return v;
};

function inputsFrom(spec: string): VolInputs {
  const [kind, arg] = spec.split(":");
  if (kind === "deribit") return new DeribitInputs(arg ?? "ETH");
  if (kind === "synthetic") return new SyntheticInputs(skewSmile(Number(arg ?? "0.6")));
  throw new Error(`unknown inputs ${spec}`);
}

async function main() {
  const manifest = loadManifest(env("MANIFEST"));
  const key = env("PUBLISHER_PRIVATE_KEY") as Hex;
  const { public: client } = await connect(env("RPC_URL"), Number(env("CHAIN_ID")));
  if (manifest.chainId !== Number(env("CHAIN_ID"))) throw new Error("manifest chain id differs from CHAIN_ID");

  const registry = manifest.proxies.OptionSeriesRegistry.proxy;
  let products: ProductSpec[];
  if (process.env.PRODUCTS) {
    const raw = JSON.parse(readFileSync(process.env.PRODUCTS, "utf8")) as any[];
    products = await Promise.all(
      raw.map(async (p) => ({
        symbol: p.symbol,
        underlying: p.underlying,
        settlementAsset: p.settlementAsset,
        productId: await client.readContract({ address: registry, abi: optionSeriesRegistryAbi, functionName: "computeProductId", args: [p.underlying, p.settlementAsset] }),
        inputs: inputsFrom(p.inputs),
        kNodes: p.kNodes,
      })),
    );
  } else {
    const e = manifest.extra as Record<string, any>;
    if (!e.ethUsdcProductId) throw new Error("PRODUCTS is required outside the local stack");
    products = [{ symbol: "ETH/USDC", underlying: e.weth, settlementAsset: e.usdc, productId: e.ethUsdcProductId, inputs: inputsFrom("synthetic:0.6") }];
  }

  const spotKind = process.env.SPOT_SOURCE ?? (manifest.chainId === 31337 ? "restamp" : "hermes");
  const spot: SpotSource =
    spotKind === "restamp"
      ? new RestampMockPythSource(client, (manifest.extra as any).pyth)
      : new HermesSource({ endpoint: env("HERMES_URL", "https://hermes.pyth.network"), apiKey: process.env.HERMES_API_KEY, apiKeyHeader: process.env.HERMES_API_KEY_HEADER });

  const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);
  const catalog = new SeriesCatalog(client, registry, BigInt(manifest.deployedAtBlock), BigInt(process.env.LOG_CHUNK ?? "100"));
  const publisher = new Publisher({
    client,
    manifest,
    products,
    signers: [privateKeyToAccount(key)],
    cosigners: (process.env.COSIGNER_URLS ?? "").split(",").filter(Boolean).map((u) => new RemoteCosigner(u)),
    catalog,
    spot,
    log,
  });

  const last = new Map<Hex, { at: string; result: PublishResult }>();
  const failingSince = new Map<Hex, number>();
  await startServer({ publisher, catalog, client, manifest, status: () => ({ ok: true, products: Object.fromEntries(last) }) }, Number(process.env.PORT ?? 8790));
  log(`publisher ${privateKeyToAccount(key).address} serving on :${process.env.PORT ?? 8790}`);

  const interval = Number(process.env.INTERVAL_SECONDS ?? 60) * 1000;
  for (;;) {
    for (const p of products) {
      try {
        const r = await publisher.publish(p);
        last.set(p.productId, { at: new Date().toISOString(), result: r });
        if (r.ok) {
          failingSince.delete(p.productId);
          log(`${p.symbol}: signed seq ${r.signed.report.surfaceSeq} (${r.signed.signers.length} signatures, confidence ${r.confidenceBps} bps)`);
        } else {
          if (!failingSince.has(p.productId)) failingSince.set(p.productId, Date.now());
          log(`${p.symbol}: no report (${r.reason}${r.detail ? `: ${r.detail}` : ""})`);
        }
      } catch (e) {
        if (!failingSince.has(p.productId)) failingSince.set(p.productId, Date.now());
        log(`${p.symbol}: error ${(e as Error).message}`);
      }
      // INDEXER_AND_KEEPERS.md §5.3: alert when no report could be produced for 2 minutes.
      const since = failingSince.get(p.productId);
      if (since !== undefined && Date.now() - since > 120_000) log(`ALERT ${p.symbol}: no report for ${Math.round((Date.now() - since) / 1000)} s`);
    }
    await new Promise((r) => setTimeout(r, interval));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
