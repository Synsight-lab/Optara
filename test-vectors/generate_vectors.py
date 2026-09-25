"""Generate language-neutral Optara V2 math vectors from the independent reference model.

Run: python3 test-vectors/generate_vectors.py
Writes test-vectors/vectors/{payoff,risk,settlement}.json. Solidity tests (contract/test/fuzz/Vectors.t.sol) and
the separate SDK repo (@optara/math) both check against these files; neither implementation generates them.

Every integer is a decimal string. `legsAbi` is abi.encode(Leg[]) with
Leg = (uint8 optionType, uint256 strikeWad, uint256 capWad, uint256 contractSizeWad, uint256 shortQty,
uint256 lockedQty), so Solidity can decode a vector without JSON struct parsing.
"""
import json
import os
from random import Random

from optara_ref import (
    WAD,
    critical_points,
    margin_native,
    numerators_at,
    phi,
    redeem_payout,
    settlement_delta,
    worst_case_numerator,
)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")


def abi_legs(legs):
    words = [0x20, len(legs)]
    for leg in legs:
        words.extend(leg)
    return "0x" + "".join(format(w, "064x") for w in words)


def leg_json(leg):
    k, K, C, cs, s, l = leg
    return {
        "optionType": "CALL" if k == 0 else "PUT",
        "strikeWad": str(K),
        "capWad": str(C),
        "contractSizeWad": str(cs),
        "shortQty": str(s),
        "lockedQty": str(l),
    }


def random_leg(rng, short_only=False):
    kind = rng.choice((0, 1))
    strike = rng.randint(1, 40) * WAD // 2 + rng.randrange(1000)
    cap = rng.randint(1, 20) * WAD // 4 + rng.randrange(1000)
    if kind == 1:
        cap = min(cap, strike)
    size = rng.choice((WAD, WAD // 10, WAD // 4, 3 * WAD // 2, WAD + 7))
    short = rng.choice((0, 1, WAD, WAD // 2, 3 * WAD, rng.randrange(1, 10 * WAD)))
    locked = 0 if short_only else rng.choice((0, 0, WAD, WAD // 3, rng.randrange(1, 10 * WAD)))
    if short == 0 and locked == 0:
        short = WAD
    return (kind, strike, cap, size, short, locked)


# Named portfolios from the specification (MATH.md sections 66-69, TEST_CASES.md Appendix F).
NAMED = [
    ("MATH-66 unhedged call K12 C5", [(0, 12 * WAD, 5 * WAD, WAD, WAD, 0)], 6),
    ("MATH-67 short K10C5 + locked K12C3", [(0, 10 * WAD, 5 * WAD, WAD, WAD, 0), (0, 12 * WAD, 3 * WAD, WAD, 0, WAD)], 6),
    ("MATH-68 unhedged put K10 C4", [(1, 10 * WAD, 4 * WAD, WAD, WAD, 0)], 6),
    ("MATH-69 ETH call K4000 C500 CS0.1 Q3", [(0, 4000 * WAD, 500 * WAD, WAD // 10, 3 * WAD, 0)], 6),
    ("FIX-016 interior perfect hedge", [(0, 10 * WAD, 2 * WAD, WAD, WAD, 0), (0, 10 * WAD, 2 * WAD, WAD // 2, 0, 2 * WAD)], 6),
    ("FIX-016 interior perfect hedge 18d", [(0, 10 * WAD, 2 * WAD, WAD, WAD, 0), (0, 10 * WAD, 2 * WAD, WAD // 2, 0, 2 * WAD)], 18),
    ("short call + short put (strangle)", [(0, 12 * WAD, 3 * WAD, WAD, WAD, 0), (1, 8 * WAD, 3 * WAD, WAD, WAD, 0)], 6),
    ("put spread short K10C4 locked K8C2", [(1, 10 * WAD, 4 * WAD, WAD, WAD, 0), (1, 8 * WAD, 2 * WAD, WAD, 0, WAD)], 6),
    ("irrelevant hedge", [(0, 10 * WAD, 5 * WAD, WAD, WAD, 0), (1, 5 * WAD, 1 * WAD, WAD, 0, WAD)], 6),
    ("put K-C = 0 boundary", [(1, 4 * WAD, 4 * WAD, WAD, WAD, 0)], 6),
    ("locked only", [(0, 10 * WAD, 5 * WAD, WAD, 0, WAD)], 6),
    ("dust quantity", [(0, 10 * WAD, 5 * WAD, WAD, 1, 0)], 6),
    ("zero-decimal asset", [(0, 10 * WAD, 5 * WAD, WAD, WAD // 3, 0)], 0),
]


def risk_vector(name, legs, decimals):
    worst = worst_case_numerator(legs)
    return {
        "name": name,
        "decimals": decimals,
        "legs": [leg_json(l) for l in legs],
        "legsAbi": abi_legs(legs),
        "criticalPoints": [str(p) for p in critical_points(legs)],
        "worstNumerator": str(worst),
        "marginNative": str(margin_native(legs, decimals)),
    }


def settlement_vector(name, legs, decimals, price):
    short_n, long_n, delta = settlement_delta(legs, price, decimals)
    return {
        "name": name,
        "decimals": decimals,
        "priceWad": str(price),
        "legs": [leg_json(l) for l in legs],
        "legsAbi": abi_legs(legs),
        "shortNumerator": str(short_n),
        "longNumerator": str(long_n),
        "isDebit": delta < 0,
        "deltaAbs": str(abs(delta)),
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = Random(20260925)

    payoff = []
    for kind, K, C, prices in (
        (0, 10 * WAD, 5 * WAD, (0, 8, 9, 10, 11, 12, 12.5, 14, 15, 16, 20, 1000)),
        (1, 10 * WAD, 4 * WAD, (0, 1, 3, 6, 7, 8, 9, 10, 12, 15, 20)),
    ):
        for p in prices:
            price = int(p * WAD)
            payoff.append({"optionType": "CALL" if kind == 0 else "PUT", "strikeWad": str(K), "capWad": str(C),
                           "priceWad": str(price), "phiWad": str(phi(kind, K, C, price))})
    redeem = []
    for decimals in (6, 18):
        for kind, K, C, cs, price, q in (
            (0, 4000 * WAD, 500 * WAD, WAD // 10, 4800 * WAD, 3 * WAD),
            (0, 4000 * WAD, 500 * WAD, WAD // 10, 4800 * WAD, WAD // 4),
            (0, 10 * WAD, 5 * WAD, WAD, 13 * WAD, WAD),
            (1, 10 * WAD, 4 * WAD, WAD, 7 * WAD, 2 * WAD),
            (0, 10 * WAD, 5 * WAD, WAD, 11 * WAD + 1, 1),
        ):
            redeem.append({"decimals": decimals, "optionType": "CALL" if kind == 0 else "PUT", "strikeWad": str(K),
                           "capWad": str(C), "contractSizeWad": str(cs), "priceWad": str(price),
                           "quantity": str(q), "payoutNative": str(redeem_payout(kind, K, C, cs, price, q, decimals))})

    risk = [risk_vector(n, legs, d) for n, legs, d in NAMED]
    for i in range(120):
        legs = [random_leg(rng) for _ in range(rng.randint(1, 8))]
        risk.append(risk_vector(f"random-{i}", legs, rng.choice((0, 6, 8, 18))))

    settlement = []
    for n, legs, d in NAMED:
        for price in critical_points(legs) + [max(critical_points(legs)) + WAD, 11 * WAD + 1]:
            settlement.append(settlement_vector(f"{n} @ {price}", legs, d, price))
    for i in range(120):
        legs = [random_leg(rng) for _ in range(rng.randint(1, 8))]
        pts = critical_points(legs)
        price = rng.choice(pts + [rng.randrange(pts[-1] + WAD), (pts[0] + pts[-1]) // 2 + 1])
        settlement.append(settlement_vector(f"random-{i}", legs, rng.choice((0, 6, 18)), price))

    meta = {"generator": "test-vectors/generate_vectors.py", "reference": "test-vectors/optara_ref.py",
            "spec": "docs/MATH.md sections 6-7, 22-26, 47, 54"}
    with open(os.path.join(OUT, "payoff.json"), "w") as f:
        json.dump({**meta, "phi": payoff, "redeem": redeem, "redeemCount": len(redeem), "phiCount": len(payoff)}, f, indent=1)
    with open(os.path.join(OUT, "risk.json"), "w") as f:
        json.dump({**meta, "count": len(risk), "vectors": risk}, f, indent=1)
    with open(os.path.join(OUT, "settlement.json"), "w") as f:
        json.dump({**meta, "count": len(settlement), "vectors": settlement}, f, indent=1)
    print(f"wrote {len(payoff)} phi, {len(redeem)} redeem, {len(risk)} risk, {len(settlement)} settlement vectors")


if __name__ == "__main__":
    main()
