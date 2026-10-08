/** `/trade`: pick direction, target, amount — buy in three taps. */
import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import type { Hex } from "viem";
import {
  ArrowRight,
  Calendar,
  CheckCircle2,
  Clock,
  HelpCircle,
  Info,
  ShieldCheck,
  Sparkles,
  TrendingDown,
  TrendingUp,
  Wallet,
  Zap,
} from "lucide-react";
import { AmountInput, Card, Details, EmptyState, Row, Skeleton, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { buySteps } from "../lib/optara/actions.ts";
import { availability, type ActionContext } from "../lib/optara/availability.ts";
import { recordTrade } from "../lib/optara/activity.ts";
import { disclosuresFor } from "../lib/optara/disclosures.ts";
import {
  fmtDuration,
  fmtExpiry,
  fmtExpiryShort,
  fmtNative,
  fmtPrice,
  fmtQty,
  fmtWad,
  optionTypeName,
  parseFixed,
  WAD,
} from "../lib/optara/format.ts";
import {
  useChainTime,
  useProductMarket,
  useSeries,
  useSeriesList,
  useSeriesMarket,
  useTokenBalance,
} from "../lib/optara/hooks.ts";
import { kuruTakerFee, previewBuyerFee } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useQuickGuide } from "../state.tsx";

const SLIPPAGE_BPS = 100n;
const withSlip = (x: bigint) => (x * (10_000n + SLIPPAGE_BPS)) / 10_000n + 1n;
const lessSlip = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
const toWadFromNative = (native: bigint, decimals: number) => native * 10n ** BigInt(18 - decimals);

export function TradePage() {
  const { id } = useParams();
  const { address } = useConnection();
  const { open: openGuide } = useQuickGuide();

  const { data: allSeries, isLoading: loadingList } = useSeriesList();
  const { data: now } = useChainTime();

  // If specific series passed in URL, load it
  const urlSeries = useSeries(id as Hex | undefined);

  // Filter active series
  const activeSeries = useMemo(
    () => (allSeries ?? []).filter((s) => now === undefined || s.expiry > now),
    [allSeries, now]
  );

  // Products
  const products = useMemo(
    () => [...new Map(activeSeries.map((s) => [s.productId, s])).values()],
    [activeSeries]
  );

  const [selectedProductId, setSelectedProductId] = useState<Hex | undefined>();
  const product =
    products.find((p) => p.productId === selectedProductId) ??
    (urlSeries ? products.find((p) => p.productId === urlSeries.productId) : products[0]);

  const { data: productMarket } = useProductMarket(product?.productId);

  // Direction: "call" (UP) or "put" (DOWN)
  const [direction, setDirection] = useState<"call" | "put">("call");

  // Expiries available for selected product
  const expiries = useMemo(() => {
    if (!product) return [];
    const exps = activeSeries
      .filter((s) => s.productId === product.productId)
      .map((s) => s.expiry);
    return [...new Set(exps)].sort((a, b) => (a < b ? -1 : 1));
  }, [activeSeries, product]);

  const [selectedExpiry, setSelectedExpiry] = useState<bigint | undefined>();
  const chosenExpiry =
    selectedExpiry !== undefined && expiries.includes(selectedExpiry)
      ? selectedExpiry
      : expiries[0];

  // Candidates for selected product, expiry, and direction
  const targetOptionType = direction === "call" ? 0 : 1;
  const candidates = useMemo(() => {
    if (!product || chosenExpiry === undefined) return [];
    return activeSeries
      .filter(
        (s) =>
          s.productId === product.productId &&
          s.expiry === chosenExpiry &&
          s.optionType === targetOptionType
      )
      .sort((a, b) => (a.strikeWad < b.strikeWad ? -1 : 1));
  }, [activeSeries, product, chosenExpiry, targetOptionType]);

  // Selected series
  const [selectedSeriesId, setSelectedSeriesId] = useState<Hex | undefined>();
  const selectedSeries =
    candidates.find((s) => s.id === selectedSeriesId) ??
    (urlSeries && candidates.some((s) => s.id === urlSeries.id) ? urlSeries : candidates[0]);

  // Sync state if urlSeries is loaded
  useEffect(() => {
    if (urlSeries) {
      setDirection(urlSeries.optionType === 0 ? "call" : "put");
      setSelectedExpiry(urlSeries.expiry);
      setSelectedSeriesId(urlSeries.id);
    }
  }, [urlSeries]);

  // Investment amount
  const [spendAmount, setSpendAmount] = useState("50");

  if (loadingList) {
    return (
      <div className="w-full space-y-4 py-6">
        <Skeleton className="h-64 w-full rounded-3xl" />
        <Skeleton className="h-48 w-full rounded-3xl" />
      </div>
    );
  }

  if (!product || !selectedSeries) {
    return (
      <div className="w-full py-12">
        <Card>
          <EmptyState
            title="No active markets available"
            body="Check back soon when new option expiries are listed."
            action={
              <Link to="/" className="btn-primary mt-3 text-xs">
                Back to Markets
              </Link>
            }
          />
        </Card>
      </div>
    );
  }

  return (
    <div className="w-full space-y-4 py-1 sm:py-4">
      <div className="flex items-center justify-between px-1 text-[13px]">
        <Link to="/" className="font-semibold text-muted hover:text-ink transition">
          ← Markets
        </Link>
        <button onClick={openGuide} className="font-semibold text-primary hover:underline flex items-center gap-1 cursor-pointer">
          <HelpCircle className="h-3.5 w-3.5" /> How it works
        </button>
      </div>

      <div className="ticket space-y-5 p-4 sm:p-6">
        <div className="flex items-center justify-between gap-2">
          <div>
            <h1 className="font-display text-xl font-bold tracking-tight sm:text-2xl">
              Trade {product.underlyingSymbol}
            </h1>
            <p className="mt-0.5 text-[13px] text-muted">Three taps: direction, target, amount</p>
          </div>
          <span className="pill border border-good/25 bg-good/10 text-good">Capped risk</span>
        </div>

        <div>
          <div className="label mb-2">
            1 · Where is {product.underlyingSymbol} headed?
          </div>
          <div className="grid grid-cols-2 gap-3">
            <button
              type="button"
              onClick={() => {
                setDirection("call");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-2.5 rounded-2xl border p-3 text-left transition active:scale-[0.98] cursor-pointer",
                direction === "call"
                  ? "border-good/60 bg-good/8"
                  : "border-line bg-surface-2/60 hover:border-good/30"
              )}
            >
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-good/15 text-good">
                <TrendingUp className="h-4.5 w-4.5" />
              </span>
              <span>
                <span className="block text-sm font-bold">Up</span>
                <span className="block text-xs font-semibold text-good">Call option</span>
              </span>
            </button>

            <button
              type="button"
              onClick={() => {
                setDirection("put");
                setSelectedSeriesId(undefined);
              }}
              className={cx(
                "flex items-center gap-2.5 rounded-2xl border p-3 text-left transition active:scale-[0.98] cursor-pointer",
                direction === "put"
                  ? "border-bad/60 bg-bad/8"
                  : "border-line bg-surface-2/60 hover:border-bad/30"
              )}
            >
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-bad/15 text-bad">
                <TrendingDown className="h-4.5 w-4.5" />
              </span>
              <span>
                <span className="block text-sm font-bold">Down</span>
                <span className="block text-xs font-semibold text-bad">Put option</span>
              </span>
            </button>
          </div>
        </div>

        <div>
          <div className="mb-2 flex items-center justify-between">
            <span className="label">
              2 · Target and expiry
            </span>
            {productMarket && (
              <span className="text-[13px] text-muted">
                Spot <b className="num font-display text-ink">${fmtWad(productMarket.spotWad, 0)}</b>
              </span>
            )}
          </div>

          <div className="mb-2.5 flex gap-1.5 overflow-x-auto pb-1 scrollbar-none">
            {expiries.map((exp) => (
              <button
                key={exp.toString()}
                type="button"
                onClick={() => {
                  setSelectedExpiry(exp);
                  setSelectedSeriesId(undefined);
                }}
                className={cx(
                  "whitespace-nowrap rounded-xl border px-2.5 py-1.5 text-[13px] font-semibold transition cursor-pointer",
                  exp === chosenExpiry
                    ? "border-primary/60 bg-primary-soft text-primary"
                    : "border-line bg-surface-2 text-muted hover:text-ink"
                )}
              >
                {fmtExpiryShort(exp)} {now !== undefined ? `· ${fmtDuration(exp - now)}` : ""}
              </button>
            ))}
          </div>

          {/* Strike Cards */}
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {candidates.map((s) => {
              const isSelected = s.id === selectedSeries.id;
              const strike = Number(s.strikeWad) / 1e18;
              const spot = productMarket ? Number(productMarket.spotWad) / 1e18 : undefined;
              const diffPct = spot ? (((strike - spot) / spot) * 100).toFixed(0) : undefined;

              return (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => setSelectedSeriesId(s.id)}
                  className={cx(
                    "flex flex-col items-center justify-center rounded-2xl border p-3 text-center transition-all active:scale-[0.98]",
                    isSelected
                      ? "border-primary bg-primary-soft text-primary shadow-sm ring-1 ring-primary/40 font-bold"
                      : "border-line bg-surface-2/60 text-ink hover:border-primary/40"
                  )}
                >
                  <span className="num text-base font-extrabold">${fmtWad(s.strikeWad, 0)}</span>
                  {diffPct !== undefined && (
                    <span
                      className={cx(
                        "num text-[10px] font-semibold mt-0.5",
                        Number(diffPct) > 0 ? "text-good" : "text-bad"
                      )}
                    >
                      {Number(diffPct) > 0 ? `+${diffPct}%` : `${diffPct}%`}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
        </div>

        <div>
          <div className="label mb-2">
            3 · How much to invest?
          </div>
          <TradeForm
            series={selectedSeries}
            amount={spendAmount}
            onAmountChange={setSpendAmount}
            productMarket={productMarket}
          />
        </div>

        {/* Advanced link */}
        <div className="text-center pt-2 border-t border-line">
          <Link
            to={`/series/${selectedSeries.id}`}
            className="text-xs text-primary font-semibold hover:underline inline-flex items-center gap-1"
          >
            See payoff chart and details <ArrowRight className="h-3 w-3" />
          </Link>
        </div>
      </div>
    </div>
  );
}

function TradeForm({
  series,
  amount,
  onAmountChange,
  productMarket,
}: {
  series: Series;
  amount: string;
  onAmountChange: (a: string) => void;
  productMarket?: any;
}) {
  const { address } = useConnection();
  const { data: market } = useSeriesMarket(series);
  const { data: balance } = useTokenBalance(series.settlementAsset, address);

  const premiumIn = parseFixed(amount, series.assetDecimals);
  const ask = market?.quote?.ask;
  const kuruMarket = market?.quote?.market;

  const fees = useQuery({
    queryKey: ["instantBuyFees", series.id, premiumIn?.toString(), kuruMarket],
    queryFn: async () => ({
      optara: await previewBuyerFee(premiumIn!),
      kuru: kuruMarket ? await kuruTakerFee(kuruMarket, premiumIn!) : 0n,
    }),
    enabled: !!premiumIn && !!kuruMarket,
  });

  const estQty =
    premiumIn && ask && fees.data
      ? (toWadFromNative(premiumIn - fees.data.kuru, series.assetDecimals) * WAD) / ask
      : undefined;

  const total = premiumIn !== undefined && fees.data ? premiumIn + fees.data.optara : undefined;
  const tooMuch = total !== undefined && balance !== undefined && total > balance;

  const ctx: ActionContext = {
    connected: !!address,
    groupState: market?.state ?? "ACTIVE",
    productCloseOnly: productMarket?.closeOnly ?? false,
    dataFresh: !!productMarket?.spotFresh && productMarket?.surface === "FRESH",
    marketTradable: !!market?.quote,
    hasAccount: true,
    health: "HEALTHY",
    accountBalance: 0n,
    walletWrappers: 0n,
    credit: false,
  };

  const a = availability("buy", ctx);

  const steps =
    address && premiumIn && fees.data && estQty
      ? buySteps(
          series,
          premiumIn,
          lessSlip(estQty),
          withSlip(fees.data.optara),
          withSlip(fees.data.kuru),
          address
        )
      : undefined;

  // Estimated payout if price moves past strike by 10%
  const strikeNum = Number(series.strikeWad) / 1e18;
  const spotNum = productMarket ? Number(productMarket.spotWad) / 1e18 : strikeNum;
  const estPayoutPerOption =
    series.optionType === 0
      ? Math.max(0, spotNum * 1.15 - strikeNum)
      : Math.max(0, strikeNum - spotNum * 0.85);

  const estTotalPayout = estQty ? (Number(estQty) / 1e18) * estPayoutPerOption : 0;

  return (
    <div className="space-y-3.5">
      <AmountInput
        label="You pay"
        value={amount}
        onChange={onAmountChange}
        unit={series.assetSymbol}
        presets={["25", "50", "100", "250"]}
        max={balance !== undefined ? fmtNative(balance, series.assetDecimals, 2).replace(/,/g, "") : undefined}
        maxLabel="Wallet"
        invalid={tooMuch ? `Wallet holds ${fmtNative(balance!, series.assetDecimals)} ${series.assetSymbol}.` : undefined}
      />

      <div className="rounded-2xl border border-line bg-surface-2/70 p-3.5">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-[13px] text-muted">You receive about</span>
          <span className="num font-display text-2xl font-bold tracking-tight">
            {estQty !== undefined ? fmtQty(estQty) : "—"}
          </span>
        </div>
        <div className="mt-0.5 flex items-baseline justify-between gap-2 text-xs text-muted">
          <span>Max loss is what you pay</span>
          {estTotalPayout > 0 && (
            <span className="num font-semibold text-good">up to +${estTotalPayout.toFixed(0)} if ±15%</span>
          )}
        </div>

        <div className="mt-2.5">
          <Details summary={<span>Total <b className="num">{total !== undefined ? `${fmtNative(total, series.assetDecimals)} ${series.assetSymbol}` : "—"}</b></span>}>
            <Row
              label="Premium"
              value={premiumIn !== undefined ? `${fmtNative(premiumIn, series.assetDecimals)} ${series.assetSymbol}` : "—"}
            />
            <Row
              label={<Term tip="Charged by the order book.">Venue fee</Term>}
              value={fees.data ? `≈ ${fmtNative(fees.data.kuru, series.assetDecimals)}` : "—"}
            />
            <Row
              label={<Term tip="Funds insurance and keepers.">Optara fee</Term>}
              value={fees.data ? `${fmtNative(fees.data.optara, series.assetDecimals)}` : "—"}
            />
          </Details>
        </div>
      </div>

      <TxButton
        label={estQty ? `Buy ${fmtQty(estQty)}` : "Buy"}
        steps={steps}
        disabled={!a.enabled || !steps || tooMuch}
        disabledReason={a.reason}
        disclosures={disclosuresFor("buy", series.underlyingSymbol)}
        successMessage="Bought. Tokens are in your wallet."

        onDone={() => recordTrade(address, series.id, "buy")}
      />
    </div>
  );
}
