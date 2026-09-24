"""Independent exact-rational checks for the documented design fixes.

Run: python3 test-vectors/design_regressions.py
This verifies arithmetic specifications, not contracts or deployed integrations.
"""
from fractions import Fraction
from random import Random
import unittest

WAD = 10**18
MAX_NUMERATOR = 2**255 - 1


def ceil_fraction(value):
    return -(-value.numerator // value.denominator)


def numerator(phi, size, quantity):
    value = phi * size * quantity
    if value > MAX_NUMERATOR:
        raise OverflowError("unsupported payoff numerator")
    return value


def native_value(phi, size, quantity, decimals):
    return Fraction(numerator(phi, size, quantity), 10**(54 - decimals))


def legacy_payoff_wad(phi, size, quantity):
    return (phi * size // WAD) * quantity // WAD


def phi_at(leg, price):
    kind, strike, cap, _, _ = leg
    intrinsic = price - strike if kind == "call" else strike - price
    return min(max(intrinsic, 0), cap)


def exact_loss(shorts, longs, price, decimals):
    def value(leg):
        return native_value(phi_at(leg, price), leg[3], leg[4], decimals)
    return sum(map(value, shorts), Fraction()) - sum(map(value, longs), Fraction())


def critical_points(legs):
    points = {0}
    for kind, strike, cap, _, _ in legs:
        points.update((strike, strike + cap if kind == "call" else strike - cap))
    return sorted(points)


class DesignRegressions(unittest.TestCase):
    def test_fragmented_writers_fund_aggregated_long(self):
        phi = WAD + 1
        half_exact = native_value(phi, WAD, WAD // 2, 18)
        whole = native_value(phi, WAD, WAD, 18)
        legacy_collected = 2 * legacy_payoff_wad(phi, WAD, WAD // 2)
        self.assertEqual(int(whole) - legacy_collected, 1)
        debits = 2 * ceil_fraction(half_exact)
        payout = int(whole)
        self.assertEqual(debits - payout, 1)
        self.assertEqual(debits - payout, 2 * (ceil_fraction(half_exact) - half_exact))

    def test_perfect_hedge_at_interior_price(self):
        shorts = [("call", 10 * WAD, 2 * WAD, WAD, WAD)]
        longs = [("call", 10 * WAD, 2 * WAD, WAD // 2, 2 * WAD)]
        interior = 11 * WAD + 1
        phi = WAD + 1
        self.assertEqual(legacy_payoff_wad(phi, WAD, WAD)
                         - legacy_payoff_wad(phi, WAD // 2, 2 * WAD), 1)
        for decimals in (6, 18):
            for price in critical_points(shorts + longs) + [interior]:
                self.assertEqual(exact_loss(shorts, longs, price, decimals), 0)

    def test_fractional_redemption_residual(self):
        initial_claim = Fraction(3, 2)
        burned = initial_claim / 2
        payout = int(burned)
        remaining = initial_claim - burned
        residual = burned - payout
        self.assertEqual(payout, 0)
        self.assertEqual(initial_claim, payout + remaining + residual)

    def test_product_bound(self):
        self.assertEqual(numerator(MAX_NUMERATOR, 1, 1), MAX_NUMERATOR)
        with self.assertRaises(OverflowError):
            numerator(MAX_NUMERATOR + 1, 1, 1)

    def test_random_portfolio_margin_bounds_integer_settlement(self):
        rng = Random(20260924)
        for _ in range(300):
            def leg():
                strike = rng.randint(1, 20) * WAD + rng.randrange(100)
                cap = rng.randint(1, 5) * WAD + rng.randrange(100)
                kind = rng.choice(("call", "put"))
                if kind == "put":
                    cap = min(cap, strike)
                size = rng.randint(1, 4) * (WAD // 4)
                quantity = rng.randint(1, 6) * (WAD // 2) + rng.randrange(100)
                return kind, strike, cap, size, quantity
            shorts = [leg() for _ in range(rng.randint(1, 5))]
            longs = [leg() for _ in range(rng.randint(0, 5))]
            points = critical_points(shorts + longs)
            for decimals in (6, 18):
                worst = max(Fraction(), *(exact_loss(shorts, longs, p, decimals) for p in points))
                margin = ceil_fraction(worst)
                interior = [(a + b) // 2 for a, b in zip(points, points[1:])]
                samples = points + interior + [rng.randrange(points[-1] + WAD), points[-1] + WAD]
                for price in samples:
                    loss = exact_loss(shorts, longs, price, decimals)
                    self.assertLessEqual(loss, worst)
                    self.assertLessEqual(ceil_fraction(max(loss, 0)), margin)

    def test_random_fragmentation_conservation_with_internal_hedges(self):
        rng = Random(42)
        for _ in range(1000):
            phi = WAD + rng.randrange(WAD)
            quantities = [rng.randrange(1, WAD) for _ in range(5)]
            # Move part of one writer's issued long into another writer's locked hedge.
            locked = rng.randrange(quantities[0] + 1)
            for decimals in (6, 18):
                liabilities = [native_value(phi, WAD, q, decimals) for q in quantities]
                hedge_value = native_value(phi, WAD, locked, decimals)
                net = liabilities[:]
                net[1] -= hedge_value
                debits = sum(ceil_fraction(x) for x in net if x > 0)
                credits = sum(int(-x) for x in net if x < 0)
                external = native_value(phi, WAD, sum(quantities) - locked, decimals)
                self.assertEqual(sum(net), external)
                payout = int(external)
                reserve = sum(Fraction(ceil_fraction(x)) - x for x in net if x > 0)
                reserve += sum(-x - int(-x) for x in net if x < 0)
                reserve += external - payout
                self.assertGreaterEqual(reserve, 0)
                self.assertEqual(debits, credits + payout + reserve)

    def test_shortfall_resolution_is_order_independent_and_bounded(self):
        # LIQUIDATION.md section 102 / MATH.md section 119.
        rng = Random(7)
        for _ in range(500):
            claims = [rng.randrange(1, 10**9) for _ in range(rng.randint(1, 12))]
            total = sum(claims)
            available = rng.randrange(1, total)  # a real shortfall
            rho = Fraction(available, total)
            payouts = [int(rho * c) for c in claims]  # floor(rho * amount)
            self.assertLessEqual(sum(payouts), available)
            order = claims[:]
            rng.shuffle(order)
            self.assertEqual(sorted(int(rho * c) for c in order), sorted(payouts))
            for c, p in zip(claims, payouts):
                self.assertLessEqual(p, rho * c)
                self.assertGreater(p + 1, rho * c)

    def test_exposure_released_once_at_finalization(self):
        # PROTOCOL_SPEC.md section 42: wider scopes = sum of unreleased groups.
        rng = Random(99)
        for _ in range(300):
            groups = {g: rng.randrange(0, 10**6) for g in range(rng.randint(1, 6))}
            asset_scope = sum(groups.values())
            released = set()
            for g in list(groups):
                if rng.random() < 0.3:  # pre-finalization burn
                    burn = rng.randrange(0, groups[g] + 1)
                    groups[g] -= burn
                    asset_scope -= burn
                if rng.random() < 0.5:  # finalize: O(1) release
                    asset_scope -= groups[g]
                    released.add(g)
                    # abandoned or later-burned tokens touch only group counters
                    groups[g] -= rng.randrange(0, groups[g] + 1)
            self.assertEqual(asset_scope,
                             sum(v for g, v in groups.items() if g not in released))
            self.assertGreaterEqual(asset_scope, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
