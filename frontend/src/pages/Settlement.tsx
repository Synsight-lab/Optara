/** `/settlement`: expired groups — finalize, settle in batches, open payouts, redeem/claim (FRONTEND.md §8, F13). */
import { useMemo } from "react";
import { Link } from "react-router";
import { useQueries, useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { buildSettlementProof, settlementOracleAbi } from "@optara/sdk";
import { CheckCircle2, Clock, Wallet } from "lucide-react";
import { Card, Details, EmptyState, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { finalizeSteps, ratioSteps, settleBatchSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { ERROR_MESSAGES } from "../lib/optara/errors.ts";
import { fmtDuration, fmtExpiry, fmtLevel, fmtNative, fmtQty, fmtWad, optionTypeName } from "../lib/optara/format.ts";
import { useChainTime, useSeriesList, useWalletWrappers } from "../lib/optara/hooks.ts";
import { legOf, payoutPerOption, usd } from "../lib/optara/payoff.ts";
import { getGroup, getHolders, getInsurance } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { SettlementTimeline, StatePill } from "./Series.tsx";

const BATCH = 20;

interface Group {
  groupId: Hex;
  series: Series[];
  expiry: bigint;
}

type GroupData = Awaited<ReturnType<typeof getGroup>>;

export function SettlementPage() {
  const { data: series, isLoading } = useSeriesList();
  const { data: now } = useChainTime();
  const { address } = useConnection();
  const { data: wallet } = useWalletWrappers(address);

  const groups = useMemo(() => {
    const m = new Map<Hex, Series[]>();
    for (const s of series ?? []) m.set(s.groupId, [...(m.get(s.groupId) ?? []), s]);
    return [...m.entries()].map(([groupId, ss]): Group => ({ groupId, series: ss, expiry: ss[0]!.expiry }));
  }, [series]);

  const expired = useMemo(
    () => (now === undefined ? [] : groups.filter((g) => g.expiry <= now).sort((a, b) => (a.expiry > b.expiry ? -1 : 1))),
    [groups, now],
  );
  // Same query key as each card, so the cards reuse these results.
  const states = useQueries({
    queries: expired.map((g) => ({ queryKey: ["group", g.groupId], queryFn: () => getGroup(g.groupId), refetchInterval: 6_000 })),
  });

  if (isLoading || now === undefined) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-24 w-full rounded-3xl" />
        <Skeleton className="h-64 w-full rounded-3xl" />
      </div>
    );
  }

  const held = (groupId: Hex) => (wallet ?? []).filter((w) => w.series.groupId === groupId && w.balance > 0n);
  const rows = expired.map((g, i) => ({ g, data: states[i]?.data, mine: held(g.groupId) }));
  // Finished = payouts open and nothing of yours left to redeem. Everything else needs attention.
  const finished = rows.filter((r) => r.data?.state === "REDEEMABLE" && r.mine.length === 0);
  const inProgress = rows.filter((r) => !finished.includes(r));
  const readyForYou = rows.filter((r) => r.data?.state === "REDEEMABLE" && r.mine.length > 0);
  const waitingForYou = rows.filter((r) => r.data?.state !== "REDEEMABLE" && r.mine.length > 0);

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="px-1">
        <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">Settlement</h1>
        <p className="mt-0.5 text-[13px] text-muted">
          After expiry, each group of options is settled in four steps. Then holders redeem their options for cash.
        </p>
      </div>

      {(readyForYou.length > 0 || waitingForYou.length > 0) && (
        <div className={cx("flex items-start gap-3 rounded-2xl border px-4 py-3 text-[13px]", readyForYou.length ? "border-good/40 bg-good/10" : "border-line bg-surface-2/60")}>
          <Wallet className={cx("mt-0.5 h-4 w-4 shrink-0", readyForYou.length ? "text-good" : "text-primary")} />
          <span>
            {readyForYou.length > 0 && (
              <b className="text-good">
                {readyForYou.length} expir{readyForYou.length === 1 ? "y is" : "ies are"} ready: redeem your options below.{" "}
              </b>
            )}
            {waitingForYou.length > 0 && (
              <span className="text-muted">
                {waitingForYou.length} expir{waitingForYou.length === 1 ? "y" : "ies"} with your options {waitingForYou.length === 1 ? "is" : "are"} still being
                settled. Nothing to do: you can redeem once payouts open.
              </span>
            )}
          </span>
        </div>
      )}

      <Upcoming groups={groups} now={now} />

      <Details summary="How settlement works">
        <ol className="grid gap-2 py-1 text-[13px] sm:grid-cols-4">
          {[
            ["Expiry", "Trading in the expiry stops."],
            ["Price fixed", "The official price at expiry is recorded on-chain. Nobody can choose it."],
            ["Accounts settled", "Writers pay what they owe from their accounts."],
            ["Payouts open", "Holders redeem options for cash. Out-of-the-money options pay nothing."],
          ].map(([t, d], i) => (
            <li key={t} className="rounded-xl border border-line bg-surface/60 p-3">
              <span className="block font-semibold">
                {i + 1}. {t}
              </span>
              <span className="mt-0.5 block text-xs leading-relaxed text-muted">{d}</span>
            </li>
          ))}
        </ol>
        <p className="pb-1 text-xs text-muted">
          Bots normally run steps 2 to 4 within minutes. Anyone can press the buttons instead and earns a small reward for it.
        </p>
      </Details>

      {expired.length === 0 ? (
        <Card>
          <EmptyState
            icon="⏳"
            title="Nothing has expired yet"
            body="When options reach their expiry, they show up here with their settlement progress and payout buttons."
          />
        </Card>
      ) : (
        <>
          {inProgress.length > 0 && (
            <section className="space-y-3">
              <h2 className="label px-1">Being settled · {inProgress.length}</h2>
              {inProgress.map(({ g, data, mine }) => (
                <GroupCard key={g.groupId} group={g} g={data} mine={mine} now={now} />
              ))}
            </section>
          )}
          {finished.length > 0 && (
            <section className="space-y-2">
              <h2 className="label px-1">Paid out · {finished.length}</h2>
              <div className="card divide-y divide-line/60 p-1.5">
                {finished.map(({ g, data }) => (
                  <FinishedRow key={g.groupId} group={g} g={data!} />
                ))}
              </div>
            </section>
          )}
        </>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ upcoming expiries, one line per date

function Upcoming({ groups, now }: { groups: Group[]; now: bigint }) {
  const byExpiry = useMemo(() => {
    const m = new Map<bigint, { count: number; symbols: Set<string> }>();
    for (const g of groups) {
      if (g.expiry <= now) continue;
      const e = m.get(g.expiry) ?? { count: 0, symbols: new Set<string>() };
      e.count += g.series.length;
      e.symbols.add(g.series[0]!.underlyingSymbol);
      m.set(g.expiry, e);
    }
    return [...m.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1)).slice(0, 3);
  }, [groups, now]);
  if (byExpiry.length === 0) return null;
  return (
    <div className="card p-3">
      <div className="label mb-2 px-1">Coming up</div>
      <ul className="grid gap-1.5 sm:grid-cols-3">
        {byExpiry.map(([expiry, e]) => (
          <li key={expiry.toString()} className="flex items-center gap-2.5 rounded-xl border border-line bg-surface-2/60 px-3 py-2">
            <Clock className="h-4 w-4 shrink-0 text-primary" />
            <span className="min-w-0">
              <span className="block truncate text-[13px] font-semibold">{fmtExpiry(expiry)}</span>
              <span className="block truncate text-xs text-muted">
                in {fmtDuration(expiry - now)} · {e.count} option{e.count === 1 ? "" : "s"} · {[...e.symbols].join(", ")}
              </span>
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ------------------------------------------------------------------ one expired group

const pairOf = (s: Series) => `${s.underlyingSymbol}/${s.assetSymbol}`;

function GroupCard({ group, g, mine, now }: { group: Group; g?: GroupData; mine: { series: Series; balance: bigint }[]; now: bigint }) {
  const s0 = group.series[0]!;
  const { data: ins } = useQuery({ queryKey: ["insurance", s0.settlementAsset], queryFn: () => getInsurance(s0.settlementAsset) });
  const { data: earliest } = useQuery({
    queryKey: ["earliest", group.groupId],
    queryFn: () =>
      publicClient.readContract({
        address: ADDR.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "earliestFinalization",
        args: [s0.settlementOracleConfigId, s0.expiry],
      }),
  });
  const holders = useQuery({
    queryKey: ["holders", group.groupId, g?.participants.toString()],
    queryFn: () => getHolders(group.series.map((s) => s.id)),
    enabled: g?.state === "FINALIZED",
  });

  // Before offering "Fix the settlement price", check the price can actually be proven (the feed has a round in force
  // inside the observation window), so the button never fails with a vague error.
  const needsPrice = g?.state === "EXPIRED" || g?.state === "ORACLE_STALLED";
  const pastWait = earliest !== undefined && now >= BigInt(earliest);
  const proof = useQuery({
    queryKey: ["settleProof", group.groupId],
    queryFn: () => buildSettlementProof(publicClient, ADDR.settlementOracle, s0.settlementOracleConfigId, s0.expiry),
    enabled: needsPrice && pastWait,
    refetchInterval: 15_000,
  });
  const unprovable = needsPrice && pastWait ? proof.data?.error : undefined;

  if (!g) return <Card><Skeleton className="h-40 w-full" /></Card>;
  const a = g.accounting;
  const asset = s0.assetSymbol;
  const dec = s0.assetDecimals;
  const waitLeft = earliest !== undefined && now < BigInt(earliest) ? BigInt(earliest) - now : 0n;
  const canFinalize = needsPrice && pastWait && !!proof.data && !unprovable;
  const unprovableText = unprovable
    ? `${ERROR_MESSAGES[unprovable.split("(")[0]!] ?? "The price can't be proven yet."} Bots will fix it automatically as soon as it can be done.`
    : undefined;
  const reward = (x?: bigint) => (x !== undefined ? `${fmtNative(x, dec)} ${asset}` : "a small reward");
  const left = Number(g.participants);
  const batch = Math.min(BATCH, left);

  // What is happening now, and the one action that moves it forward.
  let status: { tone: "wait" | "act" | "bad" | "done"; text: React.ReactNode; action?: React.ReactNode };
  switch (g.state) {
    case "EXPIRED":
      status = waitLeft > 0n
        ? { tone: "wait", text: <>Waiting {fmtDuration(waitLeft)} so the expiry price is final. Then the price can be fixed.</> }
        : unprovableText
        ? { tone: "wait", text: <>{unprovableText}</> }
        : {
            tone: "act",
            text: <>Next: record the official {s0.underlyingSymbol} price at expiry. Bots usually do this; anyone can, and earns {reward(ins?.finalizeReward)}.</>,
          };
      status.action = (
        <TxButton
          label="Fix the settlement price"
          steps={finalizeSteps(group.groupId, s0.settlementOracleConfigId, s0.expiry)}
          disabled={!canFinalize}
          disabledReason={waitLeft > 0n ? `Available in ${fmtDuration(waitLeft)}.` : unprovable ? "No provable price yet." : proof.isLoading ? "Checking the price feed…" : undefined}
          successMessage="Settlement price fixed."
        />
      );
      break;
    case "ORACLE_STALLED":
      status = {
        tone: "bad",
        text: <>The price feed has not produced a usable price for this expiry yet. Funds are safe. Anyone can fix the price as soon as it does.{unprovable ? "" : " It can be fixed now."}</>,
        action: (
          <TxButton
            label="Fix the settlement price"
            steps={finalizeSteps(group.groupId, s0.settlementOracleConfigId, s0.expiry)}
            disabled={!canFinalize}
            successMessage="Settlement price fixed."
          />
        ),
      };
      break;
    case "FINALIZED":
      status = {
        tone: "act",
        text: (
          <>
            Price fixed at <b className="text-ink">${fmtLevel(a.priceWad)}</b>. Now {left} account{left === 1 ? "" : "s"} with positions{" "}
            {left === 1 ? "is" : "are"} settled: writers pay what they owe. Anyone can help and earns {reward(ins?.settleReward)}+ per account.
          </>
        ),
        action: (
          <TxButton
            label={`Settle ${batch === left ? "all" : `the next ${batch} of`} ${left} account${left === 1 ? "" : "s"}`}
            steps={holders.data?.length ? settleBatchSteps(group.groupId, holders.data.slice(0, BATCH)) : undefined}
            disabled={!holders.data?.length}
            disabledReason={holders.isLoading ? "Finding the accounts to settle…" : undefined}
            successMessage="Accounts settled."
          />
        ),
      };
      break;
    case "ALL_SETTLED":
      status = {
        tone: "act",
        text: <>Every account is settled. One last step works out the payout rate and opens payouts.</>,
        action: <TxButton label="Open payouts" steps={ratioSteps(group.groupId)} successMessage="Payouts are open." />,
      };
      break;
    default:
      status = {
        tone: "done",
        text:
          a.ratioWad === 10n ** 18n
            ? <>Payouts are open. Every holder is paid in full.</>
            : <>Payouts are open at {fmtWad(a.ratioWad * 100n, 2)}% of the full amount, because some writers could not pay what they owed.</>,
      };
  }

  return (
    <article className="card overflow-hidden">
      <header className="flex flex-wrap items-start justify-between gap-2 p-4 pb-3 sm:p-5 sm:pb-3">
        <div className="flex items-center gap-2.5">
          <TokenIcon symbol={s0.underlyingSymbol} className="h-8 w-8" />
          <div>
            <h3 className="font-display text-base font-bold tracking-tight">{pairOf(s0)}</h3>
            <p className="text-xs text-muted">
              Expired {fmtExpiry(s0.expiry)} · {group.series.length} option{group.series.length === 1 ? "" : "s"}
            </p>
          </div>
        </div>
        <StatePill state={g.state} />
      </header>

      <div className="space-y-3 px-4 pb-4 sm:px-5 sm:pb-5">
        <SettlementTimeline state={g.state} />

        <div
          className={cx(
            "rounded-2xl border p-3.5 text-[13px] leading-relaxed",
            status.tone === "bad" && "border-bad/30 bg-bad/8 text-bad",
            status.tone === "act" && "border-primary/30 bg-primary-soft/60",
            status.tone === "wait" && "border-line bg-surface-2/60 text-muted",
            status.tone === "done" && "border-good/30 bg-good/8",
          )}
        >
          <p>{status.text}</p>
          {status.action && <div className="mt-3">{status.action}</div>}
        </div>

        {mine.length > 0 && <YourOptions mine={mine} g={g} />}

        {a.finalized ? (
          <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            <Fact label="Settlement price" value={`$${fmtLevel(a.priceWad)}`} />
            <Fact
              label={<Term tip="Accounts that still have to be settled before payouts open.">Accounts left</Term>}
              value={left === 0 ? "None" : left.toString()}
            />
            <Fact
              label={<Term tip="Share of the full payout every holder receives. It is 100% unless some writers' losses were bigger than their collateral and the insurance fund together.">Payout rate</Term>}
              value={a.ratioSet ? `${fmtWad(a.ratioWad * 100n, 2)}%` : "Set at step 4"}
              tone={a.ratioSet ? (a.ratioWad === 10n ** 18n ? "text-good" : "text-warn") : undefined}
            />
            <Fact
              label={<Term tip="How much the insurance fund paid in to cover writers who couldn't pay in full.">Insurance used</Term>}
              value={a.ratioSet ? `${fmtNative(a.insurance, dec)} ${asset}` : "Set at step 4"}
            />
          </dl>
        ) : (
          <p className="px-1 text-xs text-muted">
            {left === 0 ? "No account holds positions in this expiry." : `${left} account${left === 1 ? "" : "s"} hold${left === 1 ? "s" : ""} positions in this expiry.`}{" "}
            Prices and payouts appear here once the price is fixed.
          </p>
        )}
      </div>
    </article>
  );
}

function Fact({ label, value, tone }: { label: React.ReactNode; value: React.ReactNode; tone?: string }) {
  return (
    <div className="rounded-xl border border-line bg-surface-2/60 px-3 py-2">
      <dt className="text-[11px] text-muted">{label}</dt>
      <dd className={cx("num mt-0.5 text-[13px] font-semibold", tone)}>{value}</dd>
    </div>
  );
}

/** The connected wallet's options in this expiry, with what each pays once the price is fixed. */
function YourOptions({ mine, g }: { mine: { series: Series; balance: bigint }[]; g: GroupData }) {
  const a = g.accounting;
  const price = a.finalized ? Number(a.priceWad) / 1e18 : undefined;
  const ratio = a.ratioSet ? Number(a.ratioWad) / 1e18 : 1;
  const open = g.state === "REDEEMABLE";
  return (
    <div className={cx("rounded-2xl border p-3.5", open ? "border-good/40 bg-good/8" : "border-line bg-surface-2/60")}>
      <div className="mb-1.5 flex items-center gap-1.5 text-[13px] font-semibold">
        <Wallet className="h-4 w-4 text-primary" /> Your options in this expiry
      </div>
      <ul className="divide-y divide-line/60">
        {mine.map(({ series: s, balance }) => {
          const qty = Number(balance) / 1e18;
          const pays = price !== undefined ? payoutPerOption(legOf(s), price) * qty * ratio : undefined;
          return (
            <li key={s.id} className="flex items-center justify-between gap-3 py-2 text-[13px]">
              <span className="min-w-0">
                <span className="block font-semibold">
                  ${fmtLevel(s.strikeWad)} {optionTypeName(s.optionType)}
                </span>
                <span className="block text-xs text-muted">
                  {fmtQty(balance)} option{balance === 10n ** 18n ? "" : "s"} ·{" "}
                  {pays === undefined ? "payout known once the price is fixed" : pays === 0 ? "pays nothing" : `pays ${usd(pays)}${a.ratioSet ? "" : " (estimate)"}`}
                </span>
              </span>
              {open && pays !== 0 ? (
                <Link to={`/app/series/${s.id}?tab=redeem`} className="btn-primary shrink-0 !px-3 !py-1.5 text-xs">
                  Redeem
                </Link>
              ) : (
                <Link to={`/app/series/${s.id}?tab=redeem`} className="shrink-0 text-xs font-semibold text-primary">
                  View
                </Link>
              )}
            </li>
          );
        })}
      </ul>
      {!open && <p className="mt-1 text-xs text-muted">You can redeem once payouts open. Nothing to do until then.</p>}
    </div>
  );
}

/** A group that is fully paid out and holds nothing of yours: one compact line. */
function FinishedRow({ group, g }: { group: Group; g: GroupData }) {
  const s0 = group.series[0]!;
  const a = g.accounting;
  return (
    <div className="flex items-center gap-2.5 px-2.5 py-2.5 text-[13px]">
      <CheckCircle2 className="h-4 w-4 shrink-0 text-good" />
      <TokenIcon symbol={s0.underlyingSymbol} className="h-5 w-5" />
      <span className="min-w-0 flex-1">
        <span className="block truncate font-semibold">
          {pairOf(s0)} · {fmtExpiry(s0.expiry)}
        </span>
        <span className="block truncate text-xs text-muted">
          Settled at ${fmtLevel(a.priceWad)} · paid {a.ratioWad === 10n ** 18n ? "in full" : `${fmtWad(a.ratioWad * 100n, 2)}%`}
        </span>
      </span>
    </div>
  );
}
