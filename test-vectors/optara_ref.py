"""Independent exact-rational reference model of Optara V2 mathematics (MATH.md).

Written from the specification, not from the Solidity code, so that differential tests can catch mistakes in
either implementation (TESTING.md sections 19, 108-109; COMPOSABILITY.md section 28).

Units: prices, strikes, caps and contract sizes are WAD integers; quantities are 18-decimal integers.
Every economic value is kept as an exact Fraction until the single documented rounding step.

CLI (used by Foundry FFI; prints ABI-encoded uint256 words as one 0x-prefixed hex string):
    optara_ref.py margin   <decimals> <bufferBps> <fixedBuffer> <n> [kind K C CS short locked]*n
        -> worstNumerator, marginNative
    optara_ref.py settle   <decimals> <priceWad> <n> [kind K C CS short locked]*n
        -> shortNumerator, longNumerator, isDebit(0/1), |delta| native
    optara_ref.py redeem   <decimals> <kind> <K> <C> <CS> <priceWad> <quantity>
        -> payoutNative
    optara_ref.py lossat   <decimals> <priceWad> <n> [kind K C CS short locked]*n
        -> ceil(max(0, loss(S))) native
kind: 0 = CALL, 1 = PUT.
"""
from fractions import Fraction
import sys

WAD = 10**18
MAX_NUMERATOR = 2**255 - 1


def phi(kind, strike, cap, price):
    """Capped payoff per underlying unit (MATH.md sections 6-7)."""
    intrinsic = price - strike if kind == 0 else strike - price
    return min(max(intrinsic, 0), cap)


def denominator(decimals):
    """D_A = 10^(54 - d) (MATH.md section 24)."""
    if not 0 <= decimals <= 18:
        raise ValueError("unsupported decimals")
    return 10 ** (54 - decimals)


def ceil_div(n, d):
    return -(-n // d)


def numerators_at(legs, price):
    """Exact short and locked-long numerators at settlement price S (MATH.md sections 17-18)."""
    short_n = sum(phi(k, K, C, price) * cs * s for (k, K, C, cs, s, l) in legs)
    long_n = sum(phi(k, K, C, price) * cs * l for (k, K, C, cs, s, l) in legs)
    return short_n, long_n


def critical_points(legs):
    """{0} U {K, K+C for calls} U {K-C, K for puts}, from the account's own legs (MATH.md section 22)."""
    points = {0}
    for (k, K, C, _cs, _s, _l) in legs:
        points.add(K)
        points.add(K + C if k == 0 else K - C)
    return sorted(points)


def worst_case_numerator(legs):
    """max over critical prices of max(0, ShortN - LongN) (MATH.md section 92)."""
    worst = 0
    for price in critical_points(legs):
        short_n, long_n = numerators_at(legs, price)
        worst = max(worst, short_n - long_n)
    return worst


def margin_native(legs, decimals, buffer_bps=0, fixed_buffer=0):
    """ceilDiv(worst, D_A) + SafetyBufferNative (MATH.md sections 25-26)."""
    base = ceil_div(worst_case_numerator(legs), denominator(decimals))
    if base == 0:
        return 0
    return base + ceil_div(base * buffer_bps, 10_000) + fixed_buffer


def settlement_delta(legs, price, decimals):
    """Signed native delta owed TO the account: credit floors, debit ceils (MATH.md section 54)."""
    short_n, long_n = numerators_at(legs, price)
    d = denominator(decimals)
    if short_n >= long_n:
        return short_n, long_n, -ceil_div(short_n - long_n, d)
    return short_n, long_n, (long_n - short_n) // d


def redeem_payout(kind, strike, cap, size, price, quantity, decimals):
    """floorDiv(phi * CS * Q, D_A) (MATH.md section 47)."""
    return phi(kind, strike, cap, price) * size * quantity // denominator(decimals)


def exact_loss_native(legs, price, decimals):
    """Exact rational net liability in native units at any price."""
    short_n, long_n = numerators_at(legs, price)
    return Fraction(short_n - long_n, denominator(decimals))


def _encode(*words):
    out = ""
    for w in words:
        if w < 0 or w >= 2**256:
            raise ValueError("word out of range")
        out += format(w, "064x")
    return "0x" + out


def _parse_legs(args):
    n = int(args[0])
    vals = [int(x) for x in args[1 : 1 + 6 * n]]
    return [tuple(vals[i : i + 6]) for i in range(0, 6 * n, 6)]


def main(argv):
    cmd = argv[1]
    if cmd == "margin":
        decimals, bps, fixed = int(argv[2]), int(argv[3]), int(argv[4])
        legs = _parse_legs(argv[5:])
        print(_encode(worst_case_numerator(legs), margin_native(legs, decimals, bps, fixed)))
    elif cmd == "settle":
        decimals, price = int(argv[2]), int(argv[3])
        legs = _parse_legs(argv[4:])
        short_n, long_n, delta = settlement_delta(legs, price, decimals)
        print(_encode(short_n, long_n, 1 if delta < 0 else 0, abs(delta)))
    elif cmd == "redeem":
        decimals, kind, K, C, cs, price, q = (int(x) for x in argv[2:9])
        print(_encode(redeem_payout(kind, K, C, cs, price, q, decimals)))
    elif cmd == "lossat":
        decimals, price = int(argv[2]), int(argv[3])
        legs = _parse_legs(argv[4:])
        loss = exact_loss_native(legs, price, decimals)
        print(_encode(max(0, -((-loss.numerator) // loss.denominator))))
    else:
        raise SystemExit("unknown command " + cmd)


if __name__ == "__main__":
    main(sys.argv)
