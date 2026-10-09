/** `/system`: oracle freshness, close-only flags, reserves, services and contract addresses (FRONTEND.md §2). */
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Activity,
  CheckCircle2,
  Copy,
  ExternalLink,
  Lock,
  Radio,
  Server,
  Shield,
  ShieldCheck,
  Zap,
} from "lucide-react";
import { Card, CopyButton, Pill, Row, Skeleton, Term } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { INDEXER_URL, MANIFEST, PUBLISHER_URL, RPC_URL } from "../config/network.ts";
import { fmtDuration, fmtLevel, fmtNative, fmtWad, shortAddr } from "../lib/optara/format.ts";
import { useChainTime, useProductMarket, useSeriesList } from "../lib/optara/hooks.ts";
import { getInsurance, getUpgrades } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";

export function SystemPage() {
  const { data: series } = useSeriesList();
  const products = useMemo(() => [...new Map((series ?? []).map((s) => [s.productId, s])).values()], [series]);
  const assets = useMemo(() => [...new Map((series ?? []).map((s) => [s.settlementAsset, s])).values()], [series]);

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="px-1">
        <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">System</h1>
        <p className="mt-0.5 text-[13px] text-muted">
          Oracles, reserves and contracts — live from chain.
        </p>
      </div>

      <div className="flex flex-col gap-3">
        {products.map((p) => (
          <ProductStatus key={p.productId} s={p} />
        ))}
        {assets.map((a) => (
          <Reserves key={a.settlementAsset} s={a} />
        ))}
        <Upgrades />
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
    <Card
      title={
        <div className="flex items-center gap-2">
          <TokenIcon symbol={s.underlyingSymbol} className="h-5 w-5" />
          <span className="font-bold text-ink">
            {s.underlyingSymbol}/{s.assetSymbol} Oracles
          </span>
        </div>
      }
    >
      {!m ? (
        <Skeleton className="h-28 w-full" />
      ) : (
        <div className="space-y-2 text-xs">
          <Row label="Live price (Pyth)" value={`$${fmtLevel(m.spotWad)}`} strong />
          <Row
            label="Last price update"
            value={
              <span className="flex items-center gap-2">
                {now === undefined ? "…" : now - m.spotPublishTime <= 0n ? "just now" : `${fmtDuration(now - m.spotPublishTime)} ago`}
                <Pill tone={m.spotFresh ? "good" : "warn"} dot>
                  {m.spotFresh ? "Live" : "Delayed"}
                </Pill>
              </span>
            }
          />
          <Row
            label={<Term tip="The signed volatility data used to price options. New positions need it to be fresh.">Volatility data</Term>}
            value={
              <Pill tone={m.surface === "FRESH" ? "good" : m.surface === "STALE" ? "warn" : "bad"}>
                {m.surface === "FRESH" ? "Fresh, signed by publishers" : m.surface === "STALE" ? "Late" : m.surface === "NONE" ? "Not published" : "Expired"}
                {m.surfaceStaleSeconds > 0n ? ` (${fmtDuration(m.surfaceStaleSeconds)} late)` : ""}
              </Pill>
            }
          />
          <Row
            label="Trading State"
            value={
              <Pill tone={m.closeOnly ? "warn" : "good"}>
                {m.closeOnly ? "Closing only" : "Open for new trades"}
              </Pill>
            }
          />
        </div>
      )}
    </Card>
  );
}

function Reserves({ s }: { s: Series }) {
  const { data } = useQuery({
    queryKey: ["insurance", s.settlementAsset],
    queryFn: () => getInsurance(s.settlementAsset),
    refetchInterval: 15_000,
  });

  const bar = (v: bigint, min: bigint) => (min === 0n ? 100 : Math.min(100, Number((v * 100n) / (2n * min))));

  return (
    <Card
      title={
        <div className="flex items-center gap-2">
          <ShieldCheck className="h-5 w-5 text-good" />
          <span className="font-bold text-ink">{s.assetSymbol} Protocol Reserves</span>
        </div>
      }
    >
      {!data ? (
        <Skeleton className="h-28 w-full" />
      ) : (
        <div className="space-y-4">
          {[
            ["Insurance fund (covers writers who can't pay)", data.balance, data.minimumSeed],
            ["Keeper reserve (pays settlement rewards)", data.keeperReserve, data.minimumKeeperReserve],
          ].map(([label, v, min]) => (
            <div key={label as string} className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
              <div className="flex justify-between text-xs">
                <span className="font-semibold text-ink">{label as string}</span>
                <span className="num font-bold text-ink">
                  {fmtNative(v as bigint, s.assetDecimals)} {s.assetSymbol}
                </span>
              </div>
              <div className="mt-2 h-2 rounded-full bg-surface">
                <div
                  className={`h-2 rounded-full transition-all duration-500 ${(v as bigint) >= (min as bigint) * 2n ? "bg-good" : (v as bigint) >= (min as bigint) ? "bg-warn" : "bg-bad"}`}
                  style={{ width: `${bar(v as bigint, min as bigint)}%` }}
                />
              </div>
              <div className="mt-1.5 flex justify-between text-[11px] text-muted">
                <span>Minimum: {fmtNative(min as bigint, s.assetDecimals)}</span>
                <span className={(v as bigint) >= (min as bigint) * 2n ? "text-good" : (v as bigint) >= (min as bigint) ? "text-warn" : "text-bad"}>
                  {(min as bigint) === 0n
                    ? "No minimum set"
                    : `${Number(((v as bigint) * 100n) / (min as bigint))}% of minimum${(v as bigint) < (min as bigint) ? " · below minimum" : ""}`}
                </span>
              </div>
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
    <Card
      title={
        <div className="flex items-center gap-2">
          <Server className="h-5 w-5 text-primary" />
          <span className="font-bold text-ink">Services</span>
        </div>
      }
    >
      <div className="space-y-2 text-xs">
        <Row label="Network RPC" value={<span className="num text-muted truncate max-w-[200px]">{RPC_URL}</span>} />
        <Row
          label="Volatility publisher"
          value={<Pill tone={tone(publisher.data)}>{publisher.data ?? "verifying…"}</Pill>}
        />
        <Row
          label="Indexer"
          value={<Pill tone={tone(indexer.data)}>{indexer.data ?? "verifying…"}</Pill>}
        />
      </div>
      <p className="mt-3 text-[11px] text-muted">
        Optara operates trustlessly. If off-chain indexing is unavailable, state is read directly from RPC events.
      </p>
    </Card>
  );
}

function Contracts() {
  const rows = Object.entries(MANIFEST.proxies).map(([name, p]) => [name, p.proxy] as const);

  return (
    <Card
      title={
        <div className="flex items-center gap-2">
          <Lock className="h-5 w-5 text-accent" />
          <span className="font-bold text-ink">Contracts</span>
        </div>
      }
      className=""
    >
      <div className="flex flex-col gap-1 text-xs">
        {[
          ...rows,
          ["UpgradeAdmin", MANIFEST.upgradeAdmin] as const,
          ["KuruAdapter", MANIFEST.kuruAdapter] as const,
        ].map(([name, a]) => (
          <Row
            key={name}
            label={name}
            value={
              <span className="num flex items-center gap-1">
                {shortAddr(a)} <CopyButton text={a} label={name} />
              </span>
            }
          />
        ))}
      </div>
      <p className="mt-4 text-[11px] text-muted border-t border-line pt-3">
        Deployed at block {MANIFEST.deployedAtBlock} on Monad (Chain ID: {MANIFEST.chainId}). All upgrades are timelocked with 7-day governance execution delay.
      </p>
    </Card>
  );
}

/** Scheduled contract upgrades: what will change, and when it can take effect (FRONTEND.md §2 "pending upgrades"). */
function Upgrades() {
  const { data: now } = useChainTime();
  const { data, isLoading, error } = useQuery({ queryKey: ["upgrades"], queryFn: () => getUpgrades(MANIFEST.upgradeAdmin), refetchInterval: 30_000 });
  const nameOf = (a: string) => Object.entries(MANIFEST.proxies).find(([, p]) => p.proxy.toLowerCase() === a.toLowerCase())?.[0] ?? shortAddr(a);
  const pending = (data ?? []).filter((u) => u.state === "PENDING");
  const past = (data ?? []).filter((u) => u.state !== "PENDING").slice(0, 5);

  return (
    <Card
      className="lg:col-span-2"
      title={
        <div className="flex items-center gap-2">
          <Shield className="h-5 w-5 text-warn" />
          <span className="font-bold text-ink">Scheduled upgrades</span>
          {pending.length > 0 && <Pill tone="warn">{pending.length} pending</Pill>}
        </div>
      }
    >
      <p className="text-xs leading-relaxed text-muted">
        Optara's contracts can only be upgraded after a public waiting period: 7 days, or 24 hours for an emergency fix
        approved by a large multisig majority. Anything scheduled shows here first, so you can close positions or withdraw
        before it takes effect if you disagree with it.
      </p>
      {isLoading ? (
        <Skeleton className="mt-3 h-16 w-full" />
      ) : error ? (
        <p className="mt-3 text-xs text-bad">Couldn't read the upgrade schedule.</p>
      ) : pending.length === 0 ? (
        <div className="mt-3 flex items-center gap-2 rounded-xl border border-good/30 bg-good/8 px-3 py-2.5 text-[13px] text-good">
          <CheckCircle2 className="h-4 w-4" /> No upgrades are scheduled. Any change would appear here at least 24 hours ahead (7 days for normal upgrades).
        </div>
      ) : (
        <ul className="mt-3 space-y-2">
          {pending.map((u) => (
            <li key={u.id} className="rounded-xl border border-warn/40 bg-warn/8 p-3 text-[13px]">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-semibold">
                  {nameOf(u.proxy)} {u.emergency && <Pill tone="bad">Emergency</Pill>}
                </span>
                <span className="num font-semibold">
                  {now !== undefined && u.eta > now ? `can take effect in ${fmtDuration(u.eta - now)}` : "can take effect now"}
                </span>
              </div>
              <div className="mt-1 text-xs text-muted">
                New code <span className="num">{shortAddr(u.implementation)}</span> <CopyButton text={u.implementation} label="implementation" /> · earliest{" "}
                {new Date(Number(u.eta) * 1000).toUTCString().replace(" GMT", " UTC")}
              </div>
            </li>
          ))}
        </ul>
      )}
      {past.length > 0 && (
        <ul className="mt-3 space-y-1 border-t border-line pt-2 text-xs text-muted">
          {past.map((u) => (
            <li key={u.id}>
              {nameOf(u.proxy)} · {u.state === "EXECUTED" ? "upgraded" : "cancelled"} · {shortAddr(u.implementation)}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
