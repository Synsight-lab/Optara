import { useEffect, useRef, useState } from "react";
import { useBalance, useConnect, useConnection, useConnectors, useDisconnect } from "wagmi";
import { formatEther } from "viem";
import { IS_LOCAL } from "../config/network.ts";
import { shortAddr } from "../lib/optara/format.ts";
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

  const browser = connectors.filter((c) => c.type !== "test");
  const tests = connectors.filter((c) => c.type === "test");

  return (
    <div className="relative" ref={ref}>
      {isConnected && address ? (
        <button className="btn-ghost" onClick={() => setOpen((o) => !o)} aria-haspopup="menu" aria-expanded={open}>
          <span className="grid h-6 w-6 place-items-center rounded-full bg-gradient-to-br from-monad-purple to-monad-berry text-[10px] font-bold text-white">
            {address.slice(2, 4).toUpperCase()}
          </span>
          <span className="num">{shortAddr(address)}</span>
        </button>
      ) : (
        <button className="btn-primary" onClick={() => setOpen((o) => !o)} disabled={isPending} aria-haspopup="menu" aria-expanded={open}>
          {isPending ? "Connecting…" : "Connect wallet"}
        </button>
      )}
      {open && (
        <div role="menu" className="card rise absolute right-0 z-40 mt-2 w-72 p-2 shadow-2xl">
          {isConnected && address ? (
            <div className="space-y-2 p-2">
              <div className="text-xs text-muted">Connected with {connector?.name}</div>
              <div className="num break-all text-sm font-medium">{address}</div>
              <div className="text-xs text-muted">Gas balance: {gas ? Number(formatEther(gas.value)).toFixed(3) : "…"} {gas?.symbol}</div>
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
              {browser.map((c) => (
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
                  <div className="label px-3 pb-1 pt-3">Local test wallets (funded)</div>
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
