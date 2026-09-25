import { describe, expect, it } from "vitest";
import { Store } from "../../src/db.ts";
import { applyEvent, type StoredEvent } from "../../src/reducers.ts";

const A = "0x00000000000000000000000000000000000000aa";
const USDT = "0x00000000000000000000000000000000000000ee";
const SERIES = "0x" + "11".repeat(32);
const SERIES2 = "0x" + "12".repeat(32);
const GROUP = "0x" + "22".repeat(32);
const TOKEN = "0x00000000000000000000000000000000000000cc";
let n = 0;

function ev(name: string, args: StoredEvent["args"], address = "0xcore"): StoredEvent {
  n++;
  return { id: `0xtx:${n}`, blockNumber: n, blockHash: "0xb", txHash: "0xtx", logIndex: n, address, name, args };
}

function fresh(): Store {
  const s = new Store(":memory:");
  applyEvent(s, ev("GroupCreated", { groupId: GROUP, underlying: "0xmon", settlementAsset: USDT, expiry: "100", oracleConfigId: "0xcfg", bufferBps: 0, fixedBufferNative: "0" }));
  for (const [id, token] of [[SERIES, TOKEN], [SERIES2, "0x00000000000000000000000000000000000000cd"]] as const) {
    applyEvent(s, ev("SeriesCreated", {
      seriesId: id, groupId: GROUP, optionToken: token, underlying: "0xmon", settlementAsset: USDT, optionType: 0,
      strikeWad: "10000000000000000000", capWad: "5000000000000000000", contractSizeWad: "1000000000000000000",
      expiry: "100", oracleConfigId: "0xcfg", quantityIncrement: "1",
    }));
  }
  return s;
}

describe("reducers mirror core accounting", () => {
  it("tracks deposit, write, lock, LOCKED close, unlock and withdraw", () => {
    const s = fresh();
    applyEvent(s, ev("CollateralDeposited", { account: A, asset: USDT, amount: "10000000", cure: false }));
    applyEvent(s, ev("OptionWritten", { account: A, seriesId: SERIES, recipient: A, quantity: "3", exposureN: "0" }));
    applyEvent(s, ev("LongLocked", { account: A, seriesId: SERIES, quantity: "2" }));
    applyEvent(s, ev("ShortClosed", { account: A, seriesId: SERIES, quantity: "1", source: 1 }));
    applyEvent(s, ev("ShortClosed", { account: A, seriesId: SERIES, quantity: "1", source: 0 }));
    applyEvent(s, ev("LongUnlocked", { account: A, seriesId: SERIES, recipient: A, quantity: "1" }));
    applyEvent(s, ev("CollateralWithdrawn", { account: A, asset: USDT, recipient: A, amount: "4000000", paid: "4000000" }));
    expect(s.get("SELECT short_qty, locked_qty FROM positions WHERE account = ?", A)).toEqual({ short_qty: "1", locked_qty: "0" });
    expect(s.get("SELECT amount FROM cash WHERE account = ?", A)).toEqual({ amount: "6000000" });
    expect(s.get("SELECT minted, closed FROM series WHERE series_id = ?", SERIES)).toEqual({ minted: "3", closed: "2" });
  });

  it("removes positions that reach zero", () => {
    const s = fresh();
    applyEvent(s, ev("OptionWritten", { account: A, seriesId: SERIES, recipient: A, quantity: "1", exposureN: "0" }));
    applyEvent(s, ev("ShortCancelledUnfinalized", { account: A, seriesId: SERIES, quantity: "1", source: 0 }));
    expect(s.all("SELECT * FROM positions")).toHaveLength(0);
  });

  it("sync applies one net cash delta and clears the whole group (atomic, PROTOCOL_SPEC section 22)", () => {
    const s = fresh();
    applyEvent(s, ev("CollateralDeposited", { account: A, asset: USDT, amount: "2000000", cure: false }));
    applyEvent(s, ev("OptionWritten", { account: A, seriesId: SERIES, recipient: A, quantity: "1", exposureN: "0" }));
    applyEvent(s, ev("LongLocked", { account: A, seriesId: SERIES2, quantity: "1" }));
    applyEvent(s, ev("RiskGroupFinalized", { groupId: GROUP, oracleConfigId: "0xcfg", settlementAsset: USDT, settlementPriceWad: "20", observationTimestamp: "99", finalizer: A, releasedExposureN: "0", oracleDataHash: "0xhash" }));
    applyEvent(s, ev("RiskGroupSynced", { account: A, groupId: GROUP, settlementAsset: USDT, shortNumerator: "5", lockedLongNumerator: "3", netCashDeltaNative: "-2000000", caller: A }));
    expect(s.get("SELECT amount FROM cash WHERE account = ?", A)).toEqual({ amount: "0" });
    expect(s.all("SELECT * FROM positions")).toHaveLength(0);
    expect(s.get("SELECT finalized, settlement_price_wad FROM groups")).toEqual({ finalized: 1, settlement_price_wad: "20" });
  });

  it("tracks option-token balances from Transfer (mint, transfer, burn)", () => {
    const s = fresh();
    const zero = "0x0000000000000000000000000000000000000000";
    applyEvent(s, ev("Transfer", { from: zero, to: A, value: "5" }, TOKEN));
    applyEvent(s, ev("Transfer", { from: A, to: "0xbb", value: "2" }, TOKEN));
    applyEvent(s, ev("Transfer", { from: A, to: zero, value: "1" }, TOKEN));
    expect(s.get("SELECT amount FROM balances WHERE holder = ?", A)).toEqual({ amount: "2" });
    expect(s.get("SELECT amount FROM balances WHERE holder = ?", "0xbb")).toEqual({ amount: "2" });
  });

  it("tracks asset incident status and pauses", () => {
    const s = fresh();
    applyEvent(s, ev("AssetRestricted", { asset: USDT, account: A, deficitNative: "1", reason: "0xab", caller: A }));
    expect(s.get("SELECT status FROM asset_status")).toEqual({ status: "RESTRICTED" });
    applyEvent(s, ev("ShortfallResolved", { asset: USDT, rhoWad: "800000000000000000", reconciliationRef: "0xref" }));
    expect(s.get("SELECT status, rho_wad FROM asset_status")).toEqual({ status: "WIND_DOWN", rho_wad: "800000000000000000" });
    applyEvent(s, ev("PauseStateChanged", { scope: "0x00", oldBits: "0", newBits: "4", caller: A }));
    expect(s.get("SELECT bits FROM pauses")).toEqual({ bits: "4" });
  });

  it("refuses to go negative (a divergence is surfaced, not hidden)", () => {
    const s = fresh();
    expect(() => applyEvent(s, ev("CollateralWithdrawn", { account: A, asset: USDT, recipient: A, amount: "1", paid: "1" }))).toThrow(/negative/);
  });
});
