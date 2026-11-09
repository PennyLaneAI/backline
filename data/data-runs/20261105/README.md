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

From `benchmarks/`, with rhino as the `[server]` in `config/machines.toml`, once with
`[vpk] bitstream = "hsb"` and once with `"ernic"`:

```bash
./run_echo.sh <directory>
```
