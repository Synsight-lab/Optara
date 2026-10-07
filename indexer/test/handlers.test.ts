/**
 * Handler logic on Envio's in-process test indexer (simulated events, no network or database):
 * the ledger rebuild (accounts, positions, series totals, participants), wrapper supply and holders, and
 * IDX-002 (duplicate events): delivering the same logs again changes nothing.
 */
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";
import { once } from "../src/lib.ts";

const P = `0x${"11".repeat(32)}`;
const G = `0x${"22".repeat(32)}`;
const S = `0x${"33".repeat(32)}`;
const WRAPPER = "0x00000000000000000000000000000000000000A1";
const ALICE = "0x00000000000000000000000000000000000000A2";
const BOB = "0x00000000000000000000000000000000000000A3";
const ZERO = "0x0000000000000000000000000000000000000000";
const WETH = "0x00000000000000000000000000000000000000E1";
const USDC = "0x00000000000000000000000000000000000000E2";

const setup = (block: number) => [
  {
    contract: "OptionSeriesRegistry",
    event: "GroupCreated",
    block: { number: block },
    logIndex: 0,
    params: { groupId: G, underlying: WETH, settlementAsset: USDC, expiry: 2_000_000_000n, settlementOracleConfigId: P },
  },
  {
    contract: "OptionSeriesRegistry",
    event: "SeriesCreated",
    block: { number: block },
    logIndex: 1,
    params: {
      seriesId: S,
      groupId: G,
      wrapper: WRAPPER,
      terms: {
        underlying: WETH,
        settlementAsset: USDC,
        optionType: 0n,
        strikeWad: 4500n * 10n ** 18n,
        contractSizeWad: 10n ** 18n,
        expiry: 2_000_000_000n,
        settlementOracleConfigId: P,
        volSurfaceProductId: P,
        riskParameterSetId: P,
        wrapper: WRAPPER,
      },
    },
  },
  { contract: "SubAccounts", event: "SubAccountCreated", block: { number: block }, logIndex: 2, params: { accountId: 1n, owner: ALICE, settlementAsset: USDC } },
  { contract: "SubAccounts", event: "SubAccountCreated", block: { number: block }, logIndex: 3, params: { accountId: 2n, owner: BOB, settlementAsset: USDC } },
];

/** Alice writes 2 (short 2, wrappers to Alice), Bob buys 1 wrapper and unwraps it into his account. */
const activity = (block: number) => [
  { contract: "SubAccounts", event: "CashUpdated", block: { number: block }, logIndex: 0, params: { accountId: 1n, delta: 5000n, cash: 5000n } },
  { contract: "SubAccounts", event: "BalanceUpdated", block: { number: block }, logIndex: 1, params: { accountId: 1n, seriesId: S, delta: -2n * 10n ** 18n, balance: -2n * 10n ** 18n } },
  { contract: "SubAccounts", event: "ParticipantsUpdated", block: { number: block }, logIndex: 2, params: { groupId: G, participants: 1n } },
  { contract: "ExternalOptionWrapper", event: "Transfer", srcAddress: WRAPPER, block: { number: block }, logIndex: 3, params: { from: ZERO, to: ALICE, value: 2n * 10n ** 18n } },
  { contract: "ExternalOptionWrapper", event: "Transfer", srcAddress: WRAPPER, block: { number: block + 1 }, logIndex: 0, params: { from: ALICE, to: BOB, value: 10n ** 18n } },
  { contract: "ExternalOptionWrapper", event: "Transfer", srcAddress: WRAPPER, block: { number: block + 2 }, logIndex: 0, params: { from: BOB, to: ZERO, value: 10n ** 18n } },
  { contract: "SubAccounts", event: "BalanceUpdated", block: { number: block + 2 }, logIndex: 1, params: { accountId: 2n, seriesId: S, delta: 10n ** 18n, balance: 10n ** 18n } },
  { contract: "SubAccounts", event: "ParticipantsUpdated", block: { number: block + 2 }, logIndex: 2, params: { groupId: G, participants: 2n } },
  { contract: "SubAccounts", event: "CashUpdated", block: { number: block + 2 }, logIndex: 3, params: { accountId: 1n, delta: -100n, cash: 4900n } },
];

async function snapshot(indexer: ReturnType<typeof createTestIndexer>) {
  return {
    accounts: await indexer.Account.getAll(),
    positions: await indexer.Position.getAll(),
    series: await indexer.Series.getAll(),
    groups: await indexer.SettlementGroup.getAll(),
    wrappers: await indexer.WrapperBalance.getAll(),
  };
}

describe("ledger, wrapper and group handlers", () => {
  it("rebuild accounts, positions, totals, supply, holders and participants", async () => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 31337: { simulate: [...setup(10), ...activity(11)] as any } } });
    const s = await indexer.Series.getOrThrow(S);
    expect(s.internalShort).toBe(2n * 10n ** 18n);
    expect(s.internalLong).toBe(10n ** 18n);
    expect(s.wrapperSupply).toBe(10n ** 18n); // minted 2, Bob unwrapped (burned) 1
    expect((await indexer.Account.getOrThrow("1")).cash).toBe(4900n);
    expect((await indexer.Position.getOrThrow(`2-${S}`)).balance).toBe(10n ** 18n);
    expect((await indexer.SettlementGroup.getOrThrow(G)).participants).toBe(2n);
    expect((await indexer.WrapperBalance.getOrThrow(`${WRAPPER}-${ALICE}`)).balance).toBe(10n ** 18n);
    expect((await indexer.WrapperBalance.getOrThrow(`${WRAPPER}-${BOB}`)).balance).toBe(0n);
    expect(indexer.chains[31337].ExternalOptionWrapper.addresses).toContain(WRAPPER);
  });

  it("IDX-002: replayed absolute values change nothing (totals move only by real balance changes)", async () => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 31337: { simulate: [...setup(10), ...activity(11)] as any } } });
    const before = await snapshot(indexer);
    // The same ledger values re-asserted in later blocks (what a replay of those logs would carry).
    const replay = activity(11)
      .filter((x) => x.contract === "SubAccounts")
      .map((x, i) => ({ ...x, block: { number: 20 }, logIndex: i }));
    await indexer.process({ chains: { 31337: { simulate: replay as any } } });
    const after = await snapshot(indexer);
    expect(after.series).toEqual(before.series);
    expect(after.groups).toEqual(before.groups);
    expect(after.accounts.map((a) => [a.id, a.cash])).toEqual(before.accounts.map((a) => [a.id, a.cash]));
    expect(after.positions.map((p) => [p.id, p.balance])).toEqual(before.positions.map((p) => [p.id, p.balance]));
  });

  it("IDX-002: delta updates are applied once per log (the processed-log guard)", async () => {
    const seen = new Map<string, { id: string }>();
    const context = { ProcessedLog: { get: async (id: string) => seen.get(id), set: (e: { id: string }) => void seen.set(e.id, e) } };
    const event = { block: { number: 7 }, logIndex: 3 };
    let applied = 0;
    await once(context, event, () => void applied++);
    await once(context, event, () => void applied++);
    await once(context, { block: { number: 7 }, logIndex: 4 }, () => void applied++);
    expect(applied).toBe(2);
    // Envio itself never delivers a (block, logIndex) twice: its harness rejects it outright.
    await expect(
      createTestIndexer().process({ chains: { 31337: { simulate: [...setup(10), activity(11)[0]!, activity(11)[0]!] as any } } }),
    ).rejects.toThrow(/both resolve to block 11, logIndex 0/);
  });

  it("a balance moving through zero keeps long and short totals separate", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        31337: {
          simulate: [
            ...setup(10),
            { contract: "SubAccounts", event: "BalanceUpdated", block: { number: 11 }, logIndex: 0, params: { accountId: 1n, seriesId: S, delta: 3n, balance: 3n } },
            { contract: "SubAccounts", event: "BalanceUpdated", block: { number: 12 }, logIndex: 0, params: { accountId: 1n, seriesId: S, delta: -5n, balance: -2n } },
          ] as any,
        },
      },
    });
    const s = await indexer.Series.getOrThrow(S);
    expect([s.internalLong, s.internalShort]).toEqual([0n, 2n]);
  });
});
