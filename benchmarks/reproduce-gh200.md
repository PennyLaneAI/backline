# Reproducing the FPGA echo benchmarks on the GH200

This guide reproduces the round-trip measurements for two FPGA network IPs on the VPK120: HSB
(NVIDIA Holoscan Sensor Bridge) and ERNIC (AMD). The coprocessor is rhino, a GH200. For each IP
you run four cells of 10^6 rounds: CPU echo and GPU echo, each in sw-loop and hw-loop.

## Code

| Repository | Branch | Commit |
|---|---|---|
| [catalyst](https://github.com/PennyLaneAI/catalyst) | `rniczh/transport-lost-request` ([#3468](https://github.com/PennyLaneAI/catalyst/pull/3468)) | `be06c8c80` |
| [backline](https://github.com/PennyLaneAI/backline) | `rniczh/support-hsb-and-balboa` | the one carrying this guide (`ea59c78` or later) |
| [backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120) | `rniczh/add-hsb-patches` | `080d536` |

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

## Machines

| Machine | Address | Access |
|---|---|---|
| your laptop | | builds everything and drives the runs |
| rhino (GH200) | 192.168.3.12 | your own account |
| VPK120 board | 192.168.3.15 |  |

The board's 100G port is cabled to rhino's `enp1s0f1np1` (`mlx5_1`); check the link before a
session (step 4). The two link addresses are on that port: 192.168.1.10 (GID 3) is used by ERNIC,
and 192.168.0.1 (GID 5) by HSB.

## Bitstreams

The board carries one image at a time. [`docs/bitstreams.md`](../docs/bitstreams.md) covers
booting the board from each image and checking it.

## 1. Build on the laptop

These steps are for macOS with Homebrew. On Linux, use your distribution's `clang`, `lld` and
`llvm` packages instead.

```bash
brew install llvm lld
export PATH="$(brew --prefix llvm)/bin:$PATH"     # xbuild needs llvm-readelf
```

**Catalyst.** Build it from source, following backline's
[INSTALL.md, "Catalyst / From source"](../INSTALL.md#from-source), with this branch instead of the
tagged release:

```bash
export CATALYST_ROOT=~/catalyst
git clone --branch rniczh/transport-lost-request --recurse-submodules --shallow-submodules \
    https://github.com/PennyLaneAI/catalyst.git "$CATALYST_ROOT"
cd "$CATALYST_ROOT"
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
make all
```

Keep this venv active for everything below.

**backline:**

```bash
git clone --branch rniczh/support-hsb-and-balboa https://github.com/PennyLaneAI/backline.git ~/backline
C=$CATALYST_ROOT
X=~/backline/config/xbuild
```

**LLVM for the two executors.** The board and rhino are both aarch64, but they have different
C libraries, so each needs its own LLVM. Each build takes about an hour. rhino's LLVM gets its own
directory, so that it does not overwrite the board's:

```bash
cd $X
make catalyst-llvm TARGET=vpk120 CATALYST=$C
make catalyst-llvm TARGET=rhino  CATALYST=$C LLVM_OUTDIR=$C/mlir/llvm-project/build-aarch64-rhino
```

**Sysroots.** The board's comes from distribution packages. rhino's is copied over ssh.
`mode=copy` is required: it fixes rhino's absolute symlinks, and without it the libraries fail to
load on rhino with `undefined symbol: __frexpl`.

```bash
cd $X
make sysroot TARGET=vpk120

D=~/rhino-sysroot; mkdir -p $D
EX=(--exclude "/modules/***" --exclude "/firmware/***" --exclude "/debug/***" --exclude "*.debug" \
    --exclude "/locale/***" --exclude "/man/***" --exclude "/doc/***" --exclude "__pycache__/")
for p in /lib /lib64 /usr/lib /usr/lib64 /usr/include /usr/local/lib /usr/local/include; do
  ssh 192.168.3.12 "test -e $p" || continue
  t=$(ssh 192.168.3.12 "test -L $p && readlink $p")
  if [ -n "$t" ]; then mkdir -p "$(dirname "$D$p")"; ln -sfn "$t" "$D$p"; continue; fi
  mkdir -p "$D$p"; rsync -a "${EX[@]}" 192.168.3.12:$p/ "$D$p/"
done
make sysroot TARGET=rhino SYSROOT_PROVIDER=dir SYSROOT_PROVIDER_ARGS="path=$D mode=copy"
```

**Cross-compile.** The executor needs `-DLLVM_DIR` for rhino. Without it, xbuild can pick the
board's aarch64 LLVM.

```bash
cd $X
make build TARGET=vpk120 CATALYST=$C COMPONENT="executor rt-capi rtd-null-qubit rt-transport \
    hwhs-capi-backend hwhs-controller-session swhs-capi-backend hsb-hwhs-capi-backend"
make build TARGET=rhino CATALYST=$C COMPONENT="rt-transport rt-capi rtd-null-qubit \
    cpu-verbs-controller cpu-verbs-coprocessor echo-coprocessor-cpu steane-coprocessor-cpu gpu-coprocessor"
make build TARGET=rhino CATALYST=$C COMPONENT=executor \
    COMPONENT_CMAKE_ARGS="-DCATALYST_SRC=$C -DCATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM=ON -DLLVM_DIR=$C/mlir/llvm-project/build-aarch64-rhino/lib/cmake/llvm"
```

`gpu-coprocessor` holds GPU code, and nvcc does not cross-compile it, so xbuild builds it on rhino.
`targets/rhino.conf` names rhino as its `TARGET_BUILD_HOST` and HIP's NVIDIA backend in
`/opt/shared/hip-nv/hip-install` as its `TARGET_GPU_SDK` (the appendix shows how it was
installed): xbuild copies the sources to `~/.cache/xbuild/rhino` on rhino over ssh, builds there,
and copies the library back.

## 2. Bundle

Assemble both bundles:

```bash
cd $X
make bundle TARGET=rhino  BUNDLE=rhino-bundle CATALYST=$C
make bundle TARGET=vpk120 BUNDLE=vpk-bundle   CATALYST=$C
ls build/bundles/rhino-bundle     # 11 entries, including libcatalyst_transport_gpu_verbs_coprocessor.so
```

`rhino-bundle` warns that `libcudart.so.12` is missing. That is expected: rhino loads it from
`/usr/local/cuda`.

Point backline at rhino:

```bash
export BACKLINE_MACHINES=config/machines.rhino.toml
```

`config/machines.toml` describes the manuscript's machines; `BACKLINE_MACHINES` makes the demos
and the benchmarks read rhino's file instead. It loads rdma-core v65 from
`/opt/shared/rdma-core-v65` (`[server.executor.env] LD_LIBRARY_PATH`): rhino's own libmlx5 delays
every 64th send by about 0.6 µs, and v65's does not. There is nothing to build for it.

Set `[vpk] bitstream` in `config/machines.rhino.toml` to the image on the board: `"hsb"` or
`"ernic"`. The ssh user for rhino is your laptop login, unless you add
`user = "<your rhino user>"` under `[server.executor]`.

## 3. Before a session

rhino's machine settings are already in place. They are listed here so you can check them. The
ones marked *sudo* need someone with sudo on rhino, and must be redone after rhino reboots.

| Check (no sudo needed) | Expect | If not |
|---|---|---|
| `ip -br link show enp1s0f1np1` | `UP` | the board is cabled to another host. Ask the Backline team |
| `cat /sys/devices/system/cpu/isolated` | `24-26` | kernel command line (`isolcpus`, `nohz_full`, `rcu_nocbs` for 24-26); needs a reboot |
| `cat /sys/kernel/iommu_groups/17/type` | `identity` | *sudo*: rebind the NIC with group 17 set to `identity` |
| `ip -br addr show enp1s0f1np1` | `192.168.1.10/24 192.168.0.1/24` | *sudo*: add them, 192.168.1.10 first so it gets GID 3 |
| `systemctl is-active covalence-endpoint jcagent` | `inactive inactive` | *sudo*: `/opt/shared/turnoff.sh` |
| `pgrep -af catalyst-executor` | nothing | kill your own leftovers, or ask the owner |

`/opt/shared/turnoff.sh` stops Covalence and JumpCloud, which otherwise add 10-240 µs rounds.
Covalence restarts every day at 00:00. While JumpCloud is stopped, new logins to rhino fail, so log
in before it is stopped.

## 4. Run

On the laptop, with the venv active and `[vpk] bitstream` set to the board's image. First a smoke
test of 1000 rounds:

```bash
cd ~/backline/benchmarks
./bench.py --ctrl hw-handshake-sw-loop --coproc cpu-echo --iters 1000 -o /tmp/smoke.csv
```

Then the four cells. The board writes each hw-loop trace, so copy it off after the run:

```bash
cd ~/backline/benchmarks
B=$(python3 -c 'import placement; print(placement.VPK_BITSTREAM)')
BOARD=petalinux@192.168.3.15
for C in cpu-echo gpu-echo; do
  ./bench.py --ctrl hw-handshake-sw-loop --coproc "$C" --iters 1000000 -o "$B.sw-for-loop.$C.csv"
  ./bench.py --ctrl hw-handshake-hw-loop --coproc "$C" --iters 1000000 --pacer-freq 0 \
      --pacer-trace-out /tmp/rtt_trace.csv
  scp "$BOARD:/tmp/rtt_trace.csv" "$B.hw-for-loop.$C.b2b.csv"
done
```

Each sw-loop run prints its percentiles. Each hw-loop run prints `engine ran 1000000 round(s)` and
`pacer_cnt=1000000 timeouts=0 compare_errors=0`. For the numbers, drop round 0 of each CSV and take
the percentiles of `rtt_us` (sw-loop) or `ns` (hw-loop).

## If something goes wrong

| Symptom | Cause |
|---|---|
| Logins to rhino fail with `Permission denied (keyboard-interactive)` | JumpCloud is stopped. Ask for `sudo systemctl start jcagent` |
| The handshake never completes, and `ping 192.168.0.2` from rhino gets no reply | `enp1s0f1np1` is down: the board is cabled to another host |
| The next run hangs, or picks a port other than 9811 | An executor is left from an earlier run: `pgrep -af catalyst-executor` on rhino and on the board, then kill it |
| `bench.py` ends in a segmentation fault after the coprocessor fails | It leaves executors running on rhino and on the board. Kill them before the next run |
| ERNIC: the handshake completes, then nothing | The board has no permanent ARP entry for 192.168.1.10. Ask whoever booted it |
| HSB: the handshake completes, then every round times out | The board carries the stock HSB image, which sends WRITE_WITH_IMM. Boot the `hsb_hwhs/` image ([Bitstreams](#bitstreams)) |
| A result that does not match | Run the checks in [`docs/bitstreams.md`](../docs/bitstreams.md#checks) |
| GPU runs die with `libcatalyst_transport_gpu_verbs_coprocessor.so: cannot open shared object file` | The GPU backend is not in `rhino-bundle` (step 3) |
| `undefined symbol: __frexpl` on rhino | rhino's sysroot was made without `mode=copy` |
| Every 64th round about 0.6 µs slow | `LD_LIBRARY_PATH` does not reach `/opt/shared/rdma-core-v65/build/lib` |

## Appendix: what is in /opt/shared on rhino

These are set up once, by someone with sudo on rhino. Everyone else only uses them.

| Path | What |
|---|---|
| `/opt/shared/turnoff.sh` | stops Covalence and JumpCloud before a session |
| `/opt/shared/rdma-core-v65` | rdma-core v65, built in place; the executor loads its `build/lib` |
| `/opt/shared/hip-nv/hip-install` | hipcc and HIP's headers for NVIDIA, from the `rocm-7.0.2` tags |

rdma-core is built with `IN_PLACE`, which compiles its own path into the libraries. Build it where
it is going to stay, not somewhere else and then copy it:

```bash
sudo git clone --depth 1 -b v65.0 https://github.com/linux-rdma/rdma-core /opt/shared/rdma-core-v65
cd /opt/shared/rdma-core-v65 && sudo mkdir build && cd build
sudo cmake -GNinja -DIN_PLACE=1 -DNO_MAN_PAGES=1 -DNO_PYVERBS=1 -DENABLE_STATIC=0 .. && sudo ninja
```

HIP 7.1 and later need CUDA 12.8 for their NVIDIA path, and rhino has 12.4, so HIP comes from the
`rocm-7.0.2` tags:

```bash
H=/opt/shared/hip-nv; V=$H/rocm-7.0.2; P=$H/hip-install
sudo mkdir -p $V && cd $V
sudo git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hip
sudo git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hipother
sudo git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/clr
(cd clr && sudo git sparse-checkout set hipamd/include)
cd $H && sudo git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/llvm-project hipcc-src
(cd hipcc-src && sudo git sparse-checkout set amd/hipcc)
sudo cmake -S hipcc-src/amd/hipcc -B hipcc-src/amd/hipcc/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$P
sudo ninja -C hipcc-src/amd/hipcc/build install
sudo mkdir -p $P/include/hip
sudo cp -r $V/hip/include/hip/. $V/hipother/hipnv/include/hip/. $V/clr/hipamd/include/hip/. $P/include/hip/
sudo tee $P/include/hip/hip_version.h >/dev/null <<'EOF'
#ifndef HIP_VERSION_H
#define HIP_VERSION_H
#define HIP_VERSION_MAJOR 7
#define HIP_VERSION_MINOR 2
#define HIP_VERSION_PATCH 53211
#define HIP_VERSION_GITHASH "97f5574fe2"
#define HIP_VERSION_BUILD_ID 0
#define HIP_VERSION_BUILD_NAME ""
#define HIP_VERSION (HIP_VERSION_MAJOR * 10000000 + HIP_VERSION_MINOR * 100000 + HIP_VERSION_PATCH)
#endif
EOF
```
