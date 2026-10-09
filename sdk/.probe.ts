import { createPublicClient, http } from "viem";
import { buildSettlementProof, settlementWindowAbi, chainFor, SeriesCatalog } from "./src/index.ts";
import { loadManifest } from "./src/node.ts";
const m = loadManifest("local");
const c = createPublicClient({ chain: chainFor(m.chainId, "http://127.0.0.1:8545"), transport: http("http://127.0.0.1:8545") });
const cat = new SeriesCatalog(c as any, m.proxies.OptionSeriesRegistry.proxy, BigInt(m.deployedAtBlock), 10_000n);
await cat.sync();
const now = (await c.getBlock()).timestamp;
const S = ["ACTIVE","EXPIRED","ORACLE_STALLED","FINALIZED","ALL_SETTLED","REDEEMABLE"];
for (const g of cat.groups().filter((g) => g.expiry <= now)) {
  const st = S[Number(await c.readContract({ address: m.proxies.SettlementWindow.proxy, abi: settlementWindowAbi, functionName: "groupState", args: [g.groupId] }))];
  const p = st === "EXPIRED" ? await buildSettlementProof(c as any, m.proxies.SettlementOracle.proxy, g.settlementOracleConfigId, g.expiry) : undefined;
  console.log(g.groupId.slice(0, 10), st, p ? (p.error ?? `provable at ${Number(p.priceWad) / 1e18}`) : "");
}
