/** `/admin`: trusted-role operations for venues, products and market routing. */
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { isAddress, stringToHex, zeroAddress, type Address, type Hex } from "viem";
import { optionSeriesRegistryAbi, protocolControlAbi, venueRegistryAbi } from "@optara/sdk";
import { CheckCircle2, CircleSlash, Landmark, ListChecks, LockKeyhole, Route, ShieldCheck, SlidersHorizontal } from "lucide-react";
import { Card, EmptyState, Pill, Segmented, Skeleton, cx } from "../components/ui.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { callStep, registerExistingDirectMarketSteps } from "../lib/optara/actions.ts";
import { ADDR, DIRECT_VENUE, KURU_VENUE, publicClient } from "../lib/optara/client.ts";
import { fmtExpiryShort, fmtLevel } from "../lib/optara/format.ts";
import { useSeriesList } from "../lib/optara/hooks.ts";
import { ROLE_KEYS, TRUSTED_ROLES, hasAnyTrustedRole, hasRole, roleNames } from "../lib/optara/roles.ts";
import type { Series } from "../lib/optara/types.ts";

type VenueKey = "direct" | "kuru";
const VENUES: Record<VenueKey, { id: Hex; label: string; description: string }> = {
  direct: { id: DIRECT_VENUE, label: "Optara Direct", description: "The in-house quoted venue. Disable it if you only want external venues shown." },
  kuru: { id: KURU_VENUE, label: "Kuru", description: "External Kuru order books registered through VenueRegistry." },
};

export function AdminPage() {
  const { address, isConnected } = useConnection();
  const { data: series, isLoading } = useSeriesList();
  const [venue, setVenue] = useState<VenueKey>("direct");
  const [seriesId, setSeriesId] = useState<Hex | undefined>();
  const [market, setMarket] = useState("");
  const [metadata, setMetadata] = useState("");
  const selected = (series ?? []).find((s) => s.id === seriesId) ?? series?.[0];
  const selectedVenue = VENUES[venue];

  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const [productId, setProductId] = useState<Hex | undefined>();
  const product = products.find((p) => p.productId === productId) ?? products[0];

  const { data: roleMap, isLoading: rolesLoading } = useQuery({
    queryKey: ["adminRoles", address],
    queryFn: async () => {
      const entries = await Promise.all(
        TRUSTED_ROLES.map(async (r) => [r.key, await publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "hasRole", args: [r.key, address!] })] as const),
      );
      return new Map(entries);
    },
    enabled: !!address,
  });

  const { data: adapter, isLoading: adapterLoading } = useQuery({
    queryKey: ["adapterOf", selectedVenue.id],
    queryFn: async () => {
      const [adapter, enabled] = await publicClient.readContract({ address: ADDR.venues, abi: venueRegistryAbi, functionName: "adapterOf", args: [selectedVenue.id] });
      return { adapter, enabled };
    },
  });

  const { data: venueMarket } = useQuery({
    queryKey: ["adminMarket", selectedVenue.id, selected?.id],
    queryFn: () => publicClient.readContract({ address: ADDR.venues, abi: venueRegistryAbi, functionName: "getMarket", args: [selectedVenue.id, selected!.id] }).catch(() => undefined),
    enabled: !!selected,
  });

  const { data: productState } = useQuery({
    queryKey: ["adminProduct", product?.productId],
    queryFn: async () => ({
      enabled: await publicClient.readContract({ address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "isProductEnabled", args: [product!.productId] }),
      closeOnly: await publicClient.readContract({ address: ADDR.control, abi: protocolControlAbi, functionName: "isProductCloseOnly", args: [product!.productId] }),
    }),
    enabled: !!product,
  });

  const isVenueAdmin = hasRole(roleMap, ROLE_KEYS.venueAdmin) || hasRole(roleMap, ROLE_KEYS.governance);
  const isGovernance = hasRole(roleMap, ROLE_KEYS.governance);
  const canDisableVenue = isVenueAdmin || isGovernance || hasRole(roleMap, ROLE_KEYS.guardian);
  const myRoles = roleNames(roleMap);
  const marketAddress = isAddress(market) ? (market as Address) : undefined;
  const metadataHex = metadata.trim() ? stringToHex(metadata.trim()) : "0x";

  if (!isConnected) return <Card><EmptyState title="Connect an admin wallet" body="Admin tools are hidden until a wallet is connected. Test wallets with trusted roles work on the local fork." /></Card>;
  if (rolesLoading) return <Card><Skeleton className="h-28 w-full" /></Card>;
  if (!hasAnyTrustedRole(roleMap)) {
    return (
      <Card>
        <EmptyState
          icon={<LockKeyhole className="h-5 w-5" />}
          title="Admin tools are hidden"
          body="This wallet does not hold a trusted Optara role. Connect Bob on the local fork, or connect a production role wallet on mainnet."
        />
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      <section className="card rise overflow-hidden p-5 sm:p-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary-soft px-3 py-1 text-xs font-bold text-primary">
              <LockKeyhole className="h-3.5 w-3.5" /> Trusted operations
            </div>
            <h1 className="font-display mt-3 text-2xl font-bold tracking-tight">Optara admin</h1>
            <p className="mt-1 max-w-2xl text-sm leading-6 text-muted">
              Manage venue availability, route markets, and product safety switches from one place. Each action still goes through the contract role checks before it can execute.
            </p>
            <div className="mt-3 flex flex-wrap gap-1.5">
              {myRoles.map((r) => <Pill key={r} tone="primary">{r}</Pill>)}
            </div>
          </div>
          <div className="grid gap-2 sm:grid-cols-3 lg:min-w-[420px]">
            <Mini label="Venue" value={isVenueAdmin ? "ready" : "locked"} good={isVenueAdmin} />
            <Mini label="Governance" value={isGovernance ? "ready" : "locked"} good={isGovernance} />
            <Mini label="Products" value={products.length.toString()} good={products.length > 0} />
          </div>
        </div>
      </section>

      <Card title="Your roles">
        <div className="grid gap-2 md:grid-cols-2 xl:grid-cols-3">
          {TRUSTED_ROLES.map((r) => {
            const has = roleMap?.get(r.key);
            return (
              <div key={r.label} className={cx("rounded-2xl border p-3.5", has ? "border-good/25 bg-good/8" : "border-line bg-surface-2/45")}>
                <div className="flex items-center justify-between gap-2">
                  <div className="font-bold">{r.label}</div>
                  <Pill tone={has ? "good" : "neutral"}>{has ? "Granted" : "Not granted"}</Pill>
                </div>
                <p className="mt-1 text-xs leading-5 text-muted">{r.help}</p>
              </div>
            );
          })}
        </div>
      </Card>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1.1fr)_minmax(360px,0.9fr)]">
        <Card title="Venue controls">
          <div className="space-y-4">
            <Segmented<VenueKey> value={venue} onChange={setVenue} options={[{ value: "direct", label: "Optara Direct" }, { value: "kuru", label: "Kuru" }]} />
            <div className="rounded-2xl border border-line bg-surface-2/50 p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2 font-display text-lg font-bold">
                    <Route className="h-4 w-4 text-primary" /> {selectedVenue.label}
                  </div>
                  <p className="mt-1 max-w-xl text-sm leading-6 text-muted">{selectedVenue.description}</p>
                </div>
                {adapterLoading ? <Skeleton className="h-7 w-24" /> : <Pill tone={adapter?.enabled ? "good" : "warn"}>{adapter?.enabled ? "Enabled" : "Disabled"}</Pill>}
              </div>
              <div className="mt-3 grid gap-2 sm:grid-cols-2">
                <TxButton
                  label={`Enable ${selectedVenue.label}`}
                  steps={[callStep("enable-adapter", `Enable ${selectedVenue.label}`, { address: ADDR.venues, abi: venueRegistryAbi, functionName: "setAdapterEnabled", args: [selectedVenue.id, true] })]}
                  disabled={!isGovernance || adapter?.enabled === true}
                  disabledReason={!isGovernance ? "Only governance can enable an adapter." : "Already enabled."}
                  successMessage="Venue adapter enabled."
                />
                <TxButton
                  label={`Disable ${selectedVenue.label}`}
                  tone="accent"
                  steps={[callStep("disable-adapter", `Disable ${selectedVenue.label}`, { address: ADDR.venues, abi: venueRegistryAbi, functionName: "setAdapterEnabled", args: [selectedVenue.id, false] })]}
                  disabled={!canDisableVenue || adapter?.enabled === false}
                  disabledReason={!canDisableVenue ? "Needs governance, guardian, or venue admin." : "Already disabled."}
                  successMessage="Venue adapter disabled."
                />
              </div>
            </div>

            <div className="rounded-2xl border border-line p-4">
              <div className="flex items-start gap-3">
                <ListChecks className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
                <div>
                  <div className="font-bold">Market status</div>
                  <p className="mt-1 text-sm leading-6 text-muted">Inactivate one option market when a book is broken or should not be routed. Active markets appear in the buy/sell venue picker.</p>
                </div>
              </div>
              <SeriesSelect series={series} selected={selected} onChange={setSeriesId} loading={isLoading} />
              <div className="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-xl bg-surface-2 p-3 text-sm">
                <span className="text-muted">Current market</span>
                <span className="num font-semibold">{venueMarket?.market && venueMarket.market !== zeroAddress ? short(venueMarket.market) : "Not registered"}</span>
                <Pill tone={venueMarket?.status === 1 ? "good" : "neutral"}>{venueMarket?.status === 1 ? "Active" : "Inactive"}</Pill>
              </div>
              <div className="mt-3 grid gap-2 sm:grid-cols-2">
                <TxButton
                  label="Activate market"
                  steps={selected ? [callStep("market-active", "Activate market", { address: ADDR.venues, abi: venueRegistryAbi, functionName: "setMarketStatus", args: [selectedVenue.id, selected.id, 1] })] : undefined}
                  disabled={!isVenueAdmin || !selected || venueMarket?.market === zeroAddress || venueMarket?.status === 1}
                  disabledReason={!isVenueAdmin ? "Needs VENUE_ADMIN." : "Choose a registered inactive market."}
                  successMessage="Market activated."
                />
                <TxButton
                  label="Inactivate market"
                  tone="accent"
                  steps={selected ? [callStep("market-inactive", "Inactivate market", { address: ADDR.venues, abi: venueRegistryAbi, functionName: "setMarketStatus", args: [selectedVenue.id, selected.id, 0] })] : undefined}
                  disabled={!isVenueAdmin || !selected || venueMarket?.status !== 1}
                  disabledReason={!isVenueAdmin ? "Needs VENUE_ADMIN." : "Choose an active market."}
                  successMessage="Market inactivated."
                />
              </div>
            </div>
          </div>
        </Card>

        <Card title="Register a venue market">
          <div className="space-y-3">
            <p className="text-sm leading-6 text-muted">
              Attach an order book to a specific option series. Optara Direct can be created here. Kuru books must already exist because real Kuru deployment is owner-gated.
            </p>
            <SeriesSelect series={series} selected={selected} onChange={setSeriesId} loading={isLoading} compact />
            {venue === "direct" ? (
              <div className="rounded-2xl border border-primary/20 bg-primary-soft/45 p-3">
                <div className="font-bold">Create Optara Direct order book</div>
                <p className="mt-1 text-xs leading-5 text-muted">
                  This deploys a simple in-house book for the selected option token and registers it immediately.
                </p>
                <div className="mt-3">
                  <TxButton
                    label="Create and attach Optara Direct book"
                    steps={selected ? registerExistingDirectMarketSteps(selected, address) : undefined}
                    disabled={!isVenueAdmin || !selected || (venueMarket?.market !== zeroAddress && !!venueMarket?.market)}
                    disabledReason={!isVenueAdmin ? "Needs VENUE_ADMIN." : venueMarket?.market !== zeroAddress && !!venueMarket?.market ? "This venue already has a market for the selected series." : undefined}
                    successMessage="Optara Direct order book registered."
                  />
                </div>
              </div>
            ) : (
              <>
                <label className="block">
                  <span className="mb-1 block text-xs font-bold uppercase text-faint">Existing Kuru market address</span>
                  <input className="input" value={market} onChange={(e) => setMarket(e.target.value.trim())} placeholder="0x..." />
                </label>
                <label className="block">
                  <span className="mb-1 block text-xs font-bold uppercase text-faint">Metadata note</span>
                  <input className="input" value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder="optional: maker, source, deployment note" />
                </label>
                <TxButton
                  label={`Register on ${selectedVenue.label}`}
                  steps={selected && marketAddress ? [callStep("register-market", "Register market", { address: ADDR.venues, abi: venueRegistryAbi, functionName: "registerMarket", args: [selectedVenue.id, marketAddress, selected.id, metadataHex] })] : undefined}
                  disabled={!isVenueAdmin || !selected || !marketAddress || (venueMarket?.market !== zeroAddress && !!venueMarket?.market)}
                  disabledReason={!isVenueAdmin ? "Needs VENUE_ADMIN." : !marketAddress ? "Enter a valid market address." : venueMarket?.market !== zeroAddress && !!venueMarket?.market ? "This venue already has a market for the selected series." : undefined}
                  successMessage="Venue market registered."
                />
              </>
            )}
          </div>
        </Card>
      </div>

      <Card title="Product safety">
        {product ? (
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(320px,0.8fr)]">
            <div>
              <ProductSelect products={products} selected={product} onChange={setProductId} />
              <div className="mt-3 grid gap-2 sm:grid-cols-2">
                <StatusCard icon={CheckCircle2} title="Product listing" value={productState?.enabled ? "Enabled" : "Disabled"} good={!!productState?.enabled} />
                <StatusCard icon={CircleSlash} title="Close-only" value={productState?.closeOnly ? "On" : "Off"} good={!productState?.closeOnly} />
              </div>
            </div>
            <div className="space-y-2">
              <TxButton
                label={productState?.enabled ? "Disable new series" : "Enable new series"}
                tone={productState?.enabled ? "accent" : "primary"}
                steps={[callStep("product-enabled", productState?.enabled ? "Disable product" : "Enable product", { address: ADDR.registry, abi: optionSeriesRegistryAbi, functionName: "setProductEnabled", args: [product.productId, !productState?.enabled] })]}
                disabled={!isGovernance}
                disabledReason="Only governance can change product enablement."
                successMessage="Product listing status updated."
              />
              <TxButton
                label={productState?.closeOnly ? "Reopen trading risk" : "Set close-only"}
                tone={productState?.closeOnly ? "primary" : "accent"}
                steps={[callStep("product-close-only", productState?.closeOnly ? "Unset close-only" : "Set close-only", { address: ADDR.control, abi: protocolControlAbi, functionName: "setProductCloseOnly", args: [product.productId, !productState?.closeOnly] })]}
                disabled={!canDisableVenue}
                disabledReason="Needs governance or guardian."
                successMessage="Product close-only status updated."
              />
            </div>
          </div>
        ) : (
          <EmptyState title="No approved products found" body="Approve products through governance first, then this page can manage their enabled and close-only state." />
        )}
      </Card>

      <Card title="Approval workflow">
        <div className="grid gap-3 md:grid-cols-3">
          <Guide icon={Landmark} title="1. Approve product" text="Governance approves the underlying, settlement asset, strike bounds, expiry bounds and contract-size limits." />
          <Guide icon={ShieldCheck} title="2. Attach risk and oracle rules" text="Risk and oracle admins prepare the surface, spot source and settlement config before series creation." />
          <Guide icon={SlidersHorizontal} title="3. Register venue markets" text="Venue admin registers Kuru or Optara Direct books, then activates only the routes that should appear in trading." />
        </div>
      </Card>
    </div>
  );
}

function SeriesSelect({ series, selected, onChange, loading, compact }: { series?: Series[]; selected?: Series; onChange: (id: Hex) => void; loading?: boolean; compact?: boolean }) {
  if (loading) return <Skeleton className="mt-3 h-11 w-full" />;
  return (
    <div className={cx(compact ? "" : "mt-3")}>
      <label className="block">
        <span className="mb-1 block text-xs font-bold uppercase text-faint">Option series</span>
        <select className="input min-h-[44px] cursor-pointer" value={selected?.id ?? ""} onChange={(e) => onChange(e.target.value as Hex)}>
          {(series ?? []).map((s) => (
            <option key={s.id} value={s.id}>
              {s.underlyingSymbol}/{s.assetSymbol} · {s.optionType === 0 ? "Call ↑" : "Put ↓"} · strike ${fmtLevel(s.strikeWad)} · {fmtExpiryShort(s.expiry)} · {short(s.wrapper)}
            </option>
          ))}
        </select>
      </label>
      {selected && (
        <div className="mt-2 grid gap-2 rounded-2xl border border-line bg-surface-2/55 p-3 text-xs sm:grid-cols-2">
          <div>
            <span className="block font-bold text-ink">{selected.underlyingSymbol} {selected.optionType === 0 ? "Call" : "Put"}</span>
            <span className="text-muted">Strike ${fmtLevel(selected.strikeWad)} · {fmtExpiryShort(selected.expiry)}</span>
          </div>
          <div className="sm:text-right">
            <span className="block font-bold text-ink">Token {short(selected.wrapper)}</span>
            <span className="text-muted">Series {short(selected.id)}</span>
          </div>
        </div>
      )}
    </div>
  );
}

function ProductSelect({ products, selected, onChange }: { products: Series[]; selected: Series; onChange: (id: Hex) => void }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-bold uppercase text-faint">Product</span>
      <select className="input min-h-[44px] cursor-pointer" value={selected.productId} onChange={(e) => onChange(e.target.value as Hex)}>
        {products.map((p) => (
          <option key={p.productId} value={p.productId}>{p.underlyingSymbol}/{p.assetSymbol}</option>
        ))}
      </select>
    </label>
  );
}

function Mini({ label, value, good }: { label: string; value: string; good: boolean }) {
  return (
    <div className="rounded-2xl border border-line bg-surface-2/60 p-3">
      <div className="text-[11px] font-bold uppercase text-faint">{label}</div>
      <div className={cx("mt-1 font-display text-lg font-bold", good ? "text-good" : "text-muted")}>{value}</div>
    </div>
  );
}

function StatusCard({ icon: Icon, title, value, good }: { icon: typeof CheckCircle2; title: string; value: string; good: boolean }) {
  return (
    <div className="rounded-2xl border border-line bg-surface-2/60 p-4">
      <Icon className={cx("h-4 w-4", good ? "text-good" : "text-warn")} />
      <div className="mt-2 text-sm text-muted">{title}</div>
      <div className="font-display text-xl font-bold">{value}</div>
    </div>
  );
}

function Guide({ icon: Icon, title, text }: { icon: typeof Landmark; title: string; text: string }) {
  return (
    <div className="rounded-2xl border border-line bg-surface-2/50 p-4">
      <Icon className="h-5 w-5 text-primary" />
      <div className="mt-3 font-bold">{title}</div>
      <p className="mt-1 text-sm leading-6 text-muted">{text}</p>
    </div>
  );
}

function short(a: Hex) {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
