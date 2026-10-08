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
import { AmountInput, Card, CopyButton, Details, EmptyState, Pill, Row, Segmented, Skeleton, Stat, Term, cx, useTicker } from "../components/ui.tsx";
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
import { recordTrade } from "../lib/optara/activity.ts";
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

type Tab = "trade" | "write" | "manage" | "redeem" | "buy" | "sell";
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

  const canonicalTab: Tab = tab === "buy" || tab === "sell" ? "trade" : tab;
  const tradeSide: "buy" | "sell" = tab === "sell" ? "sell" : "buy";
  const tabs: { value: Tab; label: string; icon: any; actions: ActionKey[] }[] = [
    { value: "trade", label: "Trade", icon: TrendingUp, actions: ["buy", "sell"] },
    { value: "write", label: "Earn", icon: Coins, actions: ["write"] },
    { value: "manage", label: "Manage", icon: Shield, actions: ["unwrap", "close", "wrap"] },
    { value: "redeem", label: "Settle", icon: CheckCircle2, actions: ["redeem", "claim"] },
  ];

  const spotNum = product ? Number(product.spotWad) / 1e18 : undefined;
  const markNum = market?.mark !== undefined ? Number(market.mark) / 1e18 : undefined;
  const side = canonicalTab === "write" ? "short" : "long";
  const premiumForChart = (side === "long" ? market?.quote?.ask : market?.quote?.bid) ?? market?.mark;

  const select = (t: Tab) => {
    setTab(t);
    setParams((p) => (p.set("tab", t), p), { replace: true });
  };

  const isCall = series.optionType === 0;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between px-1">
        <Link
          to="/"
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
                {series.underlyingSymbol} ${fmtWad(series.strikeWad, 0)} {optionTypeName(series.optionType)}
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
                value={product ? `$${fmtWad(product.spotWad, 0)}` : "…"}
                sub={product?.spotFresh ? "Live" : "Delayed"}
                tone={product?.spotFresh ? "good" : "warn"}
              />
              <Stat
                label={<Term tip="Fair value per option from the on-chain volatility surface.">Fair value</Term>}
                value={market?.mark !== undefined ? fmtPrice(market.mark) : "—"}
                sub={series.assetSymbol}
              />
              <Stat
                label={<Term tip="Expected movement priced in. Higher means pricier options.">Volatility</Term>}
                value={market?.iv !== undefined ? fmtIv(market.iv) : "—"}
                sub="Annualized"
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

      <div className="flex flex-col gap-3">
        <div className="space-y-4">
          <Card
            title={side === "long" ? "What you could make" : "What writing risks"}
            action={
              <span className="text-[13px] text-muted">
                {Number(qtyForChart.toFixed(2))} option{qtyForChart === 1 ? "" : "s"} · drag the chart
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

        {/* Right: brokerage ticket */}
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
                    disabled={isDisabled}
                    title={isDisabled ? a[0]?.reason : undefined}
                    className={cx(
                      "whitespace-nowrap rounded-lg px-2.5 py-1.5 text-[13px] font-semibold transition disabled:opacity-35 cursor-pointer",
                      isSelected
                        ? "bg-primary text-white shadow"
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
                market={market?.quote?.market}
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
                market={market?.quote?.market}
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
                  <Link to="/portfolio" className="font-semibold text-primary hover:underline">
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
    <div className="mt-3 rounded-2xl border border-line bg-surface-2/60 p-3.5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-[13px] font-semibold">Try a settlement price</span>
        <span className="num font-display text-[15px] font-bold">${targetPrice.toLocaleString(undefined, { maximumFractionDigits: 0 })}</span>
      </div>

      <input
        type="range"
        min={Math.round(basePrice * 0.5)}
        max={Math.round(basePrice * 1.5)}
        step={Math.round(basePrice * 0.005) || 1}
        value={targetPrice}
        onChange={(e) => {
          setTargetPrice(Number(e.target.value));
          e.target.style.setProperty("--fill", `${((Number(e.target.value) - basePrice * 0.5) / (basePrice) * 100).toFixed(1)}%`);
        }}
        className="mt-3 w-full cursor-pointer"
      />

      <div className="mt-2 flex flex-wrap gap-1.5">
        {[
          { label: "Spot", mult: 1.0 },
          { label: "+5%", mult: 1.05 },
          { label: "+10%", mult: 1.1 },
          { label: "+20%", mult: 1.2 },
          { label: "−10%", mult: 0.9 },
        ].map((p) => (
          <button
            key={p.label}
            type="button"
            onClick={() => spot && setTargetPrice(Math.round(spot * p.mult))}
            className="chip !py-1 !text-[11px] cursor-pointer"
          >
            {p.label}
          </button>
        ))}
      </div>

      <div className="mt-3 grid grid-cols-3 gap-2 border-t border-line pt-2.5 text-center">
        <div>
          <div className="text-[11px] text-muted">Move</div>
          <div className={cx("num font-display mt-0.5 text-sm font-bold", Number(pctFromSpot) >= 0 ? "text-good" : "text-bad")}>
            {Number(pctFromSpot) >= 0 ? `+${pctFromSpot}%` : `${pctFromSpot}%`}
          </div>
        </div>
        <div>
          <div className="text-[11px] text-muted">Net</div>
          <div className={cx("num font-display mt-0.5 text-sm font-bold", totalNet >= 0 ? "text-good" : "text-bad")}>
            {totalNet >= 0 ? `+$${totalNet.toFixed(0)}` : `−$${Math.abs(totalNet).toFixed(0)}`}
          </div>
        </div>
        <div>
          <div className="text-[11px] text-muted">Return</div>
          <div className={cx("num font-display mt-0.5 text-sm font-bold", totalNet >= 0 ? "text-good" : "text-bad")}>
            {totalNet >= 0 ? `+${roi}%` : `${roi}%`}
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Unified trade ticket (buy + sell merged)
function TradePanel({
  s,
  ctx,
  ask,
  bid,
  market,
  walletQty,
  initialSide,
  onQty,
}: {
  s: Series;
  ctx: ActionContext;
  ask?: bigint;
  bid?: bigint;
  market?: Hex;
  walletQty: bigint;
  initialSide: "buy" | "sell";
  onQty: (q: number) => void;
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
          { value: "buy", label: "Buy" },
          { value: "sell", label: `Sell${hasTokens ? ` (${fmtQty(walletQty)})` : ""}`, disabled: !hasTokens, title: hasTokens ? undefined : "You hold none of this option yet" },
        ]}
      />
      {side === "buy" ? (
        <BuyPanel s={s} ctx={ctx} ask={ask} market={market} onQty={onQty} />
      ) : (
        <SellPanel s={s} ctx={ctx} bid={bid} market={market} walletQty={walletQty} onQty={onQty} />
      )}
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
    <div className="space-y-3.5">
      <div className="flex items-center gap-2 rounded-xl border border-good/25 bg-good/8 px-3 py-2 text-[13px] text-good">
        <ShieldCheck className="h-4 w-4 shrink-0" />
        <span>Max loss is what you pay. No liquidation on longs.</span>
      </div>

      <AmountInput
        label="You pay"
        value={amount}
        onChange={setAmount}
        unit={s.assetSymbol}
        presets={["25", "50", "100", "250"]}
        max={balance !== undefined ? fmtNative(balance, s.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Wallet holds ${fmtNative(balance!, s.assetDecimals)} ${s.assetSymbol}.` : undefined}
      />

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-[13px] text-muted">You receive about</span>
          <span className="num font-display text-2xl font-bold tracking-tight">
            {estQty !== undefined ? fmtQty(estQty) : "—"}
          </span>
        </div>
        <div className="mt-0.5 text-right text-xs text-muted">
          {ask !== undefined ? `${fmtWad(ask, 2)} ${s.assetSymbol} each` : "Waiting for book"} · capped risk
        </div>

        <div className="mt-2.5">
          <Details summary={<span>Total <b className="num">{total !== undefined ? `${fmtNative(total, s.assetDecimals)} ${s.assetSymbol}` : "—"}</b></span>}>
            <Row
              label="Premium"
              value={premiumIn !== undefined ? `${fmtNative(premiumIn, s.assetDecimals)} ${s.assetSymbol}` : "—"}
            />
            <Row
              label={<Term tip="Charged by the order book.">Venue fee</Term>}
              value={fees.data ? `≈ ${fmtNative(fees.data.kuru, s.assetDecimals)}` : "—"}
            />
            <Row
              label={<Term tip="Funds insurance and keepers.">Optara fee</Term>}
              value={fees.data ? `${fmtNative(fees.data.optara, s.assetDecimals)}` : "—"}
            />
          </Details>
        </div>
      </div>

      <TxButton
        label={estQty ? `Buy ${fmtQty(estQty)}` : "Buy"}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch}
        disabledReason={a.reason}
        disclosures={disclosuresFor("buy", s.underlyingSymbol)}
        successMessage="Bought. Tokens are in your wallet."
        onDone={() => recordTrade(address, s.id, "buy")}
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
    <div className="space-y-3.5">
      <div className="flex items-center gap-2 rounded-xl border border-accent/25 bg-accent/8 px-3 py-2 text-[13px] text-accent">
        <Coins className="h-4 w-4 shrink-0" />
        <span>You keep the premium today. Margin account covers the payout.</span>
      </div>

      <AmountInput
        label="Contracts to write"
        value={amount}
        onChange={setAmount}
        unit="options"
        presets={["0.1", "0.5", "1", "2"]}
        hint="Min 0.01. Needs enough margin after writing."
      />

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
          <span className="block font-semibold">Sell instantly for cash</span>
          <span className="block text-muted">
            {market && bid !== undefined
              ? `Bid ${fmtWad(bid)} ${s.assetSymbol}. Cash lands in your wallet.`
              : "No bids yet. You keep the tokens instead."}
          </span>
        </span>
      </label>

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5">
        {sellable && net !== undefined && (
          <div className="flex items-baseline justify-between gap-2 border-b border-line pb-2">
            <span className="text-[13px] text-muted">Cash to wallet</span>
            <span className="num font-display text-xl font-bold text-good">
              +{fmtNative(net, s.assetDecimals)} {s.assetSymbol}
            </span>
          </div>
        )}
        <Details summary="Margin and fees">
          <Row
            label="Optara fee"
            value={fee !== undefined ? `${fmtNative(fee, s.assetDecimals)} ${s.assetSymbol}` : "—"}
          />
          {sellable && (
            <Row
              label="Venue fee"
              value={sellFee.data !== undefined ? `${fmtNative(sellFee.data, s.assetDecimals)} ${s.assetSymbol}` : "—"}
            />
          )}
          <Row
            strong
            label={<Term tip="Equity and required margin after writing.">Equity vs required</Term>}
            value={equityAfter !== undefined ? `${fmtWad(equityAfter)} / ${fmtWad(imAfter!)}` : "—"}
            tone={ok === false ? "bad" : ok ? "good" : undefined}
          />
        </Details>
        {ok === false && (
          <p className="mt-2 text-[13px] font-semibold text-bad">
            Not enough margin. Add collateral in Portfolio or lower the size.
          </p>
        )}
      </div>

      <TxButton
        label={sellable ? `Write for +${net !== undefined ? fmtNative(net, s.assetDecimals) : ""}` : `Write ${amount || "0"}`}
        tone="accent"
        steps={ok ? steps : undefined}
        disabled={!a.enabled || !steps || ok === false}
        disabledReason={a.reason}
        disclosures={disclosuresFor("write", s.underlyingSymbol)}
        successMessage={sellable ? "Written and sold. Premium is in your wallet." : "Written. Tokens are in your wallet."}
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

  return (
    <div className="space-y-4">
      <Section
        title="Close written position"
        text="Use wallet tokens to cancel what you wrote and free margin."
        blocked={!c.enabled ? c.reason : undefined}
      >
        <AmountInput label="Amount" value={closeAmt} onChange={setCloseAmt} unit="options" max={fmtQty(maxClose)} />
        <TxButton
          label="Close position"
          steps={selected !== undefined && cq ? closeShortSteps(selected, s, cq) : undefined}
          disabled={!c.enabled || !cq || cq > maxClose}
          disabledReason={c.reason}
          successMessage="Closed. Margin freed."
        />
      </Section>

      <Section
        title="Move tokens into account"
        text="Move tokens into your account to offset shorts and reduce margin."
        blocked={!u.enabled ? u.reason : undefined}
      >
        <AmountInput label="Amount" value={unwrapAmt} onChange={setUnwrapAmt} unit="options" max={fmtQty(walletQty)} />
        <TxButton
          label="Move in"
          steps={selected !== undefined && uq ? unwrapSteps(selected, s, uq) : undefined}
          disabled={!u.enabled || !uq || uq > walletQty}
          disabledReason={u.reason}
          successMessage="Moved into your account."
        />
      </Section>

      <Section
        title="Move tokens to wallet"
        text="Turn account longs into wallet tokens you can sell."
        blocked={!w.enabled ? w.reason : undefined}
      >
        <AmountInput label="Amount" value={wrapAmt} onChange={setWrapAmt} unit="options" max={position > 0n ? fmtQty(position) : "0"} />
        <TxButton
          label="Move out"
          steps={selected !== undefined && wq && address ? wrapSteps(selected, s, wq, address) : undefined}
          disabled={!w.enabled || !wq}
          disabledReason={w.reason}
          successMessage="Sent to your wallet."
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
          <span className="text-xs sm:text-sm font-bold text-ink">Details and addresses</span>
          <span className="text-xs text-primary font-semibold">
            {open ? "Hide ▲" : "Show ▼"}
          </span>
        </button>
      }
    >
      {open ? (
        <div className="flex flex-col gap-1 text-xs pt-2">
          <Row label="Type" value={`European ${optionTypeName(s.optionType).toLowerCase()}`} />
          <Row label="Strike" value={`$${fmtWad(s.strikeWad, 2)} ${s.assetSymbol}`} />
          <Row label="Contract size" value={`1.000 ${s.underlyingSymbol}`} />
          <Row label="Settles in" value={s.assetSymbol} />
          <Row label="Expiry" value={fmtExpiry(s.expiry)} />
          <Row label="Settlement price" value="Reference price at expiry" />
          <Row
            label="Option token"
            value={
              <span>
                {shortAddr(s.wrapper)} <CopyButton text={s.wrapper} label="token address" />
              </span>
            }
          />
          <Row
            label="Order book"
            value={market ? <span>{shortAddr(market)} <CopyButton text={market} label="market address" /></span> : "Not listed"}
          />
        </div>
      ) : (
        <p className="text-xs text-muted">
          Cash-settled in {s.assetSymbol} at expiry. Terms can't change.
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
