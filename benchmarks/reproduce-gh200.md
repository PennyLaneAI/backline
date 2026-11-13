# Reproducing the FPGA echo benchmarks on the GH200

This guide reproduces the round-trip measurements for three FPGA network IPs on the VPK120: HSB
(NVIDIA Holoscan Sensor Bridge), ERNIC (AMD), BALBOA (ETH Zurich's Roce v2 stack). The coprocessor is a GH200. For each IP you run
four cells of 10^6 rounds: CPU echo and GPU echo, each in sw-loop and hw-loop.

Install the software, build both bundles, and tune the machines using
[`INSTALL_GH200.md`](../INSTALL_GH200.md). That guide specifies the source branches, GH200
libraries, machine configuration, and environment needed here.

## Results to compare against

All values are in µs over 10^6 rounds, with round 0 dropped. Each cell is a single run. The CSVs are
in [`data/data-runs/20261105/`](../data/data-runs/20261105/).

| FPGA | Cell | Mean | Std | Min | Median | P99 | P99.9 | P99.99 | P99.999 | Max |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| HSB | CPU sw-loop | 2.090 | 0.032 | 2.012 | 2.096 | 2.148 | 2.188 | 2.220 | 2.232 | 3.072 |
| HSB | CPU hw-loop | 2.083 | 0.032 | 2.008 | 2.088 | 2.140 | 2.180 | 2.208 | 2.224 | 3.088 |
| HSB | GPU sw-loop | 4.437 | 0.163 | 4.172 | 4.480 | 4.692 | 4.756 | 4.900 | 5.504 | 6.264 |
| HSB | GPU hw-loop | 4.459 | 0.104 | 4.240 | 4.460 | 4.644 | 4.712 | 4.852 | 5.628 | 6.244 |
| ERNIC | CPU sw-loop | 2.661 | 0.037 | 2.585 | 2.660 | 2.725 | 2.750 | 3.180 | 3.945 | 10.510 |
| ERNIC | CPU hw-loop | 2.820 | 0.035 | 2.745 | 2.825 | 2.880 | 2.900 | 3.340 | 4.105 | 10.320 |
| ERNIC | GPU sw-loop | 4.959 | 0.106 | 4.750 | 4.965 | 5.130 | 5.260 | 5.580 | 6.310 | 12.405 |
| ERNIC | GPU hw-loop | 5.083 | 0.105 | 4.870 | 5.085 | 5.260 | 5.450 | 5.705 | 6.925 | 13.600 |
| BALBOA | CPU sw-loop | 2.641 | 0.033 | 2.552 | 2.648 | 2.700 | 2.708 | 2.852 | 2.880 | 3.644 |
| BALBOA | CPU hw-loop | 2.634 | 0.032 | 2.556 | 2.640 | 2.692 | 2.704 | 2.892 | 2.900 | 2.956 |
| BALBOA | GPU sw-loop | 4.939 | 0.166 | 4.664 | 5.000 | 5.188 | 5.248 | 5.392 | 5.572 | 6.424 |
| BALBOA | GPU hw-loop | 4.929 | 0.166 | 4.652 | 4.972 | 5.176 | 5.300 | 5.444 | 5.660 | 6.444 |

## 1. Prepare a session

Follow [Session setup and checks](../INSTALL_GH200.md#6-session-setup-and-checks) to activate
Catalyst's virtual environment, select `config/machines.rhino.toml` and the built bundles,
and check the GH200 and board. Reapply the [boot-time tuning](../INSTALL_GH200.md#53-after-every-gh200-boot)
after a GH200 reboot and the [ERNIC ARP entry](../INSTALL_GH200.md#54-after-every-ernic-board-boot)
after booting that board image.

The board carries one image at a time. Follow [`docs/bitstreams.md`](../docs/bitstreams.md)
to boot and check it, then set `[vpk] bitstream` in `config/machines.rhino.toml` to the image:
`"hsb"`, `"balboa"`, or `"ernic"`.

## 2. Run

Run these commands on the build machine, in the environment prepared above.
First a smoke test of 1000 rounds:

```bash
cd ~/backline/benchmarks
./bench.py --ctrl hw-handshake-sw-loop --coproc cpu-echo --iters 1000 -o /tmp/smoke.csv
```

Then the four cells. The board writes each hw-loop trace, so copy it off after the run:

```bash
cd ~/backline/benchmarks
B=$(python3 -c 'import placement; print(placement.VPK_BITSTREAM)')
BOARD=petalinux@192.168.3.15    # your board's SSH account and management address
for P in cpu-echo gpu-echo; do
  ./bench.py --ctrl hw-handshake-sw-loop --coproc "$P" --iters 1000000 -o "$B.sw-for-loop.$P.csv"
  ./bench.py --ctrl hw-handshake-hw-loop --coproc "$P" --iters 1000000 --pacer-freq 0 \
      --pacer-trace-out /tmp/rtt_trace.csv
  scp "$BOARD:/tmp/rtt_trace.csv" "$B.hw-for-loop.$P.b2b.csv"
done
```

Run this once per image: boot the next image, repeat [Prepare a session](#1-prepare-a-session),
and run the four cells again.

Each sw-loop run prints its percentiles. Each hw-loop run prints `engine ran 1000000 round(s)` and
`pacer_cnt=1000000 timeouts=0 compare_errors=0`. For the numbers, drop round 0 of each CSV and take
the percentiles of `rtt_us` (sw-loop) or `ns` (hw-loop). Convert the hw-loop values from ns to µs
before comparing them with the table above.

## If something goes wrong

| Symptom | Cause |
|---|---|
| The handshake never completes, and `ping 192.168.0.2` from the GH200 gets no reply | The link to the board is down |
| The next run hangs, or picks a port other than 9811 | An executor is left from an earlier run: `pgrep -af catalyst-executor` on the GH200 and on the board, then kill it |
| `bench.py` ends in a segmentation fault after the coprocessor fails | It leaves executors running on the GH200 and on the board. Kill them before the next run |
| ERNIC: the handshake completes, then nothing | The board has no permanent ARP entry for 192.168.1.10 ([ERNIC board setup](../INSTALL_GH200.md#54-after-every-ernic-board-boot)) |
| BALBOA: every round times out after an earlier run failed | A failed session leaves BALBOA's send path stuck until the board is programmed again. Run `make boot` again, and start the next run with `--iters 1` |
| A result that does not match | Run the checks in [`INSTALL_FPGA.md`](../INSTALL_FPGA.md#2-check-the-image) |
| GPU runs die with `libcatalyst_transport_gpu_verbs_coprocessor.so: cannot open shared object file` | The GPU backend is not in `rhino-bundle` ([bundle installation](../INSTALL_GH200.md#44-bundles)) |
| Every 64th round about 0.6 µs slow | `LD_LIBRARY_PATH` does not reach `/opt/shared/rdma-core-v65/build/lib`; check the [runtime configuration](../INSTALL_GH200.md#3-configure-the-build-and-runtime) |
