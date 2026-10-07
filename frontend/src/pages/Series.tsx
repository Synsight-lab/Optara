/** `/series/:id` (and `/trade/:id`): terms, payoff, simulator and every action on one series (FRONTEND.md §2, §4, §7). */
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import { settlementWindowAbi } from "@optara/sdk";
import {
  ArrowLeft,
  ArrowRight,
  CheckCircle2,
  ChevronDown,
  ChevronUp,
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
import { AmountInput, Card, CopyButton, EmptyState, Pill, Row, Segmented, Skeleton, Stat, Term, cx, useTicker } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { PayoffChart } from "../components/PayoffChart.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { availability, type ActionContext, type ActionKey } from "../lib/optara/availability.ts";
import {
  buySteps,
  closeShortSteps,
  mintSteps,
  redeemSteps,
  claimSteps,
  sellSteps,
  setupAccountSteps,
  unwrapSteps,
  wrapSteps,
} from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import {
  fmtDuration,
  fmtExpiry,
  fmtIv,
  fmtNative,
  fmtPrice,
  fmtQty,
  fmtWad,
  optionTypeName,
  parseFixed,
  parseQty,
  shortAddr,
  WAD,
} from "../lib/optara/format.ts";
import {
  useAccountView,
  useChainTime,
  useProductMarket,
  useSeries,
  useSeriesMarket,
  useTokenBalance,
  useWalletWrappers,
} from "../lib/optara/hooks.ts";
import { kuruSellFee, kuruTakerFee, previewBuyerFee, previewMint, previewRedeem } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { HealthBar } from "../components/HealthBar.tsx";

type Tab = "buy" | "write" | "sell" | "manage" | "redeem";
const SLIPPAGE_BPS = 100n; // FRONTEND.md §7: 1% default
const withSlip = (x: bigint) => (x * (10_000n + SLIPPAGE_BPS)) / 10_000n + 1n;
const lessSlip = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
/** WAD amount in the settlement asset → native units. */
const toNative = (wad: bigint, decimals: number) => wad / 10n ** BigInt(18 - decimals);
const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);

export function SeriesPage({ initialTab }: { initialTab?: Tab }) {
  const { id } = useParams();
  const [params, setParams] = useSearchParams();
  const series = useSeries(id as Hex | undefined);
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
  const [qtyForChart, setQtyForChart] = useState(1);

  if (!series) {
    return (
      <Card>
        {id ? (
          <Skeleton className="h-40 w-full" />
        ) : (
          <EmptyState
            title="Unknown option series"
            action={
              <Link to="/" className="btn-ghost">
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

  const tabs: { value: Tab; label: string; icon: any; actions: ActionKey[] }[] = [
    { value: "buy", label: "Buy Option", icon: TrendingUp, actions: ["buy"] },
    { value: "write", label: "Write (Yield)", icon: Coins, actions: ["write"] },
    { value: "sell", label: "Sell Tokens", icon: TrendingDown, actions: ["sell"] },
    { value: "manage", label: "Manage / Hedge", icon: Shield, actions: ["unwrap", "close", "wrap"] },
    { value: "redeem", label: "Redeem Payout", icon: CheckCircle2, actions: ["redeem", "claim"] },
  ];

  const spotNum = product ? Number(product.spotWad) / 1e18 : undefined;
  const markNum = market?.mark !== undefined ? Number(market.mark) / 1e18 : undefined;
  const side = tab === "write" || tab === "sell" ? "short" : "long";
  const premiumForChart = (side === "long" ? market?.quote?.ask : market?.quote?.bid) ?? market?.mark;

  const select = (t: Tab) => {
    setTab(t);
    setParams((p) => (p.set("tab", t), p), { replace: true });
  };

  const isCall = series.optionType === 0;

  return (
    <div className="space-y-6">
      {/* Navigation Breadcrumb */}
      <div className="flex items-center justify-between">
        <Link
          to="/"
          className="flex items-center gap-1.5 text-xs font-semibold text-muted hover:text-primary transition"
        >
          <ArrowLeft className="h-4 w-4" /> Back to all markets
        </Link>
        <button
          onClick={openGuide}
          className="flex items-center gap-1 text-xs font-medium text-primary hover:underline"
        >
          <HelpCircle className="h-3.5 w-3.5" /> What does this option mean?
        </button>
      </div>

      {/* Main Header Card */}
      <section className="relative overflow-hidden rounded-3xl border border-line bg-surface/90 p-5 sm:p-7 backdrop-blur-xl shadow-xl">
        <div className="flex flex-col md:flex-row md:items-start justify-between gap-6">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <span
                className={cx(
                  "pill font-bold",
                  isCall ? "bg-good/15 text-good" : "bg-bad/15 text-bad"
                )}
              >
                {isCall ? "CALL (BULLISH)" : "PUT (BEARISH)"}
              </span>
              <StatePill state={state} />
              <span className="pill bg-surface-2 text-muted">European Cash-Settled</span>
            </div>

            <div className="mt-3 flex items-center gap-3">
              <TokenIcon symbol={series.underlyingSymbol} className="h-8 w-8 sm:h-9 sm:w-9" />
              <div>
                <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight">
                  {series.underlyingSymbol} ${fmtWad(series.strikeWad, 0)} {optionTypeName(series.optionType)}
                </h1>
                <p className="text-xs text-muted mt-0.5 flex items-center gap-1.5">
                  <Clock className="h-3.5 w-3.5 text-primary" />
                  Expires {fmtExpiry(series.expiry)}
                  {tick !== undefined && series.expiry > tick && (
                    <span className="num font-semibold text-ink">
                      · {fmtDuration(series.expiry - tick)} remaining
                    </span>
                  )}
                </p>
              </div>
            </div>
          </div>

          {/* Quick Metrics */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 sm:gap-6 border-t md:border-t-0 border-line pt-4 md:pt-0">
            <Stat
              label={`${series.underlyingSymbol} Spot`}
              value={product ? `$${fmtWad(product.spotWad, 0)}` : "…"}
              sub={product?.spotFresh ? "Pyth live" : "delayed"}
              tone={product?.spotFresh ? "good" : "warn"}
            />
            <Stat
              label={<Term tip="The protocol fair value per option derived from the volatility surface.">Mark Fair Value</Term>}
              value={market?.mark !== undefined ? fmtPrice(market.mark) : "—"}
              sub={series.assetSymbol}
            />
            <Stat
              label={<Term tip="Implied Volatility: market's expected price fluctuation. Higher IV = higher option value.">Implied Vol (IV)</Term>}
              value={market?.iv !== undefined ? fmtIv(market.iv) : "—"}
              sub="Annualized"
            />
            <Stat
              label={<Term tip="Live bid/ask order book quotes on Kuru.">Kuru Bid / Ask</Term>}
              value={
                market?.quote ? (
                  <span>
                    <span className="text-good">{market.quote.bid !== undefined ? fmtPrice(market.quote.bid) : "—"}</span>
                    <span className="text-muted"> / </span>
                    <span className="text-bad">{market.quote.ask !== undefined ? fmtPrice(market.quote.ask) : "—"}</span>
                  </span>
                ) : (
                  "No orders"
                )
              }
              sub={series.assetSymbol}
            />
          </div>
        </div>

        {/* Existing Position / Wallet Holdings Banner */}
        {(walletQty > 0n || position !== 0n) && (
          <div className="mt-5 flex flex-wrap items-center gap-2 border-t border-line pt-4 text-xs">
            <Wallet className="h-4 w-4 text-primary" />
            <span className="font-semibold text-ink">Your Holdings:</span>
            {walletQty > 0n && (
              <Pill tone="primary">{fmtQty(walletQty)} option tokens in your wallet</Pill>
            )}
            {position > 0n && (
              <Pill tone="good">{fmtQty(position)} long in Account #{selected?.toString()}</Pill>
            )}
            {position < 0n && (
              <Pill tone="accent">{fmtQty(-position)} short (written) in Account #{selected?.toString()}</Pill>
            )}
          </div>
        )}
      </section>

      {/* Main Grid: Interactive Payoff Simulator on Left, Actions Card on Right */}
      <div className="grid gap-6 lg:grid-cols-[1fr_420px]">
        {/* Left Column: Interactive Visualizer & Simulator */}
        <div className="space-y-6">
          <Card
            title={
              <span className="flex items-center gap-2">
                <Sparkles className="h-4 w-4 text-primary" />
                <span>
                  {side === "long" ? "Estimated Payout & Risk at Expiry" : "Writer Payoff & Obligation"}
                </span>
              </span>
            }
            action={
              <span className="text-xs text-muted font-medium">
                Simulating {Number(qtyForChart.toFixed(2))} option{qtyForChart === 1 ? "" : "s"}
              </span>
            }
          >
            {spotNum !== undefined || markNum !== undefined ? (
              <PayoffChart
                optionType={series.optionType}
                strike={Number(series.strikeWad) / 1e18}
                spot={spotNum}
                premium={premiumForChart !== undefined ? Number(premiumForChart) / 1e18 : 0}
                qty={qtyForChart}
                side={side}
                assetSymbol={series.assetSymbol}
                underlyingSymbol={series.underlyingSymbol}
              />
            ) : (
              <Skeleton className="h-60 w-full" />
            )}

            {/* Interactive Price Target Simulator Slider */}
            <PriceTargetSimulator
              series={series}
              spot={spotNum}
              premium={premiumForChart !== undefined ? Number(premiumForChart) / 1e18 : 0}
              qty={qtyForChart}
              side={side}
            />
          </Card>

          {/* Immutable Contract Terms */}
          <Terms s={series} market={market?.quote?.market} />
        </div>

        {/* Right Column: High-Conversion Action Tabs */}
        <div>
          <Card className="h-fit lg:sticky lg:top-24 shadow-xl">
            {/* Action Selector Tab Pills */}
            <div className="mb-5 flex gap-1.5 overflow-x-auto pb-1 border-b border-line">
              {tabs.map((t) => {
                const isSelected = tab === t.value;
                const a = t.actions.map((k) => availability(k, ctx));
                const isDisabled = a.every((x) => !x.enabled);
                return (
                  <button
                    key={t.value}
                    onClick={() => select(t.value)}
                    disabled={isDisabled}
                    title={isDisabled ? a[0]?.reason : undefined}
                    className={cx(
                      "flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 text-xs font-bold transition disabled:opacity-30",
                      isSelected
                        ? "bg-primary text-white shadow-md"
                        : "text-muted hover:bg-surface-2 hover:text-ink"
                    )}
                  >
                    <t.icon className="h-3.5 w-3.5" />
                    <span>{t.label}</span>
                  </button>
                );
              })}
            </div>

            {/* Tab Body */}
            {tab === "buy" && (
              <BuyPanel
                s={series}
                ctx={ctx}
                ask={market?.quote?.ask}
                market={market?.quote?.market}
                onQty={setQtyForChart}
              />
            )}
            {tab === "write" && (
              <WritePanel
                s={series}
                ctx={ctx}
                bid={market?.quote?.bid}
                market={market?.quote?.market}
                onQty={setQtyForChart}
              />
            )}
            {tab === "sell" && (
              <SellPanel
                s={series}
                ctx={ctx}
                bid={market?.quote?.bid}
                market={market?.quote?.market}
                walletQty={walletQty}
                onQty={setQtyForChart}
              />
            )}
            {tab === "manage" && (
              <ManagePanel s={series} ctx={ctx} walletQty={walletQty} position={position} />
            )}
            {tab === "redeem" && (
              <RedeemPanel s={series} ctx={ctx} walletQty={walletQty} />
            )}

            {/* Active Subaccount Health Widget */}
            {account && (
              <div className="mt-6 border-t border-line pt-4">
                <div className="flex items-center justify-between text-xs mb-2">
                  <span className="font-semibold text-ink">Account #{selected?.toString()} Health</span>
                  <Link to="/portfolio" className="text-primary hover:underline font-medium">
                    View Portfolio →
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
          </Card>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Interactive Price Target Simulator
function PriceTargetSimulator({
  series,
  spot,
  premium,
  qty,
  side,
}: {
  series: Series;
  spot?: number;
  premium: number;
  qty: number;
  side: "long" | "short";
}) {
  const strike = Number(series.strikeWad) / 1e18;
  const basePrice = spot ?? strike;
  const [targetPrice, setTargetPrice] = useState(basePrice);

  useEffect(() => {
    if (spot) setTargetPrice(spot);
  }, [spot]);

  const isCall = series.optionType === 0;
  const grossPayoffPerOption = isCall
    ? Math.max(0, targetPrice - strike)
    : Math.max(0, strike - targetPrice);

  const netProfitPerOption =
    side === "long" ? grossPayoffPerOption - premium : premium - grossPayoffPerOption;

  const totalNet = netProfitPerOption * qty;
  const totalCost = premium * qty;
  const roi = totalCost > 0 ? ((totalNet / totalCost) * 100).toFixed(0) : "0";
  const pctFromSpot = spot ? (((targetPrice - spot) / spot) * 100).toFixed(1) : "0";

  return (
    <div className="mt-4 rounded-2xl border border-line bg-surface-2/60 p-4">
      <div className="flex items-center justify-between">
        <span className="text-xs font-bold text-ink flex items-center gap-1.5">
          <Sparkles className="h-3.5 w-3.5 text-primary" /> Target Price Simulator
        </span>
        <span className="text-xs text-muted">
          At expiry, if {series.underlyingSymbol} is: <b className="num text-ink font-bold">${targetPrice.toLocaleString(undefined, { maximumFractionDigits: 0 })}</b>
        </span>
      </div>

      {/* Target Price Slider */}
      <input
        type="range"
        min={Math.round(basePrice * 0.5)}
        max={Math.round(basePrice * 1.5)}
        step={Math.round(basePrice * 0.005) || 1}
        value={targetPrice}
        onChange={(e) => setTargetPrice(Number(e.target.value))}
        className="mt-3 w-full accent-[var(--primary)] cursor-pointer"
      />

      {/* Quick Target Presets */}
      <div className="mt-2 flex flex-wrap gap-1.5">
        {[
          { label: "Current Spot", mult: 1.0 },
          { label: "+5%", mult: 1.05 },
          { label: "+10%", mult: 1.1 },
          { label: "+20%", mult: 1.2 },
          { label: "-10%", mult: 0.9 },
        ].map((p) => (
          <button
            key={p.label}
            type="button"
            onClick={() => spot && setTargetPrice(Math.round(spot * p.mult))}
            className="rounded-lg border border-line/60 bg-surface px-2 py-0.5 text-[10px] font-semibold text-muted hover:text-ink hover:border-primary/40 transition"
          >
            {p.label}
          </button>
        ))}
      </div>

      {/* Dynamic Results Grid */}
      <div className="mt-4 grid grid-cols-3 gap-2 border-t border-line/60 pt-3 text-center">
        <div>
          <div className="text-[10px] text-muted font-medium">Price Change</div>
          <div className={cx("num mt-0.5 text-xs font-bold", Number(pctFromSpot) >= 0 ? "text-good" : "text-bad")}>
            {Number(pctFromSpot) >= 0 ? `+${pctFromSpot}%` : `${pctFromSpot}%`}
          </div>
        </div>
        <div>
          <div className="text-[10px] text-muted font-medium">Net Profit / Loss</div>
          <div className={cx("num mt-0.5 text-xs sm:text-sm font-black", totalNet >= 0 ? "text-good" : "text-bad")}>
            {totalNet >= 0 ? `+$${totalNet.toFixed(2)}` : `-$${Math.abs(totalNet).toFixed(2)}`}
          </div>
        </div>
        <div>
          <div className="text-[10px] text-muted font-medium">Estimated ROI</div>
          <div className={cx("num mt-0.5 text-xs sm:text-sm font-black", totalNet >= 0 ? "text-good" : "text-bad")}>
            {totalNet >= 0 ? `+${roi}%` : `${roi}%`}
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Buy Panel
function BuyPanel({
  s,
  ctx,
  ask,
  market,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  ask?: bigint;
  market?: Hex;
  onQty: (q: number) => void;
}) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("50");
  const premiumIn = parseFixed(amount, s.assetDecimals);
  const { data: balance } = useTokenBalance(s.settlementAsset, address);
  const a = availability("buy", ctx);

  const fees = useQuery({
    queryKey: ["buyFees", s.id, premiumIn?.toString(), market],
    queryFn: async () => ({
      optara: await previewBuyerFee(premiumIn!),
      kuru: await kuruTakerFee(market!, premiumIn!),
    }),
    enabled: !!premiumIn && !!market,
  });

  const estQty =
    premiumIn && ask && fees.data
      ? (toWadFromNative(premiumIn - fees.data.kuru, s.assetDecimals) * WAD) / ask
      : undefined;

  useEffect(() => onQty(estQty ? Math.max(Number(estQty) / 1e18, 0.01) : 1), [estQty, onQty]);

  const total = premiumIn !== undefined && fees.data ? premiumIn + fees.data.optara : undefined;
  const tooMuch = total !== undefined && balance !== undefined && total > balance;

  const steps =
    address && premiumIn && fees.data && estQty
      ? buySteps(
          s,
          premiumIn,
          lessSlip(estQty),
          withSlip(fees.data.optara),
          withSlip(fees.data.kuru),
          address
        )
      : undefined;

  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  return (
    <div className="space-y-4">
      {/* 100% Capped Risk Safety Badge */}
      <div className="rounded-2xl border border-good/30 bg-good/10 p-3 text-xs text-good flex items-center gap-2">
        <ShieldCheck className="h-4 w-4 shrink-0" />
        <span>
          <b>Zero Liquidation Risk</b>: Your loss is 100% capped at the purchase price.
        </span>
      </div>

      <AmountInput
        label="You Spend"
        value={amount}
        onChange={setAmount}
        unit={s.assetSymbol}
        presets={["25", "50", "100", "250", "500"]}
        max={balance !== undefined ? fmtNative(balance, s.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Your wallet only has ${fmtNative(balance!, s.assetDecimals)} ${s.assetSymbol}.` : undefined}
      />

      {/* Outcome preview card */}
      <div className="rounded-2xl border border-line bg-surface-2 p-4">
        <div className="flex items-baseline justify-between">
          <span className="text-xs text-muted font-medium">Estimated Options Received:</span>
          <span className="num text-2xl font-black text-ink">
            {estQty !== undefined ? fmtQty(estQty) : "—"}
          </span>
        </div>
        <div className="text-right text-[11px] text-muted">
          Price: {ask !== undefined ? `$${fmtWad(ask, 2)}` : "—"} {s.assetSymbol} / option
        </div>

        {/* 3-Line Transparent Cost Breakdown */}
        <div className="mt-3 border-t border-line pt-2 space-y-1">
          <Row
            label="Option Premium"
            value={premiumIn !== undefined ? `${fmtNative(premiumIn, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
          <Row
            label={<Term tip="Charged by the Kuru order book.">Kuru Venue Fee</Term>}
            value={fees.data ? `≈ ${fmtNative(fees.data.kuru, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
          <Row
            label={<Term tip="Optara protocol fee on premium, supporting the insurance fund and keepers.">Optara Fee</Term>}
            value={fees.data ? `${fmtNative(fees.data.optara, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
          <Row
            strong
            label="Total Deducted From Wallet"
            value={total !== undefined ? `${fmtNative(total, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
        </div>
      </div>

      <TxButton
        label={estQty ? `Buy ${fmtQty(estQty)} Options Now` : "Buy Options"}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch}
        disabledReason={a.reason}
        disclosures={disclosuresFor("buy", s.underlyingSymbol)}
        successMessage="Options bought successfully! Tokens are in your wallet."
      />
    </div>
  );
}

// ------------------------------------------------------------------ Write Panel
function WritePanel({
  s,
  ctx,
  bid,
  market,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  bid?: bigint;
  market?: Hex;
  onQty: (q: number) => void;
}) {
  const { address } = useConnection();
  const { selected } = useAccountState();
  const [amount, setAmount] = useState("1");
  const [sellNow, setSellNow] = useState(true);
  const qty = parseQty(amount);
  useEffect(() => onQty(qty ? Number(qty) / 1e18 : 1), [qty, onQty]);
  const a = availability("write", ctx);

  const preview = useQuery({
    queryKey: ["previewMint", selected?.toString(), s.id, qty?.toString()],
    queryFn: () => previewMint(selected!, s.id, qty!),
    enabled: selected !== undefined && !!qty,
    refetchInterval: 6_000,
  });

  const sellable = sellNow && !!market && bid !== undefined;
  const grossProceeds = qty && bid ? toNative((qty * bid) / WAD, s.assetDecimals) : undefined;
  const sellFee = useQuery({
    queryKey: ["sellFee", market, grossProceeds?.toString()],
    queryFn: () => kuruSellFee(market!, grossProceeds!),
    enabled: sellable && !!grossProceeds,
  });
  const net = grossProceeds !== undefined && sellFee.data !== undefined ? grossProceeds - sellFee.data : undefined;
  const [fee, equityAfter, imAfter, ok] = preview.data ?? [];

  if (!ctx.hasAccount && ctx.connected) return <AccountSetup s={s} />;
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  const steps =
    address && selected !== undefined && qty && fee !== undefined
      ? [
          ...mintSteps(selected, s, qty, withSlip(fee), address),
          ...(sellable && net !== undefined ? sellSteps(s, qty, lessSlip(net), withSlip(sellFee.data!), address) : []),
        ]
      : undefined;

  return (
    <div className="space-y-4">
      {/* Yield Banner */}
      <div className="rounded-2xl border border-accent/30 bg-accent/10 p-3 text-xs text-accent flex items-center gap-2">
        <Coins className="h-4 w-4 shrink-0" />
        <span>
          <b>Earn Cash Yield</b>: Collect premium upfront today. Requires collateral in your Optara subaccount.
        </span>
      </div>

      <AmountInput
        label="Number of Options to Write"
        value={amount}
        onChange={setAmount}
        unit="options"
        presets={["0.1", "0.5", "1", "2"]}
        hint="Min 0.01. Requires sufficient initial margin (IM)."
      />

      <label
        className={cx(
          "flex cursor-pointer items-start gap-3 rounded-2xl border p-3.5 transition",
          sellable ? "border-primary bg-primary-soft/50" : "border-line bg-surface-2/60"
        )}
      >
        <input
          type="checkbox"
          className="mt-0.5 h-4 w-4 accent-[var(--primary)]"
          checked={sellNow}
          onChange={(e) => setSellNow(e.target.checked)}
          disabled={!market || bid === undefined}
        />
        <span className="text-xs">
          <span className="block font-bold text-ink">Sell on Kuru immediately for instant cash</span>
          <span className="block text-muted">
            {market && bid !== undefined
              ? `Best bid $${fmtWad(bid)} ${s.assetSymbol}. Premium is transferred straight to your wallet.`
              : "No current bids on Kuru. You will receive the option tokens into your wallet instead."}
          </span>
        </span>
      </label>

      {/* Write Financials Breakdown */}
      <div className="rounded-2xl border border-line bg-surface-2 p-4 space-y-2">
        {sellable && net !== undefined && (
          <div className="flex items-baseline justify-between border-b border-line pb-2">
            <span className="text-xs text-muted font-medium">Upfront Cash To Your Wallet:</span>
            <span className="num text-xl font-black text-good">
              +${fmtNative(net, s.assetDecimals)} {s.assetSymbol}
            </span>
          </div>
        )}
        <Row
          label="Optara Minting Fee"
          value={fee !== undefined ? `${fmtNative(fee, s.assetDecimals)} ${s.assetSymbol}` : "—"}
        />
        {sellable && (
          <Row
            label="Kuru Venue Fee"
            value={sellFee.data !== undefined ? `${fmtNative(sellFee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
        )}
        <Row
          strong
          label={<Term tip="Your subaccount's equity and margin requirement after writing.">Account Equity vs Required Margin</Term>}
          value={equityAfter !== undefined ? `$${fmtWad(equityAfter)} / $${fmtWad(imAfter!)}` : "—"}
          tone={ok === false ? "bad" : ok ? "good" : undefined}
        />
        {ok === false && (
          <p className="mt-2 text-xs font-semibold text-bad">
            ⚠️ Insufficient margin. Deposit more collateral in Portfolio or write a smaller amount.
          </p>
        )}
      </div>

      <TxButton
        label={sellable ? `Write & Sell for +$${net !== undefined ? fmtNative(net, s.assetDecimals) : ""}` : `Write ${amount || "0"} Options`}
        tone="accent"
        steps={ok ? steps : undefined}
        disabled={!a.enabled || !steps || ok === false}
        disabledReason={a.reason}
        disclosures={disclosuresFor("write", s.underlyingSymbol)}
        successMessage={sellable ? "Options written and sold! Premium is in your wallet." : "Options written! Tokens sent to your wallet."}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Account Setup (1-Click Onboarding)
function AccountSetup({ s }: { s: Series }) {
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
          <Sparkles className="h-4 w-4 text-primary" /> Create Your Optara Account
        </div>
        <p className="mt-1 text-muted leading-relaxed">
          Writing options requires collateral. One click creates your dedicated smart subaccount and deposits your initial margin.
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
  market,
  walletQty,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  bid?: bigint;
  market?: Hex;
  walletQty: bigint;
  onQty: (q: number) => void;
}) {
  const { address } = useConnection();
  const [amount, setAmount] = useState("");
  const qty = parseQty(amount);
  useEffect(() => onQty(qty ? Number(qty) / 1e18 : 1), [qty, onQty]);
  const a = availability("sell", ctx);

  const gross = qty && bid ? toNative((qty * bid) / WAD, s.assetDecimals) : undefined;
  const fee = useQuery({
    queryKey: ["sellFee", market, gross?.toString()],
    queryFn: () => kuruSellFee(market!, gross!),
    enabled: !!market && !!gross,
  });
  const net = gross !== undefined && fee.data !== undefined ? gross - fee.data : undefined;
  if (!a.enabled && ctx.connected) return <Blocked reason={a.reason} />;

  const tooMuch = qty !== undefined && qty > walletQty;
  const steps =
    address && qty && net !== undefined && fee.data !== undefined
      ? sellSteps(s, qty, lessSlip(net), withSlip(fee.data), address)
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
        <Row label="Current Highest Bid" value={bid !== undefined ? `$${fmtWad(bid)} ${s.assetSymbol}` : "No bids"} />
        <Row label="Kuru Venue Fee" value={fee.data !== undefined ? `${fmtNative(fee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"} />
        <Row strong label="Net Cash to Wallet" value={net !== undefined ? `+$${fmtNative(net, s.assetDecimals)} ${s.assetSymbol}` : "—"} tone="good" />
      </div>

      <TxButton
        label="Sell Options Now"
        steps={steps}
        disabled={!steps || tooMuch}
        disabledReason={a.reason}
        successMessage="Options sold! Proceeds are in your wallet."
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

  return (
    <div className="space-y-4">
      <Section
        title="Close Written Position (Short)"
        text="Burn wallet tokens to cancel your written liability and release collateral."
        blocked={!c.enabled ? c.reason : undefined}
      >
        <AmountInput label="Amount to Close" value={closeAmt} onChange={setCloseAmt} unit="options" max={fmtQty(maxClose)} />
        <TxButton
          label="Close Short"
          steps={selected !== undefined && cq ? closeShortSteps(selected, s, cq) : undefined}
          disabled={!c.enabled || !cq || cq > maxClose}
          disabledReason={c.reason}
          successMessage="Position closed and margin freed!"
        />
      </Section>

      <Section
        title="Hedge / Move Tokens Into Account"
        text="Deposit option tokens into your subaccount to offset shorts and reduce margin."
        blocked={!u.enabled ? u.reason : undefined}
      >
        <AmountInput label="Amount to Move" value={unwrapAmt} onChange={setUnwrapAmt} unit="options" max={fmtQty(walletQty)} />
        <TxButton
          label="Move Into Account"
          steps={selected !== undefined && uq ? unwrapSteps(selected, s, uq) : undefined}
          disabled={!u.enabled || !uq || uq > walletQty}
          disabledReason={u.reason}
          successMessage="Tokens deposited into account."
        />
      </Section>

      <Section
        title="Wrap Long Tokens to Wallet"
        text="Convert internal longs into tradeable ERC-20 tokens in your wallet."
        blocked={!w.enabled ? w.reason : undefined}
      >
        <AmountInput label="Amount to Wrap" value={wrapAmt} onChange={setWrapAmt} unit="options" max={position > 0n ? fmtQty(position) : "0"} />
        <TxButton
          label="Withdraw to Wallet"
          steps={selected !== undefined && wq && address ? wrapSteps(selected, s, wq, address) : undefined}
          disabled={!w.enabled || !wq}
          disabledReason={w.reason}
          successMessage="Option tokens sent to your wallet."
        />
      </Section>
    </div>
  );
}

function Section({
  title,
  text,
  children,
  blocked,
}: {
  title: string;
  text: string;
  children: React.ReactNode;
  blocked?: string;
}) {
  const [open, setOpen] = useState(!blocked);
  return (
    <div className="rounded-2xl border border-line bg-surface-2/40 overflow-hidden">
      <button
        className="flex w-full items-center justify-between gap-3 p-3.5 text-left transition hover:bg-surface-2/70"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
      >
        <div>
          <span className="block text-xs font-bold text-ink">{title}</span>
          <span className="block text-[11px] text-muted">{blocked ?? text}</span>
        </div>
        <span className="text-muted">{open ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}</span>
      </button>
      {open && <div className="space-y-3 border-t border-line p-3.5 bg-surface/40">{children}</div>}
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
        <Row label="Option Tokens in Wallet" value={fmtQty(walletQty)} />
        <Row
          strong
          label="Your Cash Payout"
          value={
            payout.data
              ? `$${fmtNative(payout.data[0], s.assetDecimals)} ${s.assetSymbol}${payout.data[1] ? "" : " (estimated)"}`
              : "—"
          }
          tone="good"
        />
      </div>

      <TxButton
        label="Redeem Tokens for Cash"
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
  return (
    <Card
      title={
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="flex w-full items-center justify-between text-left"
        >
          <span className="text-xs sm:text-sm font-bold text-ink">Contract Specifications & Addresses</span>
          <span className="text-xs text-primary font-semibold">
            {open ? "Hide Specs ▲" : "Show Specs ▼"}
          </span>
        </button>
      }
    >
      {open ? (
        <div className="grid gap-x-8 gap-y-2 sm:grid-cols-2 text-xs pt-2">
          <Row label="Exercise Style" value={`European ${optionTypeName(s.optionType).toLowerCase()}`} />
          <Row label="Strike Price" value={`$${fmtWad(s.strikeWad, 2)} ${s.assetSymbol}`} />
          <Row label="Underlying Unit" value={`1.000 ${s.underlyingSymbol}`} />
          <Row label="Settlement Asset" value={s.assetSymbol} />
          <Row label="Final Expiry" value={fmtExpiry(s.expiry)} />
          <Row label="Oracle Settlement" value="Chainlink round in force at expiry" />
          <Row
            label="Option ERC-20"
            value={
              <span>
                {shortAddr(s.wrapper)} <CopyButton text={s.wrapper} label="token address" />
              </span>
            }
          />
          <Row
            label="Kuru CLOB Market"
            value={market ? <span>{shortAddr(market)} <CopyButton text={market} label="market address" /></span> : "Not listed"}
          />
        </div>
      ) : (
        <p className="text-xs text-muted">
          European cash-settled option in {s.assetSymbol} at expiry. Fully verified on-chain.
        </p>
      )}
    </Card>
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
    { key: "FINALIZED", label: "Price Fixed" },
    { key: "ALL_SETTLED", label: "Accounts Settled" },
    { key: "REDEEMABLE", label: "Payouts Open" },
  ];
  const order = ["ACTIVE", "EXPIRED", "ORACLE_STALLED", "FINALIZED", "ALL_SETTLED", "REDEEMABLE"];
  const at = order.indexOf(state === "ORACLE_STALLED" ? "EXPIRED" : state);

  return (
    <ol className="flex items-center gap-1.5 py-1">
      {steps.map((st, i) => {
        const done = at >= order.indexOf(st.key);
        return (
          <li key={st.key} className="flex flex-1 flex-col items-center gap-1 text-center">
            <div className={cx("h-1.5 w-full rounded-full transition-all", done ? "bg-good" : "bg-line")} />
            <span className={cx("text-[10px] font-semibold leading-tight", done ? "text-ink" : "text-muted")}>
              {st.label}
            </span>
            {i === 0 && state === "ORACLE_STALLED" && (
              <span className="text-[9px] text-bad font-bold">Feed delayed</span>
            )}
          </li>
        );
      })}
    </ol>
  );
}
