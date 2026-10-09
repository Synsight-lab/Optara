/** P&L arithmetic: per option and totals per settlement asset. */
import { describe, expect, it } from "vitest";
import { averageCost, pnlOf, pnlPct, totals, unrealizedOf, type SeriesPnl } from "./pnl.ts";
import type { Series } from "./types.ts";

const series = (assetSymbol: string) => ({ assetSymbol }) as Series;
const row = (p: Partial<SeriesPnl> & Pick<SeriesPnl, "paid" | "received" | "value">, asset = "USDC"): SeriesPnl => ({
  series: series(asset),
  walletQty: 0,
  realized: 0,
  costHeld: 0,
  accountQty: 0,
  status: "open",
  approximate: false,
  wrote: false,
  history: [],
  ...p,
});

describe("pnl", () => {
  it("buyer: value plus cash in minus cash out", () => {
    // Alice's MON call: paid 103, holds options worth 89.6 now
    const r = row({ paid: 103, received: 0, value: 89.6 });
    expect(pnlOf(r)).toBeCloseTo(-13.4);
    expect(pnlPct(r)).toBeCloseTo(-0.1301, 3);
  });

  it("writer: premium received, fee paid, what is owed counts against", () => {
    const r = row({ paid: 0.28, received: 50, value: -30 });
    expect(pnlOf(r)).toBeCloseTo(19.72);
  });

  it("totals per asset, never mixing USDC and USDT", () => {
    const t = totals([row({ paid: 100, received: 0, value: 130 }), row({ paid: 50, received: 0, value: 20 }), row({ paid: 10, received: 0, value: 0 }, "USDT")]);
    expect(t.get("USDC")).toMatchObject({ paid: 150, value: 150, pnl: 0, winners: 1, losers: 1 });
    expect(t.get("USDT")?.pnl).toBe(-10);
  });

  it("buy, buy, sell: the sale realizes against the average cost (Alice on the devnet)", () => {
    const a = averageCost([
      { kind: "buy", qty: 38346.1538, cash: 103 },
      { kind: "buy", qty: 19173.0769, cash: 51.5 },
      { kind: "sell", qty: 19173, cash: 42.054058 },
    ]);
    expect(a.realized).toBeCloseTo(42.054058 - 51.4998, 2); // ≈ −9.45
    expect(a.costHeld).toBeCloseTo(103.0002, 2);
    expect(a.qtyHeld).toBeCloseTo(38346.2307, 3);
    expect(a.unknownQty).toBe(0);
    const r = { paid: 154.5, received: 42.054058, value: 90.85, realized: a.realized };
    expect(pnlOf(r)).toBeCloseTo(-21.5959, 3);
    expect(unrealizedOf(r)).toBeCloseTo(90.85 - 103.0002, 2); // ≈ −12.15
  });

  it("selling everything leaves no cost and no unrealized part", () => {
    const a = averageCost([{ kind: "buy", qty: 10, cash: 50 }, { kind: "sell", qty: 10, cash: 65 }]);
    expect(a).toEqual({ realized: 15, costHeld: 0, qtyHeld: 0, unknownQty: 0 });
    expect(unrealizedOf({ paid: 50, received: 65, value: 0, realized: a.realized })).toBeCloseTo(0);
  });

  it("written and sold tokens: proceeds realize against the writing fee", () => {
    const a = averageCost([{ kind: "mint", qty: 1, cash: 0.1 }, { kind: "sell", qty: 1, cash: 6.65 }]);
    expect(a.realized).toBeCloseTo(6.55);
    expect(a.costHeld).toBe(0);
  });

  it("marks sells beyond known cost basis instead of realizing the whole sale against one small lot", () => {
    const a = averageCost([{ kind: "buy", qty: 1, cash: 2 }, { kind: "sell", qty: 10, cash: 50 }]);
    expect(a.realized).toBeCloseTo(5 - 2);
    expect(a.unknownQty).toBeCloseTo(9);
  });
});
