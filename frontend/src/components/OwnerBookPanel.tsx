/**
 * "Your order book": shown only to the owner of an option's Optara Direct book. A Direct book sells options it HOLDS
 * at the owner's ask and buys with quote it HOLDS at the owner's bid, so a freshly created book is empty and
 * unbuyable until its owner stocks it and sets prices. This panel does exactly that, plus withdrawals.
 */
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { useQuery } from "@tanstack/react-query";
import { useConnection } from "wagmi";
import { erc20Abi, type Address } from "viem";
import { venueRegistryAbi } from "@optara/sdk";
import { Store } from "lucide-react";
import { callStep, mintSteps, type Step } from "../lib/optara/actions.ts";
import { ADDR, DIRECT_VENUE, publicClient as c } from "../lib/optara/client.ts";
import { optaraDirectMarketAbi } from "../lib/optara/directMarket.ts";
import { fmtNative, fmtPrice, fmtQty, parseFixed, parseQty } from "../lib/optara/format.ts";
import { useSeriesMarket } from "../lib/optara/hooks.ts";
import { withSlip, useSlippage } from "../lib/optara/limits.ts";
import { previewMint } from "../lib/optara/reads.ts";
import type { Series } from "../lib/optara/types.ts";
import { useAccountState } from "../state.tsx";
import { TxButton } from "./TxButton.tsx";
import { AmountInput, Card, Pill, Row, Segmented, Skeleton } from "./ui.tsx";

type Tab = "stock" | "ask" | "bid" | "withdraw";
const WAD = 10n ** 18n;

async function readBook(s: Series, owner?: Address) {
  // tradableMarket returns (adapter, market) and reverts when the option has no tradable Direct market
  const market = await c
    .readContract({ address: ADDR.venues, abi: venueRegistryAbi, functionName: "tradableMarket", args: [DIRECT_VENUE, s.id] })
    .then(([, m]) => m as Address, () => undefined);
  if (!market) return undefined;
  const read = <T,>(functionName: string) => c.readContract({ address: market, abi: optaraDirectMarketAbi, functionName } as never) as Promise<T>;
  const [bookOwner, askPrice, askSize, bidPrice, bidSize, pricePrecision, sizePrecision, inventory, funding] = await Promise.all([
    read<Address>("owner"),
    read<bigint>("askPrice"),
    read<bigint>("askSize"),
    read<bigint>("bidPrice"),
    read<bigint>("bidSize"),
    read<bigint>("pricePrecision"),
    read<bigint>("sizePrecision"),
    c.readContract({ address: s.wrapper, abi: erc20Abi, functionName: "balanceOf", args: [market] }),
    c.readContract({ address: s.settlementAsset, abi: erc20Abi, functionName: "balanceOf", args: [market] }),
  ]);
  // Books created before `withdraw` existed can't give anything back: detect it by simulating a zero withdrawal.
  let canWithdraw = false;
  if (owner && owner.toLowerCase() === bookOwner.toLowerCase()) {
    canWithdraw = await c
      .simulateContract({ account: owner, address: market, abi: optaraDirectMarketAbi, functionName: "withdraw", args: [s.settlementAsset, 0n, owner] } as never)
      .then(() => true, () => false);
  }
  return { market, owner: bookOwner, askPrice, askSize, bidPrice, bidSize, pricePrecision, sizePrecision, inventory, funding, canWithdraw };
}

export function OwnerBookPanel({ series: s }: { series: Series }) {
  const { address } = useConnection();
  const { data: book, refetch } = useQuery({ queryKey: ["directBook", s.id, address], queryFn: () => readBook(s, address), refetchInterval: 10_000 });
  if (!book || !address || book.owner.toLowerCase() !== address.toLowerCase()) return null;
  return <Panel s={s} book={book} owner={address} onDone={() => void refetch()} />;
}

function Panel({ s, book, owner, onDone }: { s: Series; book: NonNullable<Awaited<ReturnType<typeof readBook>>>; owner: Address; onDone(): void }) {
  const { data: m } = useSeriesMarket(s);
  const { selected } = useAccountState();
  const [slip] = useSlippage();
  const [tab, setTab] = useState<Tab>(book.inventory === 0n ? "stock" : "ask");
  const dec = s.assetDecimals;
  const asset = s.assetSymbol;
  // book units ↔ human: price units are pricePrecision per 1 quote token; size units are sizePrecision per option
  const priceOf = (units: bigint) => (units * WAD) / book.pricePrecision; // WAD per option
  const qtyOf = (units: bigint) => (units * WAD) / book.sizePrecision; // WAD options
  const toUnits = (wadPrice: bigint) => (wadPrice * book.pricePrecision + WAD / 2n) / WAD;
  const toSize = (wadQty: bigint) => (wadQty * book.sizePrecision) / WAD;
  const tick = WAD / book.pricePrecision;
  const askQty = qtyOf(book.askSize);
  const bidQty = qtyOf(book.bidSize);
  const overAsk = askQty > book.inventory;
  const fair = m?.mark;
  // A suggested price: fair value ± a spread, on the book's price grid and never below one step (deep
  // out-of-the-money options can have a fair value of ~0).
  const suggest = (bps: bigint) => {
    if (fair === undefined) return "";
    const p = ((fair * bps) / 10_000n / tick) * tick;
    return fmtPrice(p > tick ? p : tick, 6).replace(/,/g, "");
  };

  // form state
  const [stockQty, setStockQty] = useState("");
  const [stockFrom, setStockFrom] = useState<"write" | "wallet">("write");
  const [askP, setAskP] = useState(book.askPrice ? fmtPrice(priceOf(book.askPrice)).replace(/,/g, "") : suggest(10_500n));
  const [askQ, setAskQ] = useState(book.askSize ? fmtQty(askQty) : fmtQty(book.inventory));
  const [bidP, setBidP] = useState(book.bidPrice ? fmtPrice(priceOf(book.bidPrice)).replace(/,/g, "") : suggest(9_500n));
  const [bidQ, setBidQ] = useState(book.bidSize ? fmtQty(bidQty) : "1");
  const [wOpt, setWOpt] = useState("");
  const [wCash, setWCash] = useState("");
  // Defaults follow the data (fair value, what the book holds) until the owner types something.
  const [touched, setTouched] = useState<Record<string, boolean>>({});
  const edit = (k: string, set: (v: string) => void) => (v: string) => (setTouched((t) => ({ ...t, [k]: true })), set(v));
  useEffect(() => {
    if (!touched.askP && !book.askPrice) setAskP(suggest(10_500n));
    if (!touched.bidP && !book.bidPrice) setBidP(suggest(9_500n));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fair, tick]);
  useEffect(() => {
    if (!touched.askQ) setAskQ(fmtQty(book.inventory));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.inventory]);

  const write = <F extends string>(key: string, label: string, functionName: F, args: readonly unknown[], hint?: string): Step =>
    callStep(key, label, { address: book.market, abi: optaraDirectMarketAbi as never, functionName: functionName as never, args: args as never }, hint);

  // --- stock
  const sq = parseQty(stockQty);
  const { data: mintFee } = useQuery({
    queryKey: ["previewMint", selected?.toString(), s.id, sq?.toString()],
    queryFn: () => previewMint(selected!, s.id, sq!),
    enabled: stockFrom === "write" && selected !== undefined && !!sq,
  });
  const stockSteps: Step[] | undefined = !sq
    ? undefined
    : stockFrom === "wallet"
      ? [callStep("stock-move", "Move options into the book", { address: s.wrapper, abi: erc20Abi, functionName: "transfer", args: [book.market, sq] })]
      : selected !== undefined && mintFee
        ? mintSteps(selected, s, sq, withSlip(mintFee[0], slip), book.market)
        : undefined;

  // --- ask
  const ap = parseFixed(askP, 18);
  const aq = parseQty(askQ);
  const askTooBig = aq !== undefined && aq > book.inventory;
  const askSteps = ap !== undefined && aq !== undefined && !askTooBig ? [write("set-ask", "Set the ask", "setAsk", [toUnits(ap), toSize(aq)])] : undefined;

  // --- bid
  const bp = parseFixed(bidP, 18);
  const bq = parseQty(bidQ);
  const bidNeeds = bp !== undefined && bq !== undefined ? ((bp * bq) / WAD / 10n ** BigInt(18 - dec)) + 1n : undefined;
  const shortfall = bidNeeds !== undefined && bidNeeds > book.funding ? bidNeeds - book.funding : 0n;
  const bidSteps =
    bp !== undefined && bq !== undefined
      ? [
          ...(shortfall > 0n ? [callStep("fund-bid", `Send ${asset} for the bid`, { address: s.settlementAsset, abi: erc20Abi, functionName: "transfer", args: [book.market, shortfall] })] : []),
          write("set-bid", "Set the bid", "setBid", [toUnits(bp), toSize(bq)]),
        ]
      : undefined;

  // --- withdraw
  const wo = parseQty(wOpt);
  const wc = parseFixed(wCash, dec);
  const withdrawSteps = [
    ...(wo ? [write("withdraw-opt", "Take options back", "withdraw", [s.wrapper, wo, owner])] : []),
    ...(wo && wo > book.inventory - qtyOf(book.askSize) && book.askSize > 0n
      ? [write("lower-ask", "Lower the ask to what's left", "setAsk", [book.askPrice, toSize(book.inventory - wo > 0n ? book.inventory - wo : 0n)])]
      : []),
    ...(wc ? [write("withdraw-cash", `Take ${asset} back`, "withdraw", [s.settlementAsset, wc, owner])] : []),
  ];

  const status =
    book.askSize === 0n || book.inventory === 0n
      ? { tone: "bad" as const, text: book.inventory === 0n ? "Not buyable: the book holds no options. Stock it first." : "Not buyable: no ask is set." }
      : overAsk
        ? { tone: "warn" as const, text: "The ask is larger than what the book holds: big buys will fail. Lower the ask or add options." }
        : { tone: "good" as const, text: "Buyable: buyers can take your ask." };

  return (
    <Card
      title={
        <span className="flex items-center gap-2">
          <Store className="h-4 w-4 text-primary" /> Your order book
          <Pill tone={status.tone}>{status.tone === "good" ? "Live" : "Needs setup"}</Pill>
        </span>
      }
    >
      <p className="text-[13px] leading-relaxed text-muted">
        You own this option's Optara Direct book. It sells only options it <b className="text-ink">holds</b>, at the ask you set, and buys with{" "}
        {asset} it <b className="text-ink">holds</b>, at your bid.
      </p>

      <div className="mt-3 grid grid-cols-2 gap-2 text-[13px] sm:grid-cols-4">
        <Fact label="Ask" value={book.askSize ? `${fmtPrice(priceOf(book.askPrice))} × ${fmtQty(askQty)}` : "not set"} />
        <Fact label="Options held" value={fmtQty(book.inventory)} />
        <Fact label="Bid" value={book.bidSize ? `${fmtPrice(priceOf(book.bidPrice))} × ${fmtQty(bidQty)}` : "not set"} />
        <Fact label={`${asset} held`} value={fmtNative(book.funding, dec)} />
      </div>
      <p className={status.tone === "good" ? "mt-2 text-[13px] font-semibold text-good" : status.tone === "warn" ? "mt-2 text-[13px] font-semibold text-warn" : "mt-2 text-[13px] font-semibold text-bad"}>
        {status.text}
      </p>

      <div className="mt-3">
        <Segmented
          value={tab}
          onChange={setTab}
          options={[
            { value: "stock", label: "1 · Stock" },
            { value: "ask", label: "2 · Ask" },
            { value: "bid", label: "Bid" },
            { value: "withdraw", label: "Withdraw" },
          ]}
        />
      </div>

      <div className="mt-3 space-y-3">
        {tab === "stock" && (
          <>
            <Segmented
              size="sm"
              value={stockFrom}
              onChange={setStockFrom}
              options={[
                { value: "write", label: "Write new options into it" },
                { value: "wallet", label: "Move from my wallet" },
              ]}
            />
            <AmountInput label="Options" value={stockQty} onChange={setStockQty} unit="options" presets={["1", "10", "100"]} />
            {stockFrom === "write" && selected === undefined && (
              <p className="text-xs text-warn">
                Writing needs a margin account with collateral.{" "}
                <Link to="/app/portfolio" className="font-semibold text-primary underline">
                  Open one on Portfolio
                </Link>
                , or move options you already hold from your wallet.
              </p>
            )}
            {stockFrom === "write" && mintFee && !mintFee[3] && <p className="text-xs text-bad">Not enough margin to write that many. Add collateral or lower the amount.</p>}
            {stockFrom === "write" && mintFee && <Row label="Writing fee (from your account)" value={`${fmtNative(mintFee[0], dec)} ${asset}`} />}
            <TxButton
              label={stockFrom === "write" ? "Write into the book" : "Move into the book"}
              steps={stockFrom === "write" && mintFee && !mintFee[3] ? undefined : stockSteps}
              disabled={!stockSteps || (stockFrom === "write" && !!mintFee && !mintFee[3])}
              summary={sq ? `${fmtQty(sq)} options into your order book` : undefined}
              successMessage="The book now holds those options. Set your ask next."
              onDone={() => (onDone(), setTab("ask"))}
            />
          </>
        )}

        {tab === "ask" && (
          <>
            <AmountInput label={`Ask price (${asset} per option)`} value={askP} onChange={edit("askP", setAskP)} unit={asset} hint={fair ? `Fair value ${fmtPrice(fair)}. Price step ${fmtPrice(tick)}.` : undefined} />
            <AmountInput
              label="Options for sale"
              value={askQ}
              onChange={edit("askQ", setAskQ)}
              unit="options"
              max={fmtQty(book.inventory)}
              maxLabel="Held"
              invalid={askTooBig ? `The book holds only ${fmtQty(book.inventory)}. Stock more first.` : undefined}
            />
            <TxButton label="Set the ask" steps={askSteps} disabled={!askSteps} summary={ap && aq ? `Offer ${fmtQty(aq)} options at ${fmtPrice(ap)} ${asset}` : undefined} successMessage="Ask set: buyers can now buy this option." onDone={onDone} />
          </>
        )}

        {tab === "bid" && (
          <>
            <AmountInput label={`Bid price (${asset} per option)`} value={bidP} onChange={edit("bidP", setBidP)} unit={asset} hint={fair ? `Fair value ${fmtPrice(fair)}.` : undefined} />
            <AmountInput label="Options to buy" value={bidQ} onChange={setBidQ} unit="options" />
            {bidNeeds !== undefined && (
              <Row label={`${asset} the bid needs`} value={`${fmtNative(bidNeeds, dec)} (${shortfall > 0n ? `sends ${fmtNative(shortfall, dec)} more` : "already funded"})`} />
            )}
            <TxButton label="Fund and set the bid" steps={bidSteps} disabled={!bidSteps} summary={bp && bq ? `Bid for ${fmtQty(bq)} options at ${fmtPrice(bp)} ${asset}` : undefined} successMessage="Bid set: holders can now sell to your book." onDone={onDone} />
          </>
        )}

        {tab === "withdraw" &&
          (book.canWithdraw ? (
            <>
              <AmountInput label="Options to take back" value={wOpt} onChange={setWOpt} unit="options" max={fmtQty(book.inventory)} maxLabel="Held" />
              <AmountInput label={`${asset} to take back`} value={wCash} onChange={setWCash} unit={asset} max={fmtNative(book.funding, dec).replace(/,/g, "")} maxLabel="Held" />
              <TxButton label="Withdraw to my wallet" steps={withdrawSteps.length ? withdrawSteps : undefined} disabled={!withdrawSteps.length} successMessage="Withdrawn to your wallet." onDone={onDone} />
            </>
          ) : (
            <p className="rounded-xl border border-warn/40 bg-warn/10 p-3 text-[13px] text-warn">
              This book was created before withdrawals existed, so what it holds can only leave through trades. Books created from now on can be emptied
              by their owner. Stock it only with what you're happy to sell.
            </p>
          ))}
      </div>
    </Card>
  );
}

function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-line bg-surface-2/60 px-3 py-2">
      <div className="text-[11px] text-muted">{label}</div>
      <div className="num font-semibold">{value}</div>
    </div>
  );
}

export const OwnerBookSkeleton = () => <Skeleton className="h-40 w-full" />;
