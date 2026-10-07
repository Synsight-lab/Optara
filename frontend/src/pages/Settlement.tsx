/** `/settlement`: expired groups — finalize, settle in batches, open payouts, redeem/claim (FRONTEND.md §8, F13). */
import { useMemo } from "react";
import { Link } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { settlementOracleAbi } from "@optara/sdk";
import { Card, EmptyState, Pill, Row, Skeleton, Term } from "../components/ui.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { finalizeSteps, ratioSteps, settleBatchSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtDuration, fmtExpiry, fmtNative, fmtQty, fmtWad, optionTypeName } from "../lib/optara/format.ts";
import { useChainTime, useSeriesList, useWalletWrappers } from "../lib/optara/hooks.ts";
import { getGroup, getHolders, getInsurance } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { SettlementTimeline, StatePill } from "./Series.tsx";

const BATCH = 20;

export function SettlementPage() {
  const { data: series, isLoading } = useSeriesList();
  const { data: now } = useChainTime();
  const groups = useMemo(() => {
    const m = new Map<Hex, Series[]>();
    for (const s of series ?? []) m.set(s.groupId, [...(m.get(s.groupId) ?? []), s]);
    return [...m.entries()].map(([groupId, ss]) => ({ groupId, series: ss, expiry: ss[0]!.expiry }));
  }, [series]);
  if (isLoading || now === undefined) return <Card><Skeleton className="h-40 w-full" /></Card>;
  const expired = groups.filter((g) => g.expiry <= now).sort((a, b) => (a.expiry > b.expiry ? -1 : 1));
  const upcoming = groups.filter((g) => g.expiry > now).sort((a, b) => (a.expiry < b.expiry ? -1 : 1));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Settlement</h1>
        <p className="text-sm text-muted">
          At expiry a price is proven from the feed, every account is settled, then payouts open. Anyone can push each step forward — keepers earn a reward for it.
        </p>
      </div>
      {upcoming.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {upcoming.map((g) => (
            <span key={g.groupId} className="pill bg-surface-2 text-muted">
              Next: {fmtExpiry(g.expiry)} · in {fmtDuration(g.expiry - now)}
            </span>
          ))}
        </div>
      )}
      {expired.length === 0 ? (
        <Card>
          <EmptyState icon="⏳" title="Nothing has expired yet" body="Expired groups show up here with their progress and payout buttons." />
        </Card>
      ) : (
        expired.map((g) => <GroupCard key={g.groupId} groupId={g.groupId} series={g.series} now={now} />)
      )}
    </div>
  );
}

function GroupCard({ groupId, series, now }: { groupId: Hex; series: Series[]; now: bigint }) {
  const s0 = series[0]!;
  const { address } = useConnection();
  const { data: g } = useQuery({ queryKey: ["group", groupId], queryFn: () => getGroup(groupId), refetchInterval: 6_000 });
  const { data: ins } = useQuery({ queryKey: ["insurance", s0.settlementAsset], queryFn: () => getInsurance(s0.settlementAsset) });
  const { data: earliest } = useQuery({
    queryKey: ["earliest", groupId],
    queryFn: () => publicClient.readContract({ address: ADDR.settlementOracle, abi: settlementOracleAbi, functionName: "earliestFinalization", args: [s0.settlementOracleConfigId, s0.expiry] }),
  });
  const holders = useQuery({ queryKey: ["holders", groupId, g?.participants.toString()], queryFn: () => getHolders(series.map((s) => s.id)), enabled: g?.state === "FINALIZED" });
  const { data: wallet } = useWalletWrappers(address);
  const mine = (wallet ?? []).filter((w) => w.series.groupId === groupId);
  if (!g) return <Card><Skeleton className="h-32 w-full" /></Card>;
  const a = g.accounting;
  const canFinalize = (g.state === "EXPIRED" || g.state === "ORACLE_STALLED") && earliest !== undefined && now >= BigInt(earliest);

  return (
    <Card
      title={
        <span className="flex flex-wrap items-center gap-2">
          {s0.underlyingSymbol} expiry {fmtExpiry(s0.expiry)} <StatePill state={g.state} />
        </span>
      }
    >
      <SettlementTimeline state={g.state} />
      <div className="mt-5 grid gap-6 md:grid-cols-2">
        <div>
          <Row label="Settlement price" value={a.finalized ? `${fmtWad(a.priceWad)} ${s0.assetSymbol}` : "not fixed yet"} />
          <Row label={<Term tip="Accounts with positions in this expiry still to be settled. Payouts open at zero.">Accounts left to settle</Term>} value={g.participants.toString()} />
          <Row label={<Term tip="The share of each payout paid. 100% unless losses exceeded what was collected plus the insurance fund.">Recovery ratio</Term>} value={a.ratioSet ? `${fmtWad(a.ratioWad * 100n, 2)}%` : "—"} tone={a.ratioSet ? (a.ratioWad === 10n ** 18n ? "good" : "warn") : undefined} />
          <Row label="Insurance contribution" value={a.ratioSet ? `${fmtNative(a.insurance, 6)} ${s0.assetSymbol}` : "—"} />
          <Row label="Keeper rewards" value={ins ? `${fmtNative(ins.finalizeReward, 6)} to fix the price · ${fmtNative(ins.settleReward, 6)}+ per account` : "—"} />
        </div>
        <div className="space-y-3">
          {(g.state === "EXPIRED" || g.state === "ORACLE_STALLED") && (
            <>
              {g.state === "ORACLE_STALLED" && <Pill tone="bad">The settlement price feed is late. A late valid round can still settle it.</Pill>}
              <TxButton
                label="Fix the settlement price"
                steps={finalizeSteps(groupId, s0.settlementOracleConfigId, s0.expiry)}
                disabled={!canFinalize}
                disabledReason={earliest !== undefined && now < BigInt(earliest) ? `Possible in ${fmtDuration(BigInt(earliest) - now)}.` : undefined}
                successMessage="Settlement price fixed"
              />
            </>
          )}
          {g.state === "FINALIZED" && (
            <TxButton
              label={`Settle next ${Math.min(BATCH, Number(g.participants))} accounts`}
              steps={holders.data?.length ? settleBatchSteps(groupId, holders.data.slice(0, BATCH)) : undefined}
              disabled={!holders.data?.length}
              disabledReason={holders.isLoading ? "Finding accounts…" : undefined}
              successMessage="Accounts settled"
            />
          )}
          {g.state === "ALL_SETTLED" && <TxButton label="Open payouts" steps={ratioSteps(groupId)} successMessage="Payouts are open" />}
          {mine.length > 0 && (
            <div className="rounded-xl border border-line p-4">
              <div className="label mb-2">Your option tokens in this expiry</div>
              {mine.map((w) => (
                <Link key={w.series.id} to={`/series/${w.series.id}?tab=redeem`} className="flex items-center justify-between py-1 text-sm hover:text-primary">
                  <span>
                    {fmtWad(w.series.strikeWad, 0)} {optionTypeName(w.series.optionType)} · {fmtQty(w.balance)}
                  </span>
                  <span className="text-primary">{g.state === "REDEEMABLE" ? "Redeem →" : "Waiting →"}</span>
                </Link>
              ))}
            </div>
          )}
          {g.state === "REDEEMABLE" && mine.length === 0 && <p className="text-sm text-muted">Payouts are open. Holders redeem from the series page.</p>}
        </div>
      </div>
    </Card>
  );
}
