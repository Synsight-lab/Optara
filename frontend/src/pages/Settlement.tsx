/** `/settlement`: expired groups — finalize, settle in batches, open payouts, redeem/claim (FRONTEND.md §8, F13). */
import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router";
import { useQueries, useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { buildSettlementProof, settlementOracleAbi } from "@optara/sdk";
import { CheckCircle2, ChevronDown, Clock, Wallet } from "lucide-react";
import { Card, EmptyState, Pill, Segmented, Skeleton, Term, cx } from "../components/ui.tsx";
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
/** Expiries shown per page; "Show more" adds the next page. */
const PAGE = 6;

type Tab = "action" | "mine" | "done" | "all";

/** What the expiry's pool took in and paid out, in the settlement asset's native units. */
function payoutTotals(a: GroupData["accounting"]) {
  const total = a.collected + a.insurance; // what holders and creditors are paid from
  const left = a.pool; // still waiting to be redeemed or claimed
  return { total, left, paid: total > left ? total - left : 0n };
}

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
  const [tab, setTab] = useState<Tab | undefined>();
  const [shown, setShown] = useState(PAGE);

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
    queries: expired.map((g) => ({ queryKey: ["group", g.groupId], queryFn: () => getGroup(g.groupId), refetchInterval: 15_000 })),
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
  const mineRows = rows.filter((r) => r.mine.length > 0);
  // Open on what matters most to this visitor: their payouts, then expiries still being settled, then everything.
  const active: Tab = tab ?? (readyForYou.length > 0 ? "mine" : inProgress.length > 0 ? "action" : "all");
  const list = active === "action" ? inProgress : active === "mine" ? mineRows : active === "done" ? finished : rows;
  const page = list.slice(0, shown);

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="px-1">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">Settlement</h1>
            <p className="mt-0.5 text-[13px] text-muted">
              Expired options move from price finalization to cash payouts here.
            </p>
          </div>
          <Pill tone={readyForYou.length > 0 ? "good" : inProgress.length > 0 ? "primary" : "neutral"} dot={readyForYou.length > 0}>
            {readyForYou.length > 0 ? `${readyForYou.length} ready for you` : inProgress.length > 0 ? `${inProgress.length} active` : "No action"}
          </Pill>
        </div>
      </div>

      <SettlementSummary expired={expired.length} active={inProgress.length} ready={readyForYou.length} paid={finished.length} />

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

      <SettlementGuide />

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
          <div className="flex flex-wrap items-center justify-between gap-2 px-1">
            <Segmented
              size="sm"
              value={active}
              onChange={(v) => {
                setTab(v);
                setShown(PAGE);
              }}
              options={[
                { value: "action", label: `To settle ${inProgress.length}` },
                { value: "mine", label: `Yours ${mineRows.length}`, disabled: !address, title: address ? undefined : "Connect a wallet to see your expiries" },
                { value: "done", label: `Paid out ${finished.length}` },
                { value: "all", label: `All ${rows.length}` },
              ]}
            />
            <span className="text-xs text-muted">
              Showing {Math.min(shown, list.length)} of {list.length}, newest first
            </span>
          </div>
          {page.length === 0 ? (
            <Card>
              <EmptyState
                icon="✓"
                title={active === "action" ? "Nothing waiting to be settled" : active === "mine" ? "None of your options have expired" : "Nothing here yet"}
                body={active === "action" ? "Every expired option has been settled and its payouts are open." : undefined}
              />
            </Card>
          ) : (
            <section className="space-y-2.5">
              {page.map(({ g, data, mine }) =>
                data?.state === "REDEEMABLE" && mine.length === 0 ? (
                  <FinishedRow key={g.groupId} group={g} g={data} />
                ) : (
                  <GroupCard key={g.groupId} group={g} g={data} mine={mine} now={now} defaultOpen={mine.length > 0 || (data !== undefined && data.state !== "REDEEMABLE")} />
                ),
              )}
            </section>
          )}
          {list.length > shown && (
            <div className="flex justify-center">
              <button type="button" onClick={() => setShown((n) => n + PAGE)} className="btn-ghost text-xs">
                Show {Math.min(PAGE, list.length - shown)} more ({list.length - shown} left)
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function SettlementSummary({ expired, active, ready, paid }: { expired: number; active: number; ready: number; paid: number }) {
  const items = [
    { label: "Expired", value: expired, sub: "groups", tone: "neutral" as const },
    { label: "Settling", value: active, sub: "in progress", tone: active > 0 ? ("primary" as const) : ("neutral" as const) },
    { label: "Ready", value: ready, sub: "for you", tone: ready > 0 ? ("good" as const) : ("neutral" as const) },
    { label: "Paid", value: paid, sub: "complete", tone: paid > 0 ? ("good" as const) : ("neutral" as const) },
  ];
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
      {items.map((x) => (
        <div key={x.label} className="rounded-2xl border border-line bg-gradient-to-br from-surface to-surface-2/55 p-2.5 shadow-sm sm:p-3">
          <div className="flex items-center justify-between gap-2">
            <div className="text-[11px] font-bold uppercase text-faint">{x.label}</div>
            <span className={cx("h-2 w-2 rounded-full", x.tone === "good" ? "bg-good" : x.tone === "primary" ? "bg-primary" : "bg-faint/40")} />
          </div>
          <div className={cx("num mt-0.5 font-display text-xl font-bold sm:mt-1 sm:text-2xl", x.tone === "good" ? "text-good" : x.tone === "primary" ? "text-primary" : "")}>{x.value}</div>
          <div className="text-[11px] text-muted">{x.sub}</div>
        </div>
      ))}
    </div>
  );
}

function SettlementGuide() {
  const steps = [
    ["1", "Price", "expiry price fixed"],
    ["2", "Settle", "accounts netted"],
    ["3", "Ratio", "payout rate opens"],
    ["4", "Redeem", "holders claim cash"],
  ];
  return (
    <div className="rounded-3xl border border-line bg-gradient-to-br from-surface to-surface-2/50 p-3.5">
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div>
          <div className="font-display text-sm font-bold">Settlement path</div>
          <p className="text-xs text-muted">Bots normally move expired markets through this path. You can help when an action is available.</p>
        </div>
        <div className="grid grid-cols-4 gap-1.5 md:min-w-[520px]">
          {steps.map(([n, t, d], i) => (
            <div key={n} className="relative rounded-2xl border border-line bg-surface/80 px-2 py-2.5 text-center">
              {i > 0 && <span className="absolute -left-1.5 top-1/2 hidden h-px w-3 bg-line md:block" />}
              <div className="mx-auto grid h-6 w-6 place-items-center rounded-full bg-primary-soft text-xs font-bold text-primary">{n}</div>
              <div className="mt-1 text-xs font-bold">{t}</div>
              <div className="hidden truncate text-[11px] text-muted sm:block">{d}</div>
            </div>
          ))}
        </div>
      </div>
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

function GroupCard({
  group,
  g,
  mine,
  now,
  defaultOpen = true,
}: {
  group: Group;
  g?: GroupData;
  mine: { series: Series; balance: bigint }[];
  now: bigint;
  defaultOpen?: boolean;
}) {
  const s0 = group.series[0]!;
  const [open, setOpen] = useState(defaultOpen);
  useEffect(() => setOpen(defaultOpen), [defaultOpen]);
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

  const totals = payoutTotals(a);
  const money = (x: bigint) => `${fmtNative(x, dec)} ${asset}`;
  // One line that says where this expiry stands, shown even when the card is folded.
  const summary =
    g.state === "REDEEMABLE"
      ? totals.total === 0n
        ? "Settled · nothing was owed"
        : `Paid out ${money(totals.paid)} of ${money(totals.total)}`
      : g.state === "ALL_SETTLED"
      ? `${money(totals.total)} ready to pay out`
      : g.state === "FINALIZED"
      ? `Price $${fmtLevel(a.priceWad)} · ${left} account${left === 1 ? "" : "s"} to settle`
      : g.state === "ORACLE_STALLED"
      ? "Waiting for the price feed"
      : waitLeft > 0n
      ? `Price can be fixed in ${fmtDuration(waitLeft)}`
      : "Waiting for the settlement price";

  return (
    <article className="card overflow-hidden bg-gradient-to-br from-surface to-surface-2/45">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex w-full flex-wrap items-center justify-between gap-2 p-4 text-left cursor-pointer"
      >
        <span className="flex min-w-0 items-center gap-2.5">
          <TokenIcon symbol={s0.underlyingSymbol} className="h-8 w-8" />
          <span className="min-w-0">
            <span className="block font-display text-base font-bold tracking-tight">
              {pairOf(s0)}
              {mine.length > 0 && <span className="ml-2 rounded-full bg-primary-soft px-2 py-0.5 align-middle text-[11px] font-bold text-primary">Yours</span>}
            </span>
            <span className="block text-xs text-muted sm:truncate">
              Expired {fmtExpiry(s0.expiry)} · {group.series.length} option{group.series.length === 1 ? "" : "s"} · {summary}
            </span>
          </span>
        </span>
        <span className="flex items-center gap-2">
          <StatePill state={g.state} />
          <ChevronDown className={cx("h-4 w-4 text-faint transition", open && "rotate-180")} />
        </span>
      </button>

      {open && (
      <div className="space-y-2.5 px-4 pb-4">
        <SettlementTimeline state={g.state} />

        <div
          className={cx(
            "rounded-2xl border p-3 text-[13px] leading-relaxed shadow-sm",
            status.tone === "bad" && "border-bad/30 bg-bad/8 text-bad",
            status.tone === "act" && "border-primary/30 bg-primary-soft/60",
            status.tone === "wait" && "border-line bg-surface-2/60 text-muted",
            status.tone === "done" && "border-good/30 bg-good/8",
          )}
        >
          <p>{status.text}</p>
          {status.action && <div className="mt-2.5">{status.action}</div>}
        </div>

        {mine.length > 0 && <YourOptions mine={mine} g={g} />}

        {a.finalized ? (
          <dl className="grid grid-cols-2 gap-2 lg:grid-cols-4">
            <Fact label="Settlement price" value={`$${fmtLevel(a.priceWad)}`} />
            <Fact
              label={<Term tip="What writers who ended in the money paid into this expiry's payout pool from their accounts.">Writers paid in</Term>}
              value={money(a.collected)}
            />
            <Fact
              label={<Term tip="What writers owed but could not cover from their accounts. The insurance fund covers it first.">Writers could not pay</Term>}
              value={money(a.unpaid)}
              tone={a.unpaid > 0n ? "text-warn" : undefined}
            />
            <Fact
              label={<Term tip="The total paid to option holders and to accounts that are owed money: writers' payments plus any insurance.">Total for holders</Term>}
              value={a.ratioSet ? money(totals.total) : "Known at step 3"}
            />
            <Fact
              label={<Term tip="How much holders have already redeemed or claimed from this expiry.">Paid out so far</Term>}
              value={a.ratioSet ? money(totals.paid) : "Not open yet"}
              tone={a.ratioSet && totals.paid > 0n ? "text-good" : undefined}
            />
            <Fact
              label={<Term tip="What is still waiting for holders to redeem or claim. It stays available; there is no deadline.">Still to redeem</Term>}
              value={a.ratioSet ? money(totals.left) : "Not open yet"}
            />
            <Fact
              label={<Term tip="Accounts that still have to be settled before payouts open.">Accounts left</Term>}
              value={left === 0 ? "None" : left.toString()}
            />
            <Fact
              label={<Term tip="Share of the full payout every holder receives. It is 100% unless some writers' losses were bigger than their collateral and the insurance fund together.">Payout rate</Term>}
              value={a.ratioSet ? `${fmtWad(a.ratioWad * 100n, 2)}%` : "Set at step 3"}
              tone={a.ratioSet ? (a.ratioWad === 10n ** 18n ? "text-good" : "text-warn") : undefined}
            />
            <Fact
              label={<Term tip="How much the insurance fund paid in to cover writers who couldn't pay in full.">Insurance added</Term>}
              value={a.ratioSet ? money(a.insurance) : "Set at step 3"}
            />
          </dl>
        ) : (
          <p className="px-1 text-xs text-muted">
            {left === 0 ? "No account holds positions in this expiry." : `${left} account${left === 1 ? "" : "s"} hold${left === 1 ? "s" : ""} positions in this expiry.`}{" "}
            Prices and payouts appear here once the price is fixed.
          </p>
        )}
      </div>
      )}
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

/** A group whose payouts are open and that holds nothing of yours: one compact line with what it paid out. */
function FinishedRow({ group, g }: { group: Group; g: GroupData }) {
  const s0 = group.series[0]!;
  const a = g.accounting;
  const t = payoutTotals(a);
  const money = (x: bigint) => `${fmtNative(x, s0.assetDecimals)} ${s0.assetSymbol}`;
  return (
    <div className="card flex flex-wrap items-center gap-x-3 gap-y-1.5 px-3.5 py-3 text-[13px]">
      <CheckCircle2 className="h-4 w-4 shrink-0 text-good" />
      <TokenIcon symbol={s0.underlyingSymbol} className="h-5 w-5" />
      <span className="min-w-0 flex-1">
        <span className="block font-semibold sm:truncate">
          {pairOf(s0)} · {fmtExpiry(s0.expiry)} · {group.series.length} option{group.series.length === 1 ? "" : "s"}
        </span>
        <span className="block text-xs text-muted sm:truncate">
          Settled at ${fmtLevel(a.priceWad)} · {a.ratioWad === 10n ** 18n ? "paid in full" : `paid at ${fmtWad(a.ratioWad * 100n, 2)}%`}
          {a.insurance > 0n ? ` · insurance added ${money(a.insurance)}` : ""}
        </span>
      </span>
      <span className="w-full pl-[52px] sm:w-auto sm:pl-0 sm:text-right">
        {t.total === 0n ? (
          <span className="block text-xs text-muted">Nothing was owed</span>
        ) : (
          <>
            <span className="num block font-semibold text-good">{money(t.paid)} paid out</span>
            <span className="block text-xs text-muted">{t.left > 0n ? `${money(t.left)} still to redeem` : "all redeemed"}</span>
          </>
        )}
      </span>
    </div>
  );
}
