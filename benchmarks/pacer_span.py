#!/usr/bin/env python3
"""Pick REG_FREQ / REG_FREQ_SPAN for a given pacer interval range.

formula: interval_cycles = freq_num + (lfsr & freq_span)

Example usage:
    ./pacer_span.py 1ms 10ms                # 1ms ~ 10ms
    ./pacer_span.py 200us 5ms --iters 10000 # 200us ~ 5ms, 10000 rounds
                                            # -> it gives you how long it will take to run #rounds
    ./pacer_span.py 3ms                     # 3ms -> no jitter (fixed pacer)
    ./pacer_span.py 1ms 10ms --all          # list all candidates

Accepts ns / us / ms / s suffixes, and cycles (cyc).
"""
import argparse
import re
import sys

COLLECT_TIMEOUT_S = 5.0

_UNITS = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0, "cyc": None, "": None}

#pylint: disable=f-string-without-interpolation

def parse_time(text, clk_mhz):
    """parse the time string and convert to cycles"""
    m = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*([a-z]*)\s*", text.lower())
    if not m:
        raise ValueError(
            f"cannot parse {text!r} (want e.g. 1ms, 500us, 2s, or a cycle count)"
        )
    value, unit = float(m.group(1)), m.group(2)
    if unit not in _UNITS:
        raise ValueError(
            f"unknown unit {unit!r} in {text!r} (ns/us/ms/s, or none for cycles)"
        )
    scale = _UNITS[unit]
    if scale is None:
        return int(round(value))
    return int(round(value * scale * clk_mhz * 1e6))


def fmt_time(cycles, clk_mhz):
    """convert cycles to time string"""
    s = cycles / (clk_mhz * 1e6)
    for unit, scale in (("s", 1.0), ("ms", 1e-3), ("us", 1e-6), ("ns", 1e-9)):
        if s >= scale or unit == "ns":
            return f"{s / scale:.4g} {unit}"
    return f"{s:g} s"


def candidates(lo_cyc, hi_cyc):
    """calculate the candidates for the span"""
    want = hi_cyc - lo_cyc
    out = []
    for n in range(0, 33):
        span = (1 << n) - 1
        out.append(
            {
                "n": n,
                "span": span,
                "actual_hi": lo_cyc + span,
                "width_err": (span - want) / want if want else 0.0,
            }
        )
    return out


def main(argv=None):
    """main function"""
    ap = argparse.ArgumentParser(
        description="Pick freq_num / freq_span for a given pacer interval range.",
        epilog="Times take ns/us/ms/s or cycles (cyc).",
    )
    ap.add_argument("low", help="minimum interval, e.g. 1ms")
    ap.add_argument("high", nargs="?", help="maximum interval")
    ap.add_argument(
        "--clk-mhz", type=float, default=200.0, help="core clock (default 200)"
    )
    ap.add_argument("--iters", type=int, default=None, help="num of rounds")
    ap.add_argument("--all", action="store_true", help="list all candidates")
    a = ap.parse_args(argv)

    clk = a.clk_mhz
    lo = parse_time(a.low, clk)
    if lo <= 0:
        sys.exit("the minimum interval must be > 0")

    # ---- fixed interval -------------------------------------------------------
    if a.high is None:
        print(f"fixed interval (no jitter), {clk:g} MHz\n")
        print(f"  demo_freq={lo}        # {fmt_time(lo, clk)}")
        print(f"  demo_span=0")
        if a.iters:
            print(f"\n  {a.iters} rounds ~ {fmt_time(lo * a.iters, clk)}")
        return 0

    hi = parse_time(a.high, clk)
    if hi <= lo:
        sys.exit(f"the maximum ({hi} cyc) must exceed the minimum ({lo} cyc)")

    want = hi - lo
    cands = candidates(lo, hi)

    # closest achievable width, then prefer the one that does not undershoot
    best = min(cands, key=lambda c: (abs(c["width_err"]), -c["span"]))
    over = min(
        (c for c in cands if c["span"] >= want), key=lambda c: c["span"], default=None
    )
    under = max(
        (c for c in cands if c["span"] <= want), key=lambda c: c["span"], default=None
    )

    print(
        f"want {fmt_time(lo, clk)} ~ {fmt_time(hi, clk)}  "
        f"({lo:,} ~ {hi:,} cycles @ {clk:g} MHz)"
    )
    print(f"want {want:,} cycles, but span must be 2^N-1\n")

    rows = cands if a.all else [c for c in (under, over) if c]
    print(f"  {'N':>2}  {'span':>12}  {'actual range':>26}  {'width error':>9}")
    print(f"  {'-'*2}  {'-'*12}  {'-'*26}  {'-'*9}")
    for c in sorted({id(x): x for x in rows}.values(), key=lambda c: c["n"]):
        mark = ""
        if c is best:
            mark = "  <- closest"
        rng = f"{fmt_time(lo, clk)} ~ {fmt_time(c['actual_hi'], clk)}"
        print(
            f"  {c['n']:>2}  0x{c['span']:08X}  {rng:>26}  {c['width_err']:+8.1%}{mark}"
        )

    ah = best["actual_hi"]
    mean = (lo + ah) / 2
    print(f"\nrecommended setting:")
    print(f"  demo_freq={lo}")
    print(f"  demo_span=0x{best['span']:X}")
    print(
        f"  -> actual {fmt_time(lo, clk)} ~ {fmt_time(ah, clk)},"
        f"average {fmt_time(mean, clk)} (uniform distribution)"
    )

    warn = []
    hi_s = ah / (clk * 1e6)
    if hi_s > COLLECT_TIMEOUT_S:
        warn.append(
            f"maximum interval {fmt_time(ah, clk)} exceeds the host's collect timeout "
            f"({COLLECT_TIMEOUT_S:g} s) -> the round will return kErrStuck instead of waiting slowly."
            f"Either shrink the span, or increase the kCollectTimeoutNs."
        )
    if best["span"] >= (1 << 32):
        warn.append("span exceeds 32-bit register width")
    if abs(best["width_err"]) > 0.25:
        warn.append(
            f"width error {best['width_err']:+.0%} too large. If you must have an exact upper bound,"
            f"change to multiply-and-shift (span to range, one DSP58 cost)."
        )
    if a.iters:
        total = mean * a.iters
        warn.append(
            f"{a.iters:,} rounds x average {fmt_time(mean, clk)} "
            f"~ {fmt_time(total, clk)} (without round trip itself)"
        )

    if warn:
        print()
        for w in warn:
            print(f"warning: {w}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
