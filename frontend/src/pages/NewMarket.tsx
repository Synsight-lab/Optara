/** `/new`: list a new option market — or request one when listing is governed. */
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { type Hex } from "viem";
import { optionSeriesRegistryAbi, protocolControlAbi } from "@optara/sdk";
import { ArrowLeft, CalendarClock, CheckCircle2, CircleDollarSign, Clock3, ShieldCheck, Sparkles, TrendingDown, TrendingUp, type LucideIcon } from "lucide-react";
import { AmountInput, Card, CopyButton, EmptyState, Pill, Segmented, Skeleton, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { createSeriesSteps, createSeriesWithDirectMarketSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtDuration, fmtExpiry, fmtExpiryShort, fmtLevel, fmtWad, parseFixed } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { ROLE_KEYS } from "../lib/optara/roles.ts";

const DAY = 86_400n;

const toDateInput = (ts: bigint) => new Date(Number(ts) * 1000).toISOString().slice(0, 10);
const toTimeInput = (ts: bigint) => new Date(Number(ts) * 1000).toISOString().slice(11, 16);
const utcDayMinute = (ts: bigint) => {
  const d = new Date(Number(ts) * 1000);
  return d.getUTCHours() * 60 + d.getUTCMinutes();
};
const priceInput = (wad: bigint) => {
  const n = Number(wad) / 1e18;
  return n.toLocaleString("en-US", { useGrouping: false, maximumFractionDigits: n < 1 ? 6 : n < 100 ? 4 : 2 });
};

export function NewMarketPage() {
  const { address, isConnected } = useConnection();
  const { data: series } = useSeriesList();
  const { data: now } = useChainTime();
  const navigate = useNavigate();
  const qc = useQueryClient();

  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];
  const { data: productMarket } = useProductMarket(product?.productId);
  const [optionType, setOptionType] = useState<0 | 1>(0);
  const [strike, setStrike] = useState("");
  const [date, setDate] = useState("");
  const [time, setTime] = useState("08:00");

  const strikeWad = parseFixed(strike, 18);
  const expiry = useMemo(() => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
    const t = /^(\d{2}):(\d{2})$/.exec(time);
    if (!m || !t) return undefined;
    return BigInt(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(t[1]), Number(t[2]), 0) / 1000);
  }, [date, time]);

  // Product bounds + sibling oracle/risk defaults.
  const { data: listing } = useQuery({
    queryKey: ["listingDefaults", product?.productId, optionType],
    queryFn: async () => {
      const [prod, enabled] = await Promise.all([
        publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "getProduct", args: [product!.productId] }),
        publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "isProductEnabled", args: [product!.productId] }),
      ]);
      const sibs = (series ?? []).filter((s) => s.productId === product!.productId && s.optionType === optionType);
      let ids: { settlementOracleConfigId: Hex; volSurfaceProductId: Hex; riskParameterSetId: Hex } | undefined;
      if (sibs.length > 0) {
        const anchor = strikeWad ?? sibs[0]!.strikeWad;
        const near = [...sibs].sort((a, b) => {
          const da = a.strikeWad > anchor ? a.strikeWad - anchor : anchor - a.strikeWad;
          const db = b.strikeWad > anchor ? b.strikeWad - anchor : anchor - b.strikeWad;
          return da < db ? -1 : 1;
        })[0]!;
        const terms = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "getSeries", args: [near.id] });
        ids = { settlementOracleConfigId: terms.settlementOracleConfigId, volSurfaceProductId: terms.volSurfaceProductId, riskParameterSetId: terms.riskParameterSetId };
      }
      return { config: prod.config, enabled, ids };
    },
    enabled: !!product,
  });

  const { data: canList } = useQuery({
    queryKey: ["seriesCreator", address],
    queryFn: () => publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [ROLE_KEYS.seriesCreator, address!] }),
    enabled: !!address,
  });
  const { data: canRegisterVenue } = useQuery({
    queryKey: ["venueCreator", address],
    queryFn: async () => {
      const [venueAdmin, governance] = await Promise.all([
        publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [ROLE_KEYS.venueAdmin, address!] }),
        publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [ROLE_KEYS.governance, address!] }),
      ]);
      return venueAdmin || governance;
    },
    enabled: !!address,
  });

  const params = useMemo(() => {
    if (!product || strikeWad === undefined || expiry === undefined || !listing?.ids) return undefined;
    return {
      underlying: product.underlying,
      settlementAsset: product.settlementAsset,
      optionType,
      strikeWad,
      contractSizeWad: 10n ** 18n,
      expiry,
      ...listing.ids,
    };
  }, [product, strikeWad, expiry, listing, optionType]);

  const { data: existingId } = useQuery({
    queryKey: ["computedSeries", params?.underlying, params?.settlementAsset, params?.optionType, params?.strikeWad?.toString(), params?.expiry?.toString()],
    queryFn: async () => {
      const id = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params!] });
      const exists = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "seriesExists", args: [id] });
      return exists ? (id.toLowerCase() as Hex) : undefined;
    },
    enabled: !!params,
  });

  // Hooks stay above the early return below: React needs the same hooks on every render.
  const suggestedExpiries = useMemo(() => {
    const cfg = listing?.config;
    if (now === undefined || !cfg) return [];
    const base = now + cfg.minTimeToExpiry;
    const days = [1n, 7n, 14n, 30n].map((d) => base + d * DAY).filter((ts) => ts <= now + cfg.maxTimeToExpiry);
    return days.slice(0, 4);
  }, [now, listing?.config]);
  const strikeSuggestions = useMemo(() => {
    const spot = productMarket?.spotWad;
    if (!spot) return [];
    const shifts = optionType === 0 ? [-500, 0, 500, 1000] : [-1000, -500, 0, 500];
    return shifts.map((bps) => {
      const v = (spot * BigInt(10_000 + bps)) / 10_000n;
      return { bps, value: v, label: bps === 0 ? "At spot" : `${bps > 0 ? "+" : ""}${bps / 100}%` };
    });
  }, [productMarket?.spotWad, optionType]);

  if (!product) {
    return (
      <div className="space-y-3">
        <Back />
        <Card><EmptyState title="No products yet" body="Products are approved by governance first. Check back soon." /></Card>
      </div>
    );
  }

  const cfg = listing?.config;
  const strikeBad = strikeWad !== undefined && cfg && (strikeWad < cfg.minStrikeWad || strikeWad > cfg.maxStrikeWad);
  const expiryBad = expiry !== undefined && now !== undefined && cfg && (expiry <= now + cfg.minTimeToExpiry || expiry > now + cfg.maxTimeToExpiry);
  const minDate = now !== undefined ? toDateInput(utcDayMinute(now) < 23 * 60 + 59 ? now : now + DAY) : undefined;
  const maxDate = now !== undefined && cfg ? toDateInput(now + cfg.maxTimeToExpiry) : undefined;
  const setExpiryFromTs = (ts: bigint) => {
    setDate(toDateInput(ts));
    setTime(toTimeInput(ts));
  };
  const ready = params && !strikeBad && !expiryBad && listing?.enabled && !existingId;
  const requestJson = params ? JSON.stringify({ ...params, strikeWad: params.strikeWad.toString(), expiry: params.expiry.toString(), contractSizeWad: params.contractSizeWad.toString() }, null, 2) : "";

  return (
    <div className="space-y-4">
      <Back />

      <section className="card rise overflow-hidden p-5 sm:p-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary-soft px-3 py-1 text-xs font-bold text-primary">
              <Sparkles className="h-3.5 w-3.5" /> Market builder
            </div>
            <h1 className="font-display mt-3 text-2xl font-bold tracking-tight">Create an option market</h1>
            <p className="mt-1 max-w-2xl text-sm leading-6 text-muted">
              Build a listed option from approved product settings. Choose the asset, direction, strike, and exact UTC expiry time.
            </p>
          </div>
          <div className="grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-4 lg:min-w-[560px]">
            <BuildStat icon={Sparkles} label="Asset" value={product.underlyingSymbol} tone="primary" />
            <BuildStat icon={optionType === 0 ? TrendingUp : TrendingDown} label="Direction" value={optionType === 0 ? "Call" : "Put"} tone={optionType === 0 ? "good" : "bad"} />
            <BuildStat icon={CircleDollarSign} label="Live price" value={productMarket?.spotWad ? `$${fmtLevel(productMarket.spotWad)}` : "Loading"} tone={productMarket?.spotFresh ? "good" : "neutral"} />
            <BuildStat icon={CheckCircle2} label="Access" value={canList ? "Lister" : "Request"} tone={canList ? "good" : "neutral"} />
          </div>
        </div>
      </section>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(340px,0.72fr)]">
        <section className="card rise p-4 sm:p-5">
          <div className="grid gap-4">
            <BuilderStep n="1" title="Choose product" text="Pick the approved asset pair this option will settle against.">
              <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-none">
                {products.map((p) => (
                  <button
                    key={p.productId}
                    onClick={() => setProductId(p.productId)}
                    className={cx(
                      "flex min-h-[52px] shrink-0 items-center gap-2 rounded-2xl border px-3 text-left text-[13px] font-semibold transition cursor-pointer",
                      p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary shadow-sm" : "border-line bg-surface-2/55 text-muted hover:border-primary/30 hover:text-ink",
                    )}
                  >
                    <TokenIcon symbol={p.underlyingSymbol} className="h-5 w-5" />
                    <span>
                      <span className="block">{p.underlyingSymbol}/{p.assetSymbol}</span>
                      <span className="block text-[11px] font-medium opacity-75">1 option = 1 {p.underlyingSymbol}</span>
                    </span>
                  </button>
                ))}
              </div>
            </BuilderStep>

            <BuilderStep n="2" title="Pick direction" text="Calls are for upside. Puts are for downside or hedging.">
              <Segmented
                value={optionType === 0 ? "call" : "put"}
                onChange={(v) => setOptionType(v === "call" ? 0 : 1)}
                options={[
                  { value: "call", label: <span className="inline-flex items-center gap-1.5"><TrendingUp className="h-3.5 w-3.5" /> Call · up</span> },
                  { value: "put", label: <span className="inline-flex items-center gap-1.5"><TrendingDown className="h-3.5 w-3.5" /> Put · down</span> },
                ]}
              />
            </BuilderStep>

            <BuilderStep n="3" title="Set strike and expiry" text="The strike is the target price. Expiry is exact and shown in UTC.">
              <div className="grid gap-3 lg:grid-cols-2">
                <div className="space-y-3">
                  <div className="rounded-2xl border border-line bg-surface/75 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <div className="text-[11px] font-bold uppercase text-faint">Current {product.underlyingSymbol} price</div>
                        <div className="num mt-1 font-display text-2xl font-bold text-ink">
                          {productMarket?.spotWad ? `$${fmtLevel(productMarket.spotWad)}` : "—"}
                        </div>
                        <div className="mt-1 text-xs text-muted">
                          {productMarket?.spotFresh ? "Fresh oracle price used by risk checks." : "Waiting for a fresh oracle price."}
                        </div>
                      </div>
                      <Pill tone={productMarket?.spotFresh ? "good" : "neutral"}>{productMarket?.spotFresh ? "Live" : "Stale"}</Pill>
                    </div>
                    {strikeSuggestions.length > 0 && (
                      <div className="mt-3 flex flex-wrap gap-1.5">
                        {strikeSuggestions.map((x) => (
                          <button
                            key={x.bps}
                            type="button"
                            onClick={() => setStrike(priceInput(x.value))}
                            className="rounded-full border border-line bg-surface-2 px-3 py-1.5 text-xs font-semibold text-muted transition hover:border-primary/40 hover:text-primary"
                          >
                            {x.label} · ${fmtLevel(x.value)}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                  <AmountInput
                    label={`Strike (${product.assetSymbol})`}
                    value={strike}
                    onChange={setStrike}
                    unit={product.assetSymbol}
                    hint={cfg ? `Allowed: $${fmtLevel(cfg.minStrikeWad)} to $${fmtLevel(cfg.maxStrikeWad)}` : undefined}
                    invalid={strikeBad ? `Outside the listed range for ${product.underlyingSymbol}.` : undefined}
                  />
                </div>
                <div className="rounded-2xl border border-line bg-surface/75 p-3">
                  <div className="grid gap-3 sm:grid-cols-[1fr_132px]">
                    <label className="block">
                      <span className="label">Expiry date</span>
                      <input
                        id="new-expiry"
                        type="date"
                        value={date}
                        min={minDate}
                        max={maxDate}
                        onChange={(e) => setDate(e.target.value)}
                        className="input num mt-1.5"
                      />
                    </label>
                    <label className="block">
                      <span className="label">Time UTC</span>
                      <input
                        type="time"
                        value={time}
                        onChange={(e) => setTime(e.target.value)}
                        className="input num mt-1.5"
                      />
                    </label>
                  </div>
                  <div className="mt-3 flex flex-wrap gap-1.5">
                    {suggestedExpiries.map((ts) => (
                      <button
                        key={ts.toString()}
                        type="button"
                        onClick={() => setExpiryFromTs(ts)}
                        className="rounded-full border border-line bg-surface-2 px-3 py-1.5 text-xs font-semibold text-muted transition hover:border-primary/40 hover:text-primary"
                      >
                        {fmtDuration(ts - (now ?? ts))}
                      </button>
                    ))}
                  </div>
                  {expiry !== undefined && now !== undefined && !expiryBad && (
                    <p className="mt-2 text-[13px] text-muted">{fmtExpiry(expiry)} · in {fmtDuration(expiry - now)}</p>
                  )}
                  {cfg && now !== undefined && (
                    <p className="mt-1 text-[11px] leading-4 text-faint">
                      Window: {fmtDuration(cfg.minTimeToExpiry)} to {fmtDuration(cfg.maxTimeToExpiry)} from now.
                    </p>
                  )}
                  {expiryBad && <p className="mt-2 text-[13px] font-medium text-bad">Too close or too far out for this product.</p>}
                </div>
              </div>
            </BuilderStep>
          </div>
        </section>

        <aside className="card rise p-4 sm:p-5">
          <div className="flex items-center justify-between gap-2">
            <h2 className="font-display text-lg font-bold">Preview</h2>
            <Pill tone={ready ? "good" : existingId ? "warn" : "neutral"}>{existingId ? "Exists" : ready ? "Ready" : "Draft"}</Pill>
          </div>
          <div className="mt-4 rounded-3xl border border-line bg-gradient-to-br from-surface-2/75 to-surface/80 p-4">
            <div className="flex items-center gap-2">
              <TokenIcon symbol={product.underlyingSymbol} className="h-8 w-8" />
              <div>
                <div className="font-display text-xl font-bold">{product.underlyingSymbol} {optionType === 0 ? "Call" : "Put"}</div>
                <div className="text-xs text-muted">Settles in {product.assetSymbol}</div>
              </div>
            </div>
            <div className="mt-4 grid grid-cols-2 gap-2">
              <PreviewFact icon={CircleDollarSign} label="Strike" value={strikeWad !== undefined ? `$${fmtLevel(strikeWad)}` : "Set strike"} />
              <PreviewFact icon={CalendarClock} label="Expiry" value={expiry ? fmtExpiryShort(expiry) : "Pick date"} />
              <PreviewFact icon={Clock3} label="Time" value={expiry ? `${time} UTC` : "Pick time"} />
              <PreviewFact icon={ShieldCheck} label="Setup" value={listing?.ids ? "Inherited" : "Needs sibling"} />
            </div>
            <div className="mt-3 rounded-2xl border border-line bg-surface/70 p-3 text-xs leading-5 text-muted">
              <b className="text-ink">What happens next:</b> listing deploys the option token. Trading starts after a venue market is registered and funded.
            </div>
          </div>
        </aside>
      </div>

      {listing === undefined ? (
        <Card><Skeleton className="h-16 w-full" /></Card>
      ) : !listing.enabled ? (
        <Card><EmptyState title="Product paused" body="This product is disabled. Existing series still settle." /></Card>
      ) : !listing.ids ? (
        <Card><EmptyState title="No sibling market" body="The first series of this kind is listed by governance with its oracle and risk setup." /></Card>
      ) : existingId ? (
        <Card>
          <EmptyState
            title="Already listed"
            body={`${product.underlyingSymbol} $${fmtLevel(strikeWad!)} ${optionType === 0 ? "Call" : "Put"} · ${fmtExpiryShort(expiry!)} exists.`}
            action={<button onClick={() => navigate(`/app/series/${existingId}`)} className="btn-primary mt-2 text-xs">Open market</button>}
          />
        </Card>
      ) : !isConnected ? (
        <Card><EmptyState title="Connect to continue" body="Connect a wallet to list this market." /></Card>
      ) : canList ? (
        <section className="ticket p-4 sm:p-5">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <div className="font-display text-lg font-bold">List this market</div>
              <p className="mt-1 max-w-2xl text-sm leading-6 text-muted">
                You hold the series creator role. This will deploy the option wrapper using the approved oracle, volatility and risk settings.
              </p>
            </div>
            <TxButton
              label={canRegisterVenue ? "List market and create order book" : "List market"}
              steps={ready ? (canRegisterVenue ? createSeriesWithDirectMarketSteps(params, address) : createSeriesSteps(params)) : undefined}
              disabled={!ready}
              disabledReason={!params ? "Enter a strike and expiry first." : strikeBad || expiryBad ? "Fix the highlighted field." : undefined}
              successMessage={canRegisterVenue ? "Market listed with an Optara Direct order book." : "Market listed."}
              onDone={async () => {
                await qc.invalidateQueries({ queryKey: ["series"] });
                const id = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params!] });
                navigate(`/app/series/${id.toLowerCase()}`);
              }}
            />
            {!canRegisterVenue && (
              <p className="mt-2 text-xs leading-5 text-muted">
                This wallet can list the option series but cannot attach an order book. A venue admin can add Optara Direct or Kuru from Admin.
              </p>
            )}
          </div>
        </section>
      ) : (
        <Card>
          <EmptyState
            title="Listing is governed"
            body="New markets are listed by holders of the lister role. Copy this request for a proposal — it matches the market above exactly."
            action={<span className="pill border border-line bg-surface-2 text-muted">No special access needed to request</span>}
          />
          <div className="mt-2 rounded-xl border border-line bg-surface-2/60 p-3">
            <pre className="num overflow-x-auto text-[11px] leading-relaxed text-muted">{requestJson || "Fill in strike and expiry to preview the request."}</pre>
            {requestJson && (
              <div className="mt-2 flex justify-end">
                <CopyButton text={requestJson} label="listing request" />
              </div>
            )}
          </div>
        </Card>
      )}
    </div>
  );
}

function BuilderStep({ n, title, text, children }: { n: string; title: string; text: string; children: React.ReactNode }) {
  return (
    <section className="rounded-3xl border border-line bg-surface-2/45 p-4">
      <div className="mb-3 flex items-start gap-3">
        <span className="grid h-8 w-8 shrink-0 place-items-center rounded-2xl bg-primary-soft text-sm font-bold text-primary">{n}</span>
        <span>
          <span className="block font-display text-base font-bold">{title}</span>
          <span className="mt-0.5 block text-xs leading-5 text-muted">{text}</span>
        </span>
      </div>
      {children}
    </section>
  );
}

function BuildStat({ icon: Icon, label, value, tone }: { icon: LucideIcon; label: string; value: string; tone: "primary" | "good" | "bad" | "neutral" }) {
  return (
    <div className="min-w-0 rounded-2xl border border-line bg-surface-2/55 p-3">
      <Icon className={cx("h-4 w-4", tone === "primary" && "text-primary", tone === "good" && "text-good", tone === "bad" && "text-bad", tone === "neutral" && "text-muted")} />
      <div className="mt-2 text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className="truncate font-display text-lg font-bold">{value}</div>
    </div>
  );
}

function PreviewFact({ icon: Icon, label, value }: { icon: LucideIcon; label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-line bg-surface/80 p-3">
      <Icon className="h-4 w-4 text-primary" />
      <div className="mt-2 text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className="num truncate text-sm font-bold">{value}</div>
    </div>
  );
}


function Back() {
  return (
    <Link to="/app/markets" className="flex items-center gap-1 px-1 text-[13px] font-semibold text-muted hover:text-ink">
      <ArrowLeft className="h-4 w-4" /> Markets
    </Link>
  );
}
