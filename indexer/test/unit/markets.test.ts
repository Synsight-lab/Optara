import { describe, expect, it } from "vitest";
import { Store } from "../../src/db.ts";
import { applyEvent } from "../../src/reducers.ts";
import { validateKuruMarkets, type KuruMarket } from "../../src/api.ts";

const SERIES = ("0x" + "11".repeat(32)) as `0x${string}`;
const TOKEN = "0x00000000000000000000000000000000000000cc" as const;
const USDT = "0x00000000000000000000000000000000000000ee" as const;
const USDC = "0x00000000000000000000000000000000000000ef" as const;

describe("official market registry validation (KI-INV-08/09, DEPLOY-TEST-012)", () => {
  const store = new Store(":memory:");
  applyEvent(store, {
    id: "1", blockNumber: 1, blockHash: "0x", txHash: "0x", logIndex: 0, address: "0xcore", name: "SeriesCreated",
    args: { seriesId: SERIES, groupId: "0xg", optionToken: TOKEN, underlying: "0xmon", settlementAsset: USDT, optionType: 0,
      strikeWad: "1", capWad: "1", contractSizeWad: "1", expiry: "1", oracleConfigId: "0xc", quantityIncrement: "1" },
  });
  const ok: KuruMarket = { seriesId: SERIES, market: "0x00000000000000000000000000000000000000f1", base: TOKEN, quote: USDT, chainId: 143 };

  it("KUR-001/KUR-002: accepts base = option token and quote = settlement asset on the right chain", () => {
    expect(validateKuruMarkets(store, 143, [ok]).valid).toEqual([ok]);
  });
  it("rejects a wrong quote stablecoin (KUR-004)", () => {
    expect(validateKuruMarkets(store, 143, [{ ...ok, quote: USDC }]).rejected[0]?.reason).toBe("quote is not the series settlement asset");
  });
  it("rejects a wrong base token (KUR-003)", () => {
    expect(validateKuruMarkets(store, 143, [{ ...ok, base: USDC }]).rejected[0]?.reason).toBe("base is not the series option token");
  });
  it("rejects a wrong chain (KUR-005) and unknown series", () => {
    expect(validateKuruMarkets(store, 10143, [ok]).rejected[0]?.reason).toBe("wrong chain");
    expect(validateKuruMarkets(store, 143, [{ ...ok, seriesId: ("0x" + "99".repeat(32)) as `0x${string}` }]).rejected[0]?.reason).toBe("unknown series");
  });
});

describe("read API input validation", () => {
  it("rejects a malformed account instead of pattern-matching the event log", async () => {
    const { handle } = await import("../../src/api.ts");
    const store = new Store(":memory:");
    let status = 0;
    let body = "";
    const res = { writeHead: (s: number) => { status = s; }, end: (b: string) => { body = b; } };
    const deps = { store, client: {} as never, cfg: { chainId: 1, manifest: {} } as never, cursor: () => 0n };
    await handle(deps, { method: "GET", url: "/accounts/0x/events" } as never, res as never);
    expect(status).toBe(400);
    expect(JSON.parse(body)).toEqual({ error: "invalid account address" });
  });
});
