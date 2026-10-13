/** Blog posts. Newest first. Each cover is a gradient so posts need no image assets. */
import type { ReactNode } from "react";
import { A, B, Callout, Example, Flow, H2, Lead, P, Step, Steps, Table, UL } from "../components/Prose.tsx";

export type BlogPost = {
  slug: string;
  title: string;
  excerpt: string;
  date: string; // ISO
  tag: "Announcement" | "Product" | "Deep dive" | "Guide";
  readMins: number;
  cover: string; // CSS background
  body: () => ReactNode;
};

export const POSTS: BlogPost[] = [
  {
    slug: "trading-optara-options-on-kuru",
    title: "Kuru support in Optara",
    excerpt: "Optara supports Kuru, Monad's on-chain order book, as its trading venue. See live depth, trade at market or set your own limit price from the app.",
    date: "2026-10-10",
    tag: "Product",
    readMins: 4,
    cover: "linear-gradient(135deg, #2b1f7a 0%, #7c6cff 55%, #35f4be 120%)",
    body: () => (
      <>
        <Lead>
          Optara supports <B>Kuru</B>, Monad&apos;s fully on-chain central limit order book, as the venue where option tokens trade. Every
          listed option has an official Kuru market, and the Optara app works with it directly: you can read the book, trade at market and
          place limit orders from the option you are looking at.
        </Lead>

        <H2>What you can do</H2>
        <UL>
          <li>
            <B>See live depth.</B> Every bid and ask level, the spread, and Optara&apos;s fair value sitting in the middle of the book.
          </li>
          <li>
            <B>Trade at market.</B> Buys and sells route through Optara&apos;s VenueRouter and the KuruAdapter, with your slippage and fee
            limits enforced on-chain.
          </li>
          <li>
            <B>Set your own price.</B> Place a Kuru limit bid or ask. The app funds your Kuru balance and places the order in one flow.
          </li>
          <li>
            <B>Manage your orders.</B> <i>My Kuru orders</i> shows active, partially filled and filled orders, with Cancel and Withdraw buttons.
          </li>
        </UL>

        <H2>How a limit order works</H2>
        <Flow
          items={[
            { title: "You set price and size", text: "Snapped to tick and lot size" },
            { title: "Deposit to Kuru", text: "Approve + MarginAccount.deposit" },
            { title: "Order placed", text: "addBuyOrder / addSellOrder", tone: "primary" },
            { title: "Filled", text: "Proceeds credited on Kuru", tone: "good" },
          ]}
        />
        <P>
          Your order is a real Kuru order on the one official Kuru market for that option. Optara verified that market when it was
          registered: its base token must be the option token and its quote the settlement stablecoin, read from Kuru&apos;s own records.
          Anyone on Kuru, or anyone buying through Optara, can fill it.
        </P>

        <H2>Why Kuru</H2>
        <P>
          Options need real price discovery: many strikes, many expiries, and market makers who quote both sides. A central limit order
          book does that better than a pool, and Kuru runs one fully on-chain at Monad speed. Because Optara options are plain ERC-20
          tokens, they trade on Kuru like any other asset, while Optara keeps doing what a venue can&apos;t: margin, liquidation and
          settlement.
        </P>

        <H2>Fees</H2>
        <P>
          Market orders routed through Optara pay a <B>0.3% buyer fee</B> on the premium actually spent. Limit orders placed on Kuru pay no
          Optara fee at placement. Kuru&apos;s own maker and taker fees apply as usual.
        </P>

        <Callout kind="warn" title="Kuru balances live on Kuru">
          Funds and tokens in your Kuru balance are held by Kuru, not Optara. They don&apos;t count as margin, and option tokens there must be
          withdrawn to your wallet before you can redeem them at expiry. Cancel unfilled orders and withdraw with one click from the option&apos;s
          Order book page or the <i>On Kuru</i> card in Portfolio.
        </Callout>

        <P>
          Try it on any option: open it from <A to="/app/markets">Markets</A> and choose <B>Order book</B>. The full walkthrough is in the{" "}
          <A to="/docs/kuru-order-book">docs</A>.
        </P>
      </>
    ),
  },
  {
    slug: "what-backs-your-option",
    title: "What backs your option?",
    excerpt: "Every Optara option token is minted against a written short. Here is how to read the backing card before you buy.",
    date: "2026-10-07",
    tag: "Deep dive",
    readMins: 5,
    cover: "linear-gradient(135deg, #04281c 0%, #00cf8e 60%, #9b8dff 130%)",
    body: () => (
      <>
        <Lead>
          When you buy an option you are holding a promise: if the price ends beyond the strike, someone pays you. So the first question any
          buyer should ask is: who made that promise, and can they pay?
        </Lead>

        <H2>Every token has a writer</H2>
        <P>
          Option tokens can only be minted by the clearing contract, and only against an equal short on some user&apos;s margin account. There
          is no protocol vault quietly writing options in the background. If 500 tokens exist, accounts are short exactly 500 options.
        </P>

        <H2>Reading the backing card</H2>
        <Table
          head={["Line", "What it tells you"]}
          rows={[
            ["Options written", "How many shorts exist, which equals the tokens held by buyers."],
            ["Owed if it expired now", "What writers would pay in total at today's price."],
            ["Writers' account value", "Cash plus positions of the writing accounts. It backs all their positions, not just this one."],
            ["Writers in good standing", "Writers above their liquidation line."],
          ]}
        />

        <H2>Three layers of protection</H2>
        <Steps>
          <Step title="Margin">Writers must hold enough collateral to survive a 50% price crash or a doubling, with volatility shocked up and down.</Step>
          <Step title="Liquidation">If a writer slips below maintenance margin, keepers take over slices of their risk before they become insolvent.</Step>
          <Step title="Insurance">60% of every fee goes to an insurance fund that covers any shortfall at settlement.</Step>
        </Steps>

        <H2>And if that is not enough?</H2>
        <P>
          Then every holder in that expiry group receives the same recovery ratio, fixed before anyone can redeem. There is no race: the first
          and the last redeemer are paid the same. Read more in <A to="/docs/backing-and-insurance">Backing and insurance</A>.
        </P>
      </>
    ),
  },
  {
    slug: "settlement-without-a-race",
    title: "Settlement without a race",
    excerpt: "Why Optara fixes one price and one recovery ratio before anyone can redeem, and how keepers make it happen.",
    date: "2026-10-03",
    tag: "Deep dive",
    readMins: 6,
    cover: "linear-gradient(135deg, #3a1020 0%, #ff4d6d 55%, #ffc24a 125%)",
    body: () => (
      <>
        <Lead>
          In many protocols, settlement is first-come-first-served: redeem quickly or risk finding the pool empty. Optara was designed so that
          timing never matters.
        </Lead>

        <H2>The problem</H2>
        <P>
          Writers use margin, so at expiry a few might owe more than they hold. If holders could redeem the moment the price is known, the
          fastest ones would be paid in full and the slowest would absorb the entire loss.
        </P>

        <H2>Optara&apos;s answer: settle first, pay second</H2>
        <Flow
          items={[
            { title: "Fix the price", text: "Round in force at expiry" },
            { title: "Settle every account", text: "Debts in, credits recorded" },
            { title: "Cover from insurance", text: "Up to the shortfall" },
            { title: "Fix one ratio", text: "Then redemption opens", tone: "good" },
          ]}
        />
        <P>
          Each step is permissionless and paid. Anyone can finalize a price for a $2 reward. Settling an account pays $0.50, and that reward grows
          by 25% every hour, up to 4×, so settlement always finishes even if nobody is in a hurry.
        </P>

        <H2>A quick example</H2>
        <Example
          title="ETH 4,500 call, settles at 5,200"
          lines={[
            ["Payout per option", "700 USDC"],
            ["Holders' total claim", "70,000 USDC (100 options)"],
            ["Collected from writers", "68,500 USDC"],
            ["Insurance cover", "1,500 USDC"],
          ]}
          result={["Recovery ratio", "1.00: everyone paid in full"]}
        />

        <P>
          You can watch and push each stage from the <A to="/app/settlement">Settle</A> page. The full mechanics are in the{" "}
          <A to="/docs/settlement">settlement docs</A>.
        </P>
      </>
    ),
  },
  {
    slug: "introducing-optara",
    title: "Introducing Optara: options that feel simple",
    excerpt: "Cash-settled options on Monad with portfolio margin, token-based positions and a guided trading flow.",
    date: "2026-09-28",
    tag: "Announcement",
    readMins: 4,
    cover: "linear-gradient(135deg, #1c1440 0%, #7c6cff 60%, #f4f3ff 140%)",
    body: () => (
      <>
        <Lead>
          Options are one of the most useful tools in finance: protection with a known cost, or leverage with a capped downside. They are also
          famously confusing. Optara is our attempt to fix that on Monad.
        </Lead>

        <H2>Simple on the surface</H2>
        <P>
          Pick an asset. Choose up or down. Type how much you are willing to risk. The app shows what you get back at every price, the
          break-even, every fee and the worst case, before you sign.
        </P>

        <H2>Serious underneath</H2>
        <UL>
          <li>
            <B>Portfolio margin</B> for writers, so hedged positions need less capital.
          </li>
          <li>
            <B>Options as ERC-20 tokens</B>, traded on Kuru&apos;s on-chain order book and transferable anywhere.
          </li>
          <li>
            <B>Signed volatility surfaces</B> for fair pricing, and Pyth spot prices for margin.
          </li>
          <li>
            <B>Fair settlement</B>, with one recovery ratio for every holder.
          </li>
          <li>
            <B>Dutch-auction liquidations</B> that don&apos;t depend on order-book liquidity.
          </li>
        </UL>

        <H2>Built in the open</H2>
        <P>
          Upgrades are timelocked for 7 days and listed in the app before they can run. The docs explain every mechanism in plain words,
          starting with <A to="/docs/introduction">the introduction</A>.
        </P>
        <P>
          Follow <A to="https://x.com/Oxoptara">@Oxoptara</A> on X for new markets and updates.
        </P>
      </>
    ),
  },
];

export const postBySlug = (slug: string | undefined) => POSTS.find((p) => p.slug === slug);

export const fmtPostDate = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
