/**
 * Kuru maker orders on Envio's in-process test indexer: a Kuru market registered in the VenueRegistry is picked up
 * dynamically, and its OrderCreated / Trade / OrdersCanceled logs keep each order's status.
 */
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";
import { keccak256, toHex } from "viem";

const KURU = keccak256(toHex("KURU"));
const OTHER_VENUE = keccak256(toHex("OTHER"));
const S = `0x${"33".repeat(32)}`;
const S2 = `0x${"44".repeat(32)}`;
const BOOK = "0x00000000000000000000000000000000000000B1";
const OTHER_BOOK = "0x00000000000000000000000000000000000000B2";
const ALICE = "0x00000000000000000000000000000000000000A2";
const BOB = "0x00000000000000000000000000000000000000A3";

const registered = (block: number) => [
  { contract: "VenueRegistry", event: "MarketRegistered", block: { number: block }, logIndex: 0, params: { venueId: KURU, seriesId: S, market: BOOK } },
  { contract: "VenueRegistry", event: "MarketRegistered", block: { number: block }, logIndex: 1, params: { venueId: OTHER_VENUE, seriesId: S2, market: OTHER_BOOK } },
];
const created = (block: number, logIndex: number, orderId: bigint, owner: string, size: bigint, isBuy = true) => ({
  contract: "KuruOrderBook",
  event: "OrderCreated",
  srcAddress: BOOK,
  block: { number: block },
  logIndex,
  params: { orderId, owner, size, price: 135, isBuy },
});
const trade = (block: number, orderId: bigint, maker: string, updatedSize: bigint, filledSize: bigint) => ({
  contract: "KuruOrderBook",
  event: "Trade",
  srcAddress: BOOK,
  block: { number: block },
  logIndex: 0,
  params: { orderId, makerAddress: maker, isBuy: true, price: 135n, updatedSize, takerAddress: BOB, txOrigin: BOB, filledSize },
});
const cancelled = (block: number, ids: bigint[], owner: string) => ({
  contract: "KuruOrderBook",
  event: "OrdersCanceled",
  srcAddress: BOOK,
  block: { number: block },
  logIndex: 0,
  params: { orderId: ids, owner },
});

describe("Kuru maker orders", () => {
  it("registers only Kuru-venue markets as order books", async () => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 31337: { simulate: registered(10) as any } } });
    expect(indexer.chains[31337].KuruOrderBook.addresses).toContain(BOOK);
    expect(indexer.chains[31337].KuruOrderBook.addresses).not.toContain(OTHER_BOOK);
  });

  it("tracks open, partial, filled and cancelled orders with the series and a lowercase owner", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        31337: {
          simulate: [
            ...registered(10),
            created(11, 0, 1n, ALICE, 100n),
            created(11, 1, 2n, ALICE, 50n),
            created(11, 2, 3n, ALICE, 80n, false),
            trade(12, 1n, ALICE, 40n, 60n), // order 1: 60 of 100 filled
            trade(13, 2n, ALICE, 0n, 50n), // order 2: filled
            cancelled(14, [1n, 2n, 3n], ALICE), // 1 partly filled then cancelled; 2 already filled stays filled
          ] as any,
        },
      },
    });
    const id = (n: bigint) => `${BOOK.toLowerCase()}-${n}`;
    const o1 = await indexer.KuruOrder.getOrThrow(id(1n));
    const o2 = await indexer.KuruOrder.getOrThrow(id(2n));
    const o3 = await indexer.KuruOrder.getOrThrow(id(3n));
    expect(o1).toMatchObject({ seriesId: S, owner: ALICE.toLowerCase(), isBuy: true, priceUnits: 135n, sizeUnits: 100n, remainingUnits: 0n, filledUnits: 60n, status: "CANCELLED" });
    expect(o2).toMatchObject({ status: "FILLED", remainingUnits: 0n, filledUnits: 50n });
    expect(o3).toMatchObject({ status: "CANCELLED", isBuy: false, sizeUnits: 80n, filledUnits: 0n });
  });

  it("a partial fill is PARTIAL until cancelled or filled", async () => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 31337: { simulate: [...registered(10), created(11, 0, 7n, ALICE, 100n), trade(12, 7n, ALICE, 30n, 70n)] as any } } });
    expect(await indexer.KuruOrder.getOrThrow(`${BOOK.toLowerCase()}-7`)).toMatchObject({ status: "PARTIAL", remainingUnits: 30n, filledUnits: 70n });
  });
});
