import { useEffect, useMemo, useRef, useState } from "react";
import { useBalance, useConnect, useConnection, useConnectors, useDisconnect } from "wagmi";
import { formatEther } from "viem";
import { IS_LOCAL, IS_LOCAL_FORK } from "../config/network.ts";
import { fmtNative, shortAddr } from "../lib/optara/format.ts";
import { useSeriesList, useTokenBalance } from "../lib/optara/hooks.ts";
import type { Series } from "../lib/optara/types.ts";
import { cx } from "./ui.tsx";

export function ConnectButton() {
  const { address, connector, isConnected } = useConnection();
  const connectors = useConnectors();
  const { connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { data: gas } = useBalance({ address });
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const close = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false);
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);

  // The settlement tokens (USDC, USDT…) the app trades in: their balances show what each trade takes or returns.
  const { data: series } = useSeriesList();
  const assets = useMemo(() => [...new Map((series ?? []).map((s) => [s.settlementAsset, s])).values()], [series]);
  const main = assets.find((a) => a.assetSymbol === "USDC") ?? assets[0];
  const { data: mainBal } = useTokenBalance(main?.settlementAsset, address);

  const browser = connectors.filter((c) => c.type !== "test");
  const tests = connectors.filter((c) => c.type === "test");

  return (
    <div className="relative" ref={ref}>
      {isConnected && address ? (
        <button className="btn-ghost" onClick={() => setOpen((o) => !o)} aria-haspopup="menu" aria-expanded={open}>
          <span className="grid h-6 w-6 place-items-center rounded-full bg-gradient-to-br from-monad-purple to-monad-berry text-[10px] font-bold text-white">
            {address.slice(2, 4).toUpperCase()}
          </span>
          <span className="num hidden sm:inline">{shortAddr(address)}</span>
          {main && (
            <span className="num rounded-lg bg-surface-2 px-2 py-0.5 text-[13px] font-semibold" title={`${main.assetSymbol} in your wallet`}>
              {mainBal !== undefined ? fmtNative(mainBal, main.assetDecimals) : "…"} {main.assetSymbol}
            </span>
          )}
        </button>
      ) : (
        <button className="btn-primary whitespace-nowrap" aria-label="Connect wallet" onClick={() => setOpen((o) => !o)} disabled={isPending} aria-haspopup="menu" aria-expanded={open}>
          {isPending ? "Connecting…" : (
            <>
              Connect<span className="hidden lg:inline"> wallet</span>
            </>
          )}
        </button>
      )}
      {open && (
        <div role="menu" className="card rise absolute right-0 z-40 mt-2 w-72 p-2 shadow-2xl">
          {isConnected && address ? (
            <div className="space-y-2 p-2">
              <div className="text-xs text-muted">Connected with {connector?.name}</div>
              <div className="num break-all text-sm font-medium">{address}</div>
              <div className="rounded-xl border border-line bg-surface-2/60 p-2.5">
                <div className="label mb-1">In your wallet</div>
                {assets.map((a) => (
                  <WalletBalance key={a.settlementAsset} asset={a} owner={address} />
                ))}
                <div className="flex justify-between text-[13px] text-muted">
                  <span>Gas</span>
                  <span className="num">
                    {gas ? Number(formatEther(gas.value)).toFixed(3) : "…"} {gas?.symbol}
                  </span>
                </div>
              </div>
              <p className="text-xs text-muted">Buying, adding cash and writing take from these balances; selling, withdrawing and redeeming add to them.</p>
              <button
                className="btn-ghost mt-2 w-full"
                onClick={() => {
                  disconnect();
                  setOpen(false);
                }}
              >
                Disconnect
              </button>
            </div>
          ) : (
            <>
              {IS_LOCAL_FORK && (
                <p className="px-3 pb-1 pt-2 text-xs leading-relaxed text-warn">
                  This is a local copy of a real network, with the same network id. A browser wallet would send transactions
                  to the real network, so use a test wallet below.
                </p>
              )}
              {!IS_LOCAL_FORK && browser.map((c) => (
                <button key={c.uid} role="menuitem" className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm hover:bg-primary-soft" onClick={() => (connect({ connector: c }), setOpen(false))}>
                  <span className="grid h-8 w-8 place-items-center rounded-lg bg-primary-soft text-primary">⬡</span>
                  <span>
                    <span className="block font-medium">{c.name === "Injected" ? "Browser wallet" : c.name}</span>
                    <span className="block text-xs text-muted">MetaMask, Rabby, Phantom…</span>
                  </span>
                </button>
              ))}
              {IS_LOCAL && tests.length > 0 && (
                <>
                  <div className="label px-3 pb-0.5 pt-3">Local test wallets (funded)</div>
                  <p className="px-3 pb-1.5 text-xs text-muted">You'll approve each transaction in an Optara window.</p>
                  {tests.map((c, i) => (
                    <button key={c.uid} role="menuitem" className={cx("flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-sm hover:bg-primary-soft")} onClick={() => (connect({ connector: c }), setOpen(false))}>
                      <span className="grid h-7 w-7 place-items-center rounded-full bg-gradient-to-br from-monad-purple to-monad-deep text-xs font-bold text-white">{c.name[0]}</span>
                      <span className="font-medium">{c.name.replace(" (test wallet)", "")}</span>
                      <span className="ml-auto text-xs text-muted">#{i + 1}</span>
                    </button>
                  ))}
                </>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function WalletBalance({ asset, owner }: { asset: Series; owner: `0x${string}` }) {
  const { data } = useTokenBalance(asset.settlementAsset, owner);
  return (
    <div className="flex justify-between text-[13px]">
      <span className="font-medium">{asset.assetSymbol}</span>
      <span className="num font-semibold">{data !== undefined ? fmtNative(data, asset.assetDecimals) : "…"}</span>
    </div>
  );
}
