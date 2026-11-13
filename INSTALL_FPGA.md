# Installation of the VPK120 board images

Use this guide to load an image onto the VPK120 board, the controller in the FPGA demos (tier 4 of
[`INSTALL.md`](INSTALL.md)) and in [`benchmarks/reproduce-gh200.md`](benchmarks/reproduce-gh200.md).
The board carries one image at a time, and the image decides which network IP the controller
drives.

## Images

| IP | Image source | Engine clock | `[vpk] bitstream` |
|---|---|---|---|
| ERNIC | [backline-vpk120 `v0.1.0`](https://github.com/PennyLaneAI/backline-vpk120/tree/v0.1.0) | 200 MHz | `"ernic"` |
| HSB | [backline-vpk120 `hsb_hwhs/`](https://github.com/PennyLaneAI/backline-vpk120/tree/rniczh/add-balboa-hwhs-sw/hsb_hwhs) | 250 MHz | `"hsb"` |
| BALBOA | [backline-vpk120 `balboa_hwhs/`](https://github.com/PennyLaneAI/backline-vpk120/tree/rniczh/add-balboa-hwhs-sw/balboa_hwhs) | 250 MHz | `"balboa"` |

Set `[vpk] bitstream` in the machines file to the image on the board.

HSB and BALBOA both take 192.168.0.2, so the server's port needs a second address, 192.168.0.1,
and the coprocessor uses that address's RoCE v2 GID. ERNIC uses the server's own fabric address.

## 1. Load the image

Every image loads the same way. Set the board's boot-mode switches to JTAG, power-cycle it, and run
the image's `jtag-boot.tcl` with `xsdb`, on a host with the board's JTAG cable attached and
Vivado 2024.2's `settings64.sh` sourced. If the cable's permissions are not set up in the host's
udev rules, `xsdb` needs `sudo`.

### 1.1. ERNIC

ERNIC has prebuilt images. Download `hw_ready_for_download_v0.1.0.zip` from the
[backline-vpk120 v0.1.0 release](https://github.com/PennyLaneAI/backline-vpk120/releases/tag/v0.1.0),
then:

```bash
unzip hw_ready_for_download_v0.1.0.zip && cd hw_ready_for_download_v0.1.0
source /path/to/Vivado/2024.2/settings64.sh
xsdb jtag-boot.tcl
```

Log in on the serial console as `petalinux` (and input the appropriate password) and set up the board's network as in
[backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120/tree/v0.1.0), "Network Setup".

### 1.2. HSB and BALBOA

HSB and BALBOA have no prebuilt images, so you build them from backline-vpk120's `hsb_hwhs/` or
`balboa_hwhs/`, on the branch `rniczh/add-balboa-hwhs-sw`
([#11](https://github.com/PennyLaneAI/backline-vpk120/pull/11)). The build needs a Linux host with
Vivado 2024.2, PetaLinux 2024.2 and, for BALBOA, Vitis HLS 2024.2. It also needs AMD's ERNIC VPK120
MRMAC reference design (`reference design VPK120_mrmac_rev_1.3.zip`), which you download from AMD.
From the folder:

```bash
make amd AMD="<dir>/reference design VPK120_mrmac_rev_1.3.zip" WITH_BSP=1
source /path/to/Vivado/2024.2/settings64.sh   # BALBOA: Vitis/2024.2/settings64.sh, for Vitis HLS
make hw JOBS=<N>                                # prints the image's BUILD_ID
source /path/to/petalinux/settings.sh
make petalinux
make boot                                       # with the board in JTAG mode
```

`make hw` takes about an hour. The folder's README has the details and the options.

The image configures the board's network at boot. Log in on the serial console as `root`
(insert root password) or `petalinux` (input password).

## 2. Check the image

Before trusting a result, check that the board carries the image you expect:

| IP | Check | Expect |
|---|---|---|
| HSB | `sudo hsbctl status` | your `BUILD_ID`, `hsb_init_done=1`, `hif clock 250000000 Hz` |
| HSB | `sudo mrmac-up -s` | `status 1 aligned 1` |
| HSB, on the server | `ping 192.168.0.2` | replies |
| BALBOA | `sudo balboactl status` | your `BUILD_ID`, `stack_up=1`, `net clock 250000000 Hz` |
| BALBOA | `sudo mrmac-up -s` | `status 1 aligned 1` |
| BALBOA, on the server | `ping 192.168.0.2` | replies |
