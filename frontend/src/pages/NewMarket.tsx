/** `/new`: list a new option market — or request one when listing is governed. */
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { keccak256, toHex, type Hex } from "viem";
import { optionSeriesRegistryAbi, protocolControlAbi } from "@optara/sdk";
import { ArrowLeft } from "lucide-react";
import { AmountInput, Card, CopyButton, Details, EmptyState, Segmented, Skeleton, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { createSeriesSteps } from "../lib/optara/actions.ts";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { fmtDuration, fmtExpiry, fmtExpiryShort, fmtLevel, fmtWad, parseFixed } from "../lib/optara/format.ts";
import { useChainTime, useSeriesList } from "../lib/optara/hooks.ts";

const SERIES_CREATOR: Hex = keccak256(toHex("optara.role.SERIES_CREATOR"));
const DAY = 86_400n;

const toDateInput = (ts: bigint) => new Date(Number(ts) * 1000).toISOString().slice(0, 10);

export function NewMarketPage() {
  const { address, isConnected } = useConnection();
  const { data: series } = useSeriesList();
  const { data: now } = useChainTime();
  const navigate = useNavigate();
  const qc = useQueryClient();

  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];
  const [optionType, setOptionType] = useState<0 | 1>(0);
  const [strike, setStrike] = useState("");
  const [date, setDate] = useState("");

  const strikeWad = parseFixed(strike, 18);
  const expiry = useMemo(() => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
    if (!m) return undefined;
    return BigInt(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 8, 0, 0) / 1000);
  }, [date]);

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
    queryFn: () => publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [SERIES_CREATOR, address!] }),
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
  const minDate = now !== undefined && cfg ? toDateInput(now + cfg.minTimeToExpiry + DAY) : undefined;
  const maxDate = now !== undefined && cfg ? toDateInput(now + cfg.maxTimeToExpiry) : undefined;
  const ready = params && !strikeBad && !expiryBad && listing?.enabled && !existingId;
  const requestJson = params ? JSON.stringify({ ...params, strikeWad: params.strikeWad.toString(), expiry: params.expiry.toString(), contractSizeWad: params.contractSizeWad.toString() }, null, 2) : "";

  return (
    <div className="space-y-3">
      <Back />

      <section className="card rise p-4">
        <h1 className="font-display text-xl font-bold tracking-tight">New market</h1>
        <p className="mt-0.5 text-[13px] text-muted">Pick asset, direction, target and expiry. Same terms can never be listed twice.</p>

        {products.length > 1 && (
          <div className="mt-3 flex gap-1.5 overflow-x-auto scrollbar-none">
            {products.map((p) => (
              <button
                key={p.productId}
                onClick={() => setProductId(p.productId)}
                className={cx("flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-2xl border px-3 text-[13px] font-semibold cursor-pointer", p.productId === product.productId ? "border-primary/50 bg-primary-soft text-primary" : "border-line bg-surface text-muted")}
              >
                <TokenIcon symbol={p.underlyingSymbol} className="h-4 w-4" />
                {p.underlyingSymbol}/{p.assetSymbol}
              </button>
            ))}
          </div>
        )}

        <div className="mt-3">
          <Segmented
            value={optionType === 0 ? "call" : "put"}
            onChange={(v) => setOptionType(v === "call" ? 0 : 1)}
            options={[{ value: "call", label: `Call · ${product.underlyingSymbol} up` }, { value: "put", label: `Put · down` }]}
          />
        </div>

        <div className="mt-3 space-y-3">
          <AmountInput
            label={`Strike (${product.assetSymbol})`}
            value={strike}
            onChange={setStrike}
            unit={product.assetSymbol}
            hint={cfg ? `Between $${fmtWad(cfg.minStrikeWad, 0)} and $${fmtWad(cfg.maxStrikeWad, 0)}` : undefined}
            invalid={strikeBad ? `Outside the listed range for ${product.underlyingSymbol}.` : undefined}
          />
          <div>
            <label htmlFor="new-expiry" className="label">Expiry (settles 08:00 UTC)</label>
            <input
              id="new-expiry"
              type="date"
              value={date}
              min={minDate}
              max={maxDate}
              onChange={(e) => setDate(e.target.value)}
              className="input num mt-1.5"
            />
            {expiry !== undefined && now !== undefined && !expiryBad && (
              <p className="mt-1.5 text-[13px] text-muted">{fmtExpiry(expiry)} · in {fmtDuration(expiry - now)}</p>
            )}
            {expiryBad && <p className="mt-1.5 text-[13px] font-medium text-bad">Too close or too far out for this product.</p>}
          </div>
        </div>
      </section>

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
        <section className="ticket p-4">
          <Details summary="Settlement and risk setup">
            <p className="px-1 py-1 text-[13px] text-muted">
              Uses the same price feeds and risk settings as the nearest listed {optionType === 0 ? "call" : "put"}. One option
              covers 1 {product.underlyingSymbol}. The terms can never change once listed. Listing creates the option token
              only: it can be traded once an order book is opened for it and someone quotes prices.
            </p>
          </Details>
          <div className="mt-3">
            <TxButton
              label="List market"
              steps={ready ? createSeriesSteps(params) : undefined}
              disabled={!ready}
              disabledReason={!params ? "Enter a strike and expiry first." : strikeBad || expiryBad ? "Fix the highlighted field." : undefined}
              successMessage="Market listed."
              onDone={async () => {
                await qc.invalidateQueries({ queryKey: ["series"] });
                const id = await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "computeSeriesId", args: [params!] });
                navigate(`/app/series/${id.toLowerCase()}`);
              }}
            />
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

function Back() {
  return (
    <Link to="/app/markets" className="flex items-center gap-1 px-1 text-[13px] font-semibold text-muted hover:text-ink">
      <ArrowLeft className="h-4 w-4" /> Markets
    </Link>
  );
}
