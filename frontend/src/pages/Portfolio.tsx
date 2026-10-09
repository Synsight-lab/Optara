/** `/portfolio`: accounts, health, collateral, positions, wallet tokens and what needs doing (FRONTEND.md §2, §5). */
import { useMemo, useRef, useState } from "react";
import { Link } from "react-router";
import { useConnection } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import type { Hex } from "viem";
import {
  AlertTriangle,
  ArrowDownRight,
  ArrowUpRight,
  CheckCircle2,
  Clock,
  Coins,
  ExternalLink,
  HelpCircle,
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
import { AmountInput, Card, EmptyState, Pill, Segmented, Skeleton, Stat, Term, cx } from "../components/ui.tsx";
import { TokenIcon } from "../components/Icons.tsx";
import { HealthBar } from "../components/HealthBar.tsx";
import { PnlCard } from "../components/PnlCard.tsx";
import { KuruBalances } from "../components/KuruBalances.tsx";
import { AuctionNotice } from "../components/AuctionNotice.tsx";
import { subAccountsAbi } from "@optara/sdk";
import { ADDR, publicClient } from "../lib/optara/client.ts";
import { TxButton } from "../components/TxButton.tsx";
import { createAccountStep, createdAccountId, depositSteps, setupAccountSteps, withdrawSteps } from "../lib/optara/actions.ts";
import { fmtExpiry, fmtLevel, fmtNative, fmtQty, fmtWad, optionTypeName, parseFixed, seriesName, WAD } from "../lib/optara/format.ts";
import {
  useAccountView,
  useLiquidationSpots,
  useProductMarket,
  useSeriesList,
  useTokenBalance,
  useWalletWrappers,
} from "../lib/optara/hooks.ts";
import { getGroupState, getSeriesMarket } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState, useQuickGuide } from "../state.tsx";
import { StatePill } from "./Series.tsx";

export function PortfolioPage() {
  const { address, isConnected } = useConnection();
  const { accounts, selected, select, loading, refresh } = useAccountState();
  const { data: series } = useSeriesList();
  const asset = series?.[0];
  const { open: openGuide } = useQuickGuide();

  if (!isConnected) {
    return (
      <div className="w-full py-12">
        <Card className="text-center p-8">
          <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-3xl bg-primary-soft text-primary mb-4">
            <Wallet className="h-8 w-8" />
          </div>
          <h2 className="text-2xl font-bold tracking-tight">Connect Your Wallet</h2>
          <p className="mt-2 text-sm text-muted max-w-sm mx-auto">
            Connect a wallet to view your active options, margin health, collateral balances, and wallet tokens.
          </p>
          <div className="mt-6 flex justify-center">
            <button onClick={openGuide} className="text-xs text-primary hover:underline flex items-center gap-1">
              <HelpCircle className="h-3.5 w-3.5" /> Learn how Optara portfolio accounts work
            </button>
          </div>
        </Card>
      </div>
    );
  }

  if (loading || !asset) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-24 w-full rounded-3xl" />
        <Skeleton className="h-72 w-full rounded-3xl" />
      </div>
    );
  }

  return (
    <div className="space-y-4 sm:space-y-5">
      <div className="flex flex-wrap items-end justify-between gap-3 px-1">
        <div>
          <h1 className="font-display text-2xl font-bold tracking-tight sm:text-[28px]">Portfolio</h1>
          <p className="mt-0.5 text-[13px] text-muted">
            Margin health, collateral and open contracts in one place.
          </p>
        </div>

        {/* Account switcher */}
        <div className="flex flex-wrap items-center gap-2">
          {accounts.length > 0 && (
            <Segmented
              value={(selected ?? accounts[0]!).toString()}
              onChange={(v) => select(BigInt(v))}
              options={accounts.map((a) => ({ value: a.toString(), label: `Account #${a}` }))}
            />
          )}
          {accounts.length > 0 && (
            <NewAccountButton
              asset={asset}
              onCreated={async (id) => {
                await refresh();
                select(id);
              }}
            />
          )}
        </div>
      </div>

      <PnlCard owner={address!} accounts={accounts} series={series ?? []} />

      {/* Main Account View or Onboarding */}
      {accounts.length === 0 ? (
        <Onboarding asset={asset} />
      ) : (
        selected !== undefined && <AccountDashboard accountId={selected} asset={asset} owner={address!} />
      )}

      {/* Option Tokens in User's Wallet */}
      <WalletTokens owner={address!} />

      <KuruBalances owner={address!} series={series ?? []} />
    </div>
  );
}

function NewAccountButton({ asset, onCreated }: { asset: Series; onCreated: (id: bigint) => void }) {
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <button className="btn-ghost text-xs" onClick={() => setOpen(true)}>
        <Plus className="h-3.5 w-3.5" /> New account
      </button>
    );
  }
  return (
    <div className="w-full sm:w-64">
      <TxButton
        label="Create Another Account"
        steps={[createAccountStep(asset.settlementAsset)]}
        successMessage="New account created!"
        onDone={(r) => {
          const id = createdAccountId(r[0]!);
          setOpen(false);
          if (id !== undefined) onCreated(id);
        }}
      />
    </div>
  );
}

// ------------------------------------------------------------------ Onboarding for First-Time Users
function Onboarding({ asset }: { asset: Series }) {
  const { refresh, select } = useAccountState();
  const { address } = useConnection();
  const { data: balance } = useTokenBalance(asset.settlementAsset, address);
  const [amount, setAmount] = useState("1000");
  const deposit = parseFixed(amount, asset.assetDecimals);
  const created = useRef<bigint | undefined>(undefined);

  const steps = useMemo(
    () => (deposit ? setupAccountSteps(asset.settlementAsset, deposit, asset.assetSymbol, (id) => (created.current = id)) : undefined),
    [deposit, asset]
  );

  return (
    <div className="flex flex-col gap-3">
      <Card title="Open your margin account">
        <p className="mb-4 text-xs sm:text-sm text-muted leading-relaxed">
          <b className="text-ink">Buying options</b> requires zero account setup — tokens go straight to your wallet.
          To <b className="text-ink">write options and earn yield</b>, you maintain {asset.assetSymbol} collateral in an Optara margin account.
        </p>

        <div className="space-y-4">
          <AmountInput
            label="First deposit"
            value={amount}
            onChange={setAmount}
            unit={asset.assetSymbol}
            presets={["500", "1000", "2500", "5000"]}
            max={balance !== undefined ? fmtNative(balance, asset.assetDecimals).replace(/,/g, "") : undefined}
            maxLabel="Wallet"
          />

          <TxButton
            label="Create account & deposit"
            summary={deposit ? `New account, then ${fmtNative(deposit, asset.assetDecimals)} ${asset.assetSymbol} from your wallet into it` : undefined}
            steps={steps}
            disabled={!deposit}
            successMessage="Your margin account is ready."
            onDone={async () => {
              await refresh();
              if (created.current !== undefined) select(created.current);
            }}
          />
        </div>
      </Card>

      <Card title="Why margin?">
        <ul className="space-y-3.5 text-xs sm:text-sm">
          {[
            [
              "Less cash locked up",
              "The cash you need is worked out by stress-testing big price and volatility moves, not by locking the full worst case."
            ],
            [
              "Hedges count",
              "Options you own and options you wrote on the same asset offset each other, so a hedged account needs less."
            ],
            [
              "Premium is paid to you now",
              "When you write and sell, the premium goes to your wallet. Only cash inside the account protects it, so add some back if you like."
            ],
          ].map(([t, b]) => (
            <li key={t} className="flex gap-3">
              <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-primary" />
              <div>
                <span className="block font-semibold text-ink">{t}</span>
                <span className="block text-muted text-xs leading-relaxed mt-0.5">{b}</span>
              </div>
            </li>
          ))}
        </ul>

        <Link to="/app/markets" className="btn-ghost mt-6 w-full text-xs">
          Browse markets
        </Link>
      </Card>
    </div>
  );
}

// ------------------------------------------------------------------ Account Dashboard
function AccountDashboard({ accountId, asset, owner }: { accountId: bigint; asset: Series; owner: Hex }) {
  const { data: a, isLoading } = useAccountView(accountId);
  const { data: walletCash } = useTokenBalance(asset.settlementAsset, owner);
  const { data: product } = useProductMarket(a?.positions[0]?.series.productId ?? asset.productId);
  const spots = useLiquidationSpots(accountId, product?.productId, product?.spotWad, !!a && a.positions.length > 0);

  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const { data: allSeries } = useSeriesList();
  const { data: buckets } = useQuery({
    queryKey: ["buckets", accountId.toString()],
    queryFn: () => publicClient.readContract({ address: ADDR.ledger, abi: subAccountsAbi, functionName: "bucketsOf", args: [accountId] }),
    refetchInterval: 15_000,
  });
  const symbolOf = (u: string) => allSeries?.find((s) => s.underlying.toLowerCase() === u.toLowerCase())?.underlyingSymbol ?? "these";
  const [amount, setAmount] = useState("");
  const value = parseFixed(amount, asset.assetDecimals);

  if (isLoading || !a) return <Card><Skeleton className="h-56 w-full" /></Card>;

  // Urgent alerts & actionable to-dos
  const todo: { tone: "warn" | "bad" | "primary"; text: React.ReactNode }[] = [];
  if (a.health.state === "LIQUIDATABLE" || a.health.state === "INSOLVENT") {
    todo.push({
      tone: "bad",
      text: "Your account value is below the liquidation line. Add cash or close positions now, or part of your positions can be taken over at a discount.",
    });
  } else if (a.health.state === "CLOSE_ONLY") {
    todo.push({
      tone: "warn",
      text: "Close-only: your account value is below what's needed to open positions. You can still close. Add cash to write again.",
    });
  }

  if (walletCash && walletCash > 0n && a.positions.some((p) => p.balance < 0n)) {
    todo.push({
      tone: "primary",
      text: (
        <>
          Your wallet holds {fmtNative(walletCash, asset.assetDecimals)} {asset.assetSymbol}. Cash in your wallet doesn't
          protect this account; add some below if you want a bigger safety margin.
        </>
      ),
    });
  }

  const steps = value
    ? tab === "deposit"
      ? depositSteps(accountId, asset.settlementAsset, value, asset.assetSymbol)
      : withdrawSteps(accountId, value, owner)
    : undefined;

  const tooMuch =
    value !== undefined && (tab === "deposit" ? walletCash !== undefined && value > walletCash : value > a.maxWithdrawable);

  return (
    <>
      {(buckets ?? []).map((u) => (
        <AuctionNotice key={u} accountId={accountId} underlying={u} symbol={symbolOf(u)} mine />
      ))}

      {todo.length > 0 && (
        <div className="space-y-2">
          {todo.map((t, i) => (
            <div
              key={i}
              className={cx(
                "rounded-2xl border px-4 py-2.5 text-[13px] font-medium",
                t.tone === "bad"
                  ? "border-bad/30 bg-bad/10 text-bad"
                  : t.tone === "warn"
                  ? "border-warn/30 bg-warn/10 text-warn"
                  : "border-primary/30 bg-primary-soft text-ink"
              )}
            >
              {t.text}
            </div>
          ))}
        </div>
      )}

      <div className="flex flex-col gap-3">
        <Card
          title={`Account #${accountId.toString()}`}
        >
          <HealthBar health={a.health} hasPositions={a.positions.length > 0} assetSymbol={asset.assetSymbol} />

          {a.positions.length > 0 && (
            <div className="mt-5 border-t border-line pt-4">
              <div className="mb-2.5 text-[13px] font-semibold">
                Prices where this account would be liquidated
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
                  <Stat
                    label={<Term tip="Estimated price at which your account value would fall to the liquidation line, if nothing else changed.">If the price rises to</Term>}
                    value={spots.isLoading ? <Skeleton className="h-6 w-20" /> : spots.data?.up ? `$${fmtLevel(spots.data.up)}` : spots.data?.upTo ? `Above $${fmtLevel(spots.data.upTo)}` : "Never"}
                    sub={
                      spots.data?.up && product
                        ? `${(((Number(spots.data.up) / Number(product.spotWad)) - 1) * 100).toFixed(1)}% above today`
                        : spots.data?.upTo
                        ? "Not reached in the range checked"
                        : "Rising prices don't threaten this account"
                    }
                    tone="warn"
                  />
                </div>

                <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
                  <Stat
                    label={<Term tip="Estimated price at which your account value would fall to the liquidation line, if nothing else changed.">If the price falls to</Term>}
                    value={spots.isLoading ? <Skeleton className="h-6 w-20" /> : spots.data?.down ? `$${fmtLevel(spots.data.down)}` : spots.data?.downTo ? `Below $${fmtLevel(spots.data.downTo)}` : "Never"}
                    sub={
                      spots.data?.down && product
                        ? `${((1 - Number(spots.data.down) / Number(product.spotWad)) * 100).toFixed(1)}% below today`
                        : spots.data?.downTo
                        ? "Not reached in the range checked"
                        : "Falling prices don't threaten this account"
                    }
                    tone="warn"
                  />
                </div>
              </div>
            </div>
          )}
        </Card>

        {/* Collateral Manager (Deposit / Withdraw) */}
        <Card title={<span id="cash-card">Margin account cash</span>}>
          <div className="mb-3 rounded-2xl border border-primary/25 bg-primary-soft/40 p-3 text-[13px] leading-relaxed">
            <b>This cash is collateral for writing options.</b>{" "}
            <span className="text-muted">
              It backs the options you write, pays writing fees, and pays what you owe at expiry. Buying options doesn't use it:
              buys are paid straight from your wallet. Anything not needed for your positions can be withdrawn any time.
            </span>
          </div>
          <div className="mb-4 grid grid-cols-3 gap-3 rounded-2xl bg-surface-2/60 p-3 border border-line">
            <Stat
              label={<Term tip="Cash in your wallet. Adding cash moves it from here into the account; withdrawing moves it back.">In your wallet</Term>}
              value={walletCash !== undefined ? fmtNative(walletCash, asset.assetDecimals) : "…"}
              sub={asset.assetSymbol}
            />
            <Stat
              label="In account"
              value={fmtNative(a.cash, asset.assetDecimals)}
              sub={asset.assetSymbol}
            />
            <Stat
              label={<Term tip="The most you can take out while keeping enough to cover your open positions.">You can withdraw</Term>}
              value={fmtNative(a.maxWithdrawable, asset.assetDecimals)}
              sub={asset.assetSymbol}
            />
          </div>

          <Segmented
            value={tab}
            onChange={(t) => {
              setTab(t);
              setAmount("");
            }}
            options={[
              { value: "deposit", label: "Add" },
              { value: "withdraw", label: "Withdraw" },
            ]}
          />

          <div className="mt-4 space-y-4">
            <AmountInput
              label={tab === "deposit" ? "Deposit to account" : "Withdraw to wallet"}
              value={amount}
              onChange={setAmount}
              unit={asset.assetSymbol}
              max={
                tab === "deposit"
                  ? walletCash !== undefined
                    ? fmtNative(walletCash, asset.assetDecimals).replace(/,/g, "")
                    : undefined
                  : fmtNative(a.maxWithdrawable, asset.assetDecimals).replace(/,/g, "")
              }
              maxLabel={tab === "deposit" ? "Wallet" : "Available"}
              invalid={
                tooMuch
                  ? tab === "deposit"
                    ? "Amount exceeds wallet balance."
                    : "Exceeds max safe withdrawal."
                  : undefined
              }
            />

            <TxButton
              label={tab === "deposit" ? "Deposit Collateral" : "Withdraw to Wallet"}
              summary={
                value
                  ? tab === "deposit"
                    ? `${fmtNative(value, asset.assetDecimals)} ${asset.assetSymbol} from your wallet into account #${accountId}`
                    : `${fmtNative(value, asset.assetDecimals)} ${asset.assetSymbol} from account #${accountId} to your wallet`
                  : undefined
              }
              steps={steps}
              disabled={!value || tooMuch}
              successMessage={tab === "deposit" ? "Deposited." : "Withdrawn to your wallet."}
              onDone={() => setAmount("")}
            />
          </div>
        </Card>
      </div>

      {/* Positions in this Account */}
      <Card
        title={`Positions · ${a.positions.length}`}
      >
        {a.positions.length === 0 ? (
          <EmptyState
            title="No open positions"
            body="Write options or move tokens in from any series page. Finished trades stay listed under Profit & loss above."
            action={
              <Link to="/app/markets" className="btn-ghost mt-2 text-xs">
                Browse markets
              </Link>
            }
          />
        ) : (
          <ul className="divide-y divide-line/60">
            {a.positions.map((p) => (
              <PositionRow key={p.seriesId} s={p.series} balance={p.balance} />
            ))}
          </ul>
        )}
      </Card>
    </>
  );
}

function PositionRow({ s, balance }: { s: Series; balance: bigint }) {
  const { data: m } = useQuery({
    queryKey: ["seriesMarket", s.id],
    queryFn: () => getSeriesMarket(s),
    refetchInterval: 10_000,
  });
  const value = m?.mark !== undefined ? (m.mark * balance) / WAD : undefined;

  return (
    <li>
      <Link
        to={`/app/series/${s.id}?tab=${m?.state === "REDEEMABLE" ? "redeem" : "manage"}`}
        className="flex min-h-[68px] items-center gap-2.5 rounded-2xl px-2 py-2.5 transition hover:bg-primary-soft/50"
      >
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-bold">{seriesName(s)}</span>
          <span className="mt-0.5 flex items-center gap-1.5 text-xs text-muted">
            <Pill tone={balance > 0n ? "good" : "accent"}>{balance > 0n ? "Owned" : "Written"}</Pill>
            <span className="num">{fmtQty(balance < 0n ? -balance : balance)}</span>
            {m && <StatePill state={m.state} />}
          </span>
        </span>
        <span className="shrink-0 text-right">
          <span className={cx("num block text-sm font-bold", value !== undefined && value < 0n ? "text-bad" : "text-good")}>
            {value !== undefined ? (value < 0n ? `−$${fmtWad(-value)}` : `$${fmtWad(value)}`) : "—"}
          </span>
          <span className="block text-[11px] text-muted">{balance > 0n ? "worth today" : "owed at today's value"}</span>
        </span>
      </Link>
    </li>
  );
}

// ------------------------------------------------------------------ Wallet Tokens
function WalletTokens({ owner }: { owner: Hex }) {
  const { data, isLoading } = useWalletWrappers(owner);
  const states = useQuery({
    queryKey: ["walletStates", data?.map((d) => d.series.id).join()],
    queryFn: async () =>
      Object.fromEntries(
        await Promise.all((data ?? []).map(async (d) => [d.series.id, await getGroupState(d.series.groupId)] as const))
      ),
    enabled: !!data?.length,
  });

  const rows = useMemo(() => data ?? [], [data]);

  return (
    <Card
      title="Options in your wallet"
      action={<span className="text-xs text-muted">Options you bought. Sell them any time, or redeem them for cash after expiry.</span>}
    >
      {isLoading ? (
        <Skeleton className="h-20 w-full" />
      ) : rows.length === 0 ? (
        <EmptyState
          icon="◇"
          title="No option tokens in wallet"
          body="Options you buy land here until you sell or redeem them. Finished trades stay listed under Profit & loss above."
          action={
            <Link to="/app/markets" className="btn-ghost mt-2 text-xs">
              Explore Markets
            </Link>
          }
        />
      ) : (
        <div className="grid gap-2.5">
          {rows.map(({ series: s, balance }) => {
            const st = states.data?.[s.id];
            const isRedeemable = st === "REDEEMABLE";

            return (
              <Link
                key={s.id}
                to={`/app/series/${s.id}?tab=${isRedeemable ? "redeem" : "trade"}`}
                className={cx(
                  "rounded-2xl border p-4 transition-all hover:shadow-lg active:scale-[0.98]",
                  isRedeemable
                    ? "border-good/50 bg-good/5 hover:border-good"
                    : "border-line bg-surface-2/60 hover:border-primary/40 hover:bg-surface-2"
                )}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-bold text-ink">
                    {s.underlyingSymbol} ${fmtLevel(s.strikeWad)} {optionTypeName(s.optionType)}
                  </span>
                  {st && <StatePill state={st} />}
                </div>

                <div className="num mt-2 text-2xl font-black text-ink">{fmtQty(balance)} tokens</div>

                <div className="mt-2 flex items-center justify-between text-xs font-semibold">
                  <span className="text-muted">Expiry: {fmtExpiry(s.expiry)}</span>
                  <span className={isRedeemable ? "text-good" : "text-primary"}>
                    {isRedeemable ? "Redeem →" : "Trade →"}
                  </span>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </Card>
  );
}
