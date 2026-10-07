import type { Address, Hex, PublicClient } from "viem";
import { subAccountsAbi } from "./abi.ts";

/** Who holds what: the account lists keepers act on (settlement participants, liquidation candidates). */
export interface AccountDirectory {
  sync(): Promise<void>;
  /** Accounts with a non-zero balance in any of these series. */
  holders(seriesIds: readonly Hex[]): bigint[];
  /** Accounts with at least one non-zero balance. */
  withPositions(): bigint[];
}

/**
 * The ledger rebuilt from `SubAccounts.BalanceUpdated` (every ledger write emits it with the new balance, DD-24).
 * A fallback for keepers without the indexer; scans in chunks (Monad's public RPC caps getLogs at 100 blocks).
 */
export class LedgerLogDirectory implements AccountDirectory {
  private next: bigint;
  /** seriesId → accountId → balance */
  private readonly balances = new Map<Hex, Map<bigint, bigint>>();

  constructor(
    private readonly client: PublicClient,
    private readonly ledger: Address,
    fromBlock: bigint,
    private readonly chunk = 100n,
  ) {
    this.next = fromBlock;
  }

  async sync(): Promise<void> {
    const head = await this.client.getBlockNumber();
    while (this.next <= head) {
      const to = this.next + this.chunk - 1n > head ? head : this.next + this.chunk - 1n;
      const logs = await this.client.getContractEvents({
        address: this.ledger,
        abi: subAccountsAbi,
        eventName: "BalanceUpdated",
        fromBlock: this.next,
        toBlock: to,
        strict: true,
      });
      for (const l of logs) {
        const m = this.balances.get(l.args.seriesId) ?? new Map<bigint, bigint>();
        m.set(l.args.accountId, l.args.balance);
        this.balances.set(l.args.seriesId, m);
      }
      this.next = to + 1n;
    }
  }

  holders(seriesIds: readonly Hex[]): bigint[] {
    const out = new Set<bigint>();
    for (const id of seriesIds) for (const [a, b] of this.balances.get(id) ?? []) if (b !== 0n) out.add(a);
    return [...out].sort((a, b) => (a < b ? -1 : 1));
  }

  withPositions(): bigint[] {
    return this.holders([...this.balances.keys()]);
  }
}
