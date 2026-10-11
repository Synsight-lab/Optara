/**
 * The Optara docs. Each page is plain JSX built from the Prose primitives, so it renders with the app's theme and
 * links straight into the app. Numbers here follow docs/PARAMETERS.md; update both together.
 */
import type { ReactNode } from "react";
import { BookOpen, Coins, Download, FileText, Gavel, Layers, LineChart, Scale, ShieldCheck, Sparkles, Store, Timer, Wallet } from "lucide-react";
import { A, B, Callout, Cards, Code, Example, Flow, Formula, H2, H3, Lead, P, Step, Steps, Table, UL } from "../components/Prose.tsx";
import { ContractsTable } from "./ContractsTable.tsx";
import { SOCIALS } from "../components/Site.tsx";

export const WHITEPAPER_URL = "/whitepaper.pdf";

export type DocPage = {
  slug: string;
  group: string;
  title: string;
  description: string;
  /** Extra words the sidebar search matches on. */
  keywords?: string;
  body: () => ReactNode;
};

export const DOC_GROUPS = ["Getting started", "Trading", "Writing & margin", "Settlement & safety", "Protocol", "Resources"] as const;

const ic = "h-4 w-4 text-primary";

export const DOCS: DocPage[] = [
  /* ------------------------------------------------------------------ Getting started */
  {
    slug: "introduction",
    group: "Getting started",
    title: "Introduction",
    description: "What Optara is, who it is for and how the pieces fit together.",
    keywords: "overview about what is optara monad",
    body: () => (
      <>
        <Lead>
          Optara is a protocol for <B>cash-settled European options on Monad</B>. You can bet on a price move by paying a small, fixed
          premium, or earn that premium by writing options against collateral. Every option is a normal ERC-20 token, every token is
          backed by a written position, and every payout is made in stablecoin at expiry.
        </Lead>

        <Cards
          items={[
            { title: "Buy calls and puts", text: "Risk only the premium. Profit if the price ends beyond the strike.", to: "/docs/buying-and-selling", icon: <LineChart className={ic} /> },
            { title: "Write and earn", text: "Lock collateral, mint options, sell them and keep the premium.", to: "/docs/writing-options", icon: <Coins className={ic} /> },
            { title: "Trade on Kuru", text: "Optara supports Kuru's order book: market orders and limit orders from the app.", to: "/docs/kuru-order-book", icon: <Store className={ic} /> },
            { title: "Fair settlement", text: "One price, one recovery ratio, no race to redeem.", to: "/docs/settlement", icon: <Scale className={ic} /> },
          ]}
        />

        <H2>Why Optara</H2>
        <P>
          Most on-chain option products are either fully collateralized (every call locked 1:1 with the coin, which is capital hungry)
          or run on an off-chain matching engine you have to trust. Optara takes a different route:
        </P>
        <UL>
          <li>
            <B>Portfolio margin.</B> Writers post stablecoin collateral once. The risk engine stress-tests the whole portfolio, so a
            hedged book needs far less margin than the sum of its legs.
          </li>
          <li>
            <B>Options are tokens.</B> A bought option is a plain ERC-20. You can hold it, send it, or sell it on Kuru&apos;s order book.
            Liquidity is never locked inside Optara.
          </li>
          <li>
            <B>Settlement without a race.</B> At expiry the protocol fixes one price, settles every account, covers any shortfall from
            insurance and only then opens redemption. The first and the last redeemer get exactly the same rate.
          </li>
          <li>
            <B>Liquidation without an order book.</B> Under-margined accounts are liquidated through a Dutch auction that any keeper can
            take. It doesn&apos;t depend on Kuru liquidity.
          </li>
        </UL>

        <H2>The system at a glance</H2>
        <Flow
          items={[
            { title: "Writer", text: "Deposits collateral and mints options", tone: "primary" },
            { title: "OptionClearing", text: "Holds custody, checks margin, mints tokens" },
            { title: "Kuru", text: "The order book where options trade" },
            { title: "Buyer", text: "Holds the option token", tone: "primary" },
            { title: "Settlement", text: "Pays in stablecoin at expiry", tone: "good" },
          ]}
          caption="Writers create option tokens against margin; venues move them to buyers; settlement pays holders at expiry."
        />
        <P>
          Read <A to="/docs/architecture">How the system works</A> for the full picture, or jump to <A to="/docs/quickstart">Quickstart</A>{" "}
          to make your first trade.
        </P>

        <H2>Who uses Optara</H2>
        <Table
          head={["Role", "What they do", "Where in the app"]}
          rows={[
            ["Buyer", "Pays a premium for a call or put and redeems the payout at expiry.", <A to="/app/markets">Markets</A>],
            ["Writer", "Deposits collateral, mints options, sells them and collects premium.", <A to="/app/write">Earn</A>],
            ["Market maker", "Quotes bids and asks on each option's Kuru order book.", <A to="/docs/kuru-order-book">Kuru order book</A>],
            ["Keeper", "Finalizes prices, settles accounts and liquidates risky ones for a reward.", <A to="/app/settlement">Settle</A>],
            ["Market creator", "Lists a new strike and expiry (series creator role).", <A to="/app/new">New market</A>],
          ]}
        />

        <Callout kind="tip" title="Read the whitepaper">
          The full design rationale is in the <A to="/docs/whitepaper">Optara Protocol Whitepaper</A>.
        </Callout>

        <Callout kind="warn" title="Options carry risk">
          A buyer can lose the entire premium if the option expires worthless. A writer can lose more than the premium they collected.
          Read <A to="/docs/risks">Risks</A> before you trade.
        </Callout>
      </>
    ),
  },
  {
    slug: "whitepaper",
    group: "Getting started",
    title: "Whitepaper",
    description: "The Optara Protocol Whitepaper: portfolio-margined, cash-settled options for Monad.",
    keywords: "whitepaper paper pdf research design thesis download",
    body: () => (
      <>
        <Lead>
          The whitepaper sets out why Optara exists and how it is designed, from the non-technical basics of options to margin, oracles,
          Kuru trading, liquidation, settlement, governance and the key risks.
        </Lead>
        <div className="my-6 flex flex-wrap gap-2.5">
          <a href={WHITEPAPER_URL} target="_blank" rel="noreferrer" className="btn-primary">
            <FileText className="h-4 w-4" /> Open the whitepaper
          </a>
          <a href={WHITEPAPER_URL} download="optara-whitepaper.pdf" className="btn-ghost">
            <Download className="h-4 w-4" /> Download PDF
          </a>
        </div>
        <div className="my-6 overflow-hidden rounded-2xl border border-line bg-surface-2/40">
          <object data={`${WHITEPAPER_URL}#view=FitH`} type="application/pdf" aria-label="Optara whitepaper" className="block h-[78vh] min-h-[520px] w-full">
            <div className="p-6 text-sm text-muted">
              Your browser can&apos;t show the PDF here. <A to={WHITEPAPER_URL}>Open the whitepaper</A> in a new tab instead.
            </div>
          </object>
        </div>

        <H2>What it covers</H2>
        <Table
          compact
          head={["Part", "Sections"]}
          rows={[
            ["Why Optara", "Executive summary · What an option is · Why options matter · The problem · Protocol thesis · Why Monad · Why Kuru"],
            ["How it works", "System overview · Option lifecycle · Position model · Margin system · Oracles · Trading and venues · Fees"],
            ["Safety", "Insurance fund · Liquidation · Settlement · Governance and upgradeability · Security model"],
            ["For users", "Buyer, writer, market maker, keeper and liquidator journeys · Key risks · Glossary"],
          ]}
        />
        <Callout kind="note">
          These docs follow the whitepaper but are kept up to date with the live app. Where the two differ, the docs and the deployed
          contracts are authoritative. Mainnet fee rates are listed in <A to="/docs/fees">Fees</A>.
        </Callout>
      </>
    ),
  },
  {
    slug: "options-101",
    group: "Getting started",
    title: "Options in plain words",
    description: "Calls, puts, strikes, expiries, premiums and payoffs with worked examples.",
    keywords: "call put strike expiry premium payoff contract size european cash settled itm otm moneyness",
    body: () => (
      <>
        <Lead>
          An option is a bet with a capped downside. You pay a fee today, the <B>premium</B>, for the right to a payout later if the price
          moves your way. If it doesn&apos;t, you lose only that premium.
        </Lead>

        <H2>Calls and puts</H2>
        <Cards
          items={[
            { title: "Call: you think it goes up", text: "Pays out if the price at expiry is above the strike. Payout = price − strike, per unit." },
            { title: "Put: you think it goes down", text: "Pays out if the price at expiry is below the strike. Payout = strike − price, per unit." },
          ]}
        />

        <H2>The words you will see</H2>
        <Table
          head={["Term", "Meaning"]}
          rows={[
            ["Underlying", "The asset the option tracks, such as MON, ETH or BTC."],
            ["Strike", "The price line. Calls pay above it, puts pay below it."],
            ["Expiry", "The moment the option ends. Optara options are European: they pay only at expiry, never earlier."],
            ["Premium", "What the buyer pays the seller up front. The most a buyer can lose."],
            ["Contract size", "How much underlying one option covers. If 1 option = 1 ETH, a $100 move is worth $100 per option."],
            ["Settlement asset", "The stablecoin the option is priced and paid in, such as USDC."],
            ["Cash-settled", "No coins change hands at expiry. Holders receive the payout in stablecoin."],
            ["In / out of the money", "A call is in the money when the price is above the strike, a put when it is below."],
          ]}
        />

        <H2>Worked example: a call</H2>
        <P>
          ETH is at $4,000. You think it will rise this week, so you buy one ETH call with a $4,200 strike. One option covers 1 ETH and the
          premium is $60.
        </P>
        <Example
          title="ETH ends at $4,500"
          lines={[
            ["Payout per option", "$4,500 − $4,200 = $300"],
            ["Premium paid", "−$60"],
            ["Optara buyer fee (0.3% of premium)", "−$0.18"],
          ]}
          result={["Profit", "$239.82"]}
        />
        <Example
          title="ETH ends at $4,100"
          lines={[
            ["Payout per option", "$0 (below the strike)"],
            ["Premium paid", "−$60"],
            ["Optara buyer fee", "−$0.18"],
          ]}
          result={["Loss (the most you can lose)", "−$60.18"]}
        />

        <H3>Break-even</H3>
        <Formula>{`Call break-even = strike + premium per unit       e.g. 4,200 + 60 = $4,260
Put  break-even = strike − premium per unit       e.g. 3,800 − 45 = $3,755`}</Formula>

        <H2>Worked example: a put</H2>
        <P>
          MON is at $0.0250 and you want protection against a drop. You buy a put with a $0.0240 strike, contract size 1,000 MON, for a
          premium of $0.80. If MON settles at $0.0200, each option pays (0.0240 − 0.0200) × 1,000 = <B>$4.00</B>.
        </P>

        <H2>What moves the premium</H2>
        <UL>
          <li>
            <B>Distance to the strike.</B> Options already in the money cost more.
          </li>
          <li>
            <B>Time left.</B> More time means more chance to end in the money, so a higher premium. Value decays as expiry approaches.
          </li>
          <li>
            <B>Volatility.</B> The wilder the asset, the more an option is worth. Optara reads volatility from a signed{" "}
            <A to="/docs/oracles">volatility surface</A>.
          </li>
        </UL>
        <Callout kind="tip">
          Every trade screen shows Optara&apos;s <B>fair value</B> next to the venue price. If a seller asks far above fair value, the app
          warns you before you sign.
        </Callout>
      </>
    ),
  },
  {
    slug: "quickstart",
    group: "Getting started",
    title: "Quickstart",
    description: "Make your first trade in five steps, from wallet to payout.",
    keywords: "first trade start guide connect wallet buy redeem tutorial",
    body: () => (
      <>
        <Lead>From a fresh wallet to a settled payout. The app explains every number before you sign, so you can follow along there.</Lead>

        <H2>Before you start</H2>
        <UL>
          <li>A wallet on Monad (any injected wallet works).</li>
          <li>Some MON for gas and some of the settlement stablecoin (for example USDC) to pay premiums.</li>
        </UL>

        <H2>Buy your first option</H2>
        <Steps>
          <Step title="Connect your wallet">
            Open the <A to="/app/markets">app</A> and press <B>Connect</B> at the top right. The app shows your wallet balances once connected.
          </Step>
          <Step title="Pick an asset and a direction">
            In Markets choose MON, ETH or BTC, then <B>Up</B> (call) or <B>Down</B> (put). Each row shows the strike, the time to expiry
            and the current price.
          </Step>
          <Step title="Choose how much to risk">
            Type the premium you are willing to spend. The ticket shows how many options that buys, the fees, the break-even, and a payoff
            chart of what you get back at each price.
          </Step>
          <Step title="Review the route and sign">
            The ticket shows the best Kuru ask, the fees and your limits. Approve the stablecoin once, then sign the buy. It routes through
            Optara&apos;s VenueRouter to the option&apos;s Kuru market.
          </Step>
          <Step title="Track and redeem">
            Your position appears in <A to="/app/portfolio">Portfolio</A> with live profit and loss. After expiry and settlement, press{" "}
            <B>Redeem</B> to receive the payout in stablecoin.
          </Step>
        </Steps>

        <H2>Prefer a limit price?</H2>
        <P>
          Open an option and switch to its <B>Order book</B> page. You can place a Kuru limit bid or ask right there and it rests on Kuru
          until it fills or you cancel it. See <A to="/docs/kuru-order-book">Kuru order book</A>.
        </P>

        <H2>Want to earn instead?</H2>
        <P>
          Writing options means taking the other side. You deposit collateral, mint options and sell them for premium. Start at{" "}
          <A to="/docs/writing-options">Writing options</A>.
        </P>
      </>
    ),
  },
  {
    slug: "architecture",
    group: "Getting started",
    title: "How the system works",
    description: "Contracts, money flow and the life of an option from mint to redemption.",
    keywords: "architecture modules contracts clearing risk manager router adapters flow lifecycle",
    body: () => (
      <>
        <Lead>
          Optara separates <B>who owes what</B> (the clearing layer) from <B>where options trade</B> (venues). Venues trade claims, and
          Optara clears the obligations behind them.
        </Lead>

        <H2>The core contracts</H2>
        <Table
          head={["Contract", "Job"]}
          rows={[
            ["OptionClearing", "The heart of the protocol. Holds every account's collateral, records long and short positions, mints and burns option tokens, and runs settlement."],
            ["PortfolioRiskManager", "Decides what an account may do. Stress-tests each portfolio to compute initial and maintenance margin."],
            ["ExternalOptionWrapper", "The ERC-20 option token. One per series. Only OptionClearing can mint or burn it."],
            ["SeriesRegistry / ProductRegistry", "The list of products (underlying + stablecoin) and series (strike, expiry, call or put, contract size)."],
            ["SettlementWindow", "Fixes the expiry price, tracks every account that must settle, and computes the recovery ratio."],
            ["LiquidationEngine", "Runs Dutch auctions that move risk from unhealthy accounts to liquidators."],
            ["InsuranceFund", "Absorbs shortfalls at settlement and in liquidation. Funded by fees and penalties."],
            ["FeeController", "Charges buyer and seller fees and splits them between insurance, treasury and keepers."],
            ["VenueRouter + KuruAdapter", "The official way to buy and sell on Kuru, with fee and slippage limits."],
            ["Oracles", "LiveSpotOracle (Pyth), VolSurfaceOracle (signed volatility surface), SettlementOracle (Chainlink-style price at expiry)."],
            ["UpgradeAdmin", "Holds upgrade rights behind a 7-day timelock (24 hours in an emergency)."],
          ]}
        />
        <P>
          Live addresses for the current network are on the <A to="/docs/contracts">Contracts</A> page.
        </P>

        <H2>Life of an option</H2>
        <Flow
          items={[
            { title: "1. Deposit", text: "Writer adds stablecoin to a margin account" },
            { title: "2. Mint", text: "Clearing records a short and mints the token", tone: "primary" },
            { title: "3. Trade", text: "Token sells on Kuru" },
            { title: "4. Expire", text: "Price fixed by the settlement oracle", tone: "warn" },
            { title: "5. Redeem", text: "Holders burn tokens for stablecoin", tone: "good" },
          ]}
        />
        <Steps>
          <Step title="Deposit">A writer deposits the settlement stablecoin into a margin account (a subaccount) inside OptionClearing.</Step>
          <Step title="Mint">
            The writer mints options. OptionClearing records a <B>short</B> on the writer&apos;s account and mints the same number of option
            tokens. The risk manager checks the account still has enough margin after the mint.
          </Step>
          <Step title="Trade">The tokens are sold on a venue. The buyer only ever holds the ERC-20 token; they never need a margin account.</Step>
          <Step title="Expire and settle">
            After expiry a keeper finalizes the price. Every account with positions in the expiry group is settled, and one recovery
            ratio is fixed for everyone.
          </Step>
          <Step title="Redeem">Token holders burn their tokens and receive the payout in stablecoin, straight to their wallet.</Step>
        </Steps>

        <H2>The rules that keep it safe</H2>
        <Callout kind="safe" title="Every option token is backed">
          Option tokens are minted <B>only</B> by OptionClearing and only against an equal short on some account. Total token supply can
          never exceed the outstanding shorts. The app shows this as <B>Backing</B> on every series.
        </Callout>
        <UL>
          <li>
            <B>Custody in one place.</B> All collateral and settlement pools sit in OptionClearing. Its balance always equals account cash
            plus every settlement pool.
          </li>
          <li>
            <B>Venue prices are never oracles.</B> Kuru prices are not used for margin, liquidation or settlement. If the venue being
            margined set the margin, that would be circular.
          </li>
          <li>
            <B>Venues are optional.</B> Minting, transfers, closing, liquidation, settlement and redemption all work even if Kuru is down.
          </li>
          <li>
            <B>Risk-reducing actions always work.</B> Deposits, unwrapping and closing shorts never need an oracle update and are never
            blocked by a margin check.
          </li>
        </UL>
      </>
    ),
  },

  /* ------------------------------------------------------------------ Trading */
  {
    slug: "buying-and-selling",
    group: "Trading",
    title: "Buying and selling",
    description: "How a market order is routed, priced, protected and charged.",
    keywords: "buy sell market order router slippage fees route venue best price depth",
    body: () => (
      <>
        <Lead>
          A market order in Optara goes through the <B>VenueRouter</B>. The router pulls your stablecoin, sends it to the chosen venue,
          measures exactly what came back, checks your limits and charges the Optara fee only on what was actually spent.
        </Lead>

        <H2>Buying</H2>
        <Steps>
          <Step title="You name a budget">
            Buys are <B>exact-in</B>: you say the most premium to spend and the fewest options you accept. Kuru market orders are quoted
            in stablecoin, so this matches how the venue works.
          </Step>
          <Step title="The router sends it to Kuru">
            The router hands your budget to the KuruAdapter, which places a market order on the option&apos;s official Kuru market.
          </Step>
          <Step title="Limits protect you">
            You sign a minimum quantity (your slippage limit), a maximum Optara fee and a maximum venue fee. If any is broken, the whole
            transaction reverts and you keep your money.
          </Step>
          <Step title="Tokens arrive">
            The option tokens go to your wallet. Unspent premium comes back to you, exactly. The router must end every trade holding nothing.
          </Step>
        </Steps>

        <H2>Selling</H2>
        <P>
          Selling works the other way round: you send option tokens and name the least stablecoin you accept. There is <B>no Optara fee</B>{" "}
          on sells, because the writer already paid a fee when the option was minted. The venue&apos;s own fee still applies.
        </P>

        <H2>Slippage and depth</H2>
        <UL>
          <li>
            The default slippage is <B>1%</B>. You can change it between 0.1% and 10%; the choice is remembered on your device.
          </li>
          <li>If the book can&apos;t fill your whole budget, the unspent premium is refunded to you in the same transaction.</li>
          <li>Quantities move in steps of 0.01 option.</li>
        </UL>

        <H2>Fair-value check</H2>
        <P>
          Next to every venue price the app shows Optara&apos;s fair value, priced from spot and the volatility surface. If you are about to
          pay far more than fair value, for example because a seller listed a stale ask, the ticket warns you and asks you to confirm.
        </P>

        <H2>Fees on a buy</H2>
        <Table
          head={["Fee", "Rate", "Paid to"]}
          rows={[
            ["Optara buyer fee", "0.3% of the premium actually spent", "Insurance 60%, treasury 30%, keepers 10%"],
            ["Venue fee", "Set by the venue (for example Kuru's taker fee)", "The venue"],
          ]}
        />
        <P>
          See <A to="/docs/fees">Fees</A> for every fee in the protocol.
        </P>
      </>
    ),
  },
  {
    slug: "kuru-order-book",
    group: "Trading",
    title: "Kuru order book",
    description: "How Optara supports Kuru: market orders, limit orders and live depth from the app.",
    keywords: "kuru limit order bid ask orderbook clob margin account deposit withdraw cancel maker taker",
    body: () => (
      <>
        <Lead>
          Kuru is Monad&apos;s on-chain central limit order book. Optara <B>supports Kuru</B> as its trading venue, and the app shows each option&apos;s Kuru book: you can see the
          live depth, take resting orders, and place your own limit bids and asks without ever opening Kuru&apos;s site.
        </Lead>

        <Callout kind="tip" title="No need to leave Optara">
          A limit order you place from Optara is a real Kuru order on the official market for that option. Anyone trading on Kuru, or
          through Optara, can fill it. You track, cancel and withdraw from the same screen.
        </Callout>

        <H2>Where to find it</H2>
        <P>
          Open any option from <A to="/app/markets">Markets</A> and choose <B>Order book</B>. The page shows:
        </P>
        <UL>
          <li>
            <B>Depth.</B> Every bid and ask level with its size and running total, plus the best bid, best ask and spread.
          </li>
          <li>
            <B>Optara fair value</B> in the middle of the book, so you can see at a glance whether quotes are cheap or rich.
          </li>
          <li>
            <B>A limit ticket.</B> Pick buy or sell, set your price and size, and place the order.
          </li>
          <li>
            <B>Cancel and withdraw.</B> Cancel open orders and withdraw your Kuru balance to your wallet without leaving the page.
          </li>
          <li>
            <B>My Kuru orders</B>: your active, partially filled and filled orders on that book.
          </li>
        </UL>

        <H2>Two ways to trade on Kuru</H2>
        <Table
          head={["", "Market order (take)", "Limit order (make)"]}
          rows={[
            ["What happens", "Fills now against resting orders", "Rests on the book until someone fills it or you cancel"],
            ["Route", "Optara VenueRouter → KuruAdapter → Kuru market", "Straight to the Kuru market from your wallet"],
            ["Price", "Best available, protected by your slippage limit", "Exactly the price you set"],
            ["Optara buyer fee", "0.3% of premium spent", "None at placement"],
            ["Where tokens land", "Your wallet", "Your Kuru balance (withdraw to wallet)"],
          ]}
        />

        <H2>Placing a limit order</H2>
        <Steps>
          <Step title="Fund your Kuru balance">
            Kuru orders draw from Kuru&apos;s <B>MarginAccount</B>, not your wallet. The ticket does this for you: it approves the token and
            deposits the exact amount the order needs. For a bid that is stablecoin; for an ask it is the option tokens you are listing.
          </Step>
          <Step title="Set price and size">
            Prices snap to the market&apos;s tick size and sizes to its lot size. The ticket shows the rounded values you will actually
            place, and compares your price with Optara&apos;s fair value.
          </Step>
          <Step title="Place the order">
            The app calls Kuru&apos;s <Code>addBuyOrder</Code> or <Code>addSellOrder</Code>. Your order appears in the depth and in your
            orders list.
          </Step>
          <Step title="Get filled, or cancel">
            When a taker hits your order, the proceeds (option tokens for a bid, stablecoin for an ask) are credited to your Kuru balance.
            If it never fills, press <B>Cancel order</B> (or <B>Cancel all</B>) in <i>My Kuru orders</i>: the unfilled funds return to
            your Kuru balance. A partly filled order keeps what filled and cancels the rest.
          </Step>
          <Step title="Withdraw to your wallet">
            The <B>Ready to withdraw from Kuru</B> card on the same page, and the <B>On Kuru</B> card in Portfolio, show your free Kuru
            balance with a <B>Withdraw</B> button for the stablecoin and for the options.
          </Step>
        </Steps>

        <H2>How much can I buy right now?</H2>
        <P>
          A market buy walks the resting asks from the best price up. The Buy ticket reads the Kuru book and shows{" "}
          <B>Available to buy now</B>: how many options are for sale and what buying all of them would cost. It estimates your fill by
          walking the same asks, so a budget that reaches deeper levels shows the higher average price you will actually pay. If your
          budget is larger than everything for sale, the ticket says so and offers to spend just what fills; the router refunds any
          unspent premium in the same transaction anyway.
        </P>

        <H2>Important boundaries</H2>
        <Callout kind="warn" title="Kuru balances are not Optara margin">
          Stablecoin or option tokens sitting in Kuru do not count as collateral and cannot back options you write. Tokens on Kuru also
          cannot be redeemed at expiry or used to close a short until you withdraw them to your wallet.
        </Callout>
        <Table
          head={["Rule", "What it means for you"]}
          rows={[
            ["A Kuru fill is not an Optara close", "Buying back tokens on Kuru does not reduce your short until you burn them in Optara."],
            ["Kuru prices are not oracles", "Kuru prices never decide margin, liquidation or settlement."],
            ["Kuru fees are separate", "Kuru's maker and taker fees are shown and limited separately from Optara's fee."],
            ["Kuru down ≠ Optara down", "If Kuru is unavailable, minting, closing, settlement and redemption still work."],
          ]}
        />

        <H2>Why Kuru markets are safe to route to</H2>
        <P>
          Each option has at most one official Kuru market. When it is registered, the KuruAdapter reads the market&apos;s base and quote
          tokens from <B>Kuru&apos;s own router records</B>, not from the caller, and requires the base to be the option token and the
          quote to be the settlement stablecoin. A fake market that only claims the right tokens cannot be registered. Once an option
          expires its market is marked expired and the app switches to redemption.
        </P>
      </>
    ),
  },

  /* ------------------------------------------------------------------ Writing & margin */
  {
    slug: "writing-options",
    group: "Writing & margin",
    title: "Writing options and earning",
    description: "Deposit collateral, mint, sell for premium and close or settle your shorts.",
    keywords: "write earn premium mint short seller collateral yield close",
    body: () => (
      <>
        <Lead>
          Writing is the other side of every trade. A writer creates options, sells them and keeps the premium. In return they owe the
          payout if the option ends in the money.
        </Lead>

        <H2>Who are the writers?</H2>
        <P>
          Anyone. There is no protocol vault that writes for you: each option was minted by some user&apos;s margin account, and that
          account carries the matching short until it is closed or settled. Writers of the same series share nothing except the
          settlement price and the recovery ratio.
        </P>

        <H2>The writing flow</H2>
        <Steps>
          <Step title="Open a margin account and deposit">
            In <A to="/app/portfolio">Portfolio</A> deposit the settlement stablecoin. This cash is your collateral. It stays in your
            account when you buy options with your wallet; it only backs what you write.
          </Step>
          <Step title="Mint">
            In <A to="/app/write">Earn</A> choose a series and a quantity. The app shows the margin it will lock and the seller fee before
            you sign.
          </Step>
          <Step title="Sell">
            If the Kuru book has a bid, sell the new tokens to it instantly for premium. Or keep them and list them with a Kuru limit ask.
          </Step>
          <Step title="Close or settle">
            Buy tokens back and burn them to close the short early, or wait for expiry. At settlement your account pays the payout owed (if
            any) from its cash, and the rest of your collateral is yours again.
          </Step>
        </Steps>

        <H2>What a writer earns and risks</H2>
        <Example
          title="Writing 1 ETH call, strike $4,200, premium $60"
          lines={[
            ["Premium received", "+$60.00"],
            ["Seller fee (0.3% of the minted mark, min $0.10)", "−$0.18"],
            ["If ETH ends at or below $4,200", "owes $0"],
          ]}
          result={["Profit if it expires worthless", "$59.82"]}
        />
        <P>
          If ETH instead ends at $4,500 the writer owes $300 per option, a loss of $240.18. A call writer&apos;s loss has no fixed cap, which
          is why writing needs margin.
        </P>

        <Callout kind="tip" title="Hedged books need less margin">
          Margin is computed for the whole portfolio per underlying. Writing a $4,200 call and buying a $4,400 call (a call spread) caps
          the loss, and the margin drops to match.
        </Callout>
      </>
    ),
  },
  {
    slug: "margin-and-health",
    group: "Writing & margin",
    title: "Margin and account health",
    description: "Initial and maintenance margin, stress tests, buckets and what each health state allows.",
    keywords: "margin im mm initial maintenance health stress scenarios bucket subaccount equity close-only liquidatable",
    body: () => (
      <>
        <Lead>
          Optara uses <B>portfolio margin</B>. Instead of locking a fixed amount per option, the risk engine asks: if prices and volatility
          moved sharply, how much could this whole account lose? That worst case is the margin.
        </Lead>

        <H2>What counts</H2>
        <Table
          head={["Counts toward margin", "Does not count"]}
          rows={[
            ["Cash in the margin account", "Stablecoin in your wallet"],
            ["Options held inside the account (internal longs)", "Option tokens in your wallet or on Kuru"],
            ["Written options, as liabilities", "Balances in other accounts you own"],
          ]}
        />

        <H2>Buckets</H2>
        <P>
          Margin is computed per <B>bucket</B>: one account × one underlying. Positions on the same underlying offset each other across
          strikes, types and expiries because they face the same shocks. Positions on different underlyings never offset: an ETH loss is not
          reduced by a BTC gain. All buckets share the account&apos;s cash.
        </P>

        <H2>Initial and maintenance margin</H2>
        <Table
          head={["", "Initial margin (IM)", "Maintenance margin (MM)"]}
          rows={[
            ["Scenarios", "24 + 12: spot −50% to +100%, volatility −30% to +75%, now and near expiry", "12: spot −30% to +50%, volatility ±30%"],
            ["Extra buffer", "+5% of the current value of all shorts", "None"],
            ["Needed to", "Mint, wrap out, withdraw", "Avoid liquidation"],
          ]}
        />
        <Formula>{`margin = largest equity drop across the scenario set
equity = cash + value of longs − value of shorts`}</Formula>

        <H2>Health states</H2>
        <Table
          head={["State", "Condition", "What you can do"]}
          rows={[
            ["Healthy", "equity ≥ IM", "Everything"],
            ["Close-only", "MM ≤ equity < IM", "Only actions that reduce risk: deposit, close, unwrap"],
            ["Liquidatable", "equity < MM", "Reduce risk; anyone may start a liquidation auction"],
            ["Insolvent", "equity < 0 with nothing left to liquidate", "Waits for settlement; shortfall goes to insurance"],
          ]}
        />
        <P>
          Portfolio shows a health bar for each account. Keep a cushion above IM: prices can move between the moment you look and the moment
          a keeper checks.
        </P>

        <H2>When oracle data is stale</H2>
        <UL>
          <li>Risk-increasing actions need a fresh spot price (≤ 60 s) and a fresh volatility surface (≤ 5 min). The app pushes updates for you.</li>
          <li>As the surface ages, implied volatility is penalized in the direction that hurts the account, so stale data never flatters a position.</li>
          <li>After 6 hours without a surface, the product becomes close-only.</li>
        </UL>
      </>
    ),
  },
  {
    slug: "portfolio-and-pnl",
    group: "Writing & margin",
    title: "Portfolio and P&L",
    description: "How positions, profit and loss, history and Kuru balances are shown.",
    keywords: "portfolio pnl profit loss history positions realized unrealized kuru balances",
    body: () => (
      <>
        <Lead>Portfolio is your home in the app: wallet options, margin accounts, profit and loss per trade and overall, and balances held on Kuru.</Lead>

        <H2>Profit and loss</H2>
        <UL>
          <li>
            <B>Per position:</B> what you paid (premium + fees), what you have received from sells, and the current value at Optara&apos;s fair
            value, giving an unrealized and a realized figure.
          </li>
          <li>
            <B>Overall:</B> the sum across every trade, so you can see at a glance whether you are up or down.
          </li>
          <li>
            Buys and sells are matched in order, so selling part of a position realizes the right share of its cost.
          </li>
          <li>
            History survives expiry. Settled positions stay listed with their final payout so you can see how each trade ended.
          </li>
        </UL>

        <H2>Where the history comes from</H2>
        <P>
          On networks with an indexer, the app reads your trade history from the Optara indexer (an Envio HyperIndex service). Without one,
          it rebuilds history from on-chain events directly. Either way the numbers come from the chain, not from the app.
        </P>

        <H2>Kuru balances</H2>
        <P>
          Funds and option tokens you deposited for Kuru limit orders, or received from fills, live in Kuru&apos;s MarginAccount. Portfolio
          lists them in an <B>On Kuru</B> card, marked as outside Optara, with a <B>Withdraw to wallet</B> button for each balance. Funds still
          locked in open orders show up there once you cancel them.
        </P>
      </>
    ),
  },

  /* ------------------------------------------------------------------ Settlement & safety */
  {
    slug: "settlement",
    group: "Settlement & safety",
    title: "Settlement",
    description: "From expiry to payout: finalization, account settlement, recovery ratio and redemption.",
    keywords: "settlement expiry finalize redeem recovery ratio payout claim keeper settle price",
    body: () => (
      <>
        <Lead>
          Writers are leveraged, so some may be underwater at expiry. If holders could redeem the moment the price was known, early
          redeemers would be paid in full and late ones could find the pool empty. Optara removes that race.
        </Lead>

        <H2>The five stages</H2>
        <Flow
          items={[
            { title: "Expired", text: "Trading stops for the expiry group", tone: "warn" },
            { title: "Finalized", text: "Settlement price fixed forever" },
            { title: "All settled", text: "Every account netted" },
            { title: "Redeemable", text: "One recovery ratio fixed", tone: "good" },
          ]}
        />
        <Steps>
          <Step title="Expiry">
            Series that share a product and expiry form a <B>settlement group</B>. At expiry new minting stops. Writers can still close
            shorts by burning tokens they hold.
          </Step>
          <Step title="Finalize the price">
            Anyone can call <Code>finalizeGroup</Code>. The settlement oracle checks which price round was in force at expiry, and that
            price is stored once and can never change. The caller earns a keeper reward.
          </Step>
          <Step title="Settle every account">
            Keepers call <Code>settleAccountGroup</Code> for each account with positions. Each account&apos;s series are netted into one
            amount: debts are collected from its cash into the group&apos;s pool, credits are recorded as claims. Rewards grow each hour
            so this always finishes.
          </Step>
          <Step title="Fix the recovery ratio">
            When no participants are left, <Code>computeRecoveryRatio</Code> asks the insurance fund to cover any shortfall and fixes one
            ratio for everyone. With everyone solvent it is exactly 1.
          </Step>
          <Step title="Redeem">
            Holders burn their tokens for <Code>qty × payoff × ratio</Code> in stablecoin. There is no deadline and the order never
            matters. Worthless options can be burned for zero to clean up your wallet.
          </Step>
        </Steps>

        <H2>The recovery ratio</H2>
        <Formula>{`grossClaim = token claims + net credit claims
shortfall  = grossClaim − collected
insurance  = min(shortfall, what the insurance fund can cover)
ratio      = min(1, (collected + insurance) / grossClaim)`}</Formula>
        <Callout kind="safe" title="Everyone is paid the same rate">
          The ratio is fixed once, before anyone can redeem. A holder who redeems a year later gets exactly what the first holder got.
        </Callout>

        <H2>In the app</H2>
        <P>
          The <A to="/app/settlement">Settle</A> page lists expired groups, shows which stage each is in, and gives a button for whatever
          step is next: fix the price, settle accounts, fix the ratio. Anyone can press them and earn the keeper reward. Your redeemable
          options show a <B>Redeem</B> button in Portfolio and on the option page.
        </P>

        <H2>Why an expired option might pay less than you expected</H2>
        <P>
          The payout depends only on the settlement price, not on what you paid. If you bought an option for more than it ended up paying,
          redemption returns the smaller payout and the difference is your loss. If the settlement price is beyond the strike, you receive
          something even if the option looked unlikely to pay when you bought it.
        </P>
      </>
    ),
  },
  {
    slug: "liquidations",
    group: "Settlement & safety",
    title: "Liquidations",
    description: "Dutch-auction slice liquidation, liquidating with option tokens, and ending auctions.",
    keywords: "liquidation auction dutch slice bonus penalty keeper liquidator wrapper end auction",
    body: () => (
      <>
        <Lead>
          When a writer&apos;s equity falls below maintenance margin, their risk must move to someone who can carry it. Optara does this
          with a permissionless Dutch auction that needs no order book and no Kuru liquidity.
        </Lead>

        <H2>How an auction runs</H2>
        <Steps>
          <Step title="Start">Anyone calls <Code>startAuction</Code> for an account and underlying whose equity is below MM.</Step>
          <Step title="The bonus grows">
            The liquidator&apos;s bonus starts at 0% and rises linearly to 10% of the slice&apos;s maintenance margin over 30 minutes. Whoever
            finds the price attractive first takes it.
          </Step>
          <Step title="Take a slice">
            A liquidator takes 5% to 25% of <B>every</B> open position in the bucket at once, shorts and longs, into their own margin
            account, with cash moving to compensate. After 30 minutes, slices up to 100% are allowed.
          </Step>
          <Step title="End">
            The auction ends once the account is healthy with a buffer: equity ≥ IM × 1.05. If the owner recovers by depositing, anyone can
            call <Code>endAuction</Code>.
          </Step>
        </Steps>
        <P>
          The liquidated account also pays a 2% penalty (of slice MM) to the insurance fund. Every slice is designed to leave the account
          healthier than before.
        </P>

        <H2>Liquidating with option tokens</H2>
        <P>
          Instead of taking on positions, a liquidator can hand in option tokens of the series the account is short. The tokens cancel the
          account&apos;s written options one for one, and the account pays the liquidator their value plus the auction bonus. This lets
          someone holding tokens, but no margin account, help clear risk.
        </P>

        <H2>In the app</H2>
        <P>
          <A to="/app/liquidations">Liquidations</A> lists accounts at risk and running auctions with their current bonus. If your own
          account is in an auction, Portfolio shows a notice with an <B>End auction</B> button as soon as you are back above the target.
        </P>
      </>
    ),
  },
  {
    slug: "backing-and-insurance",
    group: "Settlement & safety",
    title: "Backing and insurance",
    description: "What stands behind every option token, and how the insurance fund absorbs shortfalls.",
    keywords: "backing collateral insurance fund shortfall solvency open interest",
    body: () => (
      <>
        <Lead>Every option token is a claim on the shorts written against it. Three layers stand behind that claim.</Lead>

        <Cards
          cols={3}
          items={[
            { title: "1. Writer margin", text: "Each short sits in an account that must hold enough collateral to survive large stress scenarios.", icon: <Wallet className={ic} /> },
            { title: "2. Liquidation", text: "Accounts that slip below maintenance are cut down before they become insolvent.", icon: <Gavel className={ic} /> },
            { title: "3. Insurance fund", text: "Covers any shortfall left at settlement, funded by 60% of fees and every liquidation penalty.", icon: <ShieldCheck className={ic} /> },
          ]}
        />

        <H2>The backing card</H2>
        <P>
          Each option page has a <B>Backing</B> section. It shows how many options have been written, what writers would owe if the
          option expired at today&apos;s price, the writers&apos; combined account value, and how many writers are in good standing. It is
          the quickest way to judge what you are buying.
        </P>

        <H2>The insurance fund</H2>
        <UL>
          <li>Holds stablecoin per settlement asset, seeded at launch.</li>
          <li>Receives 60% of every buyer and seller fee and every liquidation penalty.</li>
          <li>At settlement, covers up to the group&apos;s shortfall before the recovery ratio is fixed.</li>
          <li>In liquidation, can top up a slice when the account&apos;s cash runs out, up to a per-asset cap.</li>
        </UL>
        <Callout kind="warn">
          Insurance is a buffer, not a guarantee. If losses exceed what the fund can cover, the recovery ratio drops below 1 and every holder
          of that group takes the same haircut.
        </Callout>
      </>
    ),
  },
  {
    slug: "oracles",
    group: "Settlement & safety",
    title: "Oracles",
    description: "Spot, volatility surface and settlement oracles, and why they are kept apart.",
    keywords: "oracle pyth chainlink price feed volatility surface iv settlement round staleness",
    body: () => (
      <>
        <Lead>Optara uses three separate oracles, each for one job. They are never mixed up.</Lead>
        <Table
          head={["Oracle", "Gives", "Used for", "Never used for"]}
          rows={[
            ["LiveSpotOracle", "The current price, from Pyth pull feeds", "Margin, liquidation, fees", "Settlement"],
            ["VolSurfaceOracle", "A signed implied-volatility surface", "Pricing options for margin and liquidation", "Settlement"],
            ["SettlementOracle", "One price at expiry, from a Chainlink-style feed", "Payoffs", "Margin"],
          ]}
        />

        <H2>Spot prices</H2>
        <P>
          Spot comes from Pyth pull feeds: the transaction carries a signed price update, so the price is fresh when it is used. A price
          older than 60 seconds, or with a confidence band wider than 1%, is refused for risk-increasing actions.
        </P>

        <H2>The volatility surface</H2>
        <P>
          No oracle on Monad publishes ready-made option volatility, so Optara runs its own: a quorum of publishers signs a grid of implied
          volatility by expiry and strike. Reports expire within minutes, large jumps are rejected, and stale surfaces are penalized in the
          direction that hurts the account being checked.
        </P>

        <H2>Settlement price</H2>
        <P>
          At finalization the settlement oracle is given a price round and checks it was the round <B>in force at expiry</B>: published at
          or before expiry, with the next round published after it. A late or cherry-picked round is rejected. If no valid round appears
          within 7 days, the group is flagged as stalled, but it can still be finalized once data arrives.
        </P>

        <Callout kind="note">Kuru prices are never an oracle input. Margin and settlement can&apos;t be moved by trading on a thin book.</Callout>
      </>
    ),
  },

  /* ------------------------------------------------------------------ Protocol */
  {
    slug: "fees",
    group: "Protocol",
    title: "Fees",
    description: "Every fee Optara charges, who pays it and where it goes.",
    keywords: "fees buyer seller fee split insurance treasury keeper reward kuru fee",
    body: () => (
      <>
        <Lead>Optara charges two fees, both small and both capped in the contract. Venue fees are separate and shown separately.</Lead>
        <Table
          head={["Fee", "Rate", "Charged on", "Hard cap"]}
          rows={[
            ["Buyer fee", "0.3%", "Premium actually spent on a router buy", "10%"],
            ["Seller fee", "0.3% (min $0.10)", "Fair value of options minted", "10%"],
            ["Liquidation penalty", "2%", "Slice maintenance margin, paid by the liquidated account", "—"],
            ["Sell through router", "0%", "The writer already paid at mint", "—"],
            ["Kuru limit order", "0% Optara fee", "Kuru's own maker/taker fees apply", "—"],
          ]}
        />

        <H2>Where fees go</H2>
        <Flow
          items={[
            { title: "Insurance fund", text: "60%", tone: "good" },
            { title: "Treasury", text: "30%" },
            { title: "Keeper reserve", text: "10%", tone: "primary" },
          ]}
          caption="Every buyer and seller fee is split the same way."
        />

        <H2>Keeper rewards</H2>
        <P>The keeper reserve pays the people who keep the protocol running:</P>
        <Table
          head={["Action", "Reward"]}
          rows={[
            ["Finalize a settlement price", "$2 equivalent"],
            ["Settle one account", "$0.50 equivalent, growing 25% per hour since finalization, up to 4×"],
            ["Liquidate", "The auction bonus, up to 10% of slice MM"],
          ]}
        />
      </>
    ),
  },
  {
    slug: "governance",
    group: "Protocol",
    title: "Governance and upgrades",
    description: "Who can change what, timelocks, pauses and how upgrades are announced.",
    keywords: "governance timelock upgrade admin pause guardian roles parameters multisig",
    body: () => (
      <>
        <Lead>Changes that make the protocol riskier are slow and visible. Changes that make it safer can be fast.</Lead>
        <Table
          head={["Change", "Delay"]}
          rows={[
            ["Contract upgrade", "7 days"],
            ["Emergency upgrade (≥ 4 of 7 multisig)", "24 hours"],
            ["Risk-increasing parameter change", "48 hours"],
            ["Volatility publisher set change", "48 hours"],
            ["Risk-reducing parameter change (lower caps, bigger shocks)", "Immediate"],
          ]}
        />

        <H2>Scheduled upgrades are public</H2>
        <P>
          Every upgrade is scheduled on-chain before it can run. The app&apos;s <A to="/app/system">System status</A> page lists scheduled
          upgrades with a countdown, so anyone can exit before a change they disagree with takes effect.
        </P>

        <H2>Pauses</H2>
        <P>
          A guardian can pause parts of the protocol in an emergency, scoped by action, asset or product. Pauses are designed to stop new
          risk; deposits, closing and redemption stay open whenever possible.
        </P>

        <H2>What never changes retroactively</H2>
        <UL>
          <li>The terms of an existing series: strike, expiry, type, contract size.</li>
          <li>A finalized settlement price.</li>
          <li>A fixed recovery ratio.</li>
        </UL>
      </>
    ),
  },
  {
    slug: "risks",
    group: "Protocol",
    title: "Risks",
    description: "What can go wrong for buyers, writers and everyone. Read before trading.",
    keywords: "risk loss smart contract oracle liquidity haircut warning",
    body: () => (
      <>
        <Lead>Options are powerful and easy to misjudge. These are the risks you take on Optara.</Lead>

        <H2>For buyers</H2>
        <UL>
          <li>
            <B>You can lose the whole premium.</B> Most options expire worthless.
          </li>
          <li>
            <B>Time decay.</B> An option loses value as expiry approaches if the price doesn&apos;t move.
          </li>
          <li>
            <B>Thin books.</B> New markets may have little depth. Selling before expiry may be at a poor price, or impossible.
          </li>
          <li>
            <B>Overpaying.</B> A seller can list far above fair value. Check the fair-value line before you buy.
          </li>
        </UL>

        <H2>For writers</H2>
        <UL>
          <li>
            <B>Losses can exceed the premium.</B> A call writer&apos;s loss grows with the price.
          </li>
          <li>
            <B>Liquidation.</B> If equity falls below maintenance margin, part of your positions can be taken at a discount.
          </li>
          <li>
            <B>Close-only.</B> Below initial margin you can only reduce risk, so you may not be able to withdraw.
          </li>
        </UL>

        <H2>For everyone</H2>
        <UL>
          <li>
            <B>Recovery haircut.</B> If writer losses exceed insurance, every holder in that group is paid the same reduced ratio.
          </li>
          <li>
            <B>Oracle risk.</B> Wrong or delayed prices can affect margin and settlement, despite staleness and quorum checks.
          </li>
          <li>
            <B>Smart-contract risk.</B> Contracts can have bugs. Upgrades are timelocked, but no code is risk-free.
          </li>
          <li>
            <B>Venue risk.</B> Funds you place on Kuru are held by Kuru&apos;s contracts and follow Kuru&apos;s rules.
          </li>
        </UL>
        <Callout kind="warn">Only trade what you can afford to lose. Nothing in these docs is financial advice.</Callout>
      </>
    ),
  },
  {
    slug: "contracts",
    group: "Protocol",
    title: "Contracts",
    description: "Deployed contract addresses for the network this app is connected to.",
    keywords: "addresses deployment proxy implementation network",
    body: () => (
      <>
        <Lead>
          These are the contracts this app is using, read from its deployment manifest. Core modules are upgradeable proxies; always
          interact with the <B>proxy</B> address.
        </Lead>
        <ContractsTable />
        <Callout kind="safe">Check addresses against official Optara channels before approving large amounts.</Callout>
      </>
    ),
  },
  {
    slug: "parameters",
    group: "Protocol",
    title: "Key parameters",
    description: "The numbers that matter most, in one place.",
    keywords: "parameters limits defaults min position qty max series slippage",
    body: () => (
      <>
        <Lead>Defaults at launch. Risk-reducing changes can apply immediately; risk-increasing ones go through a timelock.</Lead>
        <Table
          compact
          head={["Parameter", "Default"]}
          rows={[
            ["Smallest position step", "0.01 option"],
            ["Series per account", "16"],
            ["Underlyings per account", "4"],
            ["IM buffer", "5% of short value"],
            ["Minimum volatility (ETH, BTC / MON)", "10% / 60%"],
            ["Maximum spot age", "60 seconds"],
            ["Surface stale after", "5 minutes"],
            ["Product close-only after", "6 hours without a surface"],
            ["Auction duration", "30 minutes"],
            ["Max liquidation bonus", "10% of slice MM"],
            ["Slice size", "5% – 25% (up to 100% after the auction duration)"],
            ["Auction ends at", "IM + 5%"],
            ["Liquidation penalty", "2% of slice MM"],
            ["Buyer / seller fee", "0.3% / 0.3%"],
            ["Default slippage", "1% (0.1% – 10%)"],
            ["Finalization delay window", "5 minutes – 7 days"],
            ["Upgrade timelock", "7 days (emergency 24 hours)"],
          ]}
        />
      </>
    ),
  },

  /* ------------------------------------------------------------------ Resources */
  {
    slug: "faq",
    group: "Resources",
    title: "FAQ",
    description: "Short answers to the questions people ask most.",
    keywords: "faq questions help why how",
    body: () => (
      <>
        <H3>Do I need a margin account to buy options?</H3>
        <P>No. Buyers pay from their wallet and hold option tokens in their wallet. Margin accounts are only for writing.</P>

        <H3>Why didn&apos;t my deposit go down when I bought an option?</H3>
        <P>Buys are paid from your wallet. The cash in your margin account is collateral for options you write, so it stays put.</P>

        <H3>Do I need to go to Kuru to use limit orders?</H3>
        <P>
          No. Optara supports Kuru directly: each option has an <B>Order book</B> page showing its Kuru book. You can place, track and fill limit orders there. See{" "}
          <A to="/docs/kuru-order-book">Kuru order book</A>.
        </P>

        <H3>Why can&apos;t I buy an option I just created?</H3>
        <P>
          A new series can only be traded once its Kuru market is deployed and registered by a venue admin, and someone has written
          options and listed them with an ask. Writers can mint and place a Kuru limit ask from the app.
        </P>

        <H3>Can I exercise early?</H3>
        <P>No. Optara options are European and pay only at expiry. To exit early, sell the token.</P>

        <H3>When can I redeem?</H3>
        <P>After the group is finalized, every account is settled and the recovery ratio is fixed. Anyone can push those steps on the Settle page.</P>

        <H3>Is there a deadline to redeem?</H3>
        <P>No. Redeemable tokens stay redeemable forever.</P>

        <H3>Why did my expired option pay something even though it seemed far from the strike when I bought it?</H3>
        <P>The payout depends only on the settlement price at expiry. If the price crossed the strike by then, the option pays.</P>

        <H3>Who sets the price of an option?</H3>
        <P>The market does, on Kuru. Optara shows a fair value from spot and volatility to help you judge it, but never forces a price.</P>
      </>
    ),
  },
  {
    slug: "glossary",
    group: "Resources",
    title: "Glossary",
    description: "Every Optara term in one sentence.",
    keywords: "glossary terms definitions",
    body: () => (
      <Table
        head={["Term", "Meaning"]}
        rows={[
          ["Series", "One option: a product, call or put, strike, expiry and contract size."],
          ["Product", "An underlying paired with a settlement stablecoin, e.g. ETH/USDC."],
          ["Option token (wrapper)", "The ERC-20 for a series that buyers hold. Minted only against a short."],
          ["Margin account (subaccount)", "An account inside OptionClearing that holds collateral and positions."],
          ["Short", "A written option: an obligation to pay at expiry."],
          ["Internal long", "An option held inside a margin account, where it counts toward margin."],
          ["Bucket", "One account × one underlying; margin is computed per bucket."],
          ["IM / MM", "Initial and maintenance margin."],
          ["Equity", "Cash plus the value of longs minus the value of shorts."],
          ["Fair value (mark)", "Optara's price for an option from spot and the volatility surface."],
          ["Settlement group", "All series of one product with the same expiry, settled together."],
          ["Recovery ratio", "The share of each payout that is paid, fixed once per group. 1 when everyone is solvent."],
          ["Keeper", "Anyone who runs maintenance calls (finalize, settle, liquidate) for a reward."],
          ["Venue", "Where option tokens trade. Optara supports Kuru's order books."],
          ["Kuru MarginAccount", "Kuru's balance contract; limit orders draw from it and fills land in it."],
        ]}
      />
    ),
  },
  {
    slug: "community",
    group: "Resources",
    title: "Community and links",
    description: "Where to follow Optara and get help.",
    keywords: "twitter x social community contact links",
    body: () => (
      <>
        <Lead>Follow Optara for launches, new markets and protocol updates.</Lead>
        <Cards
          items={[
            { title: `X ${SOCIALS.x.handle}`, text: "Announcements, new markets and updates.", to: SOCIALS.x.href, icon: <Sparkles className={ic} /> },
            { title: "Blog", text: "Deep dives on how Optara works and what's new.", to: "/blog", icon: <BookOpen className={ic} /> },
            { title: "Kuru", text: "The order book Optara supports for trading options.", to: "https://docs.kuru.io/", icon: <Layers className={ic} /> },
            { title: "Monad", text: "The chain Optara runs on.", to: "https://docs.monad.xyz/", icon: <Timer className={ic} /> },
          ]}
        />
      </>
    ),
  },
];

export const docBySlug = (slug: string | undefined) => DOCS.find((d) => d.slug === slug);
