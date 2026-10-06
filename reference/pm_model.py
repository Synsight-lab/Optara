"""Optara PM reference model (Python, standard library only).

An independent implementation of docs/MATH.md, written from the spec rather than from Solidity. It is used by
verify_math.py (properties and worked examples) and verify_invariants.py (stateful simulation).

Pricing and margin use doubles, with math.erf as the high-precision reference for the normal CDF. Settlement,
fees and rounding use exact Python integers in the same units as the contracts.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

WAD = 10**18
YEAR = 31_536_000
BPS = 10_000

# ---------------------------------------------------------------------------------------------------------------
# Normal CDF
# ---------------------------------------------------------------------------------------------------------------


def ncdf_ref(x: float) -> float:
    """Reference standard normal CDF (double precision, error ~1e-16)."""
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


def ncdf_nr(x: float) -> float:
    """Numerical Recipes erfcc, the formula OptionPricer.normCdf implements (MATH.md section 6).
    Relative erfc error < 1.2e-7 everywhere, so the CDF's absolute error is < 6e-8 and the tails stay accurate."""
    if x == 0:
        return 0.5
    z = abs(x) / math.sqrt(2.0)
    t = 1.0 / (1.0 + 0.5 * z)
    poly = t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (
        -1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277))))))))
    h = 0.5 * t * math.exp(-z * z - 1.26551223 + poly)
    return 1.0 - h if x > 0 else h


def ncdf_as(x: float) -> float:
    """Abramowitz & Stegun 7.1.26. REJECTED for the contracts (MATH.md section 6): its absolute error passes
    (<= 7.5e-8) but its relative error in the tails reaches 100%. Kept only as evidence for verify_math M1."""
    z = abs(x) / math.sqrt(2.0)
    t = 1.0 / (1.0 + 0.3275911 * z)
    poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
    erf = 1.0 - poly * math.exp(-z * z)
    return 0.5 * (1.0 + erf) if x >= 0 else 0.5 * (1.0 - erf)


# ---------------------------------------------------------------------------------------------------------------
# Payoff and Black-76 (MATH.md sections 3 and 6)
# ---------------------------------------------------------------------------------------------------------------


def intrinsic(is_call: bool, S: float, K: float) -> float:
    return max(S - K, 0.0) if is_call else max(K - S, 0.0)


# The CDF used when black76 is called without one. ffi.py switches it to ncdf_nr to compare with the contracts
# exactly (they implement NR erfcc); everything else uses the exact reference.
DEFAULT_CDF = None


def black76(is_call: bool, F: float, K: float, sigma: float, T: float, cdf=None) -> float:
    """Per-unit option price, zero rates, F = spot. Floored at intrinsic; call <= F, put <= K."""
    cdf = cdf or DEFAULT_CDF or ncdf_ref
    if T <= 0.0 or sigma <= 0.0 or F <= 0.0:
        return intrinsic(is_call, F, K)
    v = sigma * math.sqrt(T)
    d1 = (math.log(F / K) + 0.5 * v * v) / v
    d2 = d1 - v
    if is_call:
        p = F * cdf(d1) - K * cdf(d2)
        p = min(p, F)
    else:
        p = K * cdf(-d2) - F * cdf(-d1)
        p = min(p, K)
    return max(p, intrinsic(is_call, F, K))


# ---------------------------------------------------------------------------------------------------------------
# Implied volatility from a surface grid (MATH.md section 5)
# ---------------------------------------------------------------------------------------------------------------


def iv_from_surface(K: float, S: float, tau: float, report_time: float, tenors: list[float], knodes: list[float],
                    w: list[list[float]], min_iv: float, max_iv: float) -> float:
    """w[i][j] = total variance at tenor i, node j. tau / tenors / report_time in seconds."""
    if tau < tenors[0] or tau > tenors[-1]:
        raise ValueError("series not priceable: expiry outside tenor range")
    k = math.log(K / S)

    def at_tenor(i: int) -> float:
        if k <= knodes[0]:
            return w[i][0]
        if k >= knodes[-1]:
            return w[i][-1]
        for j in range(len(knodes) - 1):
            if knodes[j] <= k <= knodes[j + 1]:
                x = (k - knodes[j]) / (knodes[j + 1] - knodes[j])
                return w[i][j] + (w[i][j + 1] - w[i][j]) * x
        raise AssertionError

    a = max(i for i in range(len(tenors)) if tenors[i] <= tau)
    b = min(i for i in range(len(tenors)) if tenors[i] >= tau)
    Ta, Tb, Tt = ((t - report_time) / YEAR for t in (tenors[a], tenors[b], tau))
    wa, wb = at_tenor(a), at_tenor(b)
    wt = wa if a == b else wa + (wb - wa) * (Tt - Ta) / (Tb - Ta)
    sigma = math.sqrt(wt / Tt)
    return min(max(sigma, min_iv), max_iv)


# ---------------------------------------------------------------------------------------------------------------
# Margin (MATH.md sections 7-9)
# ---------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Scenario:
    spot_bps: int
    vol_bps: int
    time_mode: int = 0       # 0 now, 1 near-expiry floor, 2 shift
    shift: float = 0.0       # seconds, time_mode 2


SPOTS_IM = [-5000, -3000, -1500, 0, 1500, 3000, 5000, 10000]
IM_SET = ([Scenario(s, -3000) for s in SPOTS_IM] + [Scenario(s, 7500) for s in SPOTS_IM]
          + [Scenario(s, 0, 1) for s in SPOTS_IM])
SPOTS_MM = [-3000, -1500, 0, 1500, 3000, 5000]
MM_SET = [Scenario(s, -3000) for s in SPOTS_MM] + [Scenario(s, 3000) for s in SPOTS_MM]


@dataclass
class RiskParams:
    im_set: list = field(default_factory=lambda: list(IM_SET))
    mm_set: list = field(default_factory=lambda: list(MM_SET))
    im_buffer_bps: int = 500
    min_iv: float = 0.10
    max_iv: float = 5.0
    near_expiry_floor: float = 3600.0


@dataclass
class Leg:
    underlying: str
    is_call: bool
    K: float
    CS: float
    expiry: float          # seconds
    q: float               # signed quantity in options (+ long, - short)
    sigma: float           # fresh IV
    sigma_short: float | None = None   # stale-adjusted IVs (MATH.md 5.1); None = fresh
    sigma_long: float | None = None
    long_intrinsic_only: bool = False
    finalized_payoff: float | None = None   # per-unit payoff once finalized-unsettled


def leg_unit_price(leg: Leg, S: float, now: float, sc: Scenario | None, p: RiskParams) -> float:
    if leg.finalized_payoff is not None:
        return leg.finalized_payoff        # exact, no scenarios
    T = max(leg.expiry - now, 0.0) / YEAR
    sigma = leg.sigma
    if leg.q < 0 and leg.sigma_short is not None:
        sigma = leg.sigma_short
    if leg.q > 0 and leg.sigma_long is not None:
        sigma = leg.sigma_long
    S_s = S
    if sc is not None:
        S_s = S * (BPS + sc.spot_bps) / BPS
        sigma = min(max(sigma * (BPS + sc.vol_bps) / BPS, p.min_iv), p.max_iv)
        if sc.time_mode == 1:
            T = min(T, p.near_expiry_floor / YEAR)
        elif sc.time_mode == 2:
            T = max(T - sc.shift / YEAR, 0.0)
    if leg.q > 0 and leg.long_intrinsic_only:
        return intrinsic(leg.is_call, S_s, leg.K)
    return black76(leg.is_call, S_s, leg.K, sigma, T)


def leg_value(leg: Leg, S: float, now: float, sc: Scenario | None, p: RiskParams) -> float:
    return leg.q * leg.CS * leg_unit_price(leg, S, now, sc, p)


@dataclass
class Risk:
    equity: float
    im: float
    mm: float
    loss_im: float
    loss_mm: float
    buffer: float


def bucket_losses(legs: list[Leg], S: float, now: float, p: RiskParams, scenarios: list[Scenario]) -> float:
    base = sum(leg_value(l, S, now, None, p) for l in legs)
    worst = 0.0
    for sc in scenarios:
        v = sum(leg_value(l, S, now, sc, p) for l in legs)
        worst = max(worst, base - v)
    return worst


def account_risk(cash: float, legs: list[Leg], spots: dict[str, float], now: float, p: RiskParams,
                 legacy_buffer: bool = False, union: bool = True) -> Risk:
    """Spec margin. legacy_buffer/union=False reproduce the earlier draft (for regression evidence only)."""
    equity = cash + sum(leg_value(l, spots[l.underlying], now, None, p) for l in legs)
    buckets: dict[str, list[Leg]] = {}
    for l in legs:
        buckets.setdefault(l.underlying, []).append(l)
    im_scen = p.im_set + p.mm_set if union else p.im_set
    loss_im = sum(bucket_losses(b, spots[u], now, p, im_scen) for u, b in buckets.items())
    loss_mm = sum(bucket_losses(b, spots[u], now, p, p.mm_set) for u, b in buckets.items())
    if legacy_buffer:
        buffer = loss_im * p.im_buffer_bps / BPS
    else:
        short_mark = sum(-leg_value(l, spots[l.underlying], now, None, p) for l in legs if l.q < 0)
        buffer = short_mark * p.im_buffer_bps / BPS
    return Risk(equity, loss_im + buffer, loss_mm, loss_im, loss_mm, buffer)


def health_state(r: Risk) -> str:
    if r.equity >= r.im:
        return "HEALTHY"
    if r.equity >= r.mm:
        return "CLOSE_ONLY"
    return "LIQUIDATABLE"


# ---------------------------------------------------------------------------------------------------------------
# Fees (MATH.md section 11), exact integers in native units
# ---------------------------------------------------------------------------------------------------------------


def ceil_div(a: int, b: int) -> int:
    return -((-a) // b)


def seller_fee_native(mark_wad: int, fee_bps: int, decimals: int, min_fee: int) -> int:
    scale = 10 ** (18 - decimals)
    return max(ceil_div(mark_wad * fee_bps, BPS * scale), min_fee)


def split_fee(fee: int, ins_bps: int = 6000, keeper_bps: int = 1000) -> tuple[int, int, int]:
    ins = fee * ins_bps // BPS
    keeper = fee * keeper_bps // BPS
    return ins, keeper, fee - ins - keeper


# ---------------------------------------------------------------------------------------------------------------
# Liquidation (MATH.md section 12)
# ---------------------------------------------------------------------------------------------------------------


@dataclass
class SliceResult:
    slice_mark: float
    slice_mm: float
    discount: float
    penalty: float
    cash_to_liq: float
    insurance_topup: float
    unpaid: float


def liquidation_cash(slice_mark: float, slice_mm: float, bonus_bps: int, penalty_bps: int, cash: float,
                     insurance_avail: float) -> SliceResult:
    discount = slice_mm * bonus_bps / BPS
    penalty = slice_mm * penalty_bps / BPS
    if slice_mark < 0:
        owed = -slice_mark + discount
    else:
        owed = -max(0.0, slice_mark - discount)      # negative = liquidator pays the account
    topup = unpaid = 0.0
    if owed > cash:                                   # liquidator first, penalty reduced to zero
        topup = min(owed - cash, insurance_avail)
        unpaid = owed - cash - topup
        penalty = 0.0
    else:
        penalty = min(penalty, cash - owed)
    return SliceResult(slice_mark, slice_mm, discount, penalty, owed, topup, unpaid)


# ---------------------------------------------------------------------------------------------------------------
# Settlement (MATH.md section 13), exact integers
# ---------------------------------------------------------------------------------------------------------------


@dataclass
class SeriesInt:
    is_call: bool
    K: int          # WAD
    CS: int         # WAD


def intrinsic_int(s: SeriesInt, S: int) -> int:
    return max(S - s.K, 0) if s.is_call else max(s.K - S, 0)


@dataclass
class GroupResult:
    collected: int
    unpaid: int
    gross_claim_n: int
    wrapper_claim_n: int
    net_credit_n: int
    insurance: int
    available: int
    ratio_wad: int
    credits_n: dict
    cash_after: dict


def settle_group(series: dict, balances: dict, cash: dict, wrapper_supply: dict, S_star: int, decimals: int,
                 insurance_balance: int) -> GroupResult:
    """balances[a][sid] = signed qty (1e18). Returns netted results; credits paid later at the ratio."""
    D = 10 ** (54 - decimals)
    collected = unpaid = 0
    credits: dict = {}
    cash_after = dict(cash)
    net_credit_n = 0
    for a, pos in balances.items():
        N = sum(q * intrinsic_int(series[sid], S_star) * series[sid].CS for sid, q in pos.items())
        if N < 0:
            debt = ceil_div(-N, D)
            c = min(cash_after[a], debt)
            cash_after[a] -= c
            collected += c
            unpaid += debt - c
        elif N > 0:
            credits[a] = N
            net_credit_n += N
    wrapper_n = sum(w * intrinsic_int(series[sid], S_star) * series[sid].CS for sid, w in wrapper_supply.items())
    gross_n = wrapper_n + net_credit_n
    gross = ceil_div(gross_n, D)
    shortfall = max(0, gross - collected)
    ins = min(shortfall, insurance_balance)
    available = collected + ins
    ratio = WAD if gross_n == 0 else min(WAD, available * D * WAD // gross_n)
    return GroupResult(collected, unpaid, gross_n, wrapper_n, net_credit_n, ins, available, ratio, credits, cash_after)


def redeem_amount(s: SeriesInt, qty: int, S_star: int, ratio_wad: int, decimals: int) -> int:
    D = 10 ** (54 - decimals)
    return qty * intrinsic_int(s, S_star) * s.CS * ratio_wad // (D * WAD)


def claim_amount(credit_n: int, ratio_wad: int, decimals: int) -> int:
    D = 10 ** (54 - decimals)
    return credit_n * ratio_wad // (D * WAD)
