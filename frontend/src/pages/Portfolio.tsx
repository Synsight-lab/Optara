/** `/portfolio`: accounts, health, collateral, positions, wallet tokens and what needs doing (FRONTEND.md §2, §5). */
import { useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useConnection } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import { AmountInput, Card, EmptyState, Pill, Segmented, Skeleton, Stat, Term, cx } from "../components/ui.tsx";
import { HealthBar } from "../components/HealthBar.tsx";
import { TxButton } from "../components/TxButton.tsx";
import { createAccountStep, createdAccountId, depositSteps, setupAccountSteps, withdrawSteps } from "../lib/optara/actions.ts";
import { fmtNative, fmtQty, fmtWad, optionTypeName, parseFixed, seriesName, WAD } from "../lib/optara/format.ts";
import { useAccountView, useLiquidationSpots, useProductMarket, useSeriesList, useTokenBalance, useWalletWrappers } from "../lib/optara/hooks.ts";
import { getGroupState, getSeriesMarket } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState } from "../state.tsx";
import { StatePill } from "./Series.tsx";

export function PortfolioPage() {
  const { address, isConnected } = useConnection();
  const { accounts, selected, select, loading, refresh } = useAccountState();
  const { data: series } = useSeriesList();
  const asset = series?.[0];

  if (!isConnected) {
    return (
      <Card>
        <EmptyState icon="◎" title="Connect a wallet to see your portfolio" body="Your accounts, positions and option tokens appear here once you connect." />
      </Card>
    );
  }
  if (loading || !asset) return <Card><Skeleton className="h-48 w-full" /></Card>;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Portfolio</h1>
          <p className="text-sm text-muted">Your Optara accounts and the option tokens in your wallet.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {accounts.length > 0 && (
            <Segmented value={(selected ?? accounts[0]!).toString()} onChange={(v) => select(BigInt(v))} options={accounts.map((a) => ({ value: a.toString(), label: `Account #${a}` }))} />
          )}
          {accounts.length > 0 && <NewAccountButton asset={asset} onCreated={async (id) => (await refresh(), select(id))} />}
        </div>
      </div>
      {accounts.length === 0 ? <Onboarding asset={asset} /> : selected !== undefined && <AccountDashboard accountId={selected} asset={asset} owner={address!} />}
      <WalletTokens owner={address!} />
    </div>
  );
}

function NewAccountButton({ asset, onCreated }: { asset: Series; onCreated: (id: bigint) => void }) {
  const [open, setOpen] = useState(false);
  if (!open) return <button className="btn-ghost" onClick={() => setOpen(true)}>+ New account</button>;
  return (
    <div className="w-full sm:w-64">
      <TxButton label="Create another account" steps={[createAccountStep(asset.settlementAsset)]} successMessage="New account created" onDone={(r) => { const id = createdAccountId(r[0]!); setOpen(false); if (id !== undefined) onCreated(id); }} />
    </div>
  );
}

function Onboarding({ asset }: { asset: Series }) {
  const { refresh, select } = useAccountState();
  const { address } = useConnection();
  const { data: balance } = useTokenBalance(asset.settlementAsset, address);
  const [amount, setAmount] = useState("5000");
  const deposit = parseFixed(amount, asset.assetDecimals);
  const created = useRef<bigint | undefined>(undefined);
  const steps = useMemo(
    () => (deposit ? setupAccountSteps(asset.settlementAsset, deposit, asset.assetSymbol, (id) => (created.current = id)) : undefined),
    [deposit, asset],
  );
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Card title="Open your first account">
        <p className="mb-4 text-sm text-muted">
          Buying options needs no account: tokens go straight to your wallet. To <b className="text-ink">write</b> options, you hold {asset.assetSymbol} as collateral in an Optara account. One click creates it and deposits.
        </p>
        <div className="space-y-4">
          <AmountInput label="Deposit" value={amount} onChange={setAmount} unit={asset.assetSymbol} presets={["1000", "5000", "10000"]} max={balance !== undefined ? fmtNative(balance, asset.assetDecimals).replace(/,/g, "") : undefined} maxLabel="Wallet" />
          <TxButton label="Create account & deposit" steps={steps} disabled={!deposit} successMessage="Your account is ready" onDone={async () => { await refresh(); if (created.current !== undefined) select(created.current); }} />
        </div>
      </Card>
      <Card title="What you can do">
        <ul className="space-y-3 text-sm">
          {[
            ["Buy a call or put", "Pay once; your loss is limited to what you paid. Find one in Markets."],
            ["Write options for income", "Earn the premium; keep enough collateral as prices move."],
            ["Hedge", "Move option tokens into your account to offset what you've written and free margin."],
          ].map(([t, b]) => (
            <li key={t} className="flex gap-3">
              <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-primary" />
              <span>
                <span className="block font-medium">{t}</span>
                <span className="block text-muted">{b}</span>
              </span>
            </li>
          ))}
        </ul>
        <Link to="/" className="btn-ghost mt-5 w-full">Browse markets</Link>
      </Card>
    </div>
  );
}

function AccountDashboard({ accountId, asset, owner }: { accountId: bigint; asset: Series; owner: Hex }) {
  const { data: a, isLoading } = useAccountView(accountId);
  const { data: walletCash } = useTokenBalance(asset.settlementAsset, owner);
  const { data: product } = useProductMarket(a?.positions[0]?.series.productId ?? asset.productId);
  const spots = useLiquidationSpots(accountId, product?.productId, product?.spotWad, !!a && a.positions.length > 0);
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const value = parseFixed(amount, asset.assetDecimals);
  if (isLoading || !a) return <Card><Skeleton className="h-56 w-full" /></Card>;

  const todo: { tone: "warn" | "bad" | "primary"; text: React.ReactNode }[] = [];
  if (a.health.state === "LIQUIDATABLE" || a.health.state === "INSOLVENT") todo.push({ tone: "bad", text: "Below maintenance margin: deposit now or close positions to avoid liquidation." });
  else if (a.health.state === "CLOSE_ONLY") todo.push({ tone: "warn", text: "Below initial margin: new positions are blocked until you deposit or reduce." });
  if (walletCash && walletCash > 0n && a.positions.some((p) => p.balance < 0n))
    todo.push({ tone: "primary", text: <>You have {fmtNative(walletCash, asset.assetDecimals)} {asset.assetSymbol} in your wallet. Premium from Kuru stays there — deposit it to strengthen your margin.</> });
  if (!a.health.fresh) todo.push({ tone: "warn", text: "Prices are delayed, so health may be out of date." });

  const steps = value ? (tab === "deposit" ? depositSteps(accountId, asset.settlementAsset, value, asset.assetSymbol) : withdrawSteps(accountId, value, owner)) : undefined;
  const tooMuch = value !== undefined && (tab === "deposit" ? walletCash !== undefined && value > walletCash : value > a.maxWithdrawable);

  return (
    <>
      {todo.length > 0 && (
        <div className="space-y-2">
          {todo.map((t, i) => (
            <div key={i} className={cx("rounded-xl border px-4 py-3 text-sm", t.tone === "bad" ? "border-bad/40 bg-bad/10" : t.tone === "warn" ? "border-warn/40 bg-warn/10" : "border-primary/40 bg-primary-soft")}>{t.text}</div>
          ))}
        </div>
      )}
      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <Card title={`Account #${accountId} health`}>
          <HealthBar health={a.health} hasPositions={a.positions.length > 0} assetSymbol={asset.assetSymbol} />
          {a.positions.length > 0 && (
            <div className="mt-6 grid grid-cols-2 gap-4 border-t border-line pt-5">
              <Stat
                label={<Term tip="Estimated spot price at which your equity would fall to maintenance margin, holding volatility where it is. An estimate, not a guarantee.">Liquidation if price rises to</Term>}
                value={spots.isLoading ? <Skeleton className="h-6 w-24" /> : spots.data?.up ? fmtWad(spots.data.up, 0) : "—"}
                sub={spots.data?.up && product ? `${(((Number(spots.data.up) / Number(product.spotWad)) - 1) * 100).toFixed(1)}% from now · estimate` : spots.data?.upTo ? `none up to ${fmtWad(spots.data.upTo, 0)}` : "can't estimate now"}
                tone="warn"
              />
              <Stat
                label={<Term tip="Estimated spot price below which your equity would fall to maintenance margin. An estimate.">Liquidation if price falls to</Term>}
                value={spots.isLoading ? <Skeleton className="h-6 w-24" /> : spots.data?.down ? fmtWad(spots.data.down, 0) : "—"}
                sub={spots.data?.down && product ? `${((1 - Number(spots.data.down) / Number(product.spotWad)) * 100).toFixed(1)}% below now · estimate` : spots.data?.downTo ? `none down to ${fmtWad(spots.data.downTo, 0)}` : "can't estimate now"}
                tone="warn"
              />
            </div>
          )}
        </Card>
        <Card title="Collateral">
          <div className="mb-4 grid grid-cols-2 gap-4">
            <Stat label="Cash in account" value={fmtNative(a.cash, asset.assetDecimals)} sub={asset.assetSymbol} />
            <Stat label={<Term tip="How much you can withdraw while keeping equity at or above initial margin.">Withdrawable</Term>} value={fmtNative(a.maxWithdrawable, asset.assetDecimals)} sub={asset.assetSymbol} />
          </div>
          <Segmented value={tab} onChange={(t) => (setTab(t), setAmount(""))} options={[{ value: "deposit", label: "Deposit" }, { value: "withdraw", label: "Withdraw" }]} />
          <div className="mt-4 space-y-4">
            <AmountInput
              label={tab === "deposit" ? "Amount to deposit" : "Amount to withdraw"}
              value={amount}
              onChange={setAmount}
              unit={asset.assetSymbol}
              max={tab === "deposit" ? (walletCash !== undefined ? fmtNative(walletCash, asset.assetDecimals).replace(/,/g, "") : undefined) : fmtNative(a.maxWithdrawable, asset.assetDecimals).replace(/,/g, "")}
              maxLabel={tab === "deposit" ? "Wallet" : "Available"}
              invalid={tooMuch ? (tab === "deposit" ? "More than your wallet holds." : "More than you can withdraw while staying healthy.") : undefined}
            />
            <TxButton label={tab === "deposit" ? "Deposit" : "Withdraw"} steps={steps} disabled={!value || tooMuch} successMessage={tab === "deposit" ? "Deposited" : "Withdrawn to your wallet"} onDone={() => setAmount("")} />
          </div>
        </Card>
      </div>
      <Card title="Positions in this account">
        {a.positions.length === 0 ? (
          <EmptyState title="No positions yet" body="Write an option or move option tokens into this account from a series page." action={<Link to="/" className="btn-ghost">Browse markets</Link>} />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[620px] text-sm">
              <thead>
                <tr className="text-left text-xs text-muted">
                  <th className="pb-2 font-medium">Option</th>
                  <th className="pb-2 font-medium">Side</th>
                  <th className="pb-2 text-right font-medium">Size</th>
                  <th className="pb-2 pr-6 text-right font-medium">Mark value</th>
                  <th className="pb-2 font-medium">Status</th>
                  <th className="pb-2" />
                </tr>
              </thead>
              <tbody>
                {a.positions.map((p) => (
                  <PositionRow key={p.seriesId} s={p.series} balance={p.balance} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </>
  );
}

function PositionRow({ s, balance }: { s: Series; balance: bigint }) {
  const { data: m } = useQuery({ queryKey: ["seriesMarket", s.id], queryFn: () => getSeriesMarket(s), refetchInterval: 10_000 });
  const value = m?.mark !== undefined ? (m.mark * balance) / WAD : undefined;
  return (
    <tr className="border-t border-line">
      <td className="py-3">
        <Link to={`/series/${s.id}`} className="font-medium hover:text-primary">{seriesName(s)}</Link>
      </td>
      <td>
        <Pill tone={balance > 0n ? "good" : "accent"}>{balance > 0n ? "Long" : "Written"}</Pill>
      </td>
      <td className="num text-right">{fmtQty(balance < 0n ? -balance : balance)}</td>
      <td className={cx("num pr-6 text-right", value !== undefined && value < 0n && "text-bad")}>{value !== undefined ? fmtWad(value) : "—"}</td>
      <td>{m && <StatePill state={m.state} />}</td>
      <td className="text-right">
        <Link to={`/series/${s.id}?tab=${m?.state === "REDEEMABLE" ? "redeem" : "manage"}`} className="text-sm font-medium text-primary hover:underline">
          Manage →
        </Link>
      </td>
    </tr>
  );
}

function WalletTokens({ owner }: { owner: Hex }) {
  const { data, isLoading } = useWalletWrappers(owner);
  const states = useQuery({
    queryKey: ["walletStates", data?.map((d) => d.series.id).join()],
    queryFn: async () => Object.fromEntries(await Promise.all((data ?? []).map(async (d) => [d.series.id, await getGroupState(d.series.groupId)] as const))),
    enabled: !!data?.length,
  });
  const rows = useMemo(() => data ?? [], [data]);
  return (
    <Card title="Option tokens in your wallet" action={<span className="text-xs text-muted">Tokens you bought or wrote. They trade on Kuru and redeem at expiry.</span>}>
      {isLoading ? (
        <Skeleton className="h-16 w-full" />
      ) : rows.length === 0 ? (
        <EmptyState icon="◇" title="No option tokens" body="Buy an option on any series page; the tokens arrive here." />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {rows.map(({ series: s, balance }) => {
            const st = states.data?.[s.id];
            return (
              <Link key={s.id} to={`/series/${s.id}?tab=${st === "REDEEMABLE" ? "redeem" : "sell"}`} className="rounded-xl border border-line p-4 transition hover:border-primary hover:bg-primary-soft">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-semibold">{s.underlyingSymbol} {fmtWad(s.strikeWad, 0)} {optionTypeName(s.optionType)}</span>
                  {st && <StatePill state={st} />}
                </div>
                <div className="num mt-2 text-2xl font-bold">{fmtQty(balance)}</div>
                <div className="text-xs text-muted">{st === "REDEEMABLE" ? "Ready to redeem →" : "Sell, hedge or hold →"}</div>
              </Link>
            );
          })}
        </div>
      )}
    </Card>
  );
}

