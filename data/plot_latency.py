#!/usr/bin/env python3
"""
plot_latency.py

produce the end-to-end latency figure from the per-round RTT samples in csv

example csv file format:
```
# clk_mhz=200.0
sample,rtt_cycles,rtt_us
0,1184,5.9200
1,660,3.3000
2,652,3.2600
3,652,3.2600
4,654,3.2700
...
```

Hardware-paced traces with a `cycles,ns` header are also supported.

Panels:
  (a) End-to-end latency over time:
    (1) Inliers are blue points on the left y-axis
    (2) Outliers are red line on a second right y-axis
  (b) Histogram of end-to-end latency (percentage, inliers only, mean/median/std,p99-cut)

Usage:
  python3 plot_latency.py samples.csv [-o fig.png] [--skip 1] [--pct 99.0]
  --skip N   drop the first N cold-start samples (default 1)
  --exclude US  drop every sample with latency > US (us) before plotting
  --pct  P   percentile threshold; red = above this percentile (default 99)
  --ymin V   fix the steady-state latency axis lower bound (us)
  --ymax V   fix the steady-state latency axis upper bound (us)
             --ymin/--ymax pin the inlier scale on both panels
  --logy     log-scale the histogram count axis (panel b) so the sparse tail bins stay visible
  --bin-width W   histogram bin spacing in us e.g. 0.005 (5ns) gives one bin per 5 ns

Example:
  python3 plot_latency.py w_reply_in_bram.csv -o fig.png --skip 10 --pct 99  --logy --bin-width 0.0025
"""

import argparse
import sys
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import matplotlib

matplotlib.use("Agg")


def load(path):
    """Return sample numbers and latency in microseconds for either CSV schema."""
    samp, us = [], []
    sample_index = None
    latency_index = None
    latency_scale = 1.0

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(",")

            if latency_index is None:
                columns = [part.strip().lower() for part in parts]
                sample_index = columns.index("sample") if "sample" in columns else None
                if "rtt_us" in columns:
                    latency_index = columns.index("rtt_us")
                elif "ns" in columns:
                    latency_index = columns.index("ns")
                    latency_scale = 1.0 / 1000.0
                else:
                    raise ValueError(
                        f"{path}: expected sample,rtt_cycles,rtt_us or cycles,ns"
                    )
                continue

            try:
                sample = int(parts[sample_index]) if sample_index is not None else len(samp)
                latency = float(parts[latency_index]) * latency_scale
                samp.append(sample)
                us.append(latency)
            except (IndexError, ValueError):
                continue
    return np.asarray(samp, dtype=int), np.asarray(us, dtype=float)


def hist_bins(values, bins, bin_width):
    """Return histogram bin edges: fixed bin_width (us) if set, else `bins` count."""
    if not bin_width:
        return bins
    lo = np.floor(values.min() / bin_width) * bin_width
    edges = np.arange(lo, values.max() + bin_width, bin_width)
    if edges.size < 2:
        sys.exit("--bin-width too large for the data range")
    return edges


def main():
    """Main function"""
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="samples CSV file")
    ap.add_argument("-o", "--out", default="latency.png", help="output image file")
    ap.add_argument(
        "--skip", type=int, default=0, help="drop the first N samples (default 0)"
    )
    ap.add_argument(
        "--pct",
        type=float,
        default=99.0,
        help="percentile threshold (default 99 -> red = top 1%%)",
    )
    ap.add_argument("--bins", type=int, default=40, help="histogram bins (default 40)")
    ap.add_argument(
        "--bin-width",
        type=float,
        default=None,
        help="histogram bin spacing in us (overrides --bins)",
    )
    ap.add_argument(
        "--ymin",
        type=float,
        default=None,
        help="fix steady-state latency axis lower bound (us)",
    )
    ap.add_argument(
        "--ymax",
        type=float,
        default=None,
        help="fix steady-state latency axis upper bound (us)",
    )
    ap.add_argument(
        "--logy",
        action="store_true",
        help="log-scale the histogram count axis (panel b)",
    )
    ap.add_argument(
        "--exclude",
        type=float,
        default=None,
        metavar="US",
        help="drop samples with latency strictly greater than this value (us) "
        "before plotting (e.g. --exclude 60 to remove Covalence/SMI spikes)",
    )
    args = ap.parse_args()

    samp, lat = load(args.csv)
    if lat.size == 0:
        sys.exit(f"no samples parsed from {args.csv}")
    if args.skip > 0:
        samp, lat = samp[args.skip :], lat[args.skip :]
    if args.exclude is not None:
        keep = lat <= args.exclude
        n_excl = int((~keep).sum())
        samp, lat = samp[keep], lat[keep]
        print(f"excluded {n_excl} samples > {args.exclude:g} us")
    n = lat.size
    if n == 0:
        sys.exit("all samples skipped/excluded -- raise --exclude or lower --skip")

    # Split inliers vs outliers
    thr_hi = float(np.percentile(lat, args.pct))
    out_mask = lat > thr_hi
    split_label = f"p{args.pct:g}"
    in_mask = ~out_mask
    inl = lat[in_mask]
    out_idx = np.nonzero(out_mask)[0]
    n_out = out_idx.size
    if inl.size == 0:
        sys.exit("every sample flagged as outlier -- adjust --pct")

    mean = inl.mean()
    median = np.median(inl)
    std = inl.std()
    p99 = np.percentile(lat, 99)
    p999 = np.percentile(lat, 99.9)
    overall_max = float(lat.max())
    print(
        f"inliers (<= {split_label}): mean {mean:.3f} us, std {std*1000:.0f} ns  |  "
        f"tail: p99 {p99:.3f}, p99.9 {p999:.3f}, max {overall_max:.3f} us  |  "
        f"{n_out}/{n} above {split_label} ({100.0*n_out/n:.1f}%)"
    )

    fig, (ax_a, ax_b) = plt.subplots(1, 2, figsize=(11, 4.3))

    # (a) latency over time: inliers on left, outliers on right
    y = lat.copy()
    y[out_mask] = np.nan
    (h_in,) = ax_a.plot(
        np.arange(n), y, color="tab:blue", linestyle="none", marker=".", markersize=1.5
    )
    ax_a.set_xlabel("Sample Number")
    ax_a.set_ylabel(r"End-to-End Latency ($\mu$s)")
    ax_a.set_title("(a) End-to-end latency over time")
    ax_a.grid(True, linestyle=":", linewidth=0.5, alpha=0.6)
    ax_a.margins(x=0.01)
    if args.ymin is not None or args.ymax is not None:
        ax_a.set_ylim(args.ymin, args.ymax)

    handles = [h_in]
    labels = ["steady state (left axis)"]
    if n_out:
        ovals = lat[out_idx]
        omin, omax = float(ovals.min()), float(ovals.max())
        ax_o = ax_a.twinx()
        base = omin * 0.98
        ax_o.set_ylim(base, omax * 1.05)
        ax_o.vlines(out_idx, base, ovals, color="red", linewidth=1.0)
        ax_o.yaxis.set_major_locator(mticker.MaxNLocator(nbins=4, integer=True))
        ax_o.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}"))
        ax_o.yaxis.set_minor_locator(mticker.AutoMinorLocator(5))
        ax_o.yaxis.set_minor_formatter(mticker.NullFormatter())
        ax_o.tick_params(axis="y", which="minor", length=3)
        ax_o.set_ylabel(rf"Outlier latency (> {split_label}, $\mu$s)", color="red")
        ax_o.tick_params(axis="y", which="both", colors="red")
        ax_o.spines["right"].set_color("red")
        handles.append(plt.Line2D([], [], color="red", linewidth=1.0))
        labels.append(f"outlier x{n_out} (right)")
    # Use a visible marker in the legend (actual points are tiny)
    handles[0] = plt.Line2D(
        [], [], color="tab:blue", linestyle="none", marker=".", markersize=6
    )
    ax_a.legend(handles, labels, loc="upper left", fontsize=8, framealpha=0.9)

    # (b) histogram of inliers
    weights = np.ones_like(inl) / inl.size * 100.0
    ax_b.hist(
        inl,
        bins=hist_bins(inl, args.bins, args.bin_width),
        weights=weights,
        color="tab:green",
        edgecolor="black",
        linewidth=0.5,
    )
    ax_b.axvline(
        mean,
        color="red",
        linestyle="--",
        linewidth=1.4,
        label=f"Mean: {mean:.2f} $\\mu$s",
    )
    ax_b.axvline(
        median,
        color="orange",
        linestyle="-",
        linewidth=1.4,
        label=f"Median: {median:.2f} $\\mu$s",
    )
    ax_b.axvline(mean - std, color="tab:blue", linestyle="--", linewidth=1.0)
    ax_b.axvline(
        mean + std,
        color="tab:blue",
        linestyle="--",
        linewidth=1.0,
        label=f"Std Dev: $\\pm${std:.2f} $\\mu$s",
    )
    ax_b.axvline(
        thr_hi,
        color="gray",
        linestyle=":",
        linewidth=1.4,
        label=f"{split_label} cut: {thr_hi:.2f} $\\mu$s",
    )
    ax_b.set_xlabel(r"End-to-End Latency ($\mu$s)")
    ax_b.set_ylabel("Percentage (%)")
    ax_b.set_title("(b) Histogram of end-to-end latency")
    if args.logy:
        ax_b.set_yscale("log")
        ax_b.set_ylim(bottom=100.0 / inl.size)  # floor at one sample's weight
    if args.ymin is not None or args.ymax is not None:
        ax_b.set_xlim(args.ymin, args.ymax)
    ax_b.legend(loc="upper right", fontsize=8, framealpha=0.9)

    fig.tight_layout()
    fig.savefig(args.out, dpi=150, bbox_inches="tight")
    print(
        f"wrote {args.out}  ({inl.size} inliers, {n_out} outliers, skipped {args.skip})"
    )


if __name__ == "__main__":
    main()