# VPK120 bitstreams

The VPK120 board carries one image at a time, and the image decides which network IP the
controller drives. Set `[vpk] bitstream` in the machines file to the image on the board.

| IP | Image source | Engine clock | `[vpk] bitstream` |
|---|---|---|---|
| ERNIC | [backline-vpk120 `v0.1.0`](https://github.com/PennyLaneAI/backline-vpk120/tree/v0.1.0) | 200 MHz | `"ernic"` |
| HSB | [backline-vpk120 `hsb_hwhs/`](https://github.com/PennyLaneAI/backline-vpk120/tree/rniczh/add-balboa-hwhs-sw/hsb_hwhs) | 250 MHz | `"hsb"` |
| BALBOA | [backline-vpk120 `balboa_hwhs/`](https://github.com/PennyLaneAI/backline-vpk120/tree/rniczh/add-balboa-hwhs-sw/balboa_hwhs) | 250 MHz | `"balboa"` |

HSB and BALBOA both take 192.168.0.2, so the server's port needs a second address, 192.168.0.1,
and the coprocessor uses that address's RoCE v2 GID. ERNIC uses the server's own fabric address.

## Booting HSB or BALBOA

Set the board's boot-mode switches to JTAG, power-cycle it, and run `make boot` from `hsb_hwhs/`
or `balboa_hwhs/` with Vivado 2024.2's `settings64.sh` sourced.

The ERNIC image boots from the board's SD card instead; see
[backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120/tree/v0.1.0).

## Checks

Before trusting a result, check that the board carries the image you expect:

| IP | Check | Expect |
|---|---|---|
| HSB | `sudo hsbctl status` | `hsb_init_done=1`, `hif clock 250000000 Hz` |
| HSB | `sudo mrmac-up -s` | `status 1 aligned 1` |
| HSB, on the server | `ping 192.168.0.2` | replies |
| BALBOA | `sudo balboactl status` | `stack_up=1`, `net clock 250000000 Hz` |
| BALBOA | `sudo mrmac-up -s` | `status 1 aligned 1` |
| BALBOA, on the server | `ping 192.168.0.2` | replies |
