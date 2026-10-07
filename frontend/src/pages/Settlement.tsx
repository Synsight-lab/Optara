/** `/settlement`: expired groups — finalize, settle in batches, open payouts, redeem/claim (FRONTEND.md §8, F13). */
import { useMemo } from "react";
import { Link } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { settlementOracleAbi } from "@optara/sdk";
import {
  Activity,
  ArrowRight,
  CheckCircle2,
  Clock,
  Coins,
  ExternalLink,
  HelpCircle,
  Info,
  ShieldCheck,
  Sparkles,
  Users,
  Wallet,
} from "lucide-react";
import { Card, EmptyState, Pill, Row, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
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

  if (isLoading || now === undefined) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-32 w-full rounded-3xl" />
        <Skeleton className="h-64 w-full rounded-3xl" />
      </div>
    );
  }

  const expired = groups.filter((g) => g.expiry <= now).sort((a, b) => (a.expiry > b.expiry ? -1 : 1));
  const upcoming = groups.filter((g) => g.expiry > now).sort((a, b) => (a.expiry < b.expiry ? -1 : 1));

  return (
    <div className="space-y-6 sm:space-y-8">
      {/* Page Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight">Settlement & Payouts</h1>
          <p className="text-xs sm:text-sm text-muted mt-0.5">
            Transparent, provable cash settlements for expired option groups.
          </p>
        </div>

        {/* Upcoming Expiries Countdown Bar */}
        {upcoming.length > 0 && (
          <div className="flex flex-wrap gap-2">
            {upcoming.slice(0, 3).map((g) => (
              <span key={g.groupId} className="pill bg-surface-2 text-ink border border-line text-xs">
                <Clock className="h-3 w-3 text-primary inline mr-1" />
                Next: {fmtExpiry(g.expiry)} (in {fmtDuration(g.expiry - now)})
              </span>
            ))}
          </div>
        )}
      </div>

      {/* Explainer: How Settlement Works */}
      <div className="rounded-3xl border border-line bg-surface/75 p-5 backdrop-blur-xl">
        <div className="text-xs font-bold text-ink uppercase tracking-wider mb-3 flex items-center gap-1.5">
          <Sparkles className="h-4 w-4 text-primary" /> The 4-Stage Fair Settlement Window
        </div>
        <div className="grid gap-3 sm:grid-cols-4 text-xs">
          {[
            {
              n: "1. Expiration",
              desc: "Option trading ceases at 08:00 UTC on expiry day. No new positions can be opened.",
            },
            {
              n: "2. Fix Price",
              desc: "A tamper-proof settlement price is proven on-chain from the Pyth/Chainlink round in force.",
            },
            {
              n: "3. Settle Accounts",
              desc: "All subaccounts are settled automatically by keepers in batches before redemptions begin.",
            },
            {
              n: "4. Cash Payouts Open",
              desc: "The insurance fund covers shortfalls, and all long holders redeem their cash in USDC.",
            },
          ].map((step, idx) => (
            <div key={idx} className="rounded-2xl border border-line/60 bg-surface-2/60 p-3.5">
              <span className="font-bold text-ink block">{step.n}</span>
              <span className="text-muted text-[11px] leading-relaxed mt-1 block">{step.desc}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Expired Groups Cards */}
      {expired.length === 0 ? (
        <Card>
          <EmptyState
            icon="⏳"
            title="No expired groups yet"
            body="When active options reach their expiry date, they will appear here with settlement progress and payout claim buttons."
          />
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
    queryFn: () =>
      publicClient.readContract({
        address: ADDR.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "earliestFinalization",
        args: [s0.settlementOracleConfigId, s0.expiry],
      }),
  });

  const holders = useQuery({
    queryKey: ["holders", groupId, g?.participants.toString()],
    queryFn: () => getHolders(series.map((s) => s.id)),
    enabled: g?.state === "FINALIZED",
  });

  const { data: wallet } = useWalletWrappers(address);
  const mine = (wallet ?? []).filter((w) => w.series.groupId === groupId);

  if (!g) return <Card><Skeleton className="h-32 w-full" /></Card>;
  const a = g.accounting;
  const canFinalize =
    (g.state === "EXPIRED" || g.state === "ORACLE_STALLED") && earliest !== undefined && now >= BigInt(earliest);

  return (
    <Card
      title={
        <div className="flex flex-wrap items-center gap-2.5">
          <TokenIcon symbol={s0.underlyingSymbol} className="h-5 w-5" />
          <span className="font-extrabold text-ink">
            {s0.underlyingSymbol} Expiry {fmtExpiry(s0.expiry)}
          </span>
          <StatePill state={g.state} />
        </div>
      }
    >
      {/* Progress Timeline */}
      <SettlementTimeline state={g.state} />

      <div className="mt-6 grid gap-6 md:grid-cols-2">
        {/* Left Side: Accounting Data */}
        <div className="space-y-2 rounded-2xl bg-surface-2/60 p-4 border border-line">
          <Row
            label="Settlement Price"
            value={a.finalized ? `$${fmtWad(a.priceWad, 2)} ${s0.assetSymbol}` : "Awaiting finalization"}
            strong={a.finalized}
          />
          <Row
            label={<Term tip="Remaining subaccounts that must be settled before redemptions unlock.">Accounts Left to Settle</Term>}
            value={
              <span className="flex items-center gap-1.5 font-bold">
                <Users className="h-3.5 w-3.5 text-muted" />
                {g.participants.toString()}
              </span>
            }
          />
          <Row
            label={<Term tip="Uniform percentage paid to all long holders. 100% unless total deficit exceeds insurance fund balance.">Recovery Ratio</Term>}
            value={a.ratioSet ? `${fmtWad(a.ratioWad * 100n, 2)}%` : "Pending account settlement"}
            tone={a.ratioSet ? (a.ratioWad === 10n ** 18n ? "good" : "warn") : undefined}
          />
          <Row
            label="Insurance Fund Contribution"
            value={a.ratioSet ? `${fmtNative(a.insurance, 6)} ${s0.assetSymbol}` : "—"}
          />
          {ins && (
            <Row
              label="Keeper Bounty"
              value={`$${fmtNative(ins.finalizeReward, 6)} fix · $${fmtNative(ins.settleReward, 6)}+ per account`}
            />
          )}
        </div>

        {/* Right Side: Interactive Action Buttons */}
        <div className="space-y-4">
          {/* User's Claimable Tokens Banner */}
          {mine.length > 0 && (
            <div className="rounded-2xl border border-good/40 bg-good/10 p-4">
              <div className="flex items-center justify-between mb-2">
                <span className="text-xs font-bold text-good flex items-center gap-1.5">
                  <Wallet className="h-4 w-4" /> Your Option Tokens in this Expiry
                </span>
                {g.state === "REDEEMABLE" && (
                  <span className="pill bg-good text-white font-bold text-[10px]">Ready to Redeem</span>
                )}
              </div>
              <div className="divide-y divide-good/20">
                {mine.map((w) => (
                  <Link
                    key={w.series.id}
                    to={`/series/${w.series.id}?tab=redeem`}
                    className="flex items-center justify-between py-2 text-xs font-medium hover:text-primary transition"
                  >
                    <span>
                      ${fmtWad(w.series.strikeWad, 0)} {optionTypeName(w.series.optionType)} · <b className="text-ink">{fmtQty(w.balance)} tokens</b>
                    </span>
                    <span className="font-bold text-primary flex items-center gap-1">
                      {g.state === "REDEEMABLE" ? "Claim Cash →" : "View Series →"}
                    </span>
                  </Link>
                ))}
              </div>
            </div>
          )}

          {(g.state === "EXPIRED" || g.state === "ORACLE_STALLED") && (
            <div className="space-y-2">
              {g.state === "ORACLE_STALLED" && (
                <div className="rounded-xl bg-bad/10 border border-bad/30 p-3 text-xs text-bad">
                  ⚠️ Price feed observation is delayed. Anyone can trigger finalization once a valid round arrives.
                </div>
              )}
              <TxButton
                label="Fix Settlement Price On-Chain"
                steps={finalizeSteps(groupId, s0.settlementOracleConfigId, s0.expiry)}
                disabled={!canFinalize}
                disabledReason={
                  earliest !== undefined && now < BigInt(earliest)
                    ? `Settlement round locks in ${fmtDuration(BigInt(earliest) - now)}.`
                    : undefined
                }
                successMessage="Settlement price finalized!"
              />
            </div>
          )}

          {g.state === "FINALIZED" && (
            <div className="space-y-2">
              <p className="text-xs text-muted">
                Keepers earn a bounty for settling accounts. Click below to settle the next batch:
              </p>
              <TxButton
                label={`Settle Next ${Math.min(BATCH, Number(g.participants))} Accounts`}
                steps={holders.data?.length ? settleBatchSteps(groupId, holders.data.slice(0, BATCH)) : undefined}
                disabled={!holders.data?.length}
                disabledReason={holders.isLoading ? "Scanning ledger accounts…" : undefined}
                successMessage="Batch settled!"
              />
            </div>
          )}

          {g.state === "ALL_SETTLED" && (
            <TxButton
              label="Calculate Recovery Ratio & Open Payouts"
              steps={ratioSteps(groupId)}
              successMessage="Payouts are now open!"
            />
          )}

          {g.state === "REDEEMABLE" && mine.length === 0 && (
            <div className="rounded-2xl border border-line bg-surface-2/40 p-4 text-xs text-muted">
              ✅ Cash payouts are unlocked. Long holders can redeem their payout from their Series or Portfolio page.
            </div>
          )}
        </div>
      </div>
    </Card>
  );
}
