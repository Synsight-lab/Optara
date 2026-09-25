import type { ReactNode } from "react";
import { NavLink } from "react-router";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { chain, manifest } from "../config/wagmi.ts";
import { shortHex } from "../lib/optara/format.ts";

function WalletButton() {
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  if (!isConnected) {
    return (
      <button className="rounded bg-indigo-600 px-3 py-1.5 text-sm font-medium hover:bg-indigo-500" disabled={isPending}
        onClick={() => connectors[0] && connect({ connector: connectors[0] })}>
        Connect wallet
      </button>
    );
  }
  if (chainId !== chain.id) {
    return (
      <button className="rounded bg-amber-600 px-3 py-1.5 text-sm" onClick={() => switchChain({ chainId: chain.id })}>
        Wrong network — switch to {chain.name}
      </button>
    );
  }
  return (
    <button className="rounded border border-slate-700 px-3 py-1.5 text-sm" onClick={() => disconnect()} title="Disconnect">
      {shortHex(address!, 4)}
    </button>
  );
}

export function Layout({ children }: { children: ReactNode }) {
  const link = ({ isActive }: { isActive: boolean }) => `px-3 py-1.5 rounded text-sm ${isActive ? "bg-slate-800" : "hover:bg-slate-900"}`;
  return (
    <div className="mx-auto max-w-6xl px-4 py-4">
      <header className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-4">
          <span className="text-lg font-semibold">Optara</span>
          <nav className="flex gap-1">
            <NavLink to="/" className={link} end>Markets</NavLink>
            <NavLink to="/portfolio" className={link}>Portfolio</NavLink>
            <NavLink to="/settlement" className={link}>Settlement</NavLink>
          </nav>
        </div>
        <div className="flex items-center gap-3 text-xs text-slate-400">
          <span>{chain.name} · core {shortHex(manifest.contracts.OptaraCore, 4)}</span>
          <WalletButton />
        </div>
      </header>
      <main>{children}</main>
      <footer className="mt-10 border-t border-slate-800 pt-4 text-xs text-slate-500">
        Figures shown here are previews read from the Optara contracts. The contracts recompute every safety check when
        your transaction executes; a preview can go stale before inclusion.
      </footer>
    </div>
  );
}
