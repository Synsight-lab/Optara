/**
 * Balances on Kuru itself (FRONTEND.md §2: "Kuru balances, marked external"). Funds deposited on Kuru to place your
 * own orders sit in Kuru's margin account: they are not Optara collateral and can't back anything you write.
 */
import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { seriesName, shortAddr } from "../lib/optara/format.ts";
import { getKuruBalances } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { kuruWithdrawSteps } from "../lib/optara/actions.ts";
import { Card, Pill, Skeleton } from "./ui.tsx";
import { TxButton } from "./TxButton.tsx";

export function KuruBalances({ owner, series }: { owner: Address; series: Series[] }) {
  const { data, isLoading } = useQuery({
    queryKey: ["kuruBalances", owner, series.length],
    queryFn: () => getKuruBalances(owner, series),
    enabled: series.length > 0,
    refetchInterval: 30_000,
  });

  return (
    <Card
      title={
        <span className="flex items-center gap-2">
          On Kuru <Pill tone="neutral">outside Optara</Pill>
        </span>
      }
    >
      <p className="text-xs leading-relaxed text-muted">
        Money or options you deposit on Kuru to place your own orders are held by Kuru, not Optara. They don't count as
        collateral, don't back anything you write, and must be withdrawn to your wallet before you can redeem or deposit them
        here. Market buys and sells through Optara never leave anything on Kuru. Amounts below are free to withdraw; funds
        locked in open orders appear once you cancel them on the option's Order book page.
      </p>
      {isLoading ? (
        <Skeleton className="mt-3 h-10 w-full" />
      ) : !data?.margin ? (
        <p className="mt-3 text-[13px] text-muted">Kuru isn't available on this network, so there's nothing to show.</p>
      ) : data.rows.length === 0 ? (
        <p className="mt-3 text-[13px] text-muted">
          Nothing of yours is on Kuru. <span className="num text-xs">(Kuru margin account {shortAddr(data.margin)})</span>
        </p>
      ) : (
        <ul className="mt-3 divide-y divide-line/60 text-[13px]">
          {data.rows.map((r, i) => (
            <li key={i} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 py-2.5">
              <span className="min-w-0">
                {r.series ? `${seriesName(r.series)} options` : r.label} <span className="num font-semibold">{r.amount}</span>
              </span>
              <span className="w-full sm:w-44">
                <TxButton
                  compact
                  tone="ghost"
                  label="Withdraw to wallet"
                  steps={kuruWithdrawSteps(data.margin!, r.token, r.raw, r.series ? "options" : r.label)}
                  successMessage="Withdrawn from Kuru to your wallet."
                />
              </span>
            </li>
          ))}
          <li className="pt-2 text-xs text-muted">
            Place, cancel and track Kuru limit orders from each option's Order book page.
          </li>
        </ul>
      )}
    </Card>
  );
}
