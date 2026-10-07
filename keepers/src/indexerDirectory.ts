import type { Hex } from "viem";
import type { AccountDirectory } from "@optara/sdk";

/** Participant and candidate lists from the indexer API (`GET /positions`: every non-zero position). */
export class IndexerDirectory implements AccountDirectory {
  private positions: { accountId: bigint; seriesId: Hex }[] = [];

  constructor(
    private readonly url: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async sync(): Promise<void> {
    const res = await this.fetchImpl(`${this.url}/positions`);
    if (!res.ok) throw new Error(`indexer ${res.status}`);
    const rows = (await res.json()) as { accountId: string; seriesId: Hex; balance: string }[];
    this.positions = rows.filter((r) => BigInt(r.balance) !== 0n).map((r) => ({ accountId: BigInt(r.accountId), seriesId: r.seriesId }));
  }

  holders(seriesIds: readonly Hex[]): bigint[] {
    const want = new Set(seriesIds.map((s) => s.toLowerCase()));
    return [...new Set(this.positions.filter((p) => want.has(p.seriesId.toLowerCase())).map((p) => p.accountId))].sort((a, b) => (a < b ? -1 : 1));
  }

  withPositions(): bigint[] {
    return [...new Set(this.positions.map((p) => p.accountId))].sort((a, b) => (a < b ? -1 : 1));
  }
}
