/** `/series/:id` (and `/trade/:id`): terms, payoff, simulator and every action on one series (FRONTEND.md §2, §4, §7). */
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Address, Hex } from "viem";
import { settlementWindowAbi } from "@optara/sdk";
import {
  ArrowLeft,
  ArrowRight,
  ArrowDownRight,
  ArrowUpRight,
  CheckCircle2,
  Clock,
  Coins,
  ExternalLink,
  Flame,
  HelpCircle,
  Info,
  Lock,
  Minus,
  Percent,
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
import { AmountInput, Card, CopyButton, Details, EmptyState, Pill, Row, Segmented, Skeleton, Stat, Term, cx, useTicker } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { BackingCard } from "../components/BackingCard.tsx";
import { LimitsPanel } from "../components/LimitsPanel.tsx";
import { lessSlip, useSlippage, venueMinQty, withSlip } from "../lib/optara/limits.ts";
import { buyLimits } from "./Trade.tsx";
import { BuyOutcome, SellValueNotice, buyCheck } from "../components/BuyOutcome.tsx";
import { PayoffChart } from "../components/PayoffChart.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { availability, type ActionContext, type ActionKey } from "../lib/optara/availability.ts";
import {
  buyVenueSteps,
  closeShortSteps,
  kuruDepositSteps,
  kuruCancelSteps,
  kuruLimitBuySteps,
  kuruWithdrawSteps,
  kuruLimitSellSteps,
  mintSteps,
  redeemSteps,
  claimSteps,
  sellVenueSteps,
  setupAccountSteps,
  unwrapSteps,
  wrapSteps,
} from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { recordTrade } from "../lib/optara/activity.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import { fmtDuration, fmtExpiry, fmtIv, fmtLevel, fmtNative, fmtPrice, fmtQty, fmtWad, optionTypeName, parseFixed, parseQty, seriesName, shortAddr, WAD, qtyStepError, roundDownQty } from "../lib/optara/format.ts";
import {
  useAccountView,
  useChainTime,
  useProductMarket,
  useSeries,
  useSeriesMarket,
  useTokenBalance,
  useWalletWrappers,
} from "../lib/optara/hooks.ts";
import { getKuruLimitMarket, getKuruOrderBook, getKuruUserOrders, previewBuyerFee, previewMint, previewRedeem, venueBuyFee, venueSellFee, type KuruBookLevel, type KuruOrderStatus, type KuruUserOrder } from "../lib/optara/reads.ts";
import { breakeven, legOf, payoutPerOption, priceLevel, profitAt, usd } from "../lib/optara/payoff.ts";
import type { Quote, Series } from "../lib/optara/types.ts";
import { fillFromAsks } from "../lib/optara/depth.ts";
import { useAccountState, useQuickGuide, useShowMarket } from "../state.tsx";
import { HealthBar } from "../components/HealthBar.tsx";

type Tab = "trade" | "write" | "manage" | "redeem" | "buy" | "sell";
/** WAD amount in the settlement asset → native units. */
/** What a ticket reports to the expiry chart: quantity, the per-option amount, and how that amount was arrived at. */
type ChartPreview = { qty: number; cost?: number; note?: string; view?: "sell" };
type ChartReport = (qty: number, cost?: number, info?: Pick<ChartPreview, "note" | "view">) => void;

const toNative = (wad: bigint, decimals: number) => wad / 10n ** BigInt(18 - decimals);
const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);
/** A chart quantity: up to 4 decimals, no trailing zeros. */
const fmtQtyNum = (q: number) => q.toLocaleString("en-US", { maximumFractionDigits: 4 });
const MAX_UINT32 = 2n ** 32n - 1n;
const MAX_UINT96 = 2n ** 96n - 1n;

export function SeriesPage({ initialTab }: { initialTab?: Tab }) {
  const { id } = useParams();
  const [params, setParams] = useSearchParams();
  const series = useSeries(id as Hex | undefined);
  useShowMarket(series?.productId);
  const { data: market } = useSeriesMarket(series);
  const { data: product } = useProductMarket(series?.productId);
  const { address } = useConnection();
  const { selected } = useAccountState();
  const { data: account } = useAccountView(selected);
  const { data: wallet } = useWalletWrappers(address);
  const { data: now } = useChainTime();
  const tick = useTicker(now);
  const { open: openGuide } = useQuickGuide();

  const fromUrl = params.get("tab") as Tab | null;
  const [tab, setTab] = useState<Tab>(fromUrl ?? initialTab ?? "buy");
  useEffect(() => {
    if (fromUrl) setTab(fromUrl);
  }, [fromUrl]);
  // What the open ticket would trade: quantity, and the all-in price per option (fees included) when known.
  const [preview, setPreview] = useState<ChartPreview & { tab?: string }>({ qty: 1 });
  // Each ticket reports what it would trade; the report is tagged with the tab that made it, so a tab without a
  // ticket (Position, Settle) never draws another tab's numbers.
  const chartTab = useRef<string>("");
  const setQtyForChart = useCallback<ChartReport>((qty, cost, info) => setPreview({ qty, cost, ...info, tab: chartTab.current }), []);

  if (!series) {
    return (
      <Card>
        {id ? (
          <Skeleton className="h-40 w-full" />
        ) : (
          <EmptyState
            title="Unknown option series"
            action={
              <Link to="/app/markets" className="btn-ghost">
                Back to markets
              </Link>
            }
          />
        )}
      </Card>
    );
  }

  const walletQty = wallet?.find((w) => w.series.id === series.id)?.balance ?? 0n;
  const position = account?.positions.find((p) => p.seriesId === series.id)?.balance ?? 0n;
  const state = market?.state ?? "ACTIVE";
  const ctx: ActionContext = {
    connected: !!address,
    groupState: state,
    productCloseOnly: product?.closeOnly ?? false,
    dataFresh: !!product?.spotFresh && product?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: selected !== undefined,
    health: account?.health.state,
    accountBalance: position,
    walletWrappers: walletQty,
    credit: false,
  };

  const canonicalTab: Tab = tab === "buy" || tab === "sell" ? "trade" : tab;
  chartTab.current = canonicalTab;
  const chart: ChartPreview = preview.tab === canonicalTab ? preview : { qty: 1 };
  const qtyForChart = chart.qty;
  const tradeSide: "buy" | "sell" = tab === "sell" ? "sell" : "buy";
  const tabs: { value: Tab; label: string; icon: any; actions: ActionKey[] }[] = [
    { value: "trade", label: "Trade", icon: TrendingUp, actions: ["buy", "sell"] },
    { value: "write", label: "Earn", icon: Coins, actions: ["write"] },
    { value: "manage", label: "Position", icon: Shield, actions: ["unwrap", "close", "wrap"] },
    { value: "redeem", label: "Settle", icon: CheckCircle2, actions: ["redeem", "claim"] },
  ];

  const spotNum = product ? Number(product.spotWad) / 1e18 : undefined;
  const markNum = market?.mark !== undefined ? Number(market.mark) / 1e18 : undefined;
  const side = canonicalTab === "write" ? "short" : "long";
  const chartView = chart.view === "sell" && side === "long" ? "sell" : "trade";
  // Without a report from the ticket: a buyer pays the ask, a writer or seller gets the bid (fair value if none), before fees.
  const quoted = (side === "long" && chartView !== "sell" ? market?.quote?.ask : market?.quote?.bid) ?? market?.mark;
  const premiumForChart = chart.cost ?? (quoted !== undefined ? Number(quoted) / 1e18 : undefined);
  const chartNote =
    chart.note ?? (chart.cost !== undefined ? (side === "short" ? "kept after fees" : chartView === "sell" ? "after fees" : "fees included") : "before fees");

  const select = (t: Tab) => {
    setTab(t);
    setParams((p) => (p.set("tab", t), p), { replace: true });
  };

  const isCall = series.optionType === 0;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between px-1">
        <Link
          to="/app/markets"
          className="flex items-center gap-1 text-[13px] font-semibold text-muted hover:text-ink transition"
        >
          <ArrowLeft className="h-4 w-4" /> All markets
        </Link>
        <button
          onClick={openGuide}
          className="flex items-center gap-1 text-[13px] font-semibold text-primary hover:underline cursor-pointer"
        >
          <HelpCircle className="h-3.5 w-3.5" /> What does this mean?
        </button>
      </div>

      <section className="card rise overflow-hidden">
        <div className="flex flex-wrap items-start justify-between gap-4 p-4 sm:p-5">
          <div className="flex items-center gap-3">
            <TokenIcon symbol={series.underlyingSymbol} className="h-10 w-10" />
            <div>
              <div className="flex flex-wrap items-center gap-1.5">
                <span
                  className={cx(
                    "pill border font-bold",
                    isCall ? "border-good/25 bg-good/12 text-good" : "border-bad/25 bg-bad/12 text-bad"
                  )}
                >
                  {isCall ? "Call · up" : "Put · down"}
                </span>
                <StatePill state={state} />
              </div>
              <h1 className="font-display mt-1.5 text-2xl font-bold tracking-tight sm:text-[28px]">
                {series.underlyingSymbol} ${fmtLevel(series.strikeWad)} {optionTypeName(series.optionType)}
              </h1>
              <p className="mt-0.5 flex items-center gap-1.5 text-[13px] text-muted">
                Expires {fmtExpiry(series.expiry)}
                {tick !== undefined && series.expiry > tick && (
                  <span className="num font-semibold text-ink">
                    · {fmtDuration(series.expiry - tick)} left
                  </span>
                )}
              </p>
            </div>
          </div>

          <div className="w-full border-t border-line pt-3">
            <div className="grid grid-cols-3 gap-2">
              <Stat
                label={`${series.underlyingSymbol} spot`}
                value={product ? `$${fmtLevel(product.spotWad)}` : "…"}
                sub={product?.spotFresh ? "Live" : "Delayed"}
                tone={product?.spotFresh ? "good" : "warn"}
              />
              <Stat
                label={<Term tip="Fair value per option from the on-chain volatility surface.">Fair value</Term>}
                value={market?.mark !== undefined ? fmtPrice(market.mark) : "—"}
                sub={series.assetSymbol}
              />
              <Stat
                label={<Term tip="Annual implied volatility from the surface used to price this option. Higher IV usually means a more expensive option.">Annual volatility</Term>}
                value={market?.iv !== undefined ? fmtIv(market.iv) : "—"}
                sub="Implied IV"
              />
            </div>
            <div className="mt-2 flex items-center justify-between rounded-xl bg-surface-2/60 px-3 py-1.5 text-xs">
              <span className="text-muted">Order book</span>
              <span className="num font-semibold">
                {market?.quote ? (
                  <span>
                    <span className="text-good">{market.quote.bid !== undefined ? fmtPrice(market.quote.bid) : "—"}</span>
                    <span className="text-muted"> / </span>
                    <span className="text-bad">{market.quote.ask !== undefined ? fmtPrice(market.quote.ask) : "—"}</span>
                    <span className="text-muted"> {series.assetSymbol}</span>
                  </span>
                ) : (
                  <span className="text-muted">No orders yet</span>
                )}
              </span>
            </div>
          </div>
        </div>

        {(walletQty > 0n || position !== 0n) && (
          <div className="flex flex-wrap items-center gap-1.5 border-t border-line bg-surface-2/50 px-4 py-2.5 text-[13px] sm:px-5">
            <span className="font-semibold">You hold</span>
            {walletQty > 0n && (
              <Pill tone="primary">{fmtQty(walletQty)} in wallet</Pill>
            )}
            {position > 0n && (
              <Pill tone="good">{fmtQty(position)} long · account #{selected?.toString()}</Pill>
            )}
            {position < 0n && (
              <Pill tone="accent">{fmtQty(-position)} written · account #{selected?.toString()}</Pill>
            )}
          </div>
        )}
      </section>

      <SeriesQuickFacts series={series} state={state} spot={product?.spotWad} mark={market?.mark} ask={market?.quote?.ask} />

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_380px] lg:items-start">
        <div className="space-y-4">
          <Card
            title={side === "short" ? "What happens at expiry if you write" : chartView === "sell" ? "Sell now or hold to expiry?" : "What happens at expiry"}
            action={
              <span className="text-[13px] text-muted">
                {fmtQtyNum(qtyForChart)} option{qtyForChart === 1 ? "" : "s"}
                {premiumForChart !== undefined && ` at ${usd(premiumForChart)} each, ${chartNote}`}
              </span>
            }
          >
            {spotNum !== undefined || markNum !== undefined ? (
              <PayoffChart
                optionType={series.optionType}
                strike={Number(series.strikeWad) / 1e18}
                size={legOf(series).size}
                spot={spotNum}
                premium={premiumForChart ?? 0}
                qty={qtyForChart}
                side={side}
                view={chartView}
                assetSymbol={series.assetSymbol}
                underlyingSymbol={series.underlyingSymbol}
              />
            ) : (
              <Skeleton className="h-60 w-full" />
            )}
            <p className="mt-2 text-xs text-muted">Use this simulator to test settlement prices. The amount follows the order form in the action panel.</p>
          </Card>

          <div id="backing">
            <BackingCard series={series} spot={spotNum} />
          </div>

          {/* Immutable Contract Terms */}
          <Terms s={series} market={market?.quote?.market} />
        </div>

        <div className="lg:sticky lg:top-16">
          <section className="ticket p-4 sm:p-5">
            <div className="mb-4 flex gap-1 overflow-x-auto rounded-xl border border-line bg-surface-2/70 p-1 scrollbar-none">
              {tabs.map((t) => {
                const isSelected = canonicalTab === t.value || (t.value === "trade" && (tab === "buy" || tab === "sell"));
                const a = t.actions.map((k) => availability(k, ctx));
                const isDisabled = a.every((x) => !x.enabled);
                return (
                  <button
                    key={t.value}
                    onClick={() => select(t.value)}
                    title={isDisabled ? a[0]?.reason : undefined}
                    className={cx(
                      "whitespace-nowrap rounded-lg px-2.5 py-1.5 text-[13px] font-semibold transition cursor-pointer",
                      isSelected
                        ? "bg-primary text-white shadow"
                        : isDisabled
                        ? "text-muted/60 hover:text-ink"
                        : "text-muted hover:text-ink"
                    )}
                  >
                    {t.label}
                  </button>
                );
              })}
            </div>

            {/* Tab Body */}
            {(canonicalTab === "trade") && (
              <TradePanel
                s={series}
                ctx={ctx}
                ask={market?.quote?.ask}
                bid={market?.quote?.bid}
                bidQty={market?.quote?.bidQty}
                mark={market?.mark}
                market={market?.quote?.market}
                venueId={market?.quote?.venueId}
                venueName={market?.quote?.venueName}
                walletQty={walletQty}
                initialSide={tradeSide}
                onQty={setQtyForChart}
              />
            )}
            {canonicalTab === "write" && (
              <WritePanel
                s={series}
                ctx={ctx}
                bid={market?.quote?.bid}
                mark={market?.mark}
                writeCapacity={market?.writeCapacity}
                openInterest={market?.openInterest}
                openInterestCap={market?.openInterestCap}
                market={market?.quote?.market}
                venueId={market?.quote?.venueId}
                venueName={market?.quote?.venueName}
                onQty={setQtyForChart}
              />
            )}
            {canonicalTab === "manage" && (
              <ManagePanel s={series} ctx={ctx} walletQty={walletQty} position={position} />
            )}
            {canonicalTab === "redeem" && (
              <RedeemPanel s={series} ctx={ctx} walletQty={walletQty} />
            )}

            {account && (
              <div className="mt-5 border-t border-line pt-3.5">
                <div className="mb-2 flex items-center justify-between text-[13px]">
                  <span className="font-semibold">Margin account #{selected?.toString()}</span>
                  <Link to="/app/portfolio" className="font-semibold text-primary hover:underline">
                    Portfolio
                  </Link>
                </div>
                <HealthBar
                  health={account.health}
                  hasPositions={account.positions.length > 0}
                  assetSymbol={series.assetSymbol}
                  compact
                />
              </div>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}

export function KuruBookPage() {
  const { id } = useParams();
  const series = useSeries(id as Hex | undefined);
  useShowMarket(series?.productId);
  const { address } = useConnection();
  const { selected } = useAccountState();
  const { data: market } = useSeriesMarket(series);
  const { data: product } = useProductMarket(series?.productId);
  const { data: account } = useAccountView(selected);
  const { data: wallet } = useWalletWrappers(address);
  const walletQty = series ? wallet?.find((w) => w.series.id === series.id)?.balance ?? 0n : 0n;
  const position = series ? account?.positions.find((p) => p.seriesId === series.id)?.balance ?? 0n : 0n;
  const state = market?.state ?? "ACTIVE";
  const ctx: ActionContext = {
    connected: !!address,
    groupState: state,
    productCloseOnly: product?.closeOnly ?? false,
    dataFresh: !!product?.spotFresh && product?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: selected !== undefined,
    health: account?.health.state,
    accountBalance: position,
    walletWrappers: walletQty,
    credit: false,
  };
  const ignorePreview = useCallback(() => {}, []);

  if (!series) {
    return (
      <Card>
        <Skeleton className="h-40 w-full" />
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3 px-1">
        <Link to={`/app/series/${series.id}?tab=trade`} className="flex items-center gap-1 text-[13px] font-semibold text-muted transition hover:text-ink">
          <ArrowLeft className="h-4 w-4" /> Back to trade
        </Link>
        <Link to="/app/markets" className="text-[13px] font-semibold text-primary hover:underline">
          All markets
        </Link>
      </div>

      <section className="card rise overflow-hidden p-4 sm:p-5">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <TokenIcon symbol={series.underlyingSymbol} className="h-10 w-10" />
            <div>
              <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">{seriesName(series)}</h1>
              <p className="mt-0.5 text-sm text-muted">Public Kuru order book for this option token.</p>
            </div>
          </div>
          <div className="flex flex-wrap gap-2">
            <Link to={`/app/series/${series.id}?tab=buy`} className="btn-up text-sm">
              Buy best ask
            </Link>
            <Link to={`/app/series/${series.id}?tab=sell`} className="btn-down text-sm">
              Sell into bids
            </Link>
          </div>
        </div>
      </section>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
        <KuruBookPanel series={series} mark={market?.mark} />
        <section className="space-y-3">
          <KuruLimitPanel s={series} ctx={ctx} walletQty={walletQty} mark={market?.mark} onQty={ignorePreview} />
          <MyKuruOrdersPanel series={series} owner={address} />
        </section>
      </div>
    </div>
  );
}

function MyKuruOrdersPanel({ series, owner }: { series: Series; owner?: Address }) {
  const [filter, setFilter] = useState<"active" | "filled" | "all">("active");
  const [sideFilter, setSideFilter] = useState<"all" | "bid" | "ask">("all");
  const orders = useQuery({
    queryKey: ["kuruUserOrders", series.id, owner],
    queryFn: () => getKuruUserOrders(series, owner),
    enabled: !!owner,
    refetchInterval: 5_000,
  });
  // Shares its cache with the limit ticket: the free (withdrawable) Kuru balances for this option and its quote asset.
  const limit = useQuery({
    queryKey: ["kuruLimitMarket", series.id, owner],
    queryFn: () => getKuruLimitMarket(series, owner),
    enabled: !!owner,
    refetchInterval: 10_000,
  });

  if (!owner) {
    return (
      <section className="rounded-3xl border border-line bg-surface p-4">
        <div className="font-semibold text-ink">My Kuru orders</div>
        <p className="mt-1 text-sm text-muted">Connect a wallet to track your open, partially filled, and filled Kuru orders.</p>
      </section>
    );
  }

  if (orders.isLoading) return <Skeleton className="h-40 w-full rounded-3xl" />;
  const rows = orders.data ?? [];
  const activeRows = rows.filter((o) => o.status === "open" || o.status === "partial");
  const partialRows = rows.filter((o) => o.status === "partial");
  const filledRows = rows.filter((o) => o.status === "filled");
  const statusRows = filter === "active" ? activeRows : filter === "filled" ? filledRows : rows;
  const shownRows = sideFilter === "all" ? statusRows : statusRows.filter((o) => o.side === sideFilter);
  const visibleRows = shownRows.slice(0, 24);
  const bidRows = rows.filter((o) => o.side === "bid");
  const askRows = rows.filter((o) => o.side === "ask");
  const tone = partialRows.length > 0 ? "warn" : filledRows.length > 0 ? "good" : "neutral";

  return (
    <section className="overflow-hidden rounded-3xl border border-line bg-surface shadow-sm">
      <div className="border-b border-line p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="font-semibold text-ink">My Kuru orders</div>
            <p className="mt-0.5 text-xs text-muted">Track maker orders from this wallet without leaving the series.</p>
          </div>
          <Pill tone={tone}>
            {rows.length} order{rows.length === 1 ? "" : "s"}
          </Pill>
        </div>

        <div className="mt-3 grid grid-cols-3 gap-2">
          <OrderCount label="Active" value={activeRows.length} tone={activeRows.length ? "text-primary" : "text-muted"} />
          <OrderCount label="Partial" value={partialRows.length} tone={partialRows.length ? "text-warn" : "text-muted"} />
          <OrderCount label="Filled" value={filledRows.length} tone={filledRows.length ? "text-good" : "text-muted"} />
        </div>

        {activeRows.length > 1 && (
          <div className="mt-3">
            <TxButton
              compact
              tone="ghost"
              label={`Cancel all ${activeRows.length} open orders`}
              steps={kuruCancelSteps(activeRows[0]!.market, activeRows.map((o) => o.orderId))}
              successMessage="Orders cancelled. Unfilled funds are back in your Kuru balance."
            />
          </div>
        )}

        {limit.data && (limit.data.quoteBalance > 0n || limit.data.optionBalance > 0n) && (
          <KuruWithdrawCard series={series} margin={limit.data.margin} quoteBalance={limit.data.quoteBalance} optionBalance={limit.data.optionBalance} />
        )}

        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          <Segmented
            size="sm"
            value={filter}
            onChange={setFilter}
            options={[
              { value: "active", label: "Active" },
              { value: "filled", label: "Filled" },
              { value: "all", label: "All" },
            ]}
          />
          <Segmented
            size="sm"
            value={sideFilter}
            onChange={setSideFilter}
            options={[
              { value: "all", label: "Both" },
              { value: "bid", label: `Bids ${bidRows.length}` },
              { value: "ask", label: `Asks ${askRows.length}` },
            ]}
          />
        </div>
      </div>

      {rows.length === 0 ? (
        <div className="m-3 rounded-2xl border border-line bg-surface-2/55 px-3 py-5 text-center text-sm text-muted">No Kuru maker orders from this wallet yet.</div>
      ) : shownRows.length === 0 ? (
        <div className="m-3 rounded-2xl border border-line bg-surface-2/55 px-3 py-5 text-center text-sm text-muted">No {sideFilter === "all" ? "" : `${sideFilter} `}{filter} orders for this series.</div>
      ) : (
        <>
          <div className="max-h-[380px] space-y-2 overflow-y-auto p-3 pr-2">
            {visibleRows.map((o) => <CompactKuruOrder key={o.orderId.toString()} order={o} assetSymbol={series.assetSymbol} />)}
          </div>
          {shownRows.length > visibleRows.length && (
            <div className="border-t border-line bg-surface-2/45 px-4 py-2 text-center text-xs font-semibold text-muted">
              Showing {visibleRows.length} of {shownRows.length}. Use the filters above to narrow the list.
            </div>
          )}
        </>
      )}
    </section>
  );
}

/** Free Kuru balances (not locked in open orders) with one-click withdrawal to the wallet. */
function KuruWithdrawCard({ series, margin, quoteBalance, optionBalance }: { series: Series; margin: Address; quoteBalance: bigint; optionBalance: bigint }) {
  return (
    <div className="mt-3 rounded-2xl border border-primary/25 bg-primary-soft/50 p-3">
      <div className="text-sm font-semibold text-ink">Ready to withdraw from Kuru</div>
      <p className="mt-0.5 text-xs leading-5 text-muted">Filled or cancelled orders leave funds in your Kuru balance. Bring them back to your wallet here.</p>
      <div className="mt-2.5 grid gap-2 sm:grid-cols-2">
        {quoteBalance > 0n && (
          <TxButton
            compact
            label={`Withdraw ${fmtNative(quoteBalance, series.assetDecimals)} ${series.assetSymbol}`}
            steps={kuruWithdrawSteps(margin, series.settlementAsset, quoteBalance, series.assetSymbol)}
            successMessage={`${series.assetSymbol} is back in your wallet.`}
          />
        )}
        {optionBalance > 0n && (
          <TxButton
            compact
            label={`Withdraw ${fmtQty(optionBalance)} options`}
            steps={kuruWithdrawSteps(margin, series.wrapper, optionBalance, "options")}
            successMessage="Options are back in your wallet, ready to sell, close or redeem."
          />
        )}
      </div>
    </div>
  );
}

function OrderCount({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div className="rounded-2xl border border-line bg-surface-2/55 px-3 py-2">
      <div className="text-[10px] font-bold uppercase tracking-[0.14em] text-muted">{label}</div>
      <div className={cx("num mt-0.5 text-lg font-black leading-none", tone)}>{value}</div>
    </div>
  );
}

function CompactKuruOrder({ order, assetSymbol }: { order: KuruUserOrder; assetSymbol: string }) {
  const progress = order.originalSize > 0n ? Number((order.filledSize * 10000n) / order.originalSize) / 100 : 0;
  return (
    <div className="rounded-2xl border border-line bg-surface-2/55 p-3 transition hover:border-primary/25 hover:bg-surface-2">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className={cx("rounded-full px-2 py-0.5 text-xs font-bold", order.side === "bid" ? "bg-good/12 text-good" : "bg-bad/12 text-bad")}>
              {order.side === "bid" ? "Bid" : "Ask"} #{order.orderId.toString()}
            </span>
            <OrderStatus status={order.status} />
          </div>
          <div className="num mt-1.5 text-sm font-black text-ink">{fmtPrice(order.price)} {assetSymbol}</div>
        </div>
        {order.status === "filled" && (
          <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-good/12 text-good">
            <CheckCircle2 className="h-4 w-4" />
          </span>
        )}
      </div>

      <div className="mt-3 grid grid-cols-3 gap-2 text-xs">
        <OrderMiniStat label="Size" value={fmtQty(order.originalSize)} />
        <OrderMiniStat label="Filled" value={fmtQty(order.filledSize)} tone={order.filledSize > 0n ? "text-good" : undefined} />
        <OrderMiniStat label="Left" value={fmtQty(order.remainingSize)} tone={order.remainingSize === 0n ? "text-muted" : "text-ink"} />
      </div>

      <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-surface">
        <div className={cx("h-full rounded-full", order.status === "filled" ? "bg-good" : order.status === "partial" ? "bg-warn" : order.status === "cancelled" ? "bg-faint" : "bg-primary")} style={{ width: `${progress}%` }} />
      </div>

      {(order.status === "open" || order.status === "partial") && (
        <div className="mt-3">
          <TxButton
            compact
            tone="ghost"
            label={order.status === "partial" ? "Cancel the unfilled part" : "Cancel order"}
            steps={kuruCancelSteps(order.market, [order.orderId])}
            successMessage="Order cancelled. Unfilled funds are back in your Kuru balance, ready to withdraw."
          />
        </div>
      )}
    </div>
  );
}

function OrderStatus({ status }: { status: KuruOrderStatus }) {
  const cls = status === "filled" ? "bg-good/12 text-good border-good/25" : status === "partial" ? "bg-warn/12 text-warn border-warn/25" : status === "cancelled" ? "bg-surface text-faint border-line line-through" : "bg-surface text-muted border-line";
  return <span className={cx("rounded-full border px-2 py-0.5 text-xs font-bold capitalize", cls)}>{status === "partial" ? "Partially filled" : status}</span>;
}

function OrderMiniStat({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <div className="min-w-0 rounded-xl bg-surface px-2.5 py-2">
      <div className="text-[11px] font-semibold text-muted">{label}</div>
      <div className={cx("num mt-0.5 break-words font-semibold", tone ?? "text-ink")}>{value}</div>
    </div>
  );
}

function KuruBookPanel({ series, mark }: { series: Series; mark?: bigint }) {
  const book = useQuery({
    queryKey: ["kuruOrderBook", series.id],
    queryFn: () => getKuruOrderBook(series, 18),
    refetchInterval: 5_000,
  });
  if (book.isLoading) return <Skeleton className="h-[620px] w-full rounded-3xl" />;
  if (!book.data) {
    return (
      <Card>
        <EmptyState title="No Kuru book yet" body="This series needs a registered Kuru market before public limit orders can appear here." />
      </Card>
    );
  }

  const asks = [...book.data.asks].reverse();
  const bids = book.data.bids;
  const maxTotal = [...asks, ...bids].reduce((m, l) => (l.total > m ? l.total : m), 0n);
  const bestAsk = book.data.asks[0]?.price;
  const bestBid = book.data.bids[0]?.price;
  const spread = bestAsk !== undefined && bestBid !== undefined && bestAsk > bestBid ? bestAsk - bestBid : undefined;

  return (
    <section className="card rise overflow-hidden p-0">
      <div className="border-b border-line p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="font-display text-lg font-semibold tracking-tight">Kuru order book</h2>
            <p className="mt-0.5 text-sm text-muted">Aggregated public bids and asks. Click the action buttons to fill through Optara.</p>
          </div>
          <Pill tone="primary" dot>Live</Pill>
        </div>
        <div className="mt-3 grid gap-2 sm:grid-cols-3">
          <BookStat label="Best bid" value={bestBid !== undefined ? fmtPrice(bestBid) : "—"} tone="text-good" />
          <BookStat label="Best ask" value={bestAsk !== undefined ? fmtPrice(bestAsk) : "—"} tone="text-bad" />
          <BookStat label="Spread" value={spread !== undefined ? fmtPrice(spread) : "—"} />
        </div>
      </div>

      <div className="grid grid-cols-[1fr_1fr_1fr] gap-2 border-b border-line px-4 py-2 text-[11px] font-bold uppercase tracking-[0.08em] text-faint sm:px-5">
        <span>Price ({series.assetSymbol})</span>
        <span className="text-right">Size</span>
        <span className="text-right">Total</span>
      </div>

      <div className="p-3 sm:p-4">
        <div className="space-y-1">
          {asks.length === 0 ? (
            <div className="rounded-xl bg-surface-2 px-3 py-4 text-center text-sm text-muted">No asks</div>
          ) : (
            asks.map((l) => <BookRow key={`ask-${l.price}`} level={l} maxTotal={maxTotal} series={series} />)
          )}
        </div>

        <div className="my-3 flex items-center justify-between rounded-2xl border border-line bg-surface-2 px-3 py-2.5">
          <span className="text-xs font-semibold text-muted">Optara fair value</span>
          <span className="num font-display text-lg font-semibold">{mark !== undefined ? `${fmtPrice(mark)} ${series.assetSymbol}` : "—"}</span>
        </div>

        <div className="space-y-1">
          {bids.length === 0 ? (
            <div className="rounded-xl bg-surface-2 px-3 py-4 text-center text-sm text-muted">No bids</div>
          ) : (
            bids.map((l) => <BookRow key={`bid-${l.price}`} level={l} maxTotal={maxTotal} series={series} />)
          )}
        </div>
      </div>
    </section>
  );
}

function BookStat({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <div className="rounded-2xl border border-line bg-surface-2/65 px-3 py-2.5">
      <div className="text-[11px] font-bold uppercase tracking-[0.08em] text-faint">{label}</div>
      <div className={cx("num mt-1 font-display text-lg font-semibold", tone ?? "text-ink")}>{value}</div>
    </div>
  );
}

function BookRow({ level, maxTotal, series }: { level: KuruBookLevel; maxTotal: bigint; series: Series }) {
  const pct = maxTotal > 0n ? Number((level.total * 10000n) / maxTotal) / 100 : 0;
  const isBid = level.side === "bid";
  return (
    <Link
      to={`/app/series/${series.id}?tab=${isBid ? "sell" : "buy"}`}
      className="relative grid grid-cols-[1fr_1fr_1fr] overflow-hidden rounded-xl px-3 py-2 text-sm transition hover:bg-surface-2"
      title={isBid ? "Sell options into this bid" : "Buy options from this ask"}
    >
      <span
        className={cx("absolute inset-y-0 right-0 opacity-15", isBid ? "bg-good" : "bg-bad")}
        style={{ width: `${pct}%` }}
      />
      <span className={cx("relative num font-semibold", isBid ? "text-good" : "text-bad")}>{fmtPrice(level.price)}</span>
      <span className="relative num text-right text-ink">{fmtQty(level.size)}</span>
      <span className="relative num text-right text-muted">{fmtQty(level.total)}</span>
    </Link>
  );
}

function SeriesQuickFacts({
  series,
  state,
  spot,
  mark,
  ask,
}: {
  series: Series;
  state: string;
  spot?: bigint;
  mark?: bigint;
  ask?: bigint;
}) {
  const isCall = series.optionType === 0;
  const spotN = spot !== undefined ? Number(spot) / 1e18 : undefined;
  const strike = Number(series.strikeWad) / 1e18;
  const move =
    spotN === undefined
      ? undefined
      : isCall
      ? (strike - spotN) / spotN
      : (spotN - strike) / spotN;
  const target =
    move === undefined
      ? "Waiting for live spot"
      : move <= 0
      ? "Already in the money"
      : `${isCall ? "Rise" : "Fall"} ${(move * 100).toFixed(1)}% to reach strike`;
  return (
    <section className="page-band">
      <div className="grid gap-3 md:grid-cols-4">
        <SimpleFact
          label="Direction"
          value={
            <span className={cx("inline-flex items-center gap-1.5", isCall ? "text-good" : "text-bad")}>
              {isCall ? <ArrowUpRight className="h-4 w-4" /> : <ArrowDownRight className="h-4 w-4" />}
              {isCall ? "Up / Call" : "Down / Put"}
            </span>
          }
        />
        <SimpleFact label="Strike" value={`$${fmtLevel(series.strikeWad)}`} sub={target} />
        <SimpleFact
          label="Buy price"
          value={ask !== undefined ? `${fmtPrice(ask)} ${series.assetSymbol}` : mark !== undefined ? `${fmtPrice(mark)} fair` : "No quote"}
        />
        <SimpleFact label="Status" value={state.replace("_", " ")} />
      </div>
    </section>
  );
}

function SimpleFact({ label, value, sub }: { label: string; value: React.ReactNode; sub?: string }) {
  return (
    <div className="rounded-lg border border-line bg-surface-2/60 p-3">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className="mt-1 font-display text-lg font-bold">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </div>
  );
}

// ------------------------------------------------------------------ Unified trade ticket (buy + sell merged)
function TradePanel({
  s,
  ctx,
  ask,
  bid,
  bidQty,
  mark,
  market,
  venueId,
  venueName,
  walletQty,
  initialSide,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  ask?: bigint;
  bid?: bigint;
  bidQty?: bigint;
  mark?: bigint;
  market?: Hex;
  venueId?: Hex;
  venueName?: string;
  walletQty: bigint;
  initialSide: "buy" | "sell";
  onQty: ChartReport;
}) {
  const [side, setSide] = useState<"buy" | "sell">(initialSide);
  useEffect(() => setSide(initialSide), [initialSide, s.id]);
  const hasTokens = walletQty > 0n;
  return (
    <div className="space-y-3.5">
      <Segmented
        value={side}
        onChange={setSide}
        options={[
          { value: "buy", label: "Buy now" },
          { value: "sell", label: `Sell now${hasTokens ? ` (${fmtQty(walletQty)})` : ""}`, disabled: !hasTokens, title: hasTokens ? undefined : "You hold none of this option yet" },
        ]}
      />
      {side === "buy" ? (
        <BuyPanel s={s} ctx={ctx} ask={ask} market={market} onQty={onQty} />
      ) : (
        <SellPanel s={s} ctx={ctx} bid={bid} bidQty={bidQty} mark={mark} market={market} venueId={venueId} venueName={venueName} walletQty={walletQty} onQty={onQty} />
      )}
      <Link to={`/app/series/${s.id}/orderbook`} className="flex items-center justify-between gap-3 rounded-2xl border border-line bg-surface-2/60 px-3.5 py-3 text-sm transition hover:border-primary/35 hover:bg-primary-soft/40">
        <span>
          <span className="block font-semibold text-ink">Open Kuru order book</span>
          <span className="text-xs text-muted">See public bids and asks, then place or fill orders.</span>
        </span>
        <ArrowRight className="h-4 w-4 shrink-0 text-primary" />
      </Link>
    </div>
  );
}

// ------------------------------------------------------------------ Kuru limit orders
function KuruLimitPanel({
  s,
  ctx,
  walletQty,
  mark,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  walletQty: bigint;
  mark?: bigint;
  onQty: ChartReport;
}) {
  const { address } = useConnection();
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [qtyText, setQtyText] = useState("1");
  const [priceText, setPriceText] = useState("");
  const qty = parseQty(qtyText);
  const price = parseFixed(priceText, 18);
  const { data: walletCash } = useTokenBalance(s.settlementAsset, address);
  const { data: seriesMarket } = useSeriesMarket(s);
  const limit = useQuery({
    queryKey: ["kuruLimitMarket", s.id, address],
    queryFn: () => getKuruLimitMarket(s, address),
    enabled: !!address,
    refetchInterval: 15_000,
  });

  useEffect(() => {
    if (!priceText && mark !== undefined) setPriceText(fmtPrice(mark, 6).replace(/,/g, ""));
  }, [mark, priceText]);
  useEffect(() => {
    if (!qty) return onQty(1);
    const q = Number(qty) / 1e18;
    onQty(q, price !== undefined ? Number(price) / 1e18 : undefined);
  }, [qty, price, onQty]);

  const m = limit.data;
  const bestKuru = useMemo(() => {
    const quotes = seriesMarket?.quotes ?? [];
    return quotes.find((q) => q.venueName === "Kuru") ?? quotes[0];
  }, [seriesMarket?.quotes]);
  const quickPrices = useMemo(
    () =>
      [
        mark !== undefined ? { label: "Fair", value: mark } : undefined,
        bestKuru?.bid !== undefined ? { label: "Best bid", value: bestKuru.bid } : undefined,
        bestKuru?.ask !== undefined ? { label: "Best ask", value: bestKuru.ask } : undefined,
      ].filter((x): x is { label: string; value: bigint } => !!x),
    [bestKuru?.ask, bestKuru?.bid, mark],
  );
  const priceUnitsRaw = price !== undefined && m ? (price * m.pricePrecision) / WAD : undefined;
  const priceUnits = priceUnitsRaw !== undefined && m ? (priceUnitsRaw / (m.tickSize || 1n)) * (m.tickSize || 1n) : undefined;
  const sizeUnits = qty !== undefined && m ? (qty * m.sizePrecision) / WAD : undefined;
  const roundedQty = sizeUnits !== undefined && m ? (sizeUnits * WAD) / m.sizePrecision : undefined;
  const quoteNeeded = roundedQty !== undefined && priceUnits !== undefined && m ? (priceUnits * roundedQty * 10n ** BigInt(s.assetDecimals)) / m.pricePrecision / WAD + 1n : undefined;
  const grossValue = quoteNeeded !== undefined && quoteNeeded > 0n ? quoteNeeded - 1n : undefined;
  // How far the limit price is from Optara's fair value. Kuru prices are per option, so a price far below fair value
  // is usually a total typed as a per-option price; say so with the totals before the order is placed.
  const markN = mark !== undefined && mark > 0n ? Number(mark) / 1e18 : undefined;
  const priceN = price !== undefined ? Number(price) / 1e18 : undefined;
  const qtyN = qty !== undefined ? Number(qty) / 1e18 : undefined;
  const offFair = markN !== undefined && priceN !== undefined && priceN > 0 ? priceN / markN - 1 : undefined;
  const fairWarning =
    offFair === undefined || markN === undefined || priceN === undefined || Math.abs(offFair) < 0.25
      ? undefined
      : side === "buy"
      ? offFair < 0
        ? `Your bid is ${Math.round(-offFair * 100)}% below fair value (${fmtPrice(mark!)} per option), so it may never fill. Prices are per option: ${qtyN !== undefined ? `${fmtQty(qty!)} options at fair value cost about ${usd(qtyN * markN)} in total, not ${usd(qtyN * priceN)}.` : "enter the price of one option, not the total."}`
        : `Your bid is ${Math.round(offFair * 100)}% above fair value (${fmtPrice(mark!)} per option). You would pay ${qtyN !== undefined ? usd(qtyN * priceN) : "more"} for options worth about ${qtyN !== undefined ? usd(qtyN * markN) : "less"}.`
      : offFair < 0
      ? `Your ask is ${Math.round(-offFair * 100)}% below fair value (${fmtPrice(mark!)} per option). Prices are per option: ${qtyN !== undefined ? `${fmtQty(qty!)} options would sell for ${usd(qtyN * priceN)} in total, while they are worth about ${usd(qtyN * markN)}.` : "enter the price of one option, not the total."}`
      : `Your ask is ${Math.round(offFair * 100)}% above fair value (${fmtPrice(mark!)} per option), so it may take a while to fill.`;
  const missingQuote = side === "buy" && quoteNeeded !== undefined && m ? (quoteNeeded > m.quoteBalance ? quoteNeeded - m.quoteBalance : 0n) : 0n;
  const missingOptions = side === "sell" && qty !== undefined && m ? (qty > m.optionBalance ? qty - m.optionBalance : 0n) : 0n;
  const tooMuchCash = missingQuote > 0n && walletCash !== undefined && missingQuote > walletCash;
  const tooManyOptions = missingOptions > 0n && missingOptions > walletQty;
  const priceBad = priceUnits !== undefined && (priceUnits === 0n || priceUnits > MAX_UINT32);
  // The book's price grid: prices are rounded down to a multiple of the tick, so anything below one tick rounds to 0.
  const priceStep = m ? ((m.tickSize || 1n) * WAD) / m.pricePrecision : undefined;
  const belowStep = priceBad && priceUnits === 0n && price !== undefined && price > 0n;
  const sizeBad = sizeUnits !== undefined && m && (sizeUnits < m.minSize || sizeUnits > m.maxSize || sizeUnits > MAX_UINT96 || roundedQty === 0n);
  const availableQuote = m ? m.quoteBalance + (walletCash ?? 0n) : 0n;
  const buyMaxQty = m && priceUnits && priceUnits > 0n ? (availableQuote * m.pricePrecision * WAD) / (priceUnits * 10n ** BigInt(s.assetDecimals)) : 0n;
  const sellMaxQty = m ? m.optionBalance + walletQty : 0n;
  const sliderMaxQty = side === "buy" ? buyMaxQty : sellMaxQty;
  const sliderPct = sliderMaxQty > 0n && qty !== undefined ? Math.min(100, Number((qty * 10000n) / sliderMaxQty) / 100) : 0;
  const setQtyPct = (pct: number) => {
    if (sliderMaxQty === 0n) return setQtyText("0");
    const next = (sliderMaxQty * BigInt(Math.round(pct * 100))) / 10000n;
    setQtyText(fmtQty(next).replace(/,/g, ""));
  };
  const placeSteps =
    address && m && qty && priceUnits && sizeUnits && !priceBad && !sizeBad
      ? [
          ...(side === "buy" && missingQuote > 0n ? kuruDepositSteps(m.margin, s.settlementAsset, missingQuote, s.assetSymbol, address) : []),
          ...(side === "sell" && missingOptions > 0n ? kuruDepositSteps(m.margin, s.wrapper, missingOptions, "option tokens", address) : []),
          ...(side === "buy" ? kuruLimitBuySteps(m.market, priceUnits, sizeUnits) : kuruLimitSellSteps(m.market, priceUnits, sizeUnits)),
        ]
      : undefined;

  if (!ctx.connected) return <Blocked reason="Connect a wallet to place limit orders." />;
  if (limit.isLoading) return <Skeleton className="h-64 w-full" />;
  if (!m) {
    return (
      <div className="space-y-3">
        <Blocked reason="Kuru limit orders are not available for this series yet." />
        <p className="rounded-xl border border-line bg-surface-2/70 p-3 text-[13px] leading-5 text-muted">
          The series needs a registered Kuru market with real Kuru order-book support. You can still use Buy now or Sell now when current Kuru liquidity exists.
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-hidden rounded-[26px] border border-line bg-surface shadow-[0_18px_50px_-34px_rgba(20,20,45,0.65)]">
      <div className="border-b border-line bg-surface-2/60 p-2">
        <div className="grid grid-cols-2 gap-1 rounded-2xl bg-surface p-1">
          {(["buy", "sell"] as const).map((next) => (
            <button
              key={next}
              type="button"
              onClick={() => setSide(next)}
              className={cx(
                "rounded-xl px-4 py-3 text-sm font-semibold transition cursor-pointer",
                side === next
                  ? next === "buy"
                    ? "bg-good text-[#02281b] shadow-[0_10px_24px_-16px_rgba(0,207,142,0.85)]"
                    : "bg-bad text-white shadow-[0_10px_24px_-16px_rgba(239,47,88,0.85)]"
                  : "text-muted hover:bg-surface-2 hover:text-ink",
              )}
            >
              {next === "buy" ? "Buy / Bid" : "Sell / Ask"}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-4 p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 className="font-display text-lg font-semibold tracking-tight">Kuru limit order</h3>
            <p className="mt-0.5 text-sm text-muted">{side === "buy" ? "Bid at your price. Funds wait on Kuru until filled or cancelled." : "List wallet options at your price. Tokens wait on Kuru until filled or cancelled."}</p>
          </div>
          <Term tip="No Optara buyer fee is charged when the bid is placed. If it fills, the filled option tokens stay on Kuru until you withdraw them. Any Optara interface fee should be charged only on filled withdrawals through Optara.">
            <span className="inline-flex items-center gap-1.5 rounded-full border border-line bg-surface-2 px-3 py-1.5 text-xs font-semibold text-muted shadow-sm">
              Fee note <Info className="h-3.5 w-3.5" />
            </span>
          </Term>
        </div>

        <div className="rounded-3xl border border-line bg-surface p-4 shadow-sm">
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
            <label className="block min-w-0">
              <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                <span className="text-sm font-semibold text-ink">Limit price</span>
                <span className="shrink-0 rounded-full bg-surface-2 px-2.5 py-1 text-xs font-semibold text-muted">{s.assetSymbol} per option</span>
              </div>
              <input
                inputMode="decimal"
                autoComplete="off"
                className={cx(
                  "w-full min-w-0 rounded-2xl border border-line bg-surface-2 px-4 py-4 font-display text-[28px] font-semibold leading-none tracking-tight outline-none transition placeholder:text-faint focus:border-primary focus:ring-2 focus:ring-primary/20",
                  priceBad && "border-bad text-bad focus:border-bad focus:ring-bad/20",
                )}
                placeholder="0.00"
                value={priceText}
                onChange={(e) => setPriceText(e.target.value.replace(/[^\d.]/g, ""))}
              />
              <div className={cx("mt-2 text-[13px]", priceBad ? "text-bad" : "text-muted")}>
                {belowStep && priceStep !== undefined
                  ? `This book prices in steps of ${fmtPrice(priceStep)} ${s.assetSymbol}: enter at least ${fmtPrice(priceStep)}.${mark !== undefined ? ` Fair value is ${fmtPrice(mark)}.` : ""}`
                  : priceBad
                    ? "Price is outside Kuru's supported range."
                    : mark !== undefined
                      ? `Price of one option. Fair value ${fmtPrice(mark)} ${s.assetSymbol}${priceStep !== undefined ? ` (price step ${fmtPrice(priceStep)})` : ""}.`
                      : "Set the premium per option."}
              </div>
              {fairWarning && !belowStep && !priceBad && (
                <div className="mt-2 rounded-xl border border-warn/40 bg-warn/8 px-3 py-2 text-[13px] font-semibold text-warn">{fairWarning}</div>
              )}
            </label>

            <label className="block min-w-0">
              <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                <span className="text-sm font-semibold text-ink">Amount</span>
                {side === "sell" && (
                  <button type="button" className="shrink-0 text-xs font-semibold text-primary hover:underline cursor-pointer" onClick={() => setQtyText(fmtQty(walletQty).replace(/,/g, ""))}>
                    Wallet · {fmtQty(walletQty)}
                  </button>
                )}
              </div>
              <input
                inputMode="decimal"
                autoComplete="off"
                className={cx(
                  "w-full min-w-0 rounded-2xl border border-line bg-surface-2 px-4 py-4 font-display text-[28px] font-semibold leading-none tracking-tight outline-none transition placeholder:text-faint focus:border-primary focus:ring-2 focus:ring-primary/20",
                  sizeBad && "border-bad text-bad focus:border-bad focus:ring-bad/20",
                )}
                placeholder="0.00"
                value={qtyText}
                onChange={(e) => setQtyText(e.target.value.replace(/[^\d.]/g, ""))}
              />
              <div className={cx("mt-2 text-[13px]", sizeBad ? "text-bad" : "text-muted")}>
                {sizeBad
                  ? `Kuru accepts ${fmtQty((m.minSize * WAD) / m.sizePrecision)} to ${fmtQty((m.maxSize * WAD) / m.sizePrecision)} options.`
                  : roundedQty !== undefined && qty !== roundedQty
                  ? `Kuru rounds this to ${fmtQty(roundedQty)} options.`
                  : "Option tokens to bid for or offer."}
              </div>
            </label>
          </div>

          <div className="mt-4 flex flex-col gap-3">
            {quickPrices.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {quickPrices.map((p) => (
                  <button
                    key={`${p.label}-${p.value}`}
                    type="button"
                    className="rounded-full border border-line bg-surface-2 px-3 py-1.5 text-xs font-semibold text-muted transition hover:border-primary/30 hover:text-ink cursor-pointer"
                    onClick={() => setPriceText(fmtPrice(p.value, 6).replace(/,/g, ""))}
                    title={`Use ${p.label.toLowerCase()} price`}
                  >
                    {p.label} · {fmtPrice(p.value)}
                  </button>
                ))}
              </div>
            )}

            <div className="flex items-center justify-between gap-3">
              <span className="text-xs font-semibold text-muted">Order size</span>
              <span className="rounded-full bg-surface-2 px-2.5 py-1 text-xs font-semibold text-ink">{Math.round(sliderPct)}%</span>
            </div>
          </div>

          <div className="mt-2 rounded-full bg-surface-2 px-3 py-2 shadow-inner">
              <input
                type="range"
                min="0"
                max="100"
                step="1"
                value={Math.round(sliderPct)}
                onChange={(e) => setQtyPct(Number(e.target.value))}
                style={{ "--fill": `${sliderPct}%` } as CSSProperties}
                aria-label="Order size"
                className="w-full cursor-grab active:cursor-grabbing"
              />
              <div className="mt-1 flex justify-between text-[11px] font-semibold text-muted">
                <span>0%</span>
                <span>{Math.round(sliderPct)}%</span>
                <span>100%</span>
              </div>
          </div>
        </div>

        <div className="rounded-3xl border border-line bg-surface-2/60 p-3">
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2 px-1">
            <div className="font-semibold text-ink">{side === "buy" ? "Bid summary" : "Ask summary"}</div>
            <Pill tone={side === "buy" ? "good" : "warn"}>{side === "buy" ? "Buying" : "Selling"}</Pill>
          </div>
          <div className="grid gap-2 md:grid-cols-3">
            <div className="min-w-0 rounded-2xl bg-surface px-3.5 py-3">
              <div className="text-xs font-semibold text-muted">{side === "buy" ? "You pay in total (held on Kuru until filled)" : "You receive in total if filled"}</div>
              <div className="num mt-1 break-words text-[15px] font-semibold leading-snug text-ink">
                {side === "buy"
                  ? quoteNeeded !== undefined
                    ? `${fmtNative(quoteNeeded, s.assetDecimals)} ${s.assetSymbol}`
                    : "—"
                  : grossValue !== undefined
                  ? `${fmtNative(grossValue, s.assetDecimals)} ${s.assetSymbol}`
                  : "—"}
              </div>
            </div>
            <div className="min-w-0 rounded-2xl bg-surface px-3.5 py-3">
              <div className="text-xs font-semibold text-muted">Move now</div>
              <div className="num mt-1 break-words text-[15px] font-semibold leading-snug text-ink">
                {side === "buy" ? (missingQuote > 0n ? `${fmtNative(missingQuote, s.assetDecimals)} ${s.assetSymbol}` : "None") : missingOptions > 0n ? `${fmtQty(missingOptions)} options` : "None"}
              </div>
            </div>
            <div className="min-w-0 rounded-2xl bg-surface px-3.5 py-3">
              <div className="text-xs font-semibold text-muted">{side === "buy" ? "If filled" : "To close short"}</div>
              <div className="mt-1 break-words text-[15px] font-semibold leading-snug text-ink">{side === "buy" ? `${roundedQty !== undefined ? fmtQty(roundedQty) : "—"} options on Kuru` : "Withdraw, then burn"}</div>
            </div>
          </div>
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-line bg-surface px-3.5 py-3">
          <div className="flex items-center gap-2 text-sm font-semibold text-ink">
            <Wallet className="h-4 w-4 text-primary" />
            Kuru balances
          </div>
          <div className="flex flex-wrap gap-2 text-xs">
            <span className="rounded-full bg-surface-2 px-3 py-1.5 font-semibold text-muted">{fmtNative(m.quoteBalance, s.assetDecimals)} {s.assetSymbol}</span>
            <span className="rounded-full bg-surface-2 px-3 py-1.5 font-semibold text-muted">{fmtQty(m.optionBalance)} options</span>
            <Term tip="Kuru balances are separate from Optara margin. Withdraw before redeeming, closing shorts, or using them as protocol collateral.">
              <span className="rounded-full bg-surface-2 px-3 py-1.5 font-semibold text-primary">Info</span>
            </Term>
          </div>
        </div>
      </div>

      <div className="border-t border-line bg-surface-2/45 p-4 sm:p-5">
        <TxButton
          label={side === "buy" ? "Place bid on Kuru" : "Place ask on Kuru"}
          summary={
            qty && price
              ? side === "buy"
                ? `Place a Kuru bid for ${fmtQty(qty)} ${seriesName(s)} options at ${fmtPrice(price)} ${s.assetSymbol} each. Unfilled funds stay on Kuru.`
                : `Place a Kuru ask for ${fmtQty(qty)} ${seriesName(s)} options at ${fmtPrice(price)} ${s.assetSymbol} each. Unfilled tokens stay on Kuru.`
              : undefined
          }
          steps={placeSteps}
          disabled={!placeSteps || tooMuchCash || tooManyOptions || priceBad || !!sizeBad}
          disabledReason={
            tooMuchCash
              ? `Wallet holds ${walletCash !== undefined ? fmtNative(walletCash, s.assetDecimals) : "0"} ${s.assetSymbol}.`
              : tooManyOptions
              ? `Wallet holds ${fmtQty(walletQty)} option tokens.`
              : undefined
          }
          successMessage={side === "buy" ? "Limit bid placed on Kuru." : "Limit ask placed on Kuru."}
        />
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Buy Panel
/** Ask levels read for the buy estimate; a full read means deeper asks may exist. */
const BUY_DEPTH_LEVELS = 50;

function BuyPanel({
  s,
  ctx,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  ask?: bigint;
  market?: Hex;
  onQty: ChartReport;
}) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("50");
  const premiumIn = parseFixed(amount, s.assetDecimals);
  const [slip] = useSlippage();
  const { data: pm } = useProductMarket(s.productId);
  const spot = pm ? Number(pm.spotWad) / 1e18 : undefined;
  const { data: sm } = useSeriesMarket(s);
  const { data: balance } = useTokenBalance(s.settlementAsset, address);
  const a = availability("buy", ctx);
  const buyVenues = useMemo(() => (sm?.quotes ?? []).filter((q) => q.ask !== undefined), [sm?.quotes]);
  const [venueKey, setVenueKey] = useState<string>("");
  const selectedQuote = useMemo<Quote | undefined>(() => {
    if (buyVenues.length === 0) return undefined;
    return buyVenues.find((q) => `${q.venueId}:${q.market}` === venueKey) ?? buyVenues[0];
  }, [buyVenues, venueKey]);
  useEffect(() => {
    if (buyVenues.length === 0) return;
    const hasSelected = buyVenues.some((q) => `${q.venueId}:${q.market}` === venueKey);
    if (!hasSelected) setVenueKey(`${buyVenues[0]!.venueId}:${buyVenues[0]!.market}`);
  }, [buyVenues, venueKey]);
  const ask = selectedQuote?.ask;
  const venueName = selectedQuote?.venueName ?? "venue";
  // Loaded, and no venue has an ask: nobody has offered this option yet (written tokens sit in the writer's wallet
  // until they place an ask), so there is nothing to buy.
  const nothingForSale = !!sm && buyVenues.length === 0;

  const fees = useQuery({
    queryKey: ["buyFees", s.id, premiumIn?.toString(), selectedQuote?.venueId, selectedQuote?.market],
    queryFn: async () => ({
      optara: await previewBuyerFee(premiumIn!),
      kuru: await venueBuyFee(selectedQuote!, premiumIn!),
    }),
    enabled: !!premiumIn && !!selectedQuote,
  });

  // The resting Kuru asks: a market buy walks them from the best price up, so estimate the fill by walking them too.
  const book = useQuery({
    queryKey: ["kuruBuyDepth", s.id, selectedQuote?.market],
    queryFn: () => getKuruOrderBook(s, BUY_DEPTH_LEVELS),
    enabled: !!selectedQuote,
    refetchInterval: 10_000,
  });
  // A book read with no asks while the venue quotes one means the depth view isn't available: fall back to the best ask.
  const asks = book.data && book.data.asks.length > 0 ? book.data.asks : undefined;
  const budgetWad = premiumIn && fees.data && premiumIn > fees.data.kuru ? toWadFromNative(premiumIn - fees.data.kuru, s.assetDecimals) : undefined;
  const walk = asks ? fillFromAsks(asks, budgetWad ?? 0n) : undefined;
  const depthPartial = !!book.data && book.data.asks.length >= BUY_DEPTH_LEVELS; // more levels may rest beyond what was read
  const rawQty = walk ? (budgetWad !== undefined ? walk.qty : undefined) : budgetWad !== undefined && ask ? (budgetWad * WAD) / ask : undefined;
  // A buy larger than every resting ask fills what is there; the rest of the budget is refunded.
  const avail = walk ? walk.depthQty : selectedQuote?.askQty;
  const depthLimited = walk ? walk.exhausted && !depthPartial : rawQty !== undefined && avail !== undefined && rawQty > avail;
  const estQty = depthLimited && !walk ? avail : rawQty;
  const spend = depthLimited
    ? toNative(walk ? walk.cost : (avail! * ask!) / WAD, s.assetDecimals) + (fees.data?.kuru ?? 0n) + 1n // premium the fill uses
    : undefined;
  const avgPrice = walk && walk.qty > 0n ? (walk.cost * WAD) / walk.qty : undefined;

  const total = premiumIn !== undefined && fees.data ? premiumIn + fees.data.optara : undefined; // what you put up
  // what the buy really costs: a depth-limited fill spends less and pays the fee on that only
  const cost = spend !== undefined && premiumIn && fees.data ? spend + (fees.data.optara * spend) / premiumIn : total;
  // Far above fair value, the buyer must confirm first (re-asked whenever the option or amount changes).
  const check = buyCheck(estQty, cost, s.assetDecimals, sm?.mark);
  const [ack, setAck] = useState(false);
  useEffect(() => setAck(false), [s.id, amount]);
  useEffect(() => {
    if (!estQty) return onQty(1);
    const q = Number(estQty) / 1e18;
    onQty(q, cost !== undefined ? Number(cost) / 10 ** s.assetDecimals / q : undefined);
  }, [estQty, cost, s.assetDecimals, onQty]);
  const tooMuch = total !== undefined && balance !== undefined && total > balance;

  const steps =
    address && premiumIn && fees.data && estQty && selectedQuote?.venueId
      ? buyVenueSteps(
          s,
          selectedQuote.venueId,
          venueName,
          premiumIn,
          venueMinQty(estQty, slip),
          withSlip(fees.data.optara, slip),
          withSlip(fees.data.kuru, slip),
          address
        )
      : undefined;

  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  return (
    <div className="space-y-3.5">
      <div className="flex items-center gap-2 rounded-xl border border-good/25 bg-good/8 px-3 py-2 text-[13px] text-good">
        <ShieldCheck className="h-4 w-4 shrink-0" />
        <span>Max loss is what you pay. No liquidation on longs.</span>
      </div>

      <AmountInput
        label="Premium to spend"
        value={amount}
        onChange={setAmount}
        unit={s.assetSymbol}
        hint="Paid from your wallet, not your margin account. A small Optara fee is added on top; the total is shown below."
        presets={["25", "50", "100", "250"]}
        max={balance !== undefined ? fmtNative(balance, s.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Wallet holds ${fmtNative(balance!, s.assetDecimals)} ${s.assetSymbol}.` : undefined}
      />

      {buyVenues.length > 1 && (
        <div>
          <div className="mb-1.5 text-xs font-bold uppercase text-faint">Trading venue</div>
          <div className="grid gap-2 sm:grid-cols-2">
            {buyVenues.map((q) => {
              const key = `${q.venueId}:${q.market}`;
              const active = key === `${selectedQuote?.venueId}:${selectedQuote?.market}`;
              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => setVenueKey(key)}
                  className={cx(
                    "rounded-2xl border p-3 text-left transition",
                    active ? "border-primary/60 bg-primary-soft text-ink" : "border-line bg-surface-2/60 text-muted hover:text-ink"
                  )}
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="font-bold">{q.venueName}</span>
                    {active && <Pill tone="primary">Selected</Pill>}
                  </div>
                  <div className="mt-1 text-xs">
                    Ask {q.ask !== undefined ? `${fmtPrice(q.ask)} ${s.assetSymbol}` : "—"} · fee {q.venueName === "Kuru" ? "venue fee" : "none"}
                  </div>
                </button>
              );
            })}
          </div>
        </div>
      )}

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5">
        <div className="rounded-xl border border-line bg-surface px-3 py-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
              <div className="text-[11px] font-bold uppercase text-faint">Estimated tokens</div>
              <div className="num text-xs text-muted">
                {ask !== undefined ? `${fmtPrice(ask)} ${s.assetSymbol} per option on ${venueName}` : "Nobody is selling this option right now"}
              </div>
            </div>
            {/* Own line, full width: MON-sized options can run to tens of thousands with four decimals. */}
            <div
              className={cx(
                "num mt-1.5 min-w-0 font-display font-bold leading-tight tracking-tight text-ink [overflow-wrap:anywhere]",
                estQty !== undefined && fmtQty(estQty).length > 12 ? "text-xl" : "text-2xl",
              )}
            >
              {estQty !== undefined ? fmtQty(estQty) : "—"}
              {estQty !== undefined && <span className="ml-1.5 text-sm font-semibold text-muted">options</span>}
            </div>
            <div className="mt-1 text-xs leading-5 text-muted">
              Your premium, less the venue fee, walked through the resting asks from the best price up.
            </div>
          </div>
        </div>

        {walk && walk.depthQty > 0n && (
          <div className="mt-2.5 rounded-xl border border-line bg-surface px-3 py-2.5 text-[13px]">
            <div className="flex flex-wrap items-baseline justify-between gap-x-2 gap-y-0.5">
              <span className="whitespace-nowrap font-semibold text-ink">Available to buy now</span>
              <span className="num whitespace-nowrap font-semibold text-ink">
                {depthPartial ? "at least " : "up to "}
                {fmtQty(walk.depthQty)} options
              </span>
            </div>
            <p className="mt-0.5 text-muted">
              For about {fmtNative(toNative(walk.depthCost, s.assetDecimals), s.assetDecimals)} {s.assetSymbol} from the current Kuru asks
              {asks!.length > 1 ? ` across ${asks!.length} prices, ${fmtPrice(asks![0]!.price)} to ${fmtPrice(asks![asks!.length - 1]!.price)}` : ` at ${fmtPrice(asks![0]!.price)}`} {s.assetSymbol} per option, before fees.
            </p>
            {avgPrice !== undefined && walk.levels > 1 && (
              <p className="mt-1 text-muted">
                Your budget reaches {walk.levels} price levels, so you pay about <b className="num text-ink">{fmtPrice(avgPrice)} {s.assetSymbol}</b> per option on average.
              </p>
            )}
          </div>
        )}

        {(nothingForSale || (avail !== undefined && avail === 0n)) && (
          <div className="mt-2.5 rounded-xl border border-warn/40 bg-warn/10 p-3 text-[13px]">
            <p className="font-semibold text-warn">Nothing is for sale on Kuru yet.</p>
            <p className="mt-0.5 text-muted">
              Options become buyable when a holder offers them. If you wrote this option, its tokens are in your wallet: place an ask on the{" "}
              <Link to={`/app/series/${s.id}/orderbook`} className="font-semibold text-primary underline">
                order book
              </Link>{" "}
              to sell them, then anyone can buy here.
            </p>
          </div>
        )}
        {depthLimited && avail! > 0n && spend !== undefined && (
          <div className="mt-2.5 rounded-xl border border-warn/40 bg-warn/10 p-3 text-[13px]">
            <p className="font-semibold text-warn">
              Only {fmtQty(avail!)} option{avail === WAD ? " is" : "s are"} for sale on {venueName} right now.
            </p>
            <p className="mt-0.5 text-muted">
              Your buy fills {fmtQty(avail!)} for about {fmtNative(spend, s.assetDecimals)} {s.assetSymbol}; the rest of your budget comes straight back.
            </p>
            <button type="button" onClick={() => setAmount(fmtNative(spend, s.assetDecimals, 6).replace(/,/g, ""))} className="mt-1.5 text-xs font-semibold text-primary underline cursor-pointer">
              Spend just {fmtNative(spend, s.assetDecimals, 6)} {s.assetSymbol}
            </button>
          </div>
        )}

        <div className="mt-2.5">
          <BuyOutcome series={s} qty={estQty} total={cost} spot={spot} mark={sm?.mark} ack={ack} onAck={setAck} />
        </div>

        <div className="mt-2.5">
          <Details summary={<span>Total cost <b className="num">{cost !== undefined ? `${fmtNative(cost, s.assetDecimals)} ${s.assetSymbol}` : "—"}</b></span>}>
            <Row
              label="Premium"
              value={premiumIn !== undefined ? `${fmtNative(premiumIn, s.assetDecimals)} ${s.assetSymbol}` : "—"}
            />
            <Row
              label={<Term tip="Charged by the selected venue. It comes out of the premium, so you may get slightly fewer options.">Venue fee (in premium)</Term>}
              value={fees.data ? `≈ ${fmtNative(fees.data.kuru, s.assetDecimals)}` : "—"}
            />
            <Row
              label={<Term tip="Added on top of the premium. Funds the insurance fund and the keepers that settle trades.">Optara fee (added)</Term>}
              value={fees.data ? `${fmtNative(fees.data.optara, s.assetDecimals)}` : "—"}
            />
          </Details>
        </div>
      </div>

      <LimitsPanel limits={buyLimits(s, premiumIn, estQty, fees.data, slip)} />

      <TxButton
        label={estQty && cost !== undefined ? `Buy ${fmtQty(estQty)} for ${fmtNative(cost, s.assetDecimals)} ${s.assetSymbol}` : "Buy"}
        summary={estQty && total !== undefined ? `Pay up to ${fmtNative(total, s.assetDecimals)} ${s.assetSymbol} (fees included${depthLimited ? "; the unused part is refunded" : ""}) for about ${fmtQty(estQty)} ${seriesName(s)} options on ${venueName}${check.over !== undefined && check.over > 0.1 ? `, ${(check.over * 100).toFixed(0)}% above fair value` : ""}` : undefined}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch || (check.needsAck && !ack)}
        disabledReason={a.reason ?? (nothingForSale ? "Nothing is for sale on Kuru yet." : check.needsAck && !ack ? "Confirm the price above first." : undefined)}
        disclosures={disclosuresFor("buy", s.underlyingSymbol)}
        successMessage="Bought. Tokens are in your wallet."
        onDone={() => recordTrade(address, s.id, "buy")}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Write Panel
export function WritePanel({
  s,
  ctx,
  bid,
  mark,
  writeCapacity,
  openInterest,
  openInterestCap,
  market,
  venueId,
  venueName,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  bid?: bigint;
  mark?: bigint;
  writeCapacity?: bigint;
  openInterest?: bigint;
  openInterestCap?: bigint;
  market?: Hex;
  venueId?: Hex;
  venueName?: string;
  onQty: ChartReport;
}) {
  const { address } = useConnection();
  const { selected } = useAccountState();
  const [amount, setAmount] = useState("1");
  const [sellNow, setSellNow] = useState(true);
  const [slip] = useSlippage();
  const qty = parseQty(amount);
  const stepErr = qtyStepError(qty);
  const a = availability("write", ctx);

  const preview = useQuery({
    queryKey: ["previewMint", selected?.toString(), s.id, qty?.toString()],
    queryFn: () => previewMint(selected!, s.id, qty!),
    enabled: selected !== undefined && !!qty && !stepErr,
    refetchInterval: 6_000,
  });

  const sellable = sellNow && !!market && bid !== undefined;
  const capBlocked = qty !== undefined && writeCapacity !== undefined && qty > writeCapacity;
  const grossProceeds = qty && bid ? toNative((qty * bid) / WAD, s.assetDecimals) : undefined;
  const sellFee = useQuery({
    queryKey: ["sellFee", venueId, market, grossProceeds?.toString()],
    queryFn: () => venueSellFee({ market: market!, venueId, venueName }, grossProceeds!),
    enabled: sellable && !!grossProceeds && !!market,
  });
  const net = grossProceeds !== undefined && sellFee.data !== undefined ? grossProceeds - sellFee.data : undefined;
  const [fee, equityAfter, imAfter, ok] = preview.data ?? [];
  // Premium kept per option: sale proceeds after the order-book fee, less the Optara fee paid from the account.
  const kept = sellable && net !== undefined && fee !== undefined ? net - fee : undefined;
  // Not selling right away: the premium still has to come from a later sale. Estimate it at the best bid (fair value
  // when nobody bids), less the Optara fee that the mint charges either way. The order-book fee is not known yet.
  const refPrice = bid ?? mark;
  const estKept = kept === undefined && qty && refPrice !== undefined ? toNative((qty * refPrice) / WAD, s.assetDecimals) - (fee ?? 0n) : undefined;
  const qtyNum = qty ? Number(qty) / 1e18 : undefined;
  useEffect(() => {
    if (!qtyNum) return onQty(1);
    if (kept !== undefined) return onQty(qtyNum, Number(kept) / 10 ** s.assetDecimals / qtyNum, { note: "kept after all fees" });
    if (estKept !== undefined)
      return onQty(qtyNum, Number(estKept) / 10 ** s.assetDecimals / qtyNum, {
        note: `if sold later at the ${bid !== undefined ? "best bid" : "fair value"}${fee !== undefined ? ", after the Optara fee" : ", before fees"}`,
      });
    onQty(qtyNum);
  }, [qtyNum, kept, estKept, bid, fee, s.assetDecimals, onQty]);
  const leg = legOf(s);
  const keptNum = kept !== undefined ? Number(kept) / 10 ** s.assetDecimals : undefined;
  // A writer whose fees exceed the sale never breaks even.
  const writerBe = keptNum !== undefined && keptNum > 0 && qtyNum ? breakeven(leg, keptNum / qtyNum) : undefined;
  const isCall = s.optionType === 0;
  const saleAvailable = !!market && bid !== undefined;
  // Why the Write button is off, in words (the preview is computed on fresh prices, as the transaction will be).
  const writeBlockedReason =
    !qty
      ? "Enter how many options to write."
      : preview.isError
        ? `Couldn't check this trade: ${(preview.error as Error).message.split("\n")[0]}`
        : !preview.data
          ? "Checking your margin…"
          : ok === false
            ? equityAfter !== undefined && imAfter !== undefined && equityAfter < BigInt(imAfter)
              ? `Not enough margin: writing ${amount} needs ${fmtWad(BigInt(imAfter), 2)} ${s.assetSymbol} of account value, and yours would be ${fmtWad(equityAfter > 0n ? equityAfter : 0n, 2)}. Add cash in Portfolio or write fewer.`
              : "Writing isn't possible right now: the account's cash doesn't cover the fee, the option is too close to expiry, or this market is closing-only."
            : undefined;

  if (!ctx.hasAccount && ctx.connected) return <AccountSetup s={s} />;
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  const steps =
    address && selected !== undefined && qty && fee !== undefined
      ? [
          ...mintSteps(selected, s, qty, withSlip(fee, slip), address),
          ...(sellable && net !== undefined && venueId ? sellVenueSteps(s, venueId, venueName ?? "venue", qty, lessSlip(net, slip), withSlip(sellFee.data!, slip), address) : []),
        ]
      : undefined;

  return (
    <div className="space-y-3.5">
      <div className="flex items-start gap-2 rounded-xl border border-accent/25 bg-accent/8 px-3 py-2 text-[13px] text-accent">
        <Coins className="h-4 w-4 shrink-0" />
        <span>
          Premium is received when the option token sells, but the written obligation stays open until you burn matching
          option tokens or settlement charges the payout from your margin account.
        </span>
      </div>

      <AmountInput
        label="Options to write"
        value={amount}
        onChange={setAmount}
        unit="options"
        presets={["0.1", "0.5", "1", "2"]}
        hint={`Steps of 0.01. One option covers ${leg.size} ${s.underlyingSymbol}.`}
      />

      {writeCapacity !== undefined && (
        <div className={cx("rounded-xl border px-3 py-2 text-[13px]", capBlocked ? "border-bad/30 bg-bad/8 text-bad" : "border-line bg-surface-2/60 text-muted")}>
          {capBlocked ? (
            <span>
              This market has only <b>{fmtQty(writeCapacity)}</b> options of write room left. Lower the size or choose another market.
            </span>
          ) : (
            <span>
              Write room left: <b className="text-ink">{fmtQty(writeCapacity)}</b>
              {openInterest !== undefined && openInterestCap !== undefined ? ` of ${fmtQty(openInterestCap)} total capacity.` : "."}
            </span>
          )}
        </div>
      )}

      <label
        className={cx(
          "flex cursor-pointer items-start gap-3 rounded-2xl border p-3 transition",
          sellNow && sellable ? "border-primary/50 bg-primary-soft/60" : "border-line bg-surface-2/60"
        )}
      >
        <input
          type="checkbox"
          className="mt-0.5 h-4 w-4 accent-[var(--primary)]"
          checked={sellNow}
          onChange={(e) => setSellNow(e.target.checked)}
          disabled={!market || bid === undefined}
        />
        <span className="text-[13px]">
          <span className="block font-semibold">Sell the new tokens now</span>
          <span className="block text-muted">
            {market && bid !== undefined
              ? `Optional Kuru sale. If it fills, cash goes to your wallet; if you turn this off, you receive tokens and no premium now.`
              : "No Kuru bid right now. Writing only mints option tokens to your wallet; it does not pay premium until someone buys them."}
          </span>
        </span>
      </label>

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5">
        {sellable && net !== undefined && (
          <div className="flex items-baseline justify-between gap-2 border-b border-line pb-2">
            <span className="text-[13px] text-muted">Kuru sale proceeds to wallet</span>
            <span className="num font-display text-xl font-bold text-good">
              +{fmtNative(net, s.assetDecimals)} {s.assetSymbol}
            </span>
          </div>
        )}
        {!sellable && (
          <div className="border-b border-line pb-2">
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-[13px] text-muted">Cash to wallet now</span>
              <span className="num font-display text-xl font-bold text-ink">0 {s.assetSymbol}</span>
            </div>
            <p className="mt-1 text-xs leading-5 text-muted">
              {saleAvailable
                ? "You turned off the Kuru sale. The option tokens go to your wallet, and you only receive premium if you sell them later."
                : "There is no active Kuru bid to sell into. The option tokens go to your wallet, and the written short stays in your margin account."}
            </p>
          </div>
        )}
        {keptNum !== undefined && qtyNum && (
          <ul className="space-y-1.5 border-b border-line py-2.5 text-[13px]">
            <li className="flex justify-between gap-3">
              <span className="text-muted">No expiry payout owed if {s.underlyingSymbol} ends {isCall ? "at or below" : "at or above"}</span>
              <span className="num shrink-0 font-semibold">{priceLevel(leg.strike)}</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">You start losing {isCall ? "above" : "below"}</span>
              <span className="num shrink-0 font-semibold">{writerBe !== undefined ? priceLevel(writerBe) : "—"}</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">Every $100 {isCall ? "above" : "below"} that costs you</span>
              <span className="num shrink-0 font-semibold text-bad">{usd(-qtyNum * leg.size * 100)}</span>
            </li>
          </ul>
        )}
        {sellable && net !== undefined && (
          <div className="border-b border-line py-2.5">
            <SellValueNotice qty={qty} proceeds={net} decimals={s.assetDecimals} mark={mark} />
          </div>
        )}
        <Details summary="Margin and fees">
          <Row
            label={<Term tip="Charged when the options are written, paid from your margin account.">Optara fee (from account)</Term>}
            value={fee !== undefined ? `${fmtNative(fee, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
          {sellable && (
            <Row
              label={<Term tip="Charged by the selected venue on the sale. Already taken out of the cash above.">Venue fee</Term>}
              value={sellFee.data !== undefined ? `${fmtNative(sellFee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"}
            />
          )}
          <Row
            label={<Term tip="Cash plus the value of your positions, after this trade.">Account value after</Term>}
            value={equityAfter !== undefined ? `$${fmtWad(equityAfter)}` : "—"}
            tone={ok === false ? "bad" : ok ? "good" : undefined}
          />
          <Row
            label={<Term tip="The account value you need to open this position. It comes from stress-testing big price and volatility moves.">Needed to open</Term>}
            value={imAfter !== undefined ? `$${fmtWad(imAfter)}` : "—"}
          />
        </Details>
        {ok === false && (
          <p className="mt-2 text-[13px] font-semibold text-bad">
            Not enough margin. Add collateral in Portfolio or lower the size.
          </p>
        )}
      </div>

      <LimitsPanel
        limits={[
          ...(fee !== undefined ? [{ label: "Max writing fee", value: `${fmtNative(withSlip(fee, slip), s.assetDecimals)} ${s.assetSymbol}`, tip: "The Optara writing fee can't exceed this." }] : []),
          ...(sellable && net !== undefined && sellFee.data !== undefined
            ? [
                { label: "Least cash accepted", value: `${fmtNative(lessSlip(net, slip), s.assetDecimals)} ${s.assetSymbol}`, tip: "If the sale would pay less than this, it is cancelled and you keep the options." },
                { label: "Max venue fee", value: `${fmtNative(withSlip(sellFee.data, slip), s.assetDecimals)} ${s.assetSymbol}`, tip: "The selected venue's fee can't exceed this." },
              ]
            : []),
        ]}
      />

      <TxButton
        summary={qty ? `Write ${fmtQty(qty)} ${seriesName(s)} options from account #${selected}${sellable && net !== undefined ? `, sell the tokens for about ${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}, and keep the short open until you close or settle it` : ", leaving the option tokens in your wallet"}` : undefined}
        label={sellable && net !== undefined ? `Write and sell for ${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}` : `Write ${amount || "0"} option${amount === "1" ? "" : "s"}`}
        tone="accent"
        steps={ok ? steps : undefined}
        disabled={!a.enabled || !steps || ok === false || capBlocked || !!stepErr}
        disabledReason={a.reason ?? stepErr ?? (capBlocked ? "This market is at its open-interest limit for that size." : writeBlockedReason)}
        disclosures={disclosuresFor("write", s.underlyingSymbol)}
        successMessage={
          sellable
            ? "Written and sold. Cash is in your wallet; the short remains open."
            : "Written. The tokens are in your wallet: to sell them, place an ask on the order book (Trade → Open Kuru order book)."
        }
      />
    </div>
  );
}

// ------------------------------------------------------------------ Account Setup (1-Click Onboarding)
export function AccountSetup({ s }: { s: Series }) {
  const { refresh, select } = useAccountState();
  const { address } = useConnection();
  const { data: balance } = useTokenBalance(s.settlementAsset, address);
  const [amount, setAmount] = useState("1000");
  const deposit = parseFixed(amount, s.assetDecimals);
  const created = useRef<bigint | undefined>(undefined);

  const steps = useMemo(
    () => (deposit ? setupAccountSteps(s.settlementAsset, deposit, s.assetSymbol, (id) => (created.current = id)) : undefined),
    [deposit, s]
  );

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-primary/40 bg-primary-soft p-4 text-xs">
        <div className="font-bold text-ink text-sm flex items-center gap-1.5">
          <Sparkles className="h-4 w-4 text-primary" /> Create your margin account
        </div>
        <p className="mt-1 text-muted leading-relaxed">
          Writing needs collateral. One step creates your margin account and deposits funds.
        </p>
      </div>

      <AmountInput
        label="Initial Deposit"
        value={amount}
        onChange={setAmount}
        unit={s.assetSymbol}
        presets={["500", "1000", "2500", "5000"]}
        max={balance !== undefined ? fmtNative(balance, s.assetDecimals).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
      />

      <TxButton
        label="Create Account & Deposit"
        summary={deposit ? `New account, then ${fmtNative(deposit, s.assetDecimals)} ${s.assetSymbol} from your wallet into it` : undefined}
        steps={steps}
        disabled={!deposit}
        successMessage="Your Optara account is active!"
        onDone={async () => {
          await refresh();
          if (created.current !== undefined) select(created.current);
        }}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Sell Panel
function SellPanel({
  s,
  ctx,
  bid,
  bidQty,
  mark,
  market,
  venueId,
  venueName,
  walletQty,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  bid?: bigint;
  /** Options the bid will buy (venues that report depth); a bigger sale sells this much and returns the rest. */
  bidQty?: bigint;
  mark?: bigint;
  market?: Hex;
  venueId?: Hex;
  venueName?: string;
  walletQty: bigint;
  onQty: ChartReport;
}) {
  const { address } = useConnection();
  const [slip] = useSlippage();
  const [amount, setAmount] = useState("");
  const qty = parseQty(amount);
  const a = availability("sell", ctx);

  const sold = qty !== undefined && bidQty !== undefined && qty > bidQty ? bidQty : qty;
  const depthLimited = qty !== undefined && sold !== qty;
  const gross = sold && bid ? toNative((sold * bid) / WAD, s.assetDecimals) : undefined;
  const fee = useQuery({
    queryKey: ["sellFee", venueId, market, gross?.toString()],
    queryFn: () => venueSellFee({ market: market!, venueId, venueName }, gross!),
    enabled: !!market && !!gross,
  });
  const net = gross !== undefined && fee.data !== undefined ? gross - fee.data : undefined;
  // The chart compares the cash this sale brings in with holding the same options to expiry.
  useEffect(() => {
    const n = sold ? Number(sold) / 1e18 : 0;
    if (!n) return onQty(qty ? Number(qty) / 1e18 : 1, undefined, { view: "sell" });
    onQty(n, net !== undefined ? Number(net) / 10 ** s.assetDecimals / n : undefined, { view: "sell" });
  }, [qty, sold, net, s.assetDecimals, onQty]);
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  const tooMuch = qty !== undefined && qty > walletQty;
  const steps =
    address && qty && net !== undefined && fee.data !== undefined && venueId
      ? sellVenueSteps(s, venueId, venueName ?? "venue", qty, lessSlip(net, slip), withSlip(fee.data, slip), address)
      : undefined;

  return (
    <div className="space-y-4">
      <AmountInput
        label="Options to Sell"
        value={amount}
        onChange={setAmount}
        unit="options"
        max={fmtQty(walletQty)}
        maxLabel="Available in Wallet"
        invalid={tooMuch ? "Amount exceeds wallet holdings." : undefined}
      />

      <div className="rounded-2xl border border-line bg-surface-2 p-4 space-y-1">
        <Row label="Best bid per option" value={bid !== undefined ? `${fmtPrice(bid)} ${s.assetSymbol}${venueName ? ` on ${venueName}` : ""}` : "Nobody is bidding right now"} />
        <Row label={<Term tip="Charged by the selected venue on the sale.">Venue fee</Term>} value={fee.data !== undefined ? `−${fmtNative(fee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        <Row strong label="Cash to your wallet" value={net !== undefined ? `+${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}` : "—"} tone="good" />
        <SellValueNotice qty={sold} proceeds={net} decimals={s.assetDecimals} mark={mark} />
        {depthLimited && (
          <p className="pt-1 text-[13px] font-semibold text-warn">
            {sold === 0n ? `Nobody is bidding on ${venueName ?? "this venue"} right now.` : `The bid takes only ${fmtQty(sold!)} option${sold === WAD ? "" : "s"}: that many sell, the rest stay in your wallet.`}
          </p>
        )}
      </div>

      <LimitsPanel
        limits={
          net !== undefined && fee.data !== undefined
            ? [
                { label: "Least cash accepted", value: `${fmtNative(lessSlip(net, slip), s.assetDecimals)} ${s.assetSymbol}`, tip: "If the sale would pay less than this, it is cancelled and you keep the options." },
                { label: "Max venue fee", value: `${fmtNative(withSlip(fee.data, slip), s.assetDecimals)} ${s.assetSymbol}`, tip: "The selected venue's fee can't exceed this." },
              ]
            : []
        }
      />

      <TxButton
        label="Sell Options Now"
        summary={sold && net !== undefined ? `Sell ${fmtQty(sold)} ${seriesName(s)} options for about ${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}` : undefined}
        steps={steps}
        disabled={!steps || tooMuch}
        disabledReason={a.reason}
        successMessage="Options sold! Proceeds are in your wallet."

        onDone={() => recordTrade(address, s.id, "sell")}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Manage Panel
function ManagePanel({
  s,
  ctx,
  walletQty,
  position,
}: {
  s: Series;
  ctx: ActionContext;
  walletQty: bigint;
  position: bigint;
}) {
  const { selected } = useAccountState();
  const { address } = useConnection();
  const [unwrapAmt, setUnwrapAmt] = useState("");
  const [closeAmt, setCloseAmt] = useState("");
  const [wrapAmt, setWrapAmt] = useState("");

  const u = availability("unwrap", ctx);
  const c = availability("close", ctx);
  const w = availability("wrap", ctx);

  const uq = parseQty(unwrapAmt);
  const cq = parseQty(closeAmt);
  const wq = parseQty(wrapAmt);
  const maxClose = position < 0n ? (-position < walletQty ? -position : walletQty) : 0n;
  const accountLong = position > 0n ? position : 0n;
  const accountShort = position < 0n ? -position : 0n;

  if (ctx.connected && !ctx.hasAccount) {
    return (
      <div className="space-y-3.5">
        <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
          <div className="font-display text-lg font-bold">Position tools need a margin account</div>
          <p className="mt-1 text-xs leading-5 text-muted">
            Create an account to hold margin positions, offset written options, and move option tokens between account and wallet.
          </p>
        </div>
        <AccountSetup s={s} />
      </div>
    );
  }

  return (
    <div className="space-y-3.5">
      <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
        <div className="mb-3 flex items-start gap-2">
          <Shield className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
          <div>
            <div className="font-display text-lg font-bold">Manage this position</div>
            <p className="mt-0.5 text-xs leading-5 text-muted">
              Closing is not free: it burns matching option tokens from your wallet against the written position. If you sold
              the tokens earlier, you need to buy or receive them back first.
            </p>
          </div>
        </div>
        <div className="grid gap-2 sm:grid-cols-3 sm:[grid-template-columns:repeat(3,minmax(0,1fr))]">
          <PositionBalance label="Wallet tokens" value={fmtQty(walletQty)} hint="Can sell or redeem" />
          <PositionBalance label="Account long" value={fmtQty(accountLong)} hint="Can move to wallet" tone={accountLong > 0n ? "good" : undefined} />
          <PositionBalance label="Written" value={fmtQty(accountShort)} hint="Short exposure" tone={accountShort > 0n ? "warn" : undefined} />
        </div>
      </div>

      <ManageAction
        icon={RotateCcw}
        title="Close written options"
        text="Burn matching wallet tokens to reduce the written position. This removes risk only for the amount burned."
        available={maxClose > 0n}
        blocked={!c.enabled ? c.reason : maxClose === 0n ? "No closable written position. You need written options and matching wallet tokens." : undefined}
      >
        <AmountInput label="Options to close" value={closeAmt} onChange={setCloseAmt} unit="options" max={fmtQty(roundDownQty(maxClose))} hint="Steps of 0.01." />
        <TxButton
          label="Close written options"
          steps={selected !== undefined && cq ? closeShortSteps(selected, s, cq) : undefined}
          disabled={!c.enabled || !cq || cq > maxClose || !!qtyStepError(cq)}
          disabledReason={c.reason ?? qtyStepError(cq) ?? (cq && cq > maxClose ? `You can close up to ${fmtQty(roundDownQty(maxClose))}.` : undefined)}
          successMessage="Closed by burning matching option tokens. Margin freed."
        />
      </ManageAction>

      <ManageAction
        icon={ArrowRight}
        title="Move wallet tokens into margin account"
        text="Use this to offset written options or hold the long inside your margin account."
        available={walletQty > 0n}
        blocked={!u.enabled ? u.reason : walletQty === 0n ? "No wallet tokens to move in." : undefined}
      >
        <AmountInput label="Options to move in" value={unwrapAmt} onChange={setUnwrapAmt} unit="options" max={fmtQty(roundDownQty(walletQty))} hint="Steps of 0.01; any smaller remainder stays in your wallet." />
        <TxButton
          label="Move into account"
          steps={selected !== undefined && uq ? unwrapSteps(selected, s, uq) : undefined}
          disabled={!u.enabled || !uq || uq > walletQty || !!qtyStepError(uq)}
          disabledReason={u.reason ?? qtyStepError(uq) ?? (uq && uq > walletQty ? `Wallet has ${fmtQty(walletQty)}.` : undefined)}
          successMessage="Moved into your account."
        />
      </ManageAction>

      <ManageAction
        icon={Wallet}
        title="Move account longs to wallet"
        text="Use this when you want wallet tokens you can sell on a venue or redeem after settlement."
        available={accountLong > 0n}
        blocked={!w.enabled ? w.reason : accountLong === 0n ? "No account longs to move out." : undefined}
      >
        <AmountInput label="Options to move out" value={wrapAmt} onChange={setWrapAmt} unit="options" max={fmtQty(roundDownQty(accountLong))} hint="Steps of 0.01." />
        <TxButton
          label="Move to wallet"
          steps={selected !== undefined && wq && address ? wrapSteps(selected, s, wq, address) : undefined}
          disabled={!w.enabled || !wq || wq > accountLong || !!qtyStepError(wq)}
          disabledReason={w.reason ?? qtyStepError(wq) ?? (wq && wq > accountLong ? `Account has ${fmtQty(accountLong)} long options.` : undefined)}
          successMessage="Sent to your wallet."
        />
      </ManageAction>
    </div>
  );
}

function PositionBalance({ label, value, hint, tone }: { label: string; value: string; hint: string; tone?: "good" | "warn" }) {
  return (
    <div className={cx("min-w-0 rounded-xl border bg-surface p-3", tone === "good" ? "border-good/25" : tone === "warn" ? "border-accent/30" : "border-line")}>
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div
        className={cx(
          "num font-display mt-1 overflow-hidden text-ellipsis whitespace-nowrap text-[clamp(1rem,3.8vw,1.25rem)] font-bold",
          tone === "good" ? "text-good" : tone === "warn" ? "text-accent" : "text-ink",
        )}
        title={value}
      >
        {value}
      </div>
      <div className="mt-0.5 text-[11px] text-muted">{hint}</div>
    </div>
  );
}

function ManageAction({
  icon: Icon,
  title,
  text,
  children,
  blocked,
  available,
}: {
  icon: typeof Shield;
  title: string;
  text: string;
  children: React.ReactNode;
  blocked?: string;
  available: boolean;
}) {
  return (
    <div className={cx("rounded-2xl border p-3.5", available ? "border-line bg-surface/70" : "border-line bg-surface-2/35")}>
      <div className="mb-3 flex items-start gap-3">
        <div className={cx("grid h-9 w-9 shrink-0 place-items-center rounded-xl", available ? "bg-primary-soft text-primary" : "bg-surface-2 text-faint")}>
          <Icon className="h-4 w-4" />
        </div>
        <div>
          <div className="font-bold">{title}</div>
          <p className="mt-0.5 text-xs leading-5 text-muted">{blocked ?? text}</p>
        </div>
      </div>
      <div className={cx("space-y-3", !available && "opacity-75")}>{children}</div>
    </div>
  );
}

// ------------------------------------------------------------------ Redeem Panel
function RedeemPanel({ s, ctx, walletQty }: { s: Series; ctx: ActionContext; walletQty: bigint }) {
  const { address } = useConnection();
  const { selected } = useAccountState();

  const credit = useQuery({
    queryKey: ["credit", selected?.toString(), s.groupId],
    queryFn: () =>
      publicClient.readContract({
        address: ADDR.settlement,
        abi: settlementWindowAbi,
        functionName: "creditOf",
        args: [selected!, s.groupId],
      }),
    enabled: selected !== undefined,
  });

  const payout = useQuery({
    queryKey: ["previewRedeem", s.id, walletQty.toString()],
    queryFn: () => previewRedeem(s.id, walletQty),
    enabled: walletQty > 0n,
  });

  const r = availability("redeem", ctx);
  const c = availability("claim", { ...ctx, credit: (credit.data ?? 0n) > 0n });
  const steps = useMemo(
    () => (address && walletQty > 0n ? redeemSteps(s, walletQty, address) : undefined),
    [address, walletQty, s]
  );

  return (
    <div className="space-y-4">
      <SettlementTimeline state={ctx.groupState} />

      <div className="rounded-2xl border border-line bg-surface-2 p-4 space-y-2">
        <Row label="Option tokens in your wallet" value={fmtQty(walletQty)} />
        <Row
          strong
          label="Your cash payout"
          value={
            walletQty === 0n
              ? "—"
              : payout.data
              ? `${fmtNative(payout.data[0], s.assetDecimals)} ${s.assetSymbol}${payout.data[1] ? "" : " (before any shortfall cut)"}`
              : "Known once the price is fixed"
          }
          tone="good"
        />
        {payout.data && payout.data[0] === 0n && walletQty > 0n && (
          <p className="text-xs text-muted">This option expired out of the money, so it pays nothing.</p>
        )}
      </div>

      <TxButton
        label="Redeem tokens for cash"
        summary={payout.data ? `Burn ${fmtQty(walletQty)} option tokens for ${fmtNative(payout.data[0], s.assetDecimals)} ${s.assetSymbol}` : undefined}
        steps={steps}
        disabled={!r.enabled}
        disabledReason={r.reason}
        successMessage="Cash payout transferred directly to your wallet!"
      />

      {selected !== undefined && (credit.data ?? 0n) > 0n && (
        <TxButton
          label={`Claim Account #${selected} Settlement Credit`}
          steps={claimSteps(selected, s.groupId)}
          disabled={!c.enabled}
          disabledReason={c.reason}
          successMessage="Credit claimed successfully."
        />
      )}
    </div>
  );
}

// ------------------------------------------------------------------ Shared UI Elements
export function StatePill({ state }: { state: string }) {
  const map: Record<string, [string, "good" | "warn" | "bad" | "neutral" | "primary"]> = {
    ACTIVE: ["Live Trading", "good"],
    EXPIRED: ["Expired · Awaiting Price", "warn"],
    ORACLE_STALLED: ["Price Feed Late", "bad"],
    FINALIZED: ["Settling Accounts", "primary"],
    ALL_SETTLED: ["Opening Payouts", "primary"],
    REDEEMABLE: ["Payouts Open", "good"],
  };
  const [label, tone] = map[state] ?? [state, "neutral"];
  return (
    <Pill tone={tone} dot={state === "ACTIVE"}>
      {label}
    </Pill>
  );
}

function Terms({ s, market }: { s: Series; market?: Hex }) {
  const [open, setOpen] = useState(false);
  const isCall = s.optionType === 0;
  const leg = legOf(s);
  return (
    <Card
      title={
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="flex w-full items-center justify-between text-left"
        >
          <span className="text-xs sm:text-sm font-bold text-ink">Market details</span>
          <span className="text-xs text-primary font-semibold">
            {open ? "Hide" : "Show"}
          </span>
        </button>
      }
    >
      {open ? (
        <div className="space-y-3 pt-2">
          <div className="rounded-2xl border border-line bg-surface-2/60 p-3">
            <div className="mb-2 flex items-center gap-2">
              <span className={cx("grid h-8 w-8 place-items-center rounded-xl", isCall ? "bg-good/10 text-good" : "bg-bad/10 text-bad")}>
                {isCall ? <ArrowUpRight className="h-4 w-4" /> : <ArrowDownRight className="h-4 w-4" />}
              </span>
              <div>
                <div className="font-display text-base font-bold">{s.underlyingSymbol} {optionTypeName(s.optionType)}</div>
                <div className="text-xs text-muted">{isCall ? "Pays when settlement is above strike" : "Pays when settlement is below strike"}</div>
              </div>
            </div>
            <div className="grid gap-2 sm:grid-cols-2">
              <TermTile label="Strike" value={`$${fmtLevel(s.strikeWad)}`} />
              <TermTile label="Expires" value={fmtExpiry(s.expiry)} />
              <TermTile label="Contract size" value={`1 option = ${leg.size} ${s.underlyingSymbol}`} />
              <TermTile label="Cash asset" value={s.assetSymbol} />
            </div>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3">
            <div className="text-[11px] font-bold uppercase text-faint">Expiry payout</div>
            <div className="mt-1 text-sm font-semibold text-ink">
              {isCall ? "If settlement price is above strike:" : "If settlement price is below strike:"}
            </div>
            <div className="mt-2 rounded-xl bg-surface px-3 py-2 text-xs text-muted">
              {isCall ? "payout = settlement price - strike" : "payout = strike - settlement price"}
            </div>
            <p className="mt-2 text-xs leading-5 text-muted">
              The settlement price comes from the official feed at expiry. The option is European, so the protocol settles it at expiry rather than exercising early.
            </p>
          </div>

          <div className="rounded-2xl border border-line bg-surface-2/60 p-3">
            <div className="text-[11px] font-bold uppercase text-faint">Contracts</div>
            <div className="mt-2 space-y-2">
              <AddressLine label="Option token" value={s.wrapper} copyLabel="token address" />
              <AddressLine label="Order book" value={market} copyLabel="market address" empty="Not listed yet" />
            </div>
          </div>
        </div>
      ) : (
        <p className="text-xs text-muted">
          Cash-settled in {s.assetSymbol}. The strike, expiry and payout formula cannot change.
        </p>
      )}
    </Card>
  );
}

function TermTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-line/70 bg-surface px-3 py-2">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className="mt-0.5 text-sm font-bold text-ink">{value}</div>
    </div>
  );
}

function AddressLine({ label, value, copyLabel, empty }: { label: string; value?: string; copyLabel: string; empty?: string }) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-xl border border-line/70 bg-surface px-3 py-2 text-xs">
      <span className="font-semibold text-muted">{label}</span>
      {value ? (
        <span className="flex items-center gap-1.5 font-bold text-ink">
          {shortAddr(value)} <CopyButton text={value} label={copyLabel} />
        </span>
      ) : (
        <span className="font-semibold text-faint">{empty ?? "Unavailable"}</span>
      )}
    </div>
  );
}

function Blocked({ reason }: { reason?: string }) {
  return reason ? (
    <div className="rounded-2xl border border-line bg-surface-2 p-4 text-xs text-muted flex items-start gap-2">
      <Info className="h-4 w-4 text-warn shrink-0 mt-0.5" />
      <span>{reason}</span>
    </div>
  ) : null;
}

export function SettlementTimeline({ state }: { state: string }) {
  const steps = [
    { key: "EXPIRED", label: "Expired" },
    { key: "FINALIZED", label: "Price fixed" },
    { key: "ALL_SETTLED", label: "Accounts settled" },
    { key: "REDEEMABLE", label: "Payouts open" },
  ];
  const order = ["ACTIVE", "EXPIRED", "FINALIZED", "ALL_SETTLED", "REDEEMABLE"];
  const at = order.indexOf(state === "ORACLE_STALLED" ? "EXPIRED" : state);
  // The step being worked on is the one after the last finished one.
  const current = state === "REDEEMABLE" ? -1 : steps.findIndex((st) => order.indexOf(st.key) > at);

  return (
    <ol className="grid grid-cols-4 gap-1.5" aria-label="Settlement progress">
      {steps.map((st, i) => {
        const done = at >= order.indexOf(st.key);
        const now = i === current;
        return (
          <li key={st.key} className="flex flex-col gap-1.5" aria-current={now ? "step" : undefined}>
            <div className={cx("h-1.5 rounded-full", done ? "bg-good" : now ? "bg-primary/60 animate-pulse" : "bg-line")} />
            <span className={cx("flex items-center gap-1 text-[11px] font-semibold leading-tight", done ? "text-ink" : now ? "text-primary" : "text-muted")}>
              <span
                className={cx(
                  "grid h-4 w-4 shrink-0 place-items-center rounded-full text-[9px]",
                  done ? "bg-good text-white" : now ? "bg-primary text-white" : "border border-line",
                )}
              >
                {done ? "✓" : i + 1}
              </span>
              <span className="min-w-0">{st.label}</span>
            </span>
            {i === 0 && state === "ORACLE_STALLED" && <span className="text-[10px] font-bold text-bad">Price feed late</span>}
          </li>
        );
      })}
    </ol>
  );
}
