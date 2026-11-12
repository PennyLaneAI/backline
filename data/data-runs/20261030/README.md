# HSB vs ERNIC on the threadripper, 2026-10-30

The CPU echo and GPU echo traces behind the HSB-versus-ERNIC comparison, in `sw-for-loop` and
back-to-back `hw-for-loop`, 10^6 rounds each.

| Prefix | Bitstream | Engine clock |
|---|---|---|
| `hsb.` | hwhs-hsb in front of NVIDIA's Holoscan Sensor Bridge | 250 MHz |
| `ernic.` | hwhs on AMD's ERNIC | 200 MHz |

## Drawing the figures

From `data/`:

```bash
make 20261030
```

## Reproducing the dataset

From `benchmarks/`, with the default `config/machines.toml`, which describes the threadripper, once
with `[vpk] bitstream = "hsb"` and once with `"ernic"`. HSB needs the plain-WRITE image (see
[`docs/bitstreams.md`](../../../docs/bitstreams.md)).

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
