/** App-wide state: the selected subaccount per wallet, toasts, theme. */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useConnection } from "wagmi";
import type { Address, Hex } from "viem";
import { useAccounts } from "./lib/optara/hooks.ts";

// ------------------------------------------------------------------ selected account

interface AccountState {
  owner?: Address;
  accounts: bigint[];
  loading: boolean;
  selected?: bigint;
  select(id: bigint): void;
  refresh(): Promise<unknown>;
}

const AccountCtx = createContext<AccountState>({ accounts: [], loading: false, select: () => {}, refresh: async () => {} });

export function AccountProvider({ children }: { children: ReactNode }) {
  const { address } = useConnection();
  const { data, isLoading, refetch } = useAccounts(address);
  const key = address ? `optara.account.${address.toLowerCase()}` : undefined;
  const [chosen, setChosen] = useState<bigint | undefined>();
  const [optimisticAccounts, setOptimisticAccounts] = useState<bigint[]>([]);

  useEffect(() => {
    setOptimisticAccounts([]);
    if (!key) return setChosen(undefined);
    try {
      const v = localStorage.getItem(key);
      setChosen(v ? BigInt(v) : undefined);
    } catch {
      setChosen(undefined);
    }
  }, [key]);

  const accounts = useMemo(() => {
    const base = data ?? [];
    if (optimisticAccounts.length === 0) return base;
    const merged = [...base];
    for (const id of optimisticAccounts) {
      if (!merged.includes(id)) merged.push(id);
    }
    return merged.sort((a, b) => Number(a - b));
  }, [data, optimisticAccounts]);
  const selected = chosen !== undefined && accounts.includes(chosen) ? chosen : accounts[0];
  const select = useCallback(
    (id: bigint) => {
      setOptimisticAccounts((xs) => (xs.includes(id) ? xs : [...xs, id]));
      setChosen(id);
      try {
        if (key) localStorage.setItem(key, id.toString());
      } catch {
        // storage unavailable: selection lasts for the session
      }
    },
    [key],
  );
  const value = useMemo(() => ({ owner: address, accounts, loading: isLoading, selected, select, refresh: refetch }), [address, accounts, isLoading, selected, select, refetch]);
  return <AccountCtx.Provider value={value}>{children}</AccountCtx.Provider>;
}

export const useAccountState = () => useContext(AccountCtx);

// ------------------------------------------------------------------ toasts

export interface Toast {
  id: number;
  tone: "good" | "bad" | "info";
  title: string;
  body?: string;
  hash?: Hex;
}

const ToastCtx = createContext<{ toasts: Toast[]; push(t: Omit<Toast, "id">): void; dismiss(id: number): void }>({ toasts: [], push: () => {}, dismiss: () => {} });

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const next = useRef(1);
  const dismiss = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  const push = useCallback(
    (t: Omit<Toast, "id">) => {
      const id = next.current++;
      setToasts((all) => [...all.slice(-3), { ...t, id }]);
      setTimeout(() => dismiss(id), t.tone === "bad" ? 9_000 : 5_000);
    },
    [dismiss],
  );
  return <ToastCtx.Provider value={{ toasts, push, dismiss }}>{children}</ToastCtx.Provider>;
}

export const useToasts = () => useContext(ToastCtx);

// ------------------------------------------------------------------ educational guide modal

const GuideCtx = createContext<{ isOpen: boolean; open(): void; close(): void }>({
  isOpen: false,
  open: () => {},
  close: () => {},
});

export function GuideProvider({ children }: { children: ReactNode }) {
  const [isOpen, setIsOpen] = useState(false);
  const open = useCallback(() => setIsOpen(true), []);
  const close = useCallback(() => setIsOpen(false), []);
  return <GuideCtx.Provider value={{ isOpen, open, close }}>{children}</GuideCtx.Provider>;
}

export const useQuickGuide = () => useContext(GuideCtx);

// ------------------------------------------------------------------ theme

export function useTheme(): ["dark" | "light", () => void] {
  const [theme, setTheme] = useState<"dark" | "light">(() => {
    try {
      return (localStorage.getItem("optara.theme") as "dark" | "light") ?? "light";
    } catch {
      return "light";
    }
  });
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem("optara.theme", theme);
    } catch {
      // storage unavailable
    }
  }, [theme]);
  return [theme, () => setTheme((t) => (t === "dark" ? "light" : "dark"))];
}
