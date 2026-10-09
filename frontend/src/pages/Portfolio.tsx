/** `/portfolio`: accounts, health, collateral, positions, wallet tokens and what needs doing (FRONTEND.md §2, §5). */
import { useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useConnection } from "wagmi";
import { useQueries, useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import {
  AlertTriangle,
  ArrowDownRight,
  ArrowUpRight,
  CheckCircle2,
  BarChart3,
  Clock,
  Coins,
  ExternalLink,
  HelpCircle,
  Plus,
  RotateCcw,
  Shield,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
  TrendingDown,
  TrendingUp,
  Wallet,
} from "lucide-react";
import { AmountInput, Card, EmptyState, Pill, Segmented, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { PnlCard } from "../components/PnlCard.tsx";
import { KuruBalances } from "../components/KuruBalances.tsx";
import { AuctionNotice } from "../components/AuctionNotice.tsx";
import { subAccountsAbi } from "@optara/sdk";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { TxButton } from "../components/TxButton.tsx";
import { createAccountStep, createdAccountId, depositSteps, setupAccountSteps, withdrawSteps } from "../lib/optara/actions.ts";
import { fmtExpiry, fmtLevel, fmtNative, fmtQty, fmtWad, optionTypeName, parseFixed, seriesName, WAD } from "../lib/optara/format.ts";
import {
  useAccountView,
  useLiquidationSpots,
  useProductMarket,
  useSeriesList,
  useTokenBalance,
  useWalletWrappers,
} from "../lib/optara/hooks.ts";
import { getAccount, getGroupState, getSeriesMarket, type AccountView } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { StatePill } from "./Series.tsx";

export function PortfolioPage() {
  const { address, isConnected } = useConnection();
  const { accounts, selected, select, loading, refresh } = useAccountState();
  const { data: series } = useSeriesList();
  const asset = series?.[0];
  const { open: openGuide } = useQuickGuide();

  if (!isConnected) {
    return (
      <div className="w-full py-12">
        <Card className="text-center p-8">
          <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-3xl bg-primary-soft text-primary mb-4">
            <Wallet className="h-8 w-8" />
          </div>
          <h2 className="text-2xl font-bold tracking-tight">Connect Your Wallet</h2>
          <p className="mt-2 text-sm text-muted max-w-sm mx-auto">
            Connect a wallet to view your active options, margin health, collateral balances, and wallet tokens.
          </p>
          <div className="mt-6 flex justify-center">
            <button onClick={openGuide} className="text-xs text-primary hover:underline flex items-center gap-1">
              <HelpCircle className="h-3.5 w-3.5" /> Learn how Optara portfolio accounts work
            </button>
          </div>
        </Card>
      </div>
    );
  }

  if (loading || !asset) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-24 w-full rounded-3xl" />
        <Skeleton className="h-72 w-full rounded-3xl" />
      </div>
    );
  }

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="flex flex-wrap items-end justify-between gap-3 px-1">
        <div>
          <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">Portfolio</h1>
          <p className="mt-0.5 text-[13px] text-muted">
            Margin health, collateral and open contracts in one place.
          </p>
        </div>

        {/* Account switcher */}
        <div className="flex flex-wrap items-center gap-2">
          {accounts.length > 0 && (
            <Segmented
              value={(selected ?? accounts[0]!).toString()}
              onChange={(v) => select(BigInt(v))}
              options={accounts.map((a) => ({ value: a.toString(), label: `Account #${a}` }))}
            />
          )}
          {accounts.length > 0 && (
            <NewAccountButton
              asset={asset}
              onCreated={async (id) => {
                select(id);
                await refresh();
              }}
            />
          )}
        </div>
      </div>

      <PnlCard owner={address!} accounts={accounts} series={series ?? []} />

      <PortfolioOverview owner={address!} accounts={accounts} series={series ?? []} asset={asset} selected={selected} select={select} />

      {/* Main Account View or Onboarding */}
      {accounts.length === 0 ? (
        <Onboarding asset={asset} />
      ) : (
        selected !== undefined && <AccountDashboard accountId={selected} asset={asset} owner={address!} />
      )}

      {/* Option Tokens in User's Wallet */}
      <WalletTokens owner={address!} />

      <KuruBalances owner={address!} series={series ?? []} />
    </div>
  );
}

function NewAccountButton({ asset, onCreated }: { asset: Series; onCreated: (id: bigint) => void }) {
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <button className="btn-ghost text-xs" onClick={() => setOpen(true)}>
        <Plus className="h-3.5 w-3.5" /> New account
      </button>
    );
  }
  return (
    <div className="w-full sm:w-64">
      <TxButton
        label="Create Another Account"
        steps={[createAccountStep(asset.settlementAsset)]}
        successMessage="New account created!"
        onDone={(r) => {
          const id = createdAccountId(r[0]!);
          setOpen(false);
          if (id !== undefined) onCreated(id);
        }}
      />
    </div>
  );
}

function PortfolioOverview({
  owner,
  accounts,
  series,
  asset,
  selected,
  select,
}: {
  owner: Hex;
  accounts: bigint[];
  series: Series[];
  asset: Series;
  selected: bigint | undefined;
  select: (id: bigint) => void;
}) {
  const seriesById = useMemo(() => new Map(series.map((s) => [s.id, s])), [series]);
  const accountQueries = useQueries({
    queries: accounts.map((id) => ({
      queryKey: ["portfolioOverviewAccount", id.toString(), series.length],
      queryFn: () => getAccount(id, seriesById),
      enabled: seriesById.size > 0,
      refetchInterval: 15_000,
    })),
  });
  const accountViews = accountQueries.map((q) => q.data).filter((x): x is AccountView => !!x);
  const { data: walletRows } = useWalletWrappers(owner);

  const totals = useMemo(() => summarizePortfolio(accountViews, walletRows ?? []), [accountViews, walletRows]);
  const loading = accountQueries.some((q) => q.isLoading);

  return (
    <section className="card rise overflow-hidden p-4">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <div className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary-soft px-3 py-1 text-xs font-bold text-primary">
            <BarChart3 className="h-3.5 w-3.5" /> Portfolio map
          </div>
          <p className="mt-2 max-w-2xl text-[13px] leading-5 text-muted">
            Compact view of wallet options, margin positions and accounts.
          </p>
        </div>
        <div className="grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-4 lg:min-w-[520px]">
          <OverviewStat label="Accounts" value={accounts.length.toString()} sub={loading ? "loading" : `${accountViews.length} loaded`} />
          <OverviewStat label="Wallet longs" value={fmtQty(totals.walletLongQty)} sub="wallet" tone={totals.walletLongQty > 0n ? "good" : undefined} />
          <OverviewStat label="Account longs" value={fmtQty(totals.accountLongQty)} sub="margin" tone={totals.accountLongQty > 0n ? "good" : undefined} />
          <OverviewStat label="Written" value={fmtQty(totals.shortQty)} sub="short" tone={totals.shortQty > 0n ? "warn" : undefined} />
        </div>
      </div>

      <div className="mt-3 grid gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(300px,0.85fr)]">
        <ExposureBars exposures={totals.exposures} />
        <div className="rounded-2xl border border-line bg-surface-2/45 p-3">
          <div className="mb-2 flex items-center justify-between gap-2">
            <span className="text-sm font-bold">Accounts</span>
            <Pill tone={totals.riskyAccounts > 0 ? "warn" : "good"}>{totals.riskyAccounts > 0 ? `${totals.riskyAccounts} need care` : "All clear"}</Pill>
          </div>
          {accounts.length === 0 ? (
            <div className="rounded-xl border border-line bg-surface p-3 text-sm text-muted">No margin accounts yet.</div>
          ) : (
            <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-none">
              {accountViews.map((a) => (
                <button
                  key={a.id.toString()}
                  type="button"
                  onClick={() => select(a.id)}
                  className={cx(
                    "min-w-[190px] rounded-xl border p-2.5 text-left transition hover:border-primary/40 hover:bg-primary-soft/30",
                    selected === a.id ? "border-primary/50 bg-primary-soft" : "border-line bg-surface",
                  )}
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="font-bold">#{a.id.toString()}</div>
                    <Pill tone={a.health.state === "HEALTHY" ? "good" : a.health.state === "CLOSE_ONLY" ? "warn" : "bad"}>
                      {a.health.state === "HEALTHY" ? "Healthy" : a.health.state === "CLOSE_ONLY" ? "Close-only" : "Risk"}
                    </Pill>
                  </div>
                  <div className="mt-1 text-xs text-muted">{a.positions.length} position{a.positions.length === 1 ? "" : "s"} · {fmtNative(a.cash, asset.assetDecimals)} {asset.assetSymbol}</div>
                  <div className="mt-2 h-1.5 rounded-full bg-surface-2">
                    <div className={cx("h-full rounded-full", a.health.state === "HEALTHY" ? "bg-good" : a.health.state === "CLOSE_ONLY" ? "bg-warn" : "bg-bad")} style={{ width: `${accountSafetyPct(a)}%` }} />
                  </div>
                </button>
              ))}
              {loading && <Skeleton className="h-20 min-w-[190px]" />}
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function summarizePortfolio(accounts: AccountView[], walletRows: { series: Series; balance: bigint }[]) {
  const out = {
    walletLongQty: 0n,
    accountLongQty: 0n,
    shortQty: 0n,
    riskyAccounts: 0,
    exposures: new Map<string, { long: bigint; short: bigint; symbol: string }>(),
  };
  const add = (s: Series, long: bigint, short: bigint) => {
    const key = s.underlying.toLowerCase();
    const prev = out.exposures.get(key) ?? { long: 0n, short: 0n, symbol: s.underlyingSymbol };
    prev.long += long * s.contractSizeWad / WAD;
    prev.short += short * s.contractSizeWad / WAD;
    out.exposures.set(key, prev);
  };
  for (const row of walletRows) {
    out.walletLongQty += row.balance;
    add(row.series, row.balance, 0n);
  }
  for (const a of accounts) {
    if (a.health.state !== "HEALTHY") out.riskyAccounts++;
    for (const p of a.positions) {
      if (p.balance > 0n) {
        out.accountLongQty += p.balance;
        add(p.series, p.balance, 0n);
      } else if (p.balance < 0n) {
        const q = -p.balance;
        out.shortQty += q;
        add(p.series, 0n, q);
      }
    }
  }
  return out;
}

function OverviewStat({ label, value, sub, tone }: { label: string; value: string; sub: string; tone?: "good" | "warn" }) {
  return (
    <div className="min-w-0 rounded-2xl border border-line bg-surface-2/60 p-3">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className={cx("num mt-1 truncate font-display text-xl font-bold", tone === "good" ? "text-good" : tone === "warn" ? "text-warn" : "")} title={value}>{value}</div>
      <div className="mt-0.5 truncate text-[11px] text-muted">{sub}</div>
    </div>
  );
}

function ExposureBars({ exposures }: { exposures: Map<string, { long: bigint; short: bigint; symbol: string }> }) {
  const rows = [...exposures.values()].filter((x) => x.long > 0n || x.short > 0n).sort((a, b) => Number((b.long + b.short) - (a.long + a.short)));
  const max = rows.reduce((m, r) => (r.long + r.short > m ? r.long + r.short : m), 0n);
  return (
    <div className="rounded-2xl border border-line bg-surface-2/50 p-4">
      <div className="flex items-center justify-between gap-2">
        <div>
          <div className="font-bold">Market exposure</div>
          <div className="text-xs text-muted">Underlying units controlled by your options.</div>
        </div>
        <Pill tone="primary">{rows.length} market{rows.length === 1 ? "" : "s"}</Pill>
      </div>
      {rows.length === 0 ? (
        <div className="mt-4 rounded-xl border border-dashed border-line p-4 text-sm text-muted">No exposure yet. Buy or write an option to see the map fill in.</div>
      ) : (
        <div className="mt-4 space-y-3">
          {rows.slice(0, 5).map((r) => {
            const longPct = max > 0n ? Number((r.long * 10_000n) / max) / 100 : 0;
            const shortPct = max > 0n ? Number((r.short * 10_000n) / max) / 100 : 0;
            return (
              <div key={r.symbol}>
                <div className="mb-1 flex items-center justify-between text-xs">
                  <span className="font-bold">{r.symbol}</span>
                  <span className="num text-muted">long {fmtQty(r.long)} · written {fmtQty(r.short)}</span>
                </div>
                <div className="grid grid-cols-2 gap-1">
                  <div className="flex justify-end rounded-l-full bg-surface">
                    <div className="h-2.5 rounded-l-full bg-good" style={{ width: `${longPct}%` }} />
                  </div>
                  <div className="rounded-r-full bg-surface">
                    <div className="h-2.5 rounded-r-full bg-warn" style={{ width: `${shortPct}%` }} />
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function accountSafetyPct(a: AccountView) {
  if (a.health.initialMargin === 0n) return 100;
  if (a.health.equity <= 0n) return 0;
  return Math.min(100, Math.max(0, Number((a.health.equity * 100n) / a.health.initialMargin)));
}

// ------------------------------------------------------------------ Onboarding for First-Time Users
function Onboarding({ asset }: { asset: Series }) {
  const { refresh, select } = useAccountState();
  const { address } = useConnection();
  const { data: balance } = useTokenBalance(asset.settlementAsset, address);
  const [amount, setAmount] = useState("1000");
  const deposit = parseFixed(amount, asset.assetDecimals);
  const created = useRef<bigint | undefined>(undefined);

  const steps = useMemo(
    () => (deposit ? setupAccountSteps(asset.settlementAsset, deposit, asset.assetSymbol, (id) => (created.current = id)) : undefined),
    [deposit, asset]
  );

  return (
    <div className="flex flex-col gap-3">
      <Card title="Open your margin account">
        <p className="mb-4 text-xs sm:text-sm text-muted leading-relaxed">
          <b className="text-ink">Buying options</b> requires zero account setup — tokens go straight to your wallet.
          To <b className="text-ink">write options and earn yield</b>, you maintain {asset.assetSymbol} collateral in an Optara margin account.
        </p>

        <div className="space-y-4">
          <AmountInput
            label="First deposit"
            value={amount}
            onChange={setAmount}
            unit={asset.assetSymbol}
            presets={["500", "1000", "2500", "5000"]}
            max={balance !== undefined ? fmtNative(balance, asset.assetDecimals).replace(/,/g, "") : undefined}
            maxLabel="Wallet"
          />

          <TxButton
            label="Create account & deposit"
            summary={deposit ? `New account, then ${fmtNative(deposit, asset.assetDecimals)} ${asset.assetSymbol} from your wallet into it` : undefined}
            steps={steps}
            disabled={!deposit}
            successMessage="Your margin account is ready."
            onDone={async () => {
              await refresh();
              if (created.current !== undefined) select(created.current);
            }}
          />
        </div>
      </Card>

      <Card title="Why margin?">
        <ul className="space-y-3.5 text-xs sm:text-sm">
          {[
            [
              "Less cash locked up",
              "The cash you need is worked out by stress-testing big price and volatility moves, not by locking the full worst case."
            ],
            [
              "Hedges count",
              "Options you own and options you wrote on the same asset offset each other, so a hedged account needs less."
            ],
            [
              "Premium is paid to you now",
              "When you write and sell, the premium goes to your wallet. Only cash inside the account protects it, so add some back if you like."
            ],
          ].map(([t, b]) => (
            <li key={t} className="flex gap-3">
              <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-primary" />
              <div>
                <span className="block font-semibold text-ink">{t}</span>
                <span className="block text-muted text-xs leading-relaxed mt-0.5">{b}</span>
              </div>
            </li>
          ))}
        </ul>

        <Link to="/app/markets" className="btn-ghost mt-6 w-full text-xs">
          Browse markets
        </Link>
      </Card>
    </div>
  );
}

// ------------------------------------------------------------------ Account Dashboard
function AccountDashboard({ accountId, asset, owner }: { accountId: bigint; asset: Series; owner: Hex }) {
  const { data: a, isLoading } = useAccountView(accountId);
  const { data: walletCash } = useTokenBalance(asset.settlementAsset, owner);
  const { data: product } = useProductMarket(a?.positions[0]?.series.productId ?? asset.productId);
  const spots = useLiquidationSpots(accountId, product?.productId, product?.spotWad, !!a && a.positions.length > 0);

  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const { data: allSeries } = useSeriesList();
  const { data: buckets } = useQuery({
    queryKey: ["buckets", accountId.toString()],
    queryFn: () => publicClient.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "bucketsOf", args: [accountId] }),
    refetchInterval: 15_000,
  });
  const symbolOf = (u: string) => allSeries?.find((s) => s.underlying.toLowerCase() === u.toLowerCase())?.underlyingSymbol ?? "these";
  const [amount, setAmount] = useState("");
  const value = parseFixed(amount, asset.assetDecimals);

  if (isLoading || !a || a.id !== accountId) return <Card><Skeleton className="h-56 w-full" /></Card>;

  // Urgent alerts & actionable to-dos
  const todo: { tone: "warn" | "bad" | "primary"; text: React.ReactNode }[] = [];
  if (a.health.state === "LIQUIDATABLE" || a.health.state === "INSOLVENT") {
    todo.push({
      tone: "bad",
      text: "Your account value is below the liquidation line. Add cash or close positions now, or part of your positions can be taken over at a discount.",
    });
  } else if (a.health.state === "CLOSE_ONLY") {
    todo.push({
      tone: "warn",
      text: "Close-only: your account value is below what's needed to open positions. You can still close. Add cash to write again.",
    });
  }

  if (walletCash && walletCash > 0n && a.positions.some((p) => p.balance < 0n)) {
    todo.push({
      tone: "primary",
      text: (
        <>
          Your wallet holds {fmtNative(walletCash, asset.assetDecimals)} {asset.assetSymbol}. Cash in your wallet doesn't
          protect this account; add some below if you want a bigger safety margin.
        </>
      ),
    });
  }

  const steps = value
    ? tab === "deposit"
      ? depositSteps(accountId, asset.settlementAsset, value, asset.assetSymbol)
      : withdrawSteps(accountId, value, owner)
    : undefined;

  const tooMuch =
    value !== undefined && (tab === "deposit" ? walletCash !== undefined && value > walletCash : value > a.maxWithdrawable);

  return (
    <>
      {(buckets ?? []).map((u) => (
        <AuctionNotice key={u} accountId={accountId} underlying={u} symbol={symbolOf(u)} mine />
      ))}

      {todo.length > 0 && (
        <div className="space-y-2">
          {todo.map((t, i) => (
            <div
              key={i}
              className={cx(
                "rounded-2xl border px-4 py-2.5 text-[13px] font-medium",
                t.tone === "bad"
                  ? "border-bad/30 bg-bad/10 text-bad"
                  : t.tone === "warn"
                  ? "border-warn/30 bg-warn/10 text-warn"
                  : "border-primary/30 bg-primary-soft text-ink"
              )}
            >
              {t.text}
            </div>
          ))}
        </div>
      )}

      <AccountInsight account={a} asset={asset} spots={spots} productSpot={product?.spotWad} />

      {/* Collateral Manager (Deposit / Withdraw) */}
      <section className="card rise overflow-hidden p-4">
        <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h2 id="cash-card" className="font-display text-[17px] font-semibold tracking-tight">Margin cash</h2>
              <Pill tone={a.maxWithdrawable > 0n ? "good" : "neutral"}>{a.maxWithdrawable > 0n ? "Withdrawable" : "Locked"}</Pill>
            </div>
            <p className="mt-1 max-w-xl text-[13px] leading-5 text-muted">
              Account cash backs written options and pays expiry losses. Buys still spend from wallet balance.
            </p>
          </div>
          <div className="grid min-w-0 grid-cols-3 gap-2 lg:min-w-[520px]">
            <CashMetric
              label={<Term tip="Cash in your wallet. Adding cash moves it from here into the account; withdrawing moves it back.">Wallet</Term>}
              value={walletCash !== undefined ? fmtNative(walletCash, asset.assetDecimals) : "…"}
              sub={asset.assetSymbol}
            />
            <CashMetric label="Account" value={fmtNative(a.cash, asset.assetDecimals)} sub={asset.assetSymbol} tone="primary" />
            <CashMetric
              label={<Term tip="The most you can take out while keeping enough to cover your open positions.">Free</Term>}
              value={fmtNative(a.maxWithdrawable, asset.assetDecimals)}
              sub="safe to withdraw"
              tone={a.maxWithdrawable > 0n ? "good" : undefined}
            />
          </div>
        </div>

        <div className="mt-4 grid gap-3 lg:grid-cols-[180px_minmax(0,1fr)_260px] lg:items-end">
          <Segmented
            value={tab}
            size="sm"
            onChange={(t) => {
              setTab(t);
              setAmount("");
            }}
            options={[
              { value: "deposit", label: "Add" },
              { value: "withdraw", label: "Withdraw" },
            ]}
          />

          <AmountInput
            label={tab === "deposit" ? "Amount to add" : "Amount to withdraw"}
            value={amount}
            onChange={setAmount}
            unit={asset.assetSymbol}
            max={
              tab === "deposit"
                ? walletCash !== undefined
                  ? fmtNative(walletCash, asset.assetDecimals).replace(/,/g, "")
                  : undefined
                : fmtNative(a.maxWithdrawable, asset.assetDecimals).replace(/,/g, "")
            }
            maxLabel={tab === "deposit" ? "Wallet" : "Free"}
            invalid={
              tooMuch
                ? tab === "deposit"
                  ? "Amount exceeds wallet balance."
                  : "Exceeds max safe withdrawal."
                : undefined
            }
          />

          <TxButton
            label={tab === "deposit" ? "Add cash" : "Withdraw cash"}
            summary={
              value
                ? tab === "deposit"
                  ? `${fmtNative(value, asset.assetDecimals)} ${asset.assetSymbol} from your wallet into account #${accountId}`
                  : `${fmtNative(value, asset.assetDecimals)} ${asset.assetSymbol} from account #${accountId} to your wallet`
                : undefined
            }
            steps={steps}
            disabled={!value || tooMuch}
            successMessage={tab === "deposit" ? "Deposited." : "Withdrawn to your wallet."}
            onDone={() => setAmount("")}
          />
        </div>
      </section>

      {/* Positions in this Account */}
      <Card
        title={`Positions · ${a.positions.length}`}
      >
        {a.positions.length === 0 ? (
          <EmptyState
            title="No open positions"
            body="Write options or move tokens in from any series page. Finished trades stay listed under Profit & loss above."
            action={
              <Link to="/app/markets" className="btn-ghost mt-2 text-xs">
                Browse markets
              </Link>
            }
          />
        ) : (
          <ul className="divide-y divide-line/60">
            {a.positions.map((p) => (
              <PositionRow key={p.seriesId} s={p.series} balance={p.balance} />
            ))}
          </ul>
        )}
      </Card>
    </>
  );
}

function AccountInsight({
  account,
  asset,
  spots,
  productSpot,
}: {
  account: AccountView;
  asset: Series;
  spots: ReturnType<typeof useLiquidationSpots>;
  productSpot?: bigint;
}) {
  const mix = useMemo(() => {
    let longs = 0n;
    let shorts = 0n;
    const byMarket = new Map<string, { symbol: string; long: bigint; short: bigint }>();
    for (const p of account.positions) {
      const qty = p.balance > 0n ? p.balance : -p.balance;
      const units = qty * p.series.contractSizeWad / WAD;
      const key = p.series.underlying.toLowerCase();
      const row = byMarket.get(key) ?? { symbol: p.series.underlyingSymbol, long: 0n, short: 0n };
      if (p.balance > 0n) {
        longs += qty;
        row.long += units;
      } else {
        shorts += qty;
        row.short += units;
      }
      byMarket.set(key, row);
    }
    return { longs, shorts, byMarket: [...byMarket.values()] };
  }, [account.positions]);
  const total = mix.longs + mix.shorts;
  const buffer = account.health.equity - account.health.initialMargin;
  const healthTone = account.health.state === "HEALTHY" ? "good" : account.health.state === "CLOSE_ONLY" ? "warn" : "bad";
  const longPct = pctOf(mix.longs, total);
  const shortPct = pctOf(mix.shorts, total);

  return (
    <section className="card rise overflow-hidden p-4">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(320px,0.62fr)]">
        <div className="min-w-0">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h2 className="font-display text-[18px] font-bold">Account #{account.id.toString()}</h2>
                <Pill tone={healthTone}>{account.health.state.replace("_", " ")}</Pill>
              </div>
              <p className="mt-1 text-[13px] leading-5 text-muted">
                {account.positions.length} open position{account.positions.length === 1 ? "" : "s"} · {mix.shorts > 0n ? "cash is backing written options" : "no written exposure"}
              </p>
            </div>
            <div className="grid w-full grid-cols-3 gap-2 sm:w-auto sm:min-w-[420px]">
              <CashMetric label="Cash" value={fmtNative(account.cash, asset.assetDecimals)} sub={asset.assetSymbol} tone="primary" />
              <CashMetric label="Long" value={fmtQty(mix.longs)} sub="owned" tone={mix.longs > 0n ? "good" : undefined} />
              <CashMetric label="Written" value={fmtQty(mix.shorts)} sub="short" tone={mix.shorts > 0n ? "warn" : undefined} />
            </div>
          </div>

          <div className="mt-4 grid gap-3 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
            <div className="rounded-2xl border border-line bg-surface-2/45 p-3">
              <div className="mb-2 flex items-center justify-between gap-2">
                <span className="text-sm font-bold">Position mix</span>
                <span className="num text-xs text-muted">{fmtQty(total)} total</span>
              </div>
              <div className="flex h-3 overflow-hidden rounded-full bg-surface">
                <div className="bg-good" style={{ width: `${longPct}%` }} />
                <div className="bg-warn" style={{ width: `${shortPct}%` }} />
              </div>
              <div className="mt-2 grid grid-cols-2 gap-2 text-xs">
                <span className="flex items-center gap-1.5 text-muted"><i className="h-2 w-2 rounded-full bg-good" />Long {longPct.toFixed(0)}%</span>
                <span className="flex items-center gap-1.5 text-muted"><i className="h-2 w-2 rounded-full bg-warn" />Written {shortPct.toFixed(0)}%</span>
              </div>
            </div>

            <div className="rounded-2xl border border-line bg-surface-2/45 p-3">
              <div className="mb-2 flex items-center justify-between gap-2">
                <span className="text-sm font-bold">Margin room</span>
                <Pill tone={buffer >= 0n ? "good" : "bad"}>{buffer >= 0n ? "Spare" : "Needs cash"}</Pill>
              </div>
              <div className="grid grid-cols-3 gap-2">
                <MiniMetric label="Value" value={`$${fmtWad(account.health.equity, 0)}`} />
                <MiniMetric label="Needed" value={`$${fmtWad(account.health.initialMargin, 0)}`} />
                <MiniMetric label={buffer >= 0n ? "Room" : "Short"} value={`${buffer >= 0n ? "$" : "−$"}${fmtWad(buffer >= 0n ? buffer : -buffer, 0)}`} tone={buffer >= 0n ? "good" : "bad"} />
              </div>
            </div>
          </div>
        </div>

        <div className="rounded-3xl border border-line bg-gradient-to-br from-surface-2/70 to-surface/80 p-3">
          <div className="flex items-center justify-between gap-2">
            <div>
              <div className="text-sm font-bold">Risk check</div>
              <div className="text-xs text-muted">Liquidation points if prices move.</div>
            </div>
            {productSpot && <Pill tone="neutral">Spot ${fmtLevel(productSpot)}</Pill>}
          </div>
          <div className="mt-3 grid gap-2">
            <RiskLine icon={ArrowUpRight} label="Price rises" value={spots.isLoading ? "checking..." : spots.data?.up ? `$${fmtLevel(spots.data.up)}` : "Clear"} tone={spots.data?.up ? "warn" : "good"} />
            <RiskLine icon={ArrowDownRight} label="Price falls" value={spots.isLoading ? "checking..." : spots.data?.down ? `$${fmtLevel(spots.data.down)}` : "Clear"} tone={spots.data?.down ? "warn" : "good"} />
          </div>
          {mix.byMarket.length > 0 && (
            <div className="mt-3 flex gap-2 overflow-x-auto pb-1 scrollbar-none">
              {mix.byMarket.map((m) => (
                <div key={m.symbol} className="min-w-[150px] rounded-2xl border border-line bg-surface/80 p-2.5">
                  <div className="text-xs font-bold">{m.symbol}</div>
                  <div className="mt-1 text-[11px] text-muted">long {fmtQty(m.long)}</div>
                  <div className="text-[11px] text-muted">written {fmtQty(m.short)}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function CashMetric({ label, value, sub, tone }: { label: React.ReactNode; value: React.ReactNode; sub?: React.ReactNode; tone?: "primary" | "good" | "warn" }) {
  return (
    <div className="min-w-0 rounded-2xl border border-line bg-surface-2/55 p-2.5">
      <div className="truncate text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className={cx("num mt-0.5 truncate font-display text-[17px] font-bold", tone === "primary" && "text-primary", tone === "good" && "text-good", tone === "warn" && "text-warn")}>
        {value}
      </div>
      {sub && <div className="truncate text-[11px] text-muted">{sub}</div>}
    </div>
  );
}

function MiniMetric({ label, value, tone }: { label: string; value: string; tone?: "good" | "bad" }) {
  return (
    <div className="rounded-xl border border-line bg-surface p-3">
      <div className="text-[11px] text-muted">{label}</div>
      <div className={cx("num mt-0.5 font-display text-lg font-bold", tone === "good" ? "text-good" : tone === "bad" ? "text-bad" : "")}>{value}</div>
    </div>
  );
}

function RiskLine({ icon: Icon, label, value, tone }: { icon: typeof ArrowUpRight; label: string; value: string; tone: "good" | "warn" }) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-2xl border border-line bg-surface-2/50 p-3">
      <span className="flex items-center gap-2 text-sm font-semibold">
        <span className={cx("grid h-8 w-8 place-items-center rounded-xl", tone === "good" ? "bg-good/10 text-good" : "bg-warn/10 text-warn")}><Icon className="h-4 w-4" /></span>
        {label}
      </span>
      <span className={cx("num font-bold", tone === "good" ? "text-good" : "text-warn")}>{value}</span>
    </div>
  );
}

function pctOf(value: bigint, total: bigint) {
  return total > 0n ? Number((value * 10_000n) / total) / 100 : 0;
}

function PositionRow({ s, balance }: { s: Series; balance: bigint }) {
  const { data: m } = useQuery({
    queryKey: ["seriesMarket", s.id],
    queryFn: () => getSeriesMarket(s),
    refetchInterval: 10_000,
  });
  const value = m?.mark !== undefined ? (m.mark * balance) / WAD : undefined;

  return (
    <li>
      <Link
        to={`/app/series/${s.id}?tab=${m?.state === "REDEEMABLE" ? "redeem" : "manage"}`}
        className="flex min-h-[68px] items-center gap-2.5 rounded-2xl px-2 py-2.5 transition hover:bg-primary-soft/50"
      >
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-bold">{seriesName(s)}</span>
          <span className="mt-0.5 flex items-center gap-1.5 text-xs text-muted">
            <Pill tone={balance > 0n ? "good" : "accent"}>{balance > 0n ? "Owned" : "Written"}</Pill>
            <span className="num">{fmtQty(balance < 0n ? -balance : balance)}</span>
            {m && <StatePill state={m.state} />}
          </span>
        </span>
        <span className="shrink-0 text-right">
          <span className={cx("num block text-sm font-bold", value !== undefined && value < 0n ? "text-bad" : "text-good")}>
            {value !== undefined ? (value < 0n ? `−$${fmtWad(-value)}` : `$${fmtWad(value)}`) : "—"}
          </span>
          <span className="block text-[11px] text-muted">{balance > 0n ? "worth today" : "owed at today's value"}</span>
        </span>
      </Link>
    </li>
  );
}

// ------------------------------------------------------------------ Wallet Tokens
function WalletTokens({ owner }: { owner: Hex }) {
  const { data, isLoading } = useWalletWrappers(owner);
  const states = useQuery({
    queryKey: ["walletStates", data?.map((d) => d.series.id).join()],
    queryFn: async () =>
      Object.fromEntries(
        await Promise.all((data ?? []).map(async (d) => [d.series.id, await getGroupState(d.series.groupId)] as const))
      ),
    enabled: !!data?.length,
  });

  const rows = useMemo(() => data ?? [], [data]);

  return (
    <Card
      title={`Wallet options · ${rows.length}`}
      action={<span className="text-xs text-muted">Sell before expiry or redeem after settlement.</span>}
    >
      {isLoading ? (
        <Skeleton className="h-20 w-full" />
      ) : rows.length === 0 ? (
        <EmptyState
          icon="◇"
          title="No option tokens in wallet"
          body="Options you buy land here until you sell or redeem them. Finished trades stay listed under Profit & loss above."
          action={
            <Link to="/app/markets" className="btn-ghost mt-2 text-xs">
              Explore Markets
            </Link>
          }
        />
      ) : (
        <div className="max-h-[360px] overflow-y-auto pr-1 scrollbar-thin">
          {rows.map(({ series: s, balance }) => {
            const st = states.data?.[s.id];
            const isRedeemable = st === "REDEEMABLE";

            return (
              <Link
                key={s.id}
                to={`/app/series/${s.id}?tab=${isRedeemable ? "redeem" : "trade"}`}
                className={cx(
                  "grid grid-cols-[1fr_auto] items-center gap-3 border-b border-line/60 px-1 py-2.5 transition hover:bg-primary-soft/35 sm:grid-cols-[minmax(0,1fr)_auto_auto]",
                  isRedeemable
                    ? "text-good"
                    : "text-ink"
                )}
              >
                <div className="min-w-0">
                  <div className="truncate text-sm font-bold">
                    {s.underlyingSymbol} ${fmtLevel(s.strikeWad)} {optionTypeName(s.optionType)}
                  </div>
                  <div className="mt-0.5 text-xs text-muted">Expires {fmtExpiry(s.expiry)}</div>
                </div>
                <div className="text-right">
                  <div className="num text-sm font-bold text-ink">{fmtQty(balance)}</div>
                  <div className="text-[11px] text-muted">tokens</div>
                </div>
                <div className="hidden items-center justify-end gap-2 sm:flex">
                  {st && <StatePill state={st} />}
                  <span className={cx("text-xs font-bold", isRedeemable ? "text-good" : "text-primary")}>{isRedeemable ? "Redeem" : "Open"}</span>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </Card>
  );
}
