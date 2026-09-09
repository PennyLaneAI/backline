# Appendix RTT data

This directory contains ten hardware-paced round-trip-time traces used in the appendix:

- five back-to-back `hw-for-loop` traces
- five randomly delayed `hw-for-loop` traces

Files follow this pattern:

```text
hw-for-loop.<responder>.<cadence>.csv
```

The responders are `cpu-echo`, `gpu-echo`, `cpu-steane`, `gpu-steane`, and `gpu-qldpc`.

## Pacing cadences

The `hw-for-loop` driver uses the hardware-handshake engine to mimic another engine sending and
receiving data.

| Cadence | `--pacer-freq` | `--pacer-span` | Period | `--iters` |
|---|---:|---:|---|---:|
| `b2b` | `0` | - | Limited by round-trip time | 1,000,000 |
| `random-delayed` | `1000000` | `0xFFFFFFF` | 5 ms-1.347 s; mean 676 ms | 10,000 |

The CSVs contain `cycles` and `ns`; `plot_latency.py` converts nanoseconds to microseconds.

## Drawing the figures

From the parent `data/` directory:

```bash
make appendix
```

This runs `plot_latency.py` once per CSV and writes the PNGs to `figures/`.

## Reproducing the dataset

Prepare the benchmark environment:

```bash
BOARD=petalinux@192.168.3.15
C=cpu-echo  # repeat for every responder
```

The hardware-paced trace remains on the board at `/tmp/t.csv` after each run:

```bash
./bench.py --ctrl hw-handshake-hw-loop --coproc "$C" --iters 1000000 \
  --pacer-freq 0 \
  --pacer-trace-out /tmp/t.csv
scp "$BOARD":/tmp/t.csv "hw-for-loop.$C.b2b.csv"

./bench.py --ctrl hw-handshake-hw-loop --coproc "$C" --iters 10000 \
  --pacer-freq 1000000 \
  --pacer-span 0xFFFFFFF \
  --pacer-trace-out /tmp/t.csv
scp "$BOARD":/tmp/t.csv "hw-for-loop.$C.random-delayed.csv"
```

