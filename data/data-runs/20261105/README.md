# HSB vs ERNIC on rhino (GH200), 2026-11-05

The CPU echo and GPU echo traces behind the HSB-versus-ERNIC comparison on rhino, a GH200 (Grace
CPU, H100 GPU) with a ConnectX-7, in `sw-for-loop` and back-to-back `hw-for-loop`, 10^6 rounds
each.

| Prefix | Bitstream | Engine clock |
|---|---|---|
| `hsb.` | hwhs-hsb in front of NVIDIA's Holoscan Sensor Bridge | 250 MHz |
| `ernic.` | hwhs on AMD's ERNIC | 200 MHz |

## Drawing the figures

From `data/`:

```bash
make 20261105
```

## Reproducing the dataset

Follow [`benchmarks/reproduce-gh200.md`](../../../benchmarks/reproduce-gh200.md), which points the
benchmarks at rhino with `BACKLINE_MACHINES=config/machines.rhino.toml`. From `benchmarks/`, once
per image, with `[vpk] bitstream` set to `"hsb"` and `"ernic"` in turn:

```bash
BOARD=petalinux@192.168.3.15
for C in cpu-echo gpu-echo; do
  ./bench.py --ctrl hw-handshake-sw-loop --coproc "$C" --iters 1000000 \
    -o "<bitstream>.sw-for-loop.$C.csv"
  ./bench.py --ctrl hw-handshake-hw-loop --coproc "$C" --iters 1000000 \
    --pacer-freq 0 \
    --pacer-trace-out /tmp/rtt_trace.csv
  scp "$BOARD":/tmp/rtt_trace.csv "<bitstream>.hw-for-loop.$C.b2b.csv"
done
```
