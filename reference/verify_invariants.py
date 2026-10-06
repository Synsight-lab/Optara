"""Stateful invariant simulation for Optara PM (docs/INVARIANTS.md).

Random sequences of every user action (deposit, withdraw, mint, wrap, unwrap, close, internal close, wrapper
transfers, spot/vol moves, oracle staleness, liquidation), then full expiry: finalize, settle, recovery ratio,
redeem, claim. After every step all invariants are checked. Any violation raises with the run seed and step.

Run:  python3 reference/verify_invariants.py [--runs N] [--steps N] [--seed N]
"""
from __future__ import annotations

import argparse
import random
import sys
from collections import Counter

import pm_model as m

DAY = 86400
DEC = 6                      # USDC
UNIT = 10**DEC
LOT = 10**16                 # minPositionQty = 0.01 option
W = m.WAD
P = m.RiskParams()
SELLER_FEE_BPS, MIN_FEE = 300, UNIT // 10
BONUS_MAX, PENALTY = 1000, 200


class Violation(AssertionError):
    pass


def ensure(cond: bool, inv: str, msg: str = "") -> None:
    if not cond:
        raise Violation(f"{inv} violated: {msg}")


class Protocol:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.now = 0
        self.spot = {"ETH": 4000.0, "BTC": 70000.0}
        self.fresh = {"ETH": True, "BTC": True}
        self.groups = {
            "G1": dict(u="ETH", expiry=20 * DAY), "G2": dict(u="ETH", expiry=40 * DAY),
            "G3": dict(u="BTC", expiry=20 * DAY)}
        for g in self.groups.values():
            g.update(finalized=False, price=None, ratio=None, participants=0, collected=0, unpaid=0,
                     credits={}, claimed=set(), snapshot={}, pool=0, insurance=0, settled=set())
        self.series = {
            "C4500": dict(g="G1", call=True, K=4500.0, CS=1.0, iv=0.60),
            "C5000": dict(g="G1", call=True, K=5000.0, CS=1.0, iv=0.62),
            "P3500": dict(g="G1", call=False, K=3500.0, CS=1.0, iv=0.65),
            "C4500L": dict(g="G2", call=True, K=4500.0, CS=1.0, iv=0.58),
            "C70K": dict(g="G3", call=True, K=70000.0, CS=0.01, iv=0.55)}
        for s in self.series.values():
            s["u"] = self.groups[s["g"]]["u"]
            s["expiry"] = self.groups[s["g"]]["expiry"]
        self.accounts = {}           # aid -> dict(owner, cash, bal{sid: qty})
        self.wallet = {}             # owner -> dict(usdc, wr{sid: qty})
        self.supply = Counter()      # wrapper supply
        self.tot_long = Counter()
        self.tot_short = Counter()
        self.series_count = Counter()    # (aid, gid) -> non-zero series
        self.custody = 0             # USDC held by OptionClearing
        self.insurance = 1_000_000 * UNIT
        self.treasury = self.keeper = 0
        self.fees_charged = 0
        self.fee_dest = 0
        for owner, cash, n in [("W1", 30_000, 2), ("W2", 20_000, 1), ("W3", 8_000, 1), ("B1", 5_000, 1),
                               ("LIQ", 10_000_000, 1)]:
            self.wallet[owner] = dict(usdc=cash * UNIT * 2, wr=Counter())
            for _ in range(n):
                aid = len(self.accounts) + 1
                self.accounts[aid] = dict(owner=owner, cash=0, bal={})
                self.deposit(aid, cash * UNIT)
        self.liq_aid = max(a for a, x in self.accounts.items() if x["owner"] == "LIQ")

    # ------------------------------------------------------------------ ledger (single write path)
    def set_bal(self, aid: int, sid: str, new: int) -> None:
        acc = self.accounts[aid]
        old = acc["bal"].get(sid, 0)
        ensure(new == 0 or (abs(new) >= LOT and new % LOT == 0), "INV-6", f"balance {new}")
        g = self.series[sid]["g"]
        self.tot_long[sid] += max(new, 0) - max(old, 0)
        self.tot_short[sid] += max(-new, 0) - max(-old, 0)
        if old == 0 and new != 0:
            self.series_count[(aid, g)] += 1
            if self.series_count[(aid, g)] == 1:
                self.groups[g]["participants"] += 1
        if old != 0 and new == 0:
            self.series_count[(aid, g)] -= 1
            if self.series_count[(aid, g)] == 0:
                self.groups[g]["participants"] -= 1
        if new == 0:
            acc["bal"].pop(sid, None)
        else:
            acc["bal"][sid] = new

    # ------------------------------------------------------------------ risk
    def legs(self, aid: int, bal: dict | None = None) -> list:
        out = []
        for sid, q in (bal if bal is not None else self.accounts[aid]["bal"]).items():
            s, g = self.series[sid], self.groups[self.series[sid]["g"]]
            payoff = None
            if g["finalized"]:
                payoff = m.intrinsic(s["call"], g["price"] / W, s["K"])
            out.append(m.Leg(s["u"], s["call"], s["K"], s["CS"], s["expiry"], q / W, s["iv"],
                             finalized_payoff=payoff))
        return out

    def risk(self, aid: int, cash: int | None = None, bal: dict | None = None) -> m.Risk:
        c = self.accounts[aid]["cash"] if cash is None else cash
        return m.account_risk(c / UNIT, self.legs(aid, bal), self.spot, self.now, P)

    def fresh_for(self, aid: int, bal: dict | None = None) -> bool:
        b = self.accounts[aid]["bal"] if bal is None else bal
        return all(self.fresh[self.series[sid]["u"]] for sid in b)

    def active(self, sid: str) -> bool:
        return self.now < self.series[sid]["expiry"]

    def healthy(self, r: m.Risk) -> bool:
        return r.equity >= r.im - 1e-9

    # ------------------------------------------------------------------ actions (return False = reverted)
    def deposit(self, aid: int, amt: int) -> bool:
        w = self.wallet[self.accounts[aid]["owner"]]
        if amt <= 0 or w["usdc"] < amt:
            return False
        before = self.risk(aid) if self.accounts[aid]["bal"] else None
        w["usdc"] -= amt
        self.custody += amt
        self.accounts[aid]["cash"] += amt
        if before:
            self.check_not_worse(aid, before, "deposit")
        return True

    def withdraw(self, aid: int, amt: int) -> bool:
        acc = self.accounts[aid]
        if amt <= 0 or amt > acc["cash"] or (acc["bal"] and not self.fresh_for(aid)):
            return False
        if acc["bal"] and not self.healthy(self.risk(aid, cash=acc["cash"] - amt)):
            return False
        acc["cash"] -= amt
        self.custody -= amt
        self.wallet[acc["owner"]]["usdc"] += amt
        if acc["bal"]:
            ensure(self.healthy(self.risk(aid)), "INV-11", "withdraw left account unhealthy")
        return True

    def mint(self, aid: int, sid: str, q: int, to: str) -> bool:
        acc = self.accounts[aid]
        if not self.active(sid) or q <= 0:
            return False
        new = dict(acc["bal"])
        new[sid] = new.get(sid, 0) - q
        if not self.fresh_for(aid, new):
            return False
        s = self.series[sid]
        mark = m.black76(s["call"], self.spot[s["u"]], s["K"], s["iv"], (s["expiry"] - self.now) / m.YEAR)
        fee = m.seller_fee_native(int(mark * s["CS"] * q), SELLER_FEE_BPS, DEC, MIN_FEE)
        if acc["cash"] < fee:
            return False
        if not self.healthy(self.risk(aid, cash=acc["cash"] - fee, bal=new)):
            return False
        acc["cash"] -= fee
        ins, kp, tr = m.split_fee(fee)
        self.custody -= fee
        self.insurance += ins
        self.keeper += kp
        self.treasury += tr
        self.fees_charged += fee
        self.fee_dest += ins + kp + tr
        self.set_bal(aid, sid, new[sid])
        self.supply[sid] += q
        self.wallet[to]["wr"][sid] += q
        ensure(self.healthy(self.risk(aid)), "INV-11", "mint left account unhealthy")
        return True

    def unwrap(self, owner: str, aid: int, sid: str, q: int) -> bool:
        if self.accounts[aid]["owner"] != owner or not self.active(sid) or self.wallet[owner]["wr"][sid] < q:
            return False
        nb = self.accounts[aid]["bal"].get(sid, 0) + q
        if nb != 0 and abs(nb) < LOT:
            return False
        before = self.risk(aid)
        self.wallet[owner]["wr"][sid] -= q
        self.supply[sid] -= q
        self.set_bal(aid, sid, nb)
        self.check_not_worse(aid, before, "unwrap")
        return True

    def wrap(self, aid: int, sid: str, q: int, to: str) -> bool:
        acc = self.accounts[aid]
        if not self.active(sid) or acc["bal"].get(sid, 0) < q or q <= 0:
            return False
        new = dict(acc["bal"])
        new[sid] -= q
        if new[sid] == 0:
            del new[sid]
        if not self.fresh_for(aid, acc["bal"]) or not self.healthy(self.risk(aid, bal=new)):
            return False
        self.set_bal(aid, sid, acc["bal"][sid] - q)
        self.supply[sid] += q
        self.wallet[to]["wr"][sid] += q
        ensure(self.healthy(self.risk(aid)), "INV-11", "wrap left account unhealthy")
        return True

    def close_with_wrapper(self, owner: str, aid: int, sid: str, q: int) -> bool:
        acc = self.accounts[aid]
        g = self.groups[self.series[sid]["g"]]
        if acc["owner"] != owner or g["finalized"] or acc["bal"].get(sid, 0) > -q or self.wallet[owner]["wr"][sid] < q:
            return False
        before = self.risk(aid)
        self.wallet[owner]["wr"][sid] -= q
        self.supply[sid] -= q
        self.set_bal(aid, sid, acc["bal"][sid] + q)
        self.check_not_worse(aid, before, "closeShortWithWrapper")
        return True

    def close_internal(self, frm: int, to: int, sid: str, q: int) -> bool:
        a, b = self.accounts[frm], self.accounts[to]
        g = self.groups[self.series[sid]["g"]]
        if frm == to or a["owner"] != b["owner"] or g["finalized"]:
            return False
        if a["bal"].get(sid, 0) < q or b["bal"].get(sid, 0) > -q:
            return False
        new = dict(a["bal"])
        new[sid] -= q
        if new[sid] == 0:
            del new[sid]
        if not self.fresh_for(frm, a["bal"]) or not self.healthy(self.risk(frm, bal=new)):
            return False
        before_to = self.risk(to)
        self.set_bal(frm, sid, a["bal"][sid] - q)
        self.set_bal(to, sid, b["bal"][sid] + q)
        ensure(self.healthy(self.risk(frm)), "INV-11", "internal close left source unhealthy")
        self.check_not_worse(to, before_to, "closeShortWithInternalLong (target)")
        return True

    def transfer_wrapper(self, frm: str, to: str, sid: str, q: int) -> bool:
        if self.wallet[frm]["wr"][sid] < q or q <= 0:
            return False
        self.wallet[frm]["wr"][sid] -= q
        self.wallet[to]["wr"][sid] += q
        return True

    def liquidate(self, aid: int, u: str, slice_bps: int, bonus_bps: int) -> bool:
        if aid == self.liq_aid or not self.fresh[u]:
            return False
        acc = self.accounts[aid]
        r0 = self.risk(aid)
        if r0.equity >= r0.mm:                                  # INV-21: only below MM
            return False
        legs_u = {sid: q for sid, q in acc["bal"].items()
                  if self.series[sid]["u"] == u and self.active(sid)}
        if not legs_u:
            return False
        move = {}
        for sid, q in legs_u.items():
            lots = abs(q) // LOT * slice_bps // m.BPS
            if lots:
                move[sid] = (1 if q > 0 else -1) * lots * LOT
        if not move:
            return False
        rest = {sid: q - move.get(sid, 0) for sid, q in acc["bal"].items()}
        rest = {k: v for k, v in rest.items() if v}
        r_rest = self.risk(aid, bal=rest)
        slice_mm = r0.mm - r_rest.mm
        if slice_mm <= 0:
            return False
        slice_mark = sum(m.leg_value(l, self.spot[l.underlying], self.now, None, P)
                         for l in self.legs(aid, move))
        cash = acc["cash"] / UNIT
        res = m.liquidation_cash(slice_mark, slice_mm, bonus_bps, PENALTY, cash, self.insurance / UNIT)
        pay = -(-int(res.cash_to_liq * UNIT * 10**6) // 10**6) if res.cash_to_liq > 0 \
            else -int(-res.cash_to_liq * UNIT)              # to liquidator rounded up, from liquidator down
        pen = -(-int(res.penalty * UNIT * 10**6) // 10**6)
        topup = 0
        if pay > acc["cash"]:
            topup = min(pay - acc["cash"], self.insurance)
            pay_acc, pen = acc["cash"], 0
        else:
            pay_acc = pay
            pen = min(pen, acc["cash"] - pay)
        liq = self.accounts[self.liq_aid]
        short_before = dict(self.tot_short)
        net_before = {sid: self.tot_long[sid] - self.tot_short[sid] for sid in self.series}
        # simulate first: the spec requires a strict health improvement, otherwise the call reverts
        r_sim = self.risk(aid, cash=acc["cash"] - pay_acc - pen, bal=rest)
        if (r_sim.equity - r_sim.mm) <= (r0.equity - r0.mm):
            # INV-22 theorem: the gain is >= sliceMM*(1-bonus-penalty); only rounding can erase it, so a revert
            # is legitimate only for dust-sized slices (gain below ~2 native units of rounding).
            ensure(slice_mm * (1 - (bonus_bps + PENALTY) / m.BPS) <= 2 / UNIT + 1e-9 * max(1.0, abs(r0.equity)),
                   "INV-22", f"non-dust slice failed to improve health (sliceMM {slice_mm})")
            self.dust_reverts += 1
            return False
        # effects
        acc["cash"] -= pay_acc + pen
        liq["cash"] += pay_acc + topup
        self.insurance += pen - topup
        self.custody += topup - pen          # penalty leaves custody for InsuranceFund; top-up arrives
        for sid, q in move.items():
            self.set_bal(aid, sid, acc["bal"][sid] - q)
            self.set_bal(self.liq_aid, sid, liq["bal"].get(sid, 0) + q)
        r1 = self.risk(aid)
        rl = self.risk(self.liq_aid)
        if (r1.equity - r1.mm) <= (r0.equity - r0.mm):
            raise Violation(f"INV-22 violated: health {r0.equity - r0.mm:.4f} -> {r1.equity - r1.mm:.4f}")
        ensure(self.healthy(rl), "INV-23", "liquidator unhealthy after slice")
        for sid in self.series:          # INV-24: net unchanged; total short may only fall (netting)
            ensure(self.tot_long[sid] - self.tot_short[sid] == net_before[sid], "INV-24", f"net changed {sid}")
            ensure(self.tot_short[sid] <= short_before.get(sid, 0), "INV-24", f"short total rose {sid}")
        ensure(self.insurance >= 0, "INV-25", "insurance negative")
        self.liquidations += 1
        return True

    # ------------------------------------------------------------------ settlement
    def finalize(self, gid: str, price: float) -> bool:
        g = self.groups[gid]
        if g["finalized"] or self.now < g["expiry"]:
            return False
        for sid, s in self.series.items():                    # INV-1 at finalization
            if s["g"] == gid:
                ensure(self.tot_long[sid] - self.tot_short[sid] + self.supply[sid] == 0, "INV-1", sid)
                g["snapshot"][sid] = self.supply[sid]
        g["finalized"], g["price"] = True, int(price * W)
        return True

    def settle(self, aid: int, gid: str) -> bool:
        g = self.groups[gid]
        if not g["finalized"] or self.series_count[(aid, gid)] == 0:
            return False
        acc = self.accounts[aid]
        D = 10 ** (54 - DEC)
        N = 0
        for sid, q in list(acc["bal"].items()):
            s = self.series[sid]
            if s["g"] != gid:
                continue
            si = m.SeriesInt(s["call"], int(s["K"] * W), int(s["CS"] * W))
            N += q * m.intrinsic_int(si, g["price"]) * si.CS
            self.set_bal(aid, sid, 0)
        if N < 0:
            debt = m.ceil_div(-N, D)
            c = min(acc["cash"], debt)
            acc["cash"] -= c
            g["collected"] += c
            g["pool"] += c                   # collected cash is held in the group pool at once
            g["unpaid"] += debt - c
        elif N > 0:
            g["credits"][aid] = N
        g["settled"].add(aid)
        return True

    def compute_ratio(self, gid: str) -> bool:
        g = self.groups[gid]
        if not g["finalized"] or g["participants"] != 0 or g["ratio"] is not None:
            return False
        D = 10 ** (54 - DEC)
        wn = 0
        for sid, w in g["snapshot"].items():
            s = self.series[sid]
            si = m.SeriesInt(s["call"], int(s["K"] * W), int(s["CS"] * W))
            wn += w * m.intrinsic_int(si, g["price"]) * si.CS
        gross_n = wn + sum(g["credits"].values())
        gross = m.ceil_div(gross_n, D)
        shortfall = max(0, gross - g["collected"])
        ins = min(shortfall, self.insurance)
        self.insurance -= ins
        self.custody += ins
        g["insurance"] = ins
        g["pool"] += ins
        ensure(g["pool"] == g["collected"] + ins, "INV-31", "pool != collected + insurance")
        g["available"] = g["pool"]
        g["ratio"] = m.WAD if gross_n == 0 else min(m.WAD, g["pool"] * D * m.WAD // gross_n)
        if g["unpaid"] == 0:
            ensure(g["ratio"] == m.WAD, "INV-30", f"solvent group ratio {g['ratio']}")
        ensure(g["ratio"] <= m.WAD, "INV-29", "ratio > 1")
        return True

    def redeem(self, owner: str, sid: str, q: int) -> bool:
        g = self.groups[self.series[sid]["g"]]
        if g["ratio"] is None or self.wallet[owner]["wr"][sid] < q or q <= 0:
            return False
        s = self.series[sid]
        si = m.SeriesInt(s["call"], int(s["K"] * W), int(s["CS"] * W))
        pay = m.redeem_amount(si, q, g["price"], g["ratio"], DEC)
        ensure(pay <= g["pool"], "INV-31", "pool would go negative")
        self.wallet[owner]["wr"][sid] -= q
        self.supply[sid] -= q
        g["pool"] -= pay
        self.custody -= pay
        self.wallet[owner]["usdc"] += pay
        return True

    def claim(self, aid: int, gid: str) -> bool:
        g = self.groups[gid]
        if g["ratio"] is None or aid not in g["credits"] or aid in g["claimed"]:
            return False
        amt = m.claim_amount(g["credits"][aid], g["ratio"], DEC)
        ensure(amt <= g["pool"], "INV-31", "claim exceeds pool")
        g["pool"] -= amt
        g["claimed"].add(aid)
        self.accounts[aid]["cash"] += amt
        return True

    # ------------------------------------------------------------------ invariant checks
    def check_not_worse(self, aid: int, before: m.Risk, what: str) -> None:
        after = self.risk(aid)
        tol = 1e-6 * max(1.0, abs(before.im), abs(before.equity))
        ensure(after.equity - after.im >= before.equity - before.im - tol, "INV-13", f"{what} lowered equity-IM")
        ensure(after.equity - after.mm >= before.equity - before.mm - tol, "INV-13", f"{what} lowered equity-MM")

    def check_all(self) -> None:
        tl, ts = Counter(), Counter()
        for aid, acc in self.accounts.items():
            ensure(acc["cash"] >= 0, "INV-8", f"account {aid} cash {acc['cash']}")
            for sid, q in acc["bal"].items():
                ensure(q != 0 and abs(q) >= LOT and q % LOT == 0, "INV-6", f"{aid}/{sid}={q}")
                tl[sid] += max(q, 0)
                ts[sid] += max(-q, 0)
            if acc["bal"]:
                r = self.risk(aid)
                ensure(r.mm <= r.im + 1e-9 * max(1, r.im), "INV-14", f"account {aid}")
        for sid in self.series:
            ensure(tl[sid] == self.tot_long[sid] and ts[sid] == self.tot_short[sid], "INV-2", sid)
            g = self.groups[self.series[sid]["g"]]
            wallets = sum(w["wr"][sid] for w in self.wallet.values())
            ensure(wallets == self.supply[sid], "INV-4", f"wrapper supply {sid}")
            if not g["finalized"]:
                ensure(tl[sid] - ts[sid] + self.supply[sid] == 0, "INV-1", sid)
            else:
                ensure(self.supply[sid] <= g["snapshot"][sid], "INV-33", sid)
        for gid, g in self.groups.items():
            n = sum(1 for aid in self.accounts if self.series_count[(aid, gid)] > 0)
            recount = sum(1 for aid, acc in self.accounts.items()
                          if any(self.series[s]["g"] == gid for s in acc["bal"]))
            ensure(n == recount == g["participants"], "INV-27", f"{gid} {g['participants']} vs {recount}")
            ensure(g["pool"] >= 0, "INV-31", gid)
        pools = sum(g["pool"] for g in self.groups.values())
        cash = sum(a["cash"] for a in self.accounts.values())
        ensure(self.custody == cash + pools, "INV-7", f"custody {self.custody} vs {cash + pools}")
        ensure(self.fees_charged == self.fee_dest, "INV-9", "fee split mismatch")
        ensure(self.insurance >= 0, "INV-25", "insurance negative")


def random_step(p: Protocol, rng: random.Random, stats: Counter) -> None:
    owners = ["W1", "W2", "W3", "B1"]
    aids = [a for a in p.accounts if a != p.liq_aid]
    sids = list(p.series)
    q = rng.randint(1, 300) * LOT
    act = rng.choices(["deposit", "withdraw", "mint", "unwrap", "wrap", "close", "internal", "transfer", "spot",
                       "vol", "stale", "warp", "liquidate"],
                      weights=[6, 6, 18, 10, 5, 8, 4, 8, 10, 4, 3, 5, 10])[0]
    ok = False
    if act == "deposit":
        ok = p.deposit(rng.choice(aids), rng.randint(1, 5000) * UNIT)
    elif act == "withdraw":
        ok = p.withdraw(rng.choice(aids), rng.randint(1, 5000) * UNIT)
    elif act == "mint":
        a = rng.choice(aids)
        ok = p.mint(a, rng.choice(sids), q, rng.choice(owners))
    elif act == "unwrap":
        o = rng.choice(owners)
        mine = [a for a in aids if p.accounts[a]["owner"] == o]
        held = [s for s in sids if p.wallet[o]["wr"][s] >= LOT]
        if mine and held:
            s = rng.choice(held)
            ok = p.unwrap(o, rng.choice(mine), s, min(q, p.wallet[o]["wr"][s] // LOT * LOT))
    elif act == "wrap":
        a = rng.choice(aids)
        longs = [s for s, x in p.accounts[a]["bal"].items() if x > 0]
        if longs:
            s = rng.choice(longs)
            ok = p.wrap(a, s, min(q, p.accounts[a]["bal"][s]), p.accounts[a]["owner"])
    elif act == "close":
        a = rng.choice(aids)
        o = p.accounts[a]["owner"]
        shorts = [s for s, x in p.accounts[a]["bal"].items() if x < 0 and p.wallet[o]["wr"][s] >= LOT]
        if shorts:
            s = rng.choice(shorts)
            ok = p.close_with_wrapper(o, a, s, min(q, -p.accounts[a]["bal"][s], p.wallet[o]["wr"][s] // LOT * LOT))
    elif act == "internal":
        w1 = [a for a in aids if p.accounts[a]["owner"] == "W1"]
        if len(w1) == 2:
            frm, to = rng.sample(w1, 2)
            common = [s for s in sids if p.accounts[frm]["bal"].get(s, 0) > 0 and p.accounts[to]["bal"].get(s, 0) < 0]
            if common:
                s = rng.choice(common)
                ok = p.close_internal(frm, to, s, min(q, p.accounts[frm]["bal"][s], -p.accounts[to]["bal"][s]))
    elif act == "transfer":
        o1, o2 = rng.sample(owners, 2)
        held = [s for s in sids if p.wallet[o1]["wr"][s] >= LOT]
        if held:
            s = rng.choice(held)
            ok = p.transfer_wrapper(o1, o2, s, min(q, p.wallet[o1]["wr"][s]))
    elif act == "spot":
        u = rng.choice(["ETH", "BTC"])
        p.spot[u] *= rng.choice([0.4, 0.7, 0.85, 0.95, 1.05, 1.15, 1.3, 1.5, 2.0, 3.0])   # includes gaps
        ok = True
    elif act == "vol":
        s = rng.choice(sids)
        p.series[s]["iv"] = min(3.0, max(0.15, p.series[s]["iv"] * rng.uniform(0.7, 1.4)))
        ok = True
    elif act == "stale":
        u = rng.choice(["ETH", "BTC"])
        p.fresh[u] = not p.fresh[u]
        ok = True
    elif act == "warp":
        p.now = min(p.now + rng.randint(1, 2 * DAY), 19 * DAY)
        ok = True
    elif act == "liquidate":
        under = [a for a in aids if p.accounts[a]["bal"]]
        if under:
            a = rng.choice(under)
            r = p.risk(a)
            if r.equity < r.mm:
                stats["below_mm_seen"] += 1
                us = sorted({p.series[s]["u"] for s in p.accounts[a]["bal"]})
                ok = p.liquidate(a, rng.choice(us), rng.choice([500, 1000, 2500, 10000]),
                                 rng.randint(0, BONUS_MAX))
    stats[f"{act}:{'ok' if ok else 'revert'}"] += 1
    try:
        p.check_all()
    except Violation as e:
        raise Violation(f"{e} (after action '{act}', ok={ok}, t={p.now / DAY:.1f}d)") from None


def expiry_phase(p: Protocol, rng: random.Random, stats: Counter) -> None:
    p.fresh = {"ETH": True, "BTC": True}
    for deadline, gids in [(21 * DAY, ["G1", "G3"]), (41 * DAY, ["G2"])]:
        p.now = deadline
        for gid in gids:
            # after expiry, before finalization: unwrap must revert; closing with wrappers still works
            for sid in [s for s in p.series if p.series[s]["g"] == gid]:
                for o in ["W1", "W2", "W3", "B1"]:
                    mine = [a for a in p.accounts if p.accounts[a]["owner"] == o]
                    if p.wallet[o]["wr"][sid] >= LOT:
                        ensure(not p.unwrap(o, mine[0], sid, LOT), "STATE", "unwrap after expiry")
            for a in list(p.accounts):
                o = p.accounts[a]["owner"]
                for sid, x in list(p.accounts[a]["bal"].items()):
                    if p.series[sid]["g"] == gid and x < 0 and p.wallet[o]["wr"][sid] >= LOT and rng.random() < 0.5:
                        p.close_with_wrapper(o, a, sid, min(-x, p.wallet[o]["wr"][sid] // LOT * LOT))
                        stats["expired_close"] += 1
            p.check_all()
            u = p.groups[gid]["u"]
            mult = 4.0 if rng.random() < 0.3 else rng.uniform(0.6, 1.6)          # 4x = beyond every stress scenario
            ensure(p.finalize(gid, p.spot[u] * mult), "STATE", "finalize failed")
            ensure(not p.finalize(gid, 1.0), "INV-26", "finalized twice")
            parts = [a for a in p.accounts if p.series_count[(a, gid)] > 0]
            rng.shuffle(parts)
            for a in parts:
                for sid in [s for s in p.series if p.series[s]["g"] == gid]:   # INV-28
                    for o in p.wallet:
                        if p.wallet[o]["wr"][sid] > 0:
                            ensure(not p.redeem(o, sid, p.wallet[o]["wr"][sid]), "INV-28", "redeem before ratio")
                ensure(not p.compute_ratio(gid), "INV-28", "ratio before all settled")
                p.settle(a, gid)
                p.check_all()
            ensure(p.compute_ratio(gid), "STATE", "ratio not computable")
            stats["ratio<1" if p.groups[gid]["ratio"] < m.WAD else "ratio=1"] += 1
            # redeem in random order and random chunks; claims
            g = p.groups[gid]
            per_unit = {}
            jobs = [(o, s) for o in p.wallet for s in p.series if p.series[s]["g"] == gid and p.wallet[o]["wr"][s] > 0]
            rng.shuffle(jobs)
            for o, s in jobs:
                while p.wallet[o]["wr"][s] > 0:
                    qq = min(p.wallet[o]["wr"][s], rng.randint(1, 200) * LOT)
                    before = p.wallet[o]["usdc"]
                    p.redeem(o, s, qq)
                    unit = (p.wallet[o]["usdc"] - before) * W // qq
                    per_unit.setdefault(s, []).append(unit)
                    p.check_all()
            for a in list(g["credits"]):
                p.claim(a, gid)
            for s, units in per_unit.items():           # INV-32: same per-unit payout (up to rounding)
                ensure(max(units) - min(units) <= W // LOT + 1, "INV-32", f"{s} per-unit payouts differ")
            paid_out = g["available"] - g["pool"]
            ensure(paid_out <= g["available"], "INV-31", gid)
            for sid in [s for s in p.series if p.series[s]["g"] == gid]:
                ensure(p.supply[sid] == 0, "INV-33", f"{sid} not fully redeemed")
            p.check_all()


def run(seed: int, steps: int, stats: Counter) -> None:
    rng = random.Random(seed)
    p = Protocol(rng)
    p.liquidations = 0
    if rng.random() < 0.5:
        p.insurance = 0                  # empty insurance fund: shortfalls reach the recovery ratio
    p.dust_reverts = 0
    for _ in range(steps):
        random_step(p, rng, stats)
    expiry_phase(p, rng, stats)
    stats["liquidations"] += p.liquidations
    stats["dust_liquidation_reverts"] += p.dust_reverts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=150)
    ap.add_argument("--steps", type=int, default=150)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    stats: Counter = Counter()
    for i in range(a.runs):
        seed = a.seed * 100_000 + i
        try:
            run(seed, a.steps, stats)
        except Violation as e:
            print(f"FAIL run seed={seed}: {e}")
            return 1
    print(f"PASS  {a.runs} runs x {a.steps} steps + full expiry/settlement per run; all invariants held")
    keys = sorted(stats)
    print("action outcomes:", ", ".join(f"{k}={stats[k]}" for k in keys))
    return 0


if __name__ == "__main__":
    sys.exit(main())
