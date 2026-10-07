/** `/system`: oracle freshness, close-only flags, reserves, services and contract addresses (FRONTEND.md §2). */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { Card, CopyButton, Pill, Row, Skeleton } from "../components/ui.tsx";
import { INDEXER_URL, MANIFEST, PUBLISHER_URL, RPC_URL } from "../config/network.ts";
import { fmtDuration, fmtNative, fmtWad, shortAddr } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { getInsurance } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";

export function SystemPage() {
  const { data: series } = useSeriesList();
  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const assets = useMemo(() => [...new Map((series ?? []).map((s) => [s.settlementAsset, s])).values()], [series]);
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">System status</h1>
        <p className="text-sm text-muted">Live checks of the data and reserves the protocol depends on.</p>
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        {products.map((p) => (
          <ProductStatus key={p.productId} s={p} />
        ))}
        {assets.map((a) => (
          <Reserves key={a.settlementAsset} s={a} />
        ))}
        <Services />
        <Contracts />
      </div>
    </div>
  );
}

function ProductStatus({ s }: { s: Series }) {
  const { data: m } = useProductMarket(s.productId);
  const { data: now } = useChainTime();
  return (
    <Card title={`${s.underlyingSymbol}/${s.assetSymbol} oracles`}>
      {!m ? (
        <Skeleton className="h-24 w-full" />
      ) : (
        <>
          <Row label="Spot price" value={fmtWad(m.spotWad)} />
          <Row label="Spot age" value={<span className="flex items-center gap-2">{now !== undefined ? fmtDuration(now - m.spotPublishTime) : "…"} <Pill tone={m.spotFresh ? "good" : "warn"}>{m.spotFresh ? "fresh" : "stale"}</Pill></span>} />
          <Row label="Volatility surface" value={<Pill tone={m.surface === "FRESH" ? "good" : m.surface === "STALE" ? "warn" : "bad"}>{m.surface.toLowerCase().replace("_", " ")}{m.surfaceStaleSeconds > 0n ? ` (${fmtDuration(m.surfaceStaleSeconds)} past due)` : ""}</Pill>} />
          <Row label="New positions" value={<Pill tone={m.closeOnly ? "warn" : "good"}>{m.closeOnly ? "closing only" : "open"}</Pill>} />
        </>
      )}
    </Card>
  );
}

function Reserves({ s }: { s: Series }) {
  const { data } = useQuery({ queryKey: ["insurance", s.settlementAsset], queryFn: () => getInsurance(s.settlementAsset), refetchInterval: 15_000 });
  const bar = (v: bigint, min: bigint) => (min === 0n ? 100 : Math.min(100, Number((v * 100n) / (2n * min))));
  return (
    <Card title={`${s.assetSymbol} reserves`}>
      {!data ? (
        <Skeleton className="h-24 w-full" />
      ) : (
        <div className="space-y-4">
          {[
            ["Insurance fund", data.balance, data.minimumSeed],
            ["Keeper reserve", data.keeperReserve, data.minimumKeeperReserve],
          ].map(([label, v, min]) => (
            <div key={label as string}>
              <div className="flex justify-between text-sm">
                <span className="text-muted">{label as string}</span>
                <span className="num font-semibold">{fmtNative(v as bigint, s.assetDecimals)} {s.assetSymbol}</span>
              </div>
              <div className="mt-1.5 h-2 rounded-full bg-surface-2">
                <div className={`h-2 rounded-full ${(v as bigint) >= (min as bigint) * 2n ? "bg-good" : (v as bigint) >= (min as bigint) ? "bg-warn" : "bg-bad"}`} style={{ width: `${bar(v as bigint, min as bigint)}%` }} />
              </div>
              <div className="mt-1 text-xs text-muted">Minimum {fmtNative(min as bigint, s.assetDecimals)} · alert below 2×</div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

function Services() {
  const probe = (url?: string) => async () => {
    if (!url) return "not configured";
    try {
      const r = await fetch(`${url}/health`);
      return r.ok ? "online" : `error ${r.status}`;
    } catch {
      return "offline";
    }
  };
  const publisher = useQuery({ queryKey: ["svc", "publisher"], queryFn: probe(PUBLISHER_URL), refetchInterval: 15_000 });
  const indexer = useQuery({ queryKey: ["svc", "indexer"], queryFn: probe(INDEXER_URL), refetchInterval: 15_000 });
  const tone = (s?: string) => (s === "online" ? "good" : s === "not configured" ? "neutral" : "bad");
  return (
    <Card title="Services">
      <Row label="RPC" value={<span className="num">{RPC_URL}</span>} />
      <Row label="Price service (publisher)" value={<Pill tone={tone(publisher.data)}>{publisher.data ?? "checking…"}</Pill>} />
      <Row label="Indexer" value={<Pill tone={tone(indexer.data)}>{indexer.data ?? "checking…"}</Pill>} />
      <p className="mt-2 text-xs text-muted">Without the indexer, lists are read from on-chain events (slower on long histories).</p>
    </Card>
  );
}

function Contracts() {
  const rows = Object.entries(MANIFEST.proxies).map(([name, p]) => [name, p.proxy] as const);
  return (
    <Card title="Contracts" className="lg:col-span-2">
      <div className="grid gap-x-8 sm:grid-cols-2">
        {[...rows, ["UpgradeAdmin", MANIFEST.upgradeAdmin] as const, ["KuruAdapter", MANIFEST.kuruAdapter] as const].map(([name, a]) => (
          <Row key={name} label={name} value={<span className="num">{shortAddr(a)} <CopyButton text={a} label={name} /></span>} />
        ))}
      </div>
      <p className="mt-3 text-xs text-muted">Deployed at block {MANIFEST.deployedAtBlock} on chain {MANIFEST.chainId}. Upgrades go through a 7-day timelock.</p>
    </Card>
  );
}
