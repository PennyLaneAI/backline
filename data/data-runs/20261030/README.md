# HSB vs ERNIC on the threadripper, 2026-10-30

The CPU echo `hw-for-loop` traces behind the HSB-versus-ERNIC comparison.

| File | Bitstream | Engine clock |
|---|---|---|
| `hsb.hw-for-loop.cpu-echo.b2b.csv` | hwhs-hsb in front of NVIDIA's Holoscan Sensor Bridge | 250 MHz |
| `ernic.hw-for-loop.cpu-echo.b2b.csv` | hwhs on AMD's ERNIC | 200 MHz |

## Drawing the figures

From `data/`:

```bash
make 20261030
```

## Reproducing the dataset

From `benchmarks/`, once with `[vpk] bitstream = "hsb"` in `config/machines.toml` and once with
`"ernic"`:

```bash
BOARD=petalinux@192.168.3.15
./bench.py --ctrl hw-handshake-hw-loop --coproc cpu-echo --iters 1000000 \
  --pacer-freq 0 \
  --pacer-trace-out /tmp/rtt_trace.csv
scp "$BOARD":/tmp/rtt_trace.csv "<bitstream>.hw-for-loop.cpu-echo.b2b.csv"
```
