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
import { TxButton } from "../components/TxButton.tsx";
import { createAccountStep, createdAccountId, depositSteps, setupAccountSteps, withdrawSteps } from "../lib/optara/actions.ts";
import { fmtExpiry, fmtNative, fmtQty, fmtWad, optionTypeName, parseFixed, seriesName, WAD } from "../lib/optara/format.ts";
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

      {/* Main Account View or Onboarding */}
      {accounts.length === 0 ? (
        <Onboarding asset={asset} />
      ) : (
        selected !== undefined && <AccountDashboard accountId={selected} asset={asset} owner={address!} />
      )}

      {/* Option Tokens in User's Wallet */}
      <WalletTokens owner={address!} />
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
              "Capital Efficiency",
              "Collateral is sized from realistic market scenarios, not the full worst case.",
            ],
            [
              "Risk Offsetting",
              "Longs and shorts on the same asset offset each other, lowering what you must lock up.",
            ],
            [
              "Instant Cash Premiums",
              "Premiums land in your wallet. Re-deposit them to strengthen margin.",
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

        <Link to="/" className="btn-ghost mt-6 w-full text-xs">
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
  const [amount, setAmount] = useState("");
  const value = parseFixed(amount, asset.assetDecimals);

  if (isLoading || !a) return <Card><Skeleton className="h-56 w-full" /></Card>;

  // Urgent alerts & actionable to-dos
  const todo: { tone: "warn" | "bad" | "primary"; text: React.ReactNode }[] = [];
  if (a.health.state === "LIQUIDATABLE" || a.health.state === "INSOLVENT") {
    todo.push({
      tone: "bad",
      text: "Account is below its liquidation threshold. Deposit collateral or close positions to avoid liquidation.",
    });
  } else if (a.health.state === "CLOSE_ONLY") {
    todo.push({
      tone: "warn",
      text: "Close-only: below required margin. Deposit collateral or reduce risk to open new positions.",
    });
  }

  if (walletCash && walletCash > 0n && a.positions.some((p) => p.balance < 0n)) {
    todo.push({
      tone: "primary",
      text: (
        <>
          You have {fmtNative(walletCash, asset.assetDecimals)} {asset.assetSymbol} in your wallet from option premiums.
          Deposit it below to strengthen your margin buffer!
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
                Liquidation estimates
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
                  <Stat
                    label={<Term tip="Estimated spot price at which equity falls to maintenance margin.">If Price Climbs To</Term>}
                    value={spots.isLoading ? <Skeleton className="h-6 w-20" /> : spots.data?.up ? `$${fmtWad(spots.data.up, 0)}` : "—"}
                    sub={
                      spots.data?.up && product
                        ? `+${(((Number(spots.data.up) / Number(product.spotWad)) - 1) * 100).toFixed(1)}% above current`
                        : spots.data?.upTo
                        ? `Safe up to $${fmtWad(spots.data.upTo, 0)}`
                        : "No upward risk"
                    }
                    tone="warn"
                  />
                </div>

                <div className="rounded-2xl border border-line bg-surface-2/60 p-3.5">
                  <Stat
                    label={<Term tip="Estimated spot price below which equity falls to maintenance margin.">If Price Drops To</Term>}
                    value={spots.isLoading ? <Skeleton className="h-6 w-20" /> : spots.data?.down ? `$${fmtWad(spots.data.down, 0)}` : "—"}
                    sub={
                      spots.data?.down && product
                        ? `-${((1 - Number(spots.data.down) / Number(product.spotWad)) * 100).toFixed(1)}% below current`
                        : spots.data?.downTo
                        ? `Safe down to $${fmtWad(spots.data.downTo, 0)}`
                        : "No downward risk"
                    }
                    tone="warn"
                  />
                </div>
              </div>
            </div>
          )}
        </Card>

        {/* Collateral Manager (Deposit / Withdraw) */}
        <Card title="Cash">
          <div className="mb-4 grid grid-cols-2 gap-3 rounded-2xl bg-surface-2/60 p-3 border border-line">
            <Stat
              label="In account"
              value={`$${fmtNative(a.cash, asset.assetDecimals)}`}
              sub={asset.assetSymbol}
            />
            <Stat
              label={<Term tip="Available to withdraw without breaching initial margin.">Safe To Withdraw</Term>}
              value={`$${fmtNative(a.maxWithdrawable, asset.assetDecimals)}`}
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
            body="Write options or move tokens in from any series page."
            action={
              <Link to="/" className="btn-ghost mt-2 text-xs">
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
        to={`/series/${s.id}?tab=${m?.state === "REDEEMABLE" ? "redeem" : "manage"}`}
        className="flex min-h-[68px] items-center gap-2.5 rounded-2xl px-2 py-2.5 transition hover:bg-primary-soft/50"
      >
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-bold">{seriesName(s)}</span>
          <span className="mt-0.5 flex items-center gap-1.5 text-xs text-muted">
            <Pill tone={balance > 0n ? "good" : "accent"}>{balance > 0n ? "Long" : "Written"}</Pill>
            <span className="num">{fmtQty(balance < 0n ? -balance : balance)}</span>
            {m && <StatePill state={m.state} />}
          </span>
        </span>
        <span className={cx("num shrink-0 text-sm font-bold", value !== undefined && value < 0n ? "text-bad" : "text-good")}>
          {value !== undefined ? (value < 0n ? `−$${fmtWad(-value)}` : `+$${fmtWad(value)}`) : "—"}
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
      title="Option Tokens in Your Wallet"
      action={<span className="text-xs text-muted">ERC-20 option tokens held in your wallet. Tradeable elsewhere.</span>}
    >
      {isLoading ? (
        <Skeleton className="h-20 w-full" />
      ) : rows.length === 0 ? (
        <EmptyState
          icon="◇"
          title="No option tokens in wallet"
          body="Options bought on any series page are held directly in your wallet."
          action={
            <Link to="/" className="btn-ghost mt-2 text-xs">
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
                to={`/series/${s.id}?tab=${isRedeemable ? "redeem" : "trade"}`}
                className={cx(
                  "rounded-2xl border p-4 transition-all hover:shadow-lg active:scale-[0.98]",
                  isRedeemable
                    ? "border-good/50 bg-good/5 hover:border-good"
                    : "border-line bg-surface-2/60 hover:border-primary/40 hover:bg-surface-2"
                )}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-bold text-ink">
                    {s.underlyingSymbol} ${fmtWad(s.strikeWad, 0)} {optionTypeName(s.optionType)}
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
