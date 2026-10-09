/**
 * FRONTEND.md §7: every limit the user signs (premium budget, minimum quantity, maximum Optara fee, maximum order-book
 * fee, minimum proceeds) is shown, with a default slippage of 1% that the user can change. The choice is remembered
 * on this device.
 */
import { useCallback, useEffect, useState } from "react";

export const DEFAULT_SLIPPAGE_BPS = 100;
export const MIN_SLIPPAGE_BPS = 10; // 0.1%: tighter fails on any price tick
export const MAX_SLIPPAGE_BPS = 1000; // 10%: beyond that the limit stops protecting anything
export const SLIPPAGE_PRESETS = [50, 100, 200, 300];

const KEY = "optara.slippageBps";
const EVENT = "optara:slippage";

export const clampSlippage = (bps: number) => Math.round(Math.min(MAX_SLIPPAGE_BPS, Math.max(MIN_SLIPPAGE_BPS, bps)));

function read(): number {
  try {
    const v = Number(localStorage.getItem(KEY));
    return v ? clampSlippage(v) : DEFAULT_SLIPPAGE_BPS;
  } catch {
    return DEFAULT_SLIPPAGE_BPS;
  }
}

/** An upper limit: the amount plus slippage, rounded up (fees, budgets). */
export const withSlip = (x: bigint, bps: number) => (x * BigInt(10_000 + bps)) / 10_000n + 1n;
/** A lower limit: the amount minus slippage (minimum quantity, minimum proceeds). */
export const lessSlip = (x: bigint, bps: number) => (x * BigInt(10_000 - bps)) / 10_000n;

/** The shared slippage setting; every form updates when it changes anywhere. */
export function useSlippage(): [number, (bps: number) => void] {
  const [bps, setLocal] = useState(read);
  useEffect(() => {
    const sync = () => setLocal(read());
    window.addEventListener(EVENT, sync);
    window.addEventListener("storage", sync);
    return () => (window.removeEventListener(EVENT, sync), window.removeEventListener("storage", sync));
  }, []);
  const set = useCallback((v: number) => {
    const c = clampSlippage(v);
    setLocal(c);
    try {
      localStorage.setItem(KEY, String(c));
    } catch {
      // storage unavailable: the setting lasts for this page
    }
    window.dispatchEvent(new Event(EVENT));
  }, []);
  return [bps, set];
}
