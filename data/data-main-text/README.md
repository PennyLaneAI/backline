# Main-text RTT data

This directory contains the five `sw-for-loop` round-trip-time traces used in the manuscript. The
host drives each round while the hardware-handshake engine posts requests and detects replies.

Files are named `sw-for-loop.<responder>.csv`, where the responder is one of:

- `cpu-echo`
- `gpu-echo`
- `cpu-steane`
- `gpu-steane`
- `gpu-qldpc`

Each CSV contains `sample`, `rtt_cycles`, and `rtt_us`, preceded by comments that record the clock
and benchmark configuration.

## Drawing the figures

From the parent `data/` directory:

```bash
make main-text
```

This runs `plot_latency.py` once per CSV and writes the PNGs to `figures/`.

## Reproducing the dataset

From the benchmark directory, run:

```bash
for C in cpu-echo gpu-echo cpu-steane gpu-steane gpu-qldpc; do
  ./bench.py --ctrl hw-handshake-sw-loop \
    --coproc "$C" --iters 1000000 \
    -o "sw-for-loop.$C.csv"
done
```

