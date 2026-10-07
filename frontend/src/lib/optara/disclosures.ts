/** FRONTEND.md §6 (FE-003): disclosures shown and acknowledged once before the flows that need them. */
import { NETWORK } from "../../config/network.ts";

export const DISCLOSURES = {
  uncapped: { title: "Uncapped risk for writers", text: "Calls you write have no maximum loss. If your margin runs low you will be liquidated at a discount." },
  recovery: { title: "Recovery ratio", text: "If losses exceed the insurance fund, all holders of this expiry receive the same reduced percentage of their payoff." },
  premium: { title: "Where your premium goes", text: "Premium received on Kuru stays in your wallet. Deposit it to improve your Optara margin." },
  kuru: { title: "Kuru and Optara are separate", text: "Kuru balances do not count as Optara collateral." },
  upgradeable: { title: "Upgradeable contracts", text: "Optara contracts are upgradeable after a 7-day timelock." },
  oracle: { title: "Price data dependency", text: "New positions need fresh price and volatility data. If data stops, only closing is possible." },
  mon: { title: "MON volatility", text: "MON volatility is synthetic. No liquid MON options market exists yet." },
  settlement: { title: "Settlement timing", text: "Payouts open only after every account in this expiry is settled." },
} as const;
export type DisclosureId = keyof typeof DISCLOSURES;

/** Which disclosures a flow needs (§6, USER_FLOWS.md F9 "Disclosures before buying"). */
export function disclosuresFor(flow: "buy" | "write", underlyingSymbol: string): DisclosureId[] {
  const base: DisclosureId[] = flow === "write" ? ["uncapped", "premium", "kuru", "oracle", "upgradeable", "settlement"] : ["recovery", "oracle", "upgradeable", "settlement"];
  return underlyingSymbol === "MON" ? [...base, "mon"] : base;
}

const KEY = `optara.disclosures.${NETWORK}`;

export interface AckStore {
  get(): DisclosureId[];
  set(ids: DisclosureId[]): void;
}

export const localAckStore: AckStore = {
  get: () => {
    try {
      return JSON.parse(localStorage.getItem(KEY) ?? "[]") as DisclosureId[];
    } catch {
      return [];
    }
  },
  set: (ids) => {
    try {
      localStorage.setItem(KEY, JSON.stringify(ids));
    } catch {
      // private mode: acknowledgements last for the session only
    }
  },
};

/** The disclosures of `needed` not yet acknowledged. */
export const pendingDisclosures = (needed: DisclosureId[], store: AckStore = localAckStore) => {
  const acked = new Set(store.get());
  return needed.filter((d) => !acked.has(d));
};

export const acknowledge = (ids: DisclosureId[], store: AckStore = localAckStore) => store.set([...new Set([...store.get(), ...ids])]);
