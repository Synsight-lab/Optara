"""Verify Optara PM core math (docs/MATH.md) with randomized property tests and the docs' worked examples.

Run:  python3 reference/verify_math.py [--seed N] [--n N]
Exit code 0 = every check passed.
"""
from __future__ import annotations

import argparse
import math
import random
import sys
from fractions import Fraction

import pm_model as m

DAY = 86400.0
RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))


def close(a: float, b: float, tol: float = 1e-9) -> bool:
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


# ---------------------------------------------------------------------------------------------------------------
# Random generators
# ---------------------------------------------------------------------------------------------------------------


def rand_leg(rng: random.Random, S: float, underlying: str = "ETH", sign: int = 0) -> m.Leg:
    q = rng.choice([-1, 1]) * rng.uniform(0.05, 5.0) if sign == 0 else sign * rng.uniform(0.05, 5.0)
    return m.Leg(underlying=underlying, is_call=rng.random() < 0.5, K=S * rng.uniform(0.5, 1.6),
                 CS=rng.choice([1.0, 0.1, 10.0]), expiry=rng.uniform(1, 120) * DAY, q=q,
                 sigma=rng.uniform(0.2, 1.5))


def rand_portfolio(rng: random.Random, S: float, n_max: int = 6, underlying: str = "ETH") -> list[m.Leg]:
    return [rand_leg(rng, S, underlying) for _ in range(rng.randint(1, n_max))]


P = m.RiskParams()

# ---------------------------------------------------------------------------------------------------------------
# M1-M3 Pricing
# ---------------------------------------------------------------------------------------------------------------


def m1_cdf() -> None:
    xs = [x / 1000 for x in range(-37000, 37001)]
    worst = max(abs(m.ncdf_nr(x) - m.ncdf_ref(x)) for x in xs)
    # relative accuracy in the lower tail is what keeps deep out-of-the-money prices meaningful
    tail = max(abs(m.ncdf_nr(x) - m.ncdf_ref(x)) / m.ncdf_ref(x) for x in xs if x < 0)
    tail_as = max(abs(m.ncdf_as(x) - m.ncdf_ref(x)) / m.ncdf_ref(x) for x in xs if x < 0)
    check("M1 normal CDF (NR erfcc) abs error <= 1e-7 and tail relative error <= 2e-7 (MATH 6)",
          worst <= 1e-7 and tail <= 2e-7 and tail_as > 0.5,
          f"abs {worst:.2e}, tail rel {tail:.2e} (A&S 7.1.26 tail rel {tail_as:.2f}, rejected)")


def m2_black76(rng: random.Random, n: int) -> None:
    bad = []
    for _ in range(n):
        F = rng.uniform(1, 10000)
        K = F * rng.uniform(0.2, 3.0)
        sig = rng.uniform(0.01, 3.0)
        T = rng.uniform(0, 2)
        c = m.black76(True, F, K, sig, T)
        p = m.black76(False, F, K, sig, T)
        if c < m.intrinsic(True, F, K) - 1e-9 or c > F + 1e-9:
            bad.append(("call bounds", F, K, sig, T))
        if p < m.intrinsic(False, F, K) - 1e-9 or p > K + 1e-9:
            bad.append(("put bounds", F, K, sig, T))
        if T > 0 and abs((c - p) - (F - K)) > 1e-7 * max(F, K):
            bad.append(("parity", F, K, sig, T))
        dF, ds, dT = F * 1.01, sig * 1.1, T + 0.05
        if m.black76(True, dF, K, sig, T) < c - 1e-9 or m.black76(False, dF, K, sig, T) > p + 1e-9:
            bad.append(("spot monotonicity", F, K, sig, T))
        if m.black76(True, F, K, ds, T) < c - 1e-9 or m.black76(False, F, K, ds, T) < p - 1e-9:
            bad.append(("vol monotonicity", F, K, sig, T))
        if m.black76(True, F, K, sig, dT) < c - 1e-9:
            bad.append(("time monotonicity", F, K, sig, T))
    check("M2 Black-76 bounds, put-call parity, monotonicity in spot/vol/time", not bad, f"{len(bad)} violations"
          + (f", first {bad[0]}" if bad else f" in {n} random cases"))


def m3_approx_pricing(rng: random.Random, n: int) -> None:
    worst = 0.0
    for _ in range(n):
        F = rng.uniform(1, 10000)
        K = F * rng.uniform(0.3, 3.0)
        sig, T = rng.uniform(0.05, 3.0), rng.uniform(1 / 365, 2)
        for call in (True, False):
            a = m.black76(call, F, K, sig, T, cdf=m.ncdf_nr)
            r = m.black76(call, F, K, sig, T)
            worst = max(worst, abs(a - r) / (F + K))
    # |dC| <= F*eps + K*eps with eps = CDF error (<= 1e-7), so the bound is (F + K) * 1e-7.
    check("M3 Black-76 with the approximate CDF stays within (F+K) x 1e-7 of the reference", worst <= 1e-7,
          f"max |diff|/(F+K) {worst:.2e}")


# ---------------------------------------------------------------------------------------------------------------
# M4 Interpolation
# ---------------------------------------------------------------------------------------------------------------


def m4_interp(rng: random.Random, n: int) -> None:
    bad = 0
    for _ in range(n):
        t0 = 0.0
        tenors = sorted(rng.sample(range(7, 400), 4))
        tenors = [t * DAY for t in tenors]
        knodes = sorted(rng.sample([x / 10 for x in range(-15, 16)], 6))
        base = [rng.uniform(0.04, 1.0) for _ in knodes]                       # IV^2 at each node
        w = []
        acc = [0.0] * len(knodes)
        for i, t in enumerate(tenors):                                         # nondecreasing in tenor
            acc = [max(acc[j], base[j] * (t / m.YEAR) * rng.uniform(1.0, 1.3)) for j in range(len(knodes))]
            w.append(list(acc))
        S = 1000.0
        tau = rng.uniform(tenors[0], tenors[-1])
        K = S * math.exp(rng.uniform(-2, 2))
        sig = m.iv_from_surface(K, S, tau, t0, tenors, knodes, w, 0.0, 100.0)
        wt = sig * sig * tau / m.YEAR
        lo = min(min(r) for r in w)
        hi = max(max(r) for r in w)
        if not (lo - 1e-12 <= wt <= hi + 1e-12):
            bad += 1
        # exact at grid nodes
        i, j = rng.randrange(4), rng.randrange(len(knodes))
        Kn = S * math.exp(knodes[j])
        sn = m.iv_from_surface(Kn, S, tenors[i], t0, tenors, knodes, w, 0.0, 100.0)
        if not close(sn * sn * tenors[i] / m.YEAR, w[i][j], 1e-9):
            bad += 1
        # calendar: total variance nondecreasing in expiry for a fixed strike
        tau2 = rng.uniform(tau, tenors[-1])
        s2 = m.iv_from_surface(K, S, tau2, t0, tenors, knodes, w, 0.0, 100.0)
        if s2 * s2 * tau2 < sig * sig * tau * (1 - 1e-9):
            bad += 1
    check("M4 surface interpolation: bounded by grid, exact at nodes, calendar-monotone", bad == 0,
          f"{bad} violations in {n} cases")


# ---------------------------------------------------------------------------------------------------------------
# M5 Worked examples in the docs
# ---------------------------------------------------------------------------------------------------------------


def m5_examples() -> None:
    S, now = 4000.0, 0.0
    exp = 30 * DAY
    c45 = m.black76(True, S, 4500, 0.60, 30 / 365)
    c50 = m.black76(True, S, 5000, 0.62, 30 / 365)
    p35 = m.black76(False, S, 3500, 0.65, 30 / 365)
    check("M5a example prices 106.77 / 39.65 / 96.62 (MATH 10)",
          (round(c45, 2), round(c50, 2), round(p35, 2)) == (106.77, 39.65, 96.62),
          f"{c45:.2f} {c50:.2f} {p35:.2f}")

    def risk(legs):
        return m.account_risk(0.0, legs, {"ETH": S}, now, P)

    naked = risk([m.Leg("ETH", True, 4500, 1, exp, -1, 0.60)])
    spread = risk([m.Leg("ETH", True, 4500, 1, exp, -1, 0.60), m.Leg("ETH", True, 5000, 1, exp, 1, 0.62)])
    put = risk([m.Leg("ETH", False, 3500, 1, exp, -1, 0.65)])
    got = [(round(r.loss_im, 2), round(r.im, 2), round(r.mm, 2), round(r.im - r.equity, 2))
           for r in (naked, spread, put)]
    want = [(3412.44, 3417.78, 1447.43, 3524.55), (432.88, 438.22, 413.06, 505.34),
            (1418.40, 1423.23, 676.31, 1519.85)]
    check("M5b margin table (maxLoss, IM, MM, cash needed) matches MATH 10", got == want, f"got {got}")

    # Liquidation example (MATH 12.1)
    S2, now2 = 6200.0, 10 * DAY
    leg = m.Leg("ETH", True, 4500, 1, exp, -1, 0.60)
    r0 = m.account_risk(3700.0, [leg], {"ETH": S2}, now2, P)
    mark = m.leg_value(leg, S2, now2, None, P)
    f = 0.25
    res = m.liquidation_cash(f * mark, f * r0.mm, 500, 200, 3700.0, 0.0)
    leg_after = m.Leg("ETH", True, 4500, 1, exp, -0.75, 0.60)
    r1 = m.account_risk(3700.0 - res.cash_to_liq - res.penalty, [leg_after], {"ETH": S2}, now2, P)
    got = (round(mark, 2), round(r0.equity, 2), round(r0.mm, 2), round(res.cash_to_liq, 2), round(res.penalty, 2),
           round(r0.equity - r0.mm, 2), round(r1.equity - r1.mm, 2))
    want = (-1702.86, 1997.14, 3097.15, 464.43, 15.49, -1100.01, -379.92)
    check("M5c liquidation example matches MATH 12.1", got == want, f"got {got}")

    # Settlement example (MATH 13.2)
    W = m.WAD
    X, Y = m.SeriesInt(True, 4500 * W, W), m.SeriesInt(True, 5000 * W, W)
    series = {"X": X, "Y": Y}
    bal = {"A": {"X": -W, "Y": W}, "B": {"Y": -W}}
    wraps = {"X": W, "Y": 0}
    S_star = 5200 * W
    g = m.settle_group(series, bal, {"A": 10**12, "B": 10**12}, wraps, S_star, 6, 0)
    pay_w = m.redeem_amount(X, W, S_star, g.ratio_wad, 6)
    gross_wrong = (700 + 200) * 10**6
    check("M5d netting example: ratio 1.0, holder gets 700; gross-longs formula would give 0.78",
          g.ratio_wad == W and pay_w == 700 * 10**6 and round(g.collected / gross_wrong, 2) == 0.78,
          f"ratio {g.ratio_wad / W}, pay {pay_w / 1e6}, wrong {g.collected / gross_wrong:.4f}")
    g2 = m.settle_group(series, bal, {"A": 10**12, "B": 50 * 10**6}, wraps, S_star, 6, 100 * 10**6)
    pay2 = m.redeem_amount(X, W, S_star, g2.ratio_wad, 6)
    check("M5e shortfall example: collected 550, insurance 100, ratio 0.9286, holder gets 649.999999 (rounded down)",
          (g2.collected, g2.insurance, round(g2.ratio_wad / W, 4), pay2)
          == (550 * 10**6, 100 * 10**6, 0.9286, 649_999_999),
          f"{g2.collected / 1e6} {g2.insurance / 1e6} {g2.ratio_wad / W:.6f} {pay2 / 1e6}")


# ---------------------------------------------------------------------------------------------------------------
# M6-M12 Margin theorems
# ---------------------------------------------------------------------------------------------------------------


def m6_risk_reducing(rng: random.Random, n: int) -> None:
    """Adding a long, removing (part of) a short, or depositing never lowers equity-IM or equity-MM."""
    bad_im = bad_mm = legacy_bad = 0
    for _ in range(n):
        S = rng.uniform(100, 10000)
        legs = rand_portfolio(rng, S)
        cash = rng.uniform(0, 5000)
        spots = {"ETH": S}
        now = 0.0
        r0 = m.account_risk(cash, legs, spots, now, P)
        l0 = m.account_risk(cash, legs, spots, now, P, legacy_buffer=True)
        action = rng.choice(["add_long", "cut_short", "deposit"])
        if action == "add_long":
            new = legs + [rand_leg(rng, S, sign=+1)]
        elif action == "cut_short" and any(l.q < 0 for l in legs):
            i = rng.choice([i for i, l in enumerate(legs) if l.q < 0])
            new = list(legs)
            cut = rng.uniform(0.1, 1.0)
            new[i] = m.Leg(**{**legs[i].__dict__, "q": legs[i].q * (1 - cut)})
        else:
            new = legs
            cash += rng.uniform(1, 1000)
        r1 = m.account_risk(cash, new, spots, now, P)
        l1 = m.account_risk(cash, new, spots, now, P, legacy_buffer=True)
        tol = 1e-7 * max(1.0, abs(r0.im), abs(r0.equity))
        if r1.equity - r1.im < r0.equity - r0.im - tol:
            bad_im += 1
        if r1.equity - r1.mm < r0.equity - r0.mm - tol:
            bad_mm += 1
        if l1.equity - l1.im < l0.equity - l0.im - tol:
            legacy_bad += 1
    check("M6 risk-reducing actions never lower equity-IM or equity-MM (INV-13)", bad_im == 0 and bad_mm == 0,
          f"IM violations {bad_im}, MM violations {bad_mm} in {n} cases")
    check("M6b evidence: the earlier draft buffer (% of loss) DID violate INV-13", legacy_bad > 0,
          f"{legacy_bad} violations with buffer = imBufferBps x loss (why the spec changed)")


def m7_mm_le_im(rng: random.Random, n: int) -> None:
    bad = non_union_bad = 0
    for _ in range(n):
        S = rng.uniform(100, 10000)
        legs = rand_portfolio(rng, S, 8)
        r = m.account_risk(0.0, legs, {"ETH": S}, 0.0, P)
        if r.mm > r.im + 1e-9 * max(1, r.im):
            bad += 1
        nu = m.account_risk(0.0, legs, {"ETH": S}, 0.0, m.RiskParams(im_buffer_bps=0), union=False)
        if nu.mm > nu.loss_im + 1e-9 * max(1, nu.loss_im):
            non_union_bad += 1
    check("M7 MM <= IM always, because the IM loss uses IM set U MM set (INV-14)", bad == 0, f"{bad} violations")
    check("M7b evidence: with separate sets MM can exceed IM", True,
          f"{non_union_bad} portfolios had maxLoss_MM > maxLoss_IM without the union (why the spec changed)")


def m8_scaling(rng: random.Random, n: int) -> None:
    bad = 0
    for _ in range(n):
        S = rng.uniform(100, 10000)
        legs = rand_portfolio(rng, S)
        f = rng.uniform(0.01, 0.99)
        scaled = [m.Leg(**{**l.__dict__, "q": l.q * (1 - f)}) for l in legs]
        a = m.account_risk(0.0, legs, {"ETH": S}, 0.0, P)
        b = m.account_risk(0.0, scaled, {"ETH": S}, 0.0, P)
        if not close(b.mm, (1 - f) * a.mm, 1e-9) or not close(b.loss_im, (1 - f) * a.loss_im, 1e-9):
            bad += 1
    check("M8 margin is homogeneous: scaling every position by (1-f) scales MM and IM loss by (1-f)", bad == 0,
          f"{bad} violations in {n} cases")


def m9_liquidation(rng: random.Random, n: int) -> None:
    bad = cases = short_cash = exact_bad = exact_cases = 0
    for _ in range(n):
        S = rng.uniform(100, 10000)
        legs = rand_portfolio(rng, S)
        spots = {"ETH": S}
        r = m.account_risk(0.0, legs, spots, 0.0, P)
        if r.mm <= 0:
            continue
        mark = r.equity                                  # cash = 0 here, so equity = net mark
        cash = max(0.0, r.mm - mark - rng.uniform(1, r.mm))   # make equity < MM
        r0 = m.account_risk(cash, legs, spots, 0.0, P)
        if r0.equity >= r0.mm:
            continue
        cases += 1
        f = rng.choice([0.05, 0.1, 0.25, 0.5, 1.0])
        bonus, pen = rng.randint(0, 1000), 200
        slice_mark = f * (r0.equity - cash)
        slice_mm = f * r0.mm
        res = m.liquidation_cash(slice_mark, slice_mm, bonus, pen, cash, insurance_avail=1e18)
        remaining = [m.Leg(**{**l.__dict__, "q": l.q * (1 - f)}) for l in legs]
        paid_by_account = min(res.cash_to_liq, cash) if res.cash_to_liq > 0 else res.cash_to_liq
        cash1 = cash - paid_by_account - res.penalty
        r1 = m.account_risk(cash1, remaining, spots, 0.0, P)
        gain = (r1.equity - r1.mm) - (r0.equity - r0.mm)
        floor_gain = slice_mm * (1 - (bonus + pen) / m.BPS)
        tol = 1e-7 * max(1.0, abs(floor_gain), r0.mm)
        if res.cash_to_liq > cash:
            short_cash += 1
        if gain < floor_gain - tol or (slice_mm > 0 and gain <= 0):
            bad += 1
        # Normal case (account pays in full, penalty not reduced, liability slice): equality holds.
        full = (res.cash_to_liq <= cash and slice_mark < 0
                and close(res.penalty, slice_mm * pen / m.BPS, 1e-12))
        if full:
            exact_cases += 1
            if not close(gain, floor_gain, 1e-7):
                exact_bad += 1
    check("M9 every slice improves equity-MM by at least sliceMM x (1-bonus-penalty) (INV-22)", bad == 0,
          f"{bad} violations in {cases} liquidations ({short_cash} with insufficient cash)")
    check("M9b ...and by exactly that amount when the account pays in full", exact_bad == 0,
          f"{exact_bad} mismatches in {exact_cases} full-payment liquidations")


def m10_buckets(rng: random.Random, n: int) -> None:
    bad = 0
    for _ in range(n):
        S_e, S_b = rng.uniform(1000, 5000), rng.uniform(20000, 90000)
        eth = rand_portfolio(rng, S_e, 4, "ETH")
        btc = rand_portfolio(rng, S_b, 4, "BTC")
        spots = {"ETH": S_e, "BTC": S_b}
        both = m.account_risk(0.0, eth + btc, spots, 0.0, P)
        e = m.account_risk(0.0, eth, spots, 0.0, P)
        b = m.account_risk(0.0, btc, spots, 0.0, P)
        if not (close(both.loss_im, e.loss_im + b.loss_im) and close(both.mm, e.mm + b.mm)):
            bad += 1
    check("M10 different underlyings never offset: margin = sum of bucket margins (INV-15)", bad == 0,
          f"{bad} violations")


def m11_stale(rng: random.Random, n: int) -> None:
    bad = 0
    for _ in range(n):
        S = rng.uniform(100, 10000)
        leg = rand_leg(rng, S)
        pen = rng.uniform(0.01, 0.5)
        fresh = m.leg_unit_price(leg, S, 0.0, None, P)
        if leg.q < 0:
            stale_leg = m.Leg(**{**leg.__dict__, "sigma_short": min(leg.sigma + pen, P.max_iv)})
            if m.leg_unit_price(stale_leg, S, 0.0, None, P) < fresh - 1e-9:
                bad += 1
        else:
            stale_leg = m.Leg(**{**leg.__dict__, "sigma_long": max(leg.sigma - pen, P.min_iv)})
            intr_leg = m.Leg(**{**leg.__dict__, "long_intrinsic_only": True})
            if m.leg_unit_price(stale_leg, S, 0.0, None, P) > fresh + 1e-9:
                bad += 1
            if m.leg_unit_price(intr_leg, S, 0.0, None, P) > fresh + 1e-9:
                bad += 1
    check("M11 stale pricing never values a short lower or a long higher (INV-16)", bad == 0, f"{bad} violations")


# ---------------------------------------------------------------------------------------------------------------
# M12-M14 Settlement and fees (exact integers)
# ---------------------------------------------------------------------------------------------------------------


def rand_group(rng: random.Random):
    W = m.WAD
    lot = 10**16
    series = {}
    for i in range(rng.randint(1, 4)):
        series[f"s{i}"] = m.SeriesInt(rng.random() < 0.5, rng.randint(1000, 8000) * W,
                                      rng.choice([W, W // 10, 10 * W]))
    accounts = [f"a{i}" for i in range(rng.randint(1, 6))]
    bal = {a: {} for a in accounts}
    wraps = {s: 0 for s in series}
    holders: dict = {}
    for _ in range(rng.randint(1, 12)):                       # mints: short in account, wrappers out
        a, s, q = rng.choice(accounts), rng.choice(list(series)), rng.randint(1, 500) * lot
        bal[a][s] = bal[a].get(s, 0) - q
        wraps[s] += q
        h = rng.choice(["h0", "h1", "h2"])
        holders.setdefault(h, {}).setdefault(s, 0)
        holders[h][s] += q
    for _ in range(rng.randint(0, 8)):                        # unwraps: wrappers into accounts
        h = rng.choice(list(holders))
        s = rng.choice(list(holders[h]))
        q = holders[h][s] * rng.randint(0, 100) // 100 // lot * lot
        if q == 0:
            continue
        holders[h][s] -= q
        wraps[s] -= q
        a = rng.choice(accounts)
        bal[a][s] = bal[a].get(s, 0) + q
    return series, bal, wraps, holders


def m12_settlement(rng: random.Random, n: int) -> None:
    ident_bad = solvent_bad = cover_bad = sum_bad = 0
    for _ in range(n):
        series, bal, wraps, holders = rand_group(rng)
        for s in series:                                        # INV-1 at finalization
            assert sum(b.get(s, 0) for b in bal.values()) + wraps[s] == 0
        S_star = rng.randint(0, 12000) * m.WAD + rng.randint(0, m.WAD)
        dec = rng.choice([6, 18])
        # identity: sum of all account numerators + wrapper numerators == 0
        tot = sum(q * m.intrinsic_int(series[s], S_star) * series[s].CS for b in bal.values() for s, q in b.items())
        tot += sum(w * m.intrinsic_int(series[s], S_star) * series[s].CS for s, w in wraps.items())
        if tot != 0:
            ident_bad += 1
        rich = {a: 10**40 for a in bal}
        g = m.settle_group(series, bal, rich, wraps, S_star, dec, 0)
        if g.ratio_wad != m.WAD:
            solvent_bad += 1
        poor = {a: rng.randint(0, 10**(dec + 4)) for a in bal}
        ins = rng.randint(0, 10**(dec + 4))
        g2 = m.settle_group(series, bal, poor, wraps, S_star, dec, ins)
        if g2.unpaid <= ins and g2.ratio_wad != m.WAD:
            cover_bad += 1
        paid = sum(m.redeem_amount(series[s], q, S_star, g2.ratio_wad, dec)
                   for h in holders.values() for s, q in h.items())
        paid += sum(m.claim_amount(c, g2.ratio_wad, dec) for c in g2.credits_n.values())
        if paid > g2.available or g2.ratio_wad > m.WAD:
            sum_bad += 1
    check("M12a settlement identity: sum of account nets + wrapper claims == 0 exactly (netting)", ident_bad == 0,
          f"{ident_bad} violations in {n} groups")
    check("M12b everyone solvent => recovery ratio exactly 1 (INV-30)", solvent_bad == 0, f"{solvent_bad} violations")
    check("M12c insurance covering the unpaid debt => ratio exactly 1", cover_bad == 0, f"{cover_bad} violations")
    check("M12d total payouts never exceed collected + insurance; ratio <= 1 (INV-29, INV-31)", sum_bad == 0,
          f"{sum_bad} violations")


def m13_order(rng: random.Random, n: int) -> None:
    """Payout per unit doesn't depend on who redeems first, and splitting never pays more."""
    bad = 0
    for _ in range(n):
        series, bal, wraps, holders = rand_group(rng)
        S_star = rng.randint(0, 12000) * m.WAD
        poor = {a: rng.randint(0, 10**9) for a in bal}
        g = m.settle_group(series, bal, poor, wraps, S_star, 6, rng.randint(0, 10**8))
        for s, w in wraps.items():
            if w == 0:
                continue
            whole = m.redeem_amount(series[s], w, S_star, g.ratio_wad, 6)
            parts, left = [], w
            while left > 0:
                p = min(left, rng.randint(1, 50) * 10**16)
                parts.append(p)
                left -= p
            rng.shuffle(parts)
            if sum(m.redeem_amount(series[s], p, S_star, g.ratio_wad, 6) for p in parts) > whole:
                bad += 1
    check("M13 redemption order/splitting can't increase payout (INV-32)", bad == 0, f"{bad} violations")


def m14_fees_rounding(rng: random.Random, n: int) -> None:
    bad = 0
    for _ in range(n):
        dec = rng.choice([0, 6, 8, 18])
        mark = rng.randint(0, 10**24)
        bps = rng.randint(0, 1000)
        fee = m.seller_fee_native(mark, bps, dec, 0)
        exact = Fraction(mark * bps, m.BPS * 10 ** (18 - dec))
        if fee < exact or fee - exact >= 1:
            bad += 1
        ins, keep, tre = m.split_fee(fee)
        if ins + keep + tre != fee or min(ins, keep, tre) < 0:
            bad += 1
        N = rng.randint(1, 10**60)
        D = 10 ** (54 - dec)
        if m.ceil_div(N, D) < Fraction(N, D) or N // D > Fraction(N, D):
            bad += 1
    check("M14 fees round up, split sums exactly, debts round up, credits round down (MATH 2, 11)", bad == 0,
          f"{bad} violations")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--n", type=int, default=2000)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    m1_cdf()
    m2_black76(rng, a.n * 5)
    m3_approx_pricing(rng, a.n * 2)
    m4_interp(rng, a.n)
    m5_examples()
    m6_risk_reducing(rng, a.n)
    m7_mm_le_im(rng, a.n)
    m8_scaling(rng, a.n // 2)
    m9_liquidation(rng, a.n)
    m10_buckets(rng, a.n // 4)
    m11_stale(rng, a.n * 2)
    m12_settlement(rng, a.n * 2)
    m13_order(rng, a.n)
    m14_fees_rounding(rng, a.n * 5)
    width = max(len(r[0]) for r in RESULTS)
    for name, ok, detail in RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}  {name.ljust(width)}  {detail}")
    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed (seed {a.seed}, n {a.n})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
