# Reproducing the FPGA echo benchmarks on the GH200

This guide reproduces the round-trip measurements for three FPGA network IPs on the VPK120: HSB
(NVIDIA Holoscan Sensor Bridge), ERNIC (AMD), BALBOA (ETH Zurich's Roce v2 stack). The coprocessor is a GH200. For each IP you run
four cells of 10^6 rounds: CPU echo and GPU echo, each in sw-loop and hw-loop.

## Code

| Repository | Branch |
|---|---|
| [catalyst](https://github.com/PennyLaneAI/catalyst) | `rniczh/transport-balboa` ([#3469](https://github.com/PennyLaneAI/catalyst/pull/3469)) |
| [backline](https://github.com/PennyLaneAI/backline) | `rniczh/support-hsb-and-balboa` |
| [backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120) | `rniczh/add-balboa-hwhs-sw` |

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

## Machines

| Machine | Login | Role |
|---|---|---|
| laptop | | builds everything and drives the runs |
| GH200 | your account | coprocessor |
| VPK120 board | `petalinux` | controller |

The board's 100G port is cabled to a ConnectX-7 port on the GH200, `enp1s0f1np1` (`mlx5_1`) below.
That port carries two link addresses: 192.168.1.10 (GID 3: `::ffff:192.168.1.10, RoCE v2`) for ERNIC,
and 192.168.0.1 (GID 5: `::ffff:192.168.0.1, RoCE v2`) for HSB and BALBOA.

## Bitstreams

The board carries one image at a time. [`INSTALL.FPGA.md`](../INSTALL.FPGA.md) covers
booting the board from each image and checking it.

## 1. Set up the GH200

Our GH200, `rhino`, runs Ubuntu 22.04.4 LTS with kernel `6.8.0-1040-nvidia-64k`. It has
MLNX OFED package `24.07-0.6.1.0`, CUDA toolkit package `12.4.1-1`, and NVIDIA open driver
package and DKMS version `550.144.03` installed.

Run these commands on your GH200 machine.

Do this setup once. `/opt/shared` is writable by everyone, so build rdma-core and HIP there as
your normal user, without `sudo`. The commands below use CMake with `make`.

**rdma-core v65.** Older libmlx5 builds, such as MLNX_OFED 24.07's, delay every 64th send by about
0.6 µs; v65's does not. `config/machines.rhino.toml` loads it from `/opt/shared/rdma-core-v65`.
rdma-core is built with `IN_PLACE`, which compiles its own path into the libraries, so build it
where it is going to stay:

```bash
git clone --depth 1 -b v65.0 https://github.com/linux-rdma/rdma-core /opt/shared/rdma-core-v65
cd /opt/shared/rdma-core-v65 && mkdir build && cd build
cmake -G "Unix Makefiles" -DIN_PLACE=1 -DNO_MAN_PAGES=1 -DNO_PYVERBS=1 -DENABLE_STATIC=0 .. && make
```

**CUDA and HIP for NVIDIA.** Our GH200 uses CUDA 12.4. Before running on your own GH200,
update `CUDA_HOME` under `[server.executor.env]` in
[`config/machines.rhino.toml`](../config/machines.rhino.toml#L67) to your CUDA toolkit's
installation directory. The checked-in value, `/usr/local/cuda-12.4/`, matches `rhino`; your
installation may use `/usr/local/cuda` or a different versioned path.

xbuild expects HIP at `/opt/shared/hip-nv/hip-install` and uses its hipcc to compile the GPU
backend on the GH200. If that HIP installation is missing, install it with the commands below.
They use the `rocm-7.0.2` tags for compatibility with `rhino`'s CUDA 12.4; ROCm 7.1 needs
CUDA 12.8, which is not installed on `rhino`. If your CUDA version differs, choose a compatible
HIP release.

```bash
H=/opt/shared/hip-nv; V=$H/rocm-7.0.2; P=$H/hip-install
mkdir -p $V && cd $V
git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hip
git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hipother
git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/clr
(cd clr && git sparse-checkout set hipamd/include)
cd $H && git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/llvm-project hipcc-src
(cd hipcc-src && git sparse-checkout set amd/hipcc)
cmake -S hipcc-src/amd/hipcc -B hipcc-src/amd/hipcc/build -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$P
make -C hipcc-src/amd/hipcc/build install
mkdir -p $P/include/hip
cp -r $V/hip/include/hip/. $V/hipother/hipnv/include/hip/. $V/clr/hipamd/include/hip/. $P/include/hip/
tee $P/include/hip/hip_version.h >/dev/null <<'EOF'
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

**Isolated cores.** The coprocessor polls on core 24
([`cpu_pin=24`](../config/machines.rhino.toml#L49) in the machines file). Add this to the kernel
command line and reboot:

```
isolcpus=managed_irq,domain,24-26 nohz_full=24-26 rcu_nocbs=24-26 irqaffinity=0-23,27-71
```

**After every boot.** Put the port to the board in an identity IOMMU domain (it must be alone in its
IOMMU group), give it both link addresses, 192.168.1.10 first so that it gets GID 3 and 192.168.0.1
GID 5, and run [`scripts/rt_tune.sh`](../scripts/rt_tune.sh), copied to the GH200:

```bash
NIC=enp1s0f1np1
PCI=$(basename "$(readlink /sys/class/net/$NIC/device)")
GRP=$(basename "$(readlink /sys/class/net/$NIC/device/iommu_group)")
echo $PCI     | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
echo identity | sudo tee /sys/kernel/iommu_groups/$GRP/type
echo $PCI     | sudo tee /sys/bus/pci/drivers/mlx5_core/bind
sudo ip link set $NIC mtu 4200 up
sudo ip addr add 192.168.1.10/24 dev $NIC
sudo ip addr add 192.168.0.1/24 dev $NIC
sudo ./rt_tune.sh 24,25,26 $NIC
```

**Configs.** In `config/xbuild/targets/rhino.conf`, set `TARGET_BUILD_HOST` and the `host=` in
`SYSROOT_PROVIDER_ARGS` to the GH200. If it does not run Ubuntu 22.04, update the rest of that file
with `make probe TARGET=rhino SSH=<user>@<host>` in `config/xbuild`. In
`config/machines.rhino.toml`, set `host` under `[server.executor]` and `coproc_endpoint` under
`[vpk.hsb]` and `[vpk.balboa]` to the GH200, `host` under `[vpk.executor]` to the board, and `dev`,
`gid` and `cpu_pin` in `[server] config` and in both tables' `coproc_config` if they differ. The ssh user for the
GH200 is your laptop login, unless you add `user = "<user>"` under `[server.executor]`.

## 2. Build on the laptop

These steps are for macOS with Homebrew. On Linux, use your distribution's `clang`, `lld` and
`llvm` packages instead.

```bash
brew install llvm@22 lld@22
export PATH="$(brew --prefix llvm@22)/bin:$(brew --prefix lld@22)/bin:$PATH"   # both are keg-only
```

**Catalyst.** Build it from source, following backline's
[INSTALL.md, "Catalyst / From source"](../INSTALL.md#from-source), using the branch below instead
of the tagged release.

The requirements install below provides CMake and Ninja inside the venv. Catalyst and
`make catalyst-llvm` require Ninja, even though their entry point is `make`; no system Ninja
installation is needed.

```bash
export CATALYST_ROOT=~/catalyst
git clone --branch rniczh/transport-balboa --recurse-submodules --shallow-submodules \
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

**LLVM for the two executors.** The board and the GH200 are both aarch64, but they have different
C libraries, so each needs its own LLVM. Each build takes about an hour. The GH200's LLVM gets its
own directory, so that it does not overwrite the board's:

```bash
cd $X
make catalyst-llvm TARGET=vpk120 CATALYST=$C
make catalyst-llvm TARGET=rhino  CATALYST=$C LLVM_OUTDIR=$C/mlir/llvm-project/build-aarch64-rhino
```

**Sysroots.** The board's comes from distribution packages. The GH200's is copied off it over ssh.

```bash
cd $X
make sysroot TARGET=vpk120
make sysroot TARGET=rhino
```

**Cross-compile.** The GH200's executor needs `-DLLVM_DIR`. Without it, xbuild can pick the board's
aarch64 LLVM.

```bash
cd $X
make build TARGET=vpk120 CATALYST=$C COMPONENT="executor rt-capi rtd-null-qubit rt-transport \
    hwhs-capi-backend hwhs-controller-session swhs-capi-backend hsb-hwhs-capi-backend \
    balboa-hwhs-capi-backend"
make build TARGET=rhino CATALYST=$C COMPONENT="rt-transport rt-capi rtd-null-qubit \
    cpu-verbs-controller cpu-verbs-coprocessor echo-coprocessor-cpu steane-coprocessor-cpu gpu-coprocessor"
make build TARGET=rhino CATALYST=$C COMPONENT=executor \
    COMPONENT_CMAKE_ARGS="-DCATALYST_SRC=$C -DLLVM_DIR=$C/mlir/llvm-project/build-aarch64-rhino/lib/cmake/llvm"
```

`gpu-coprocessor` holds GPU code, and nvcc does not cross-compile it, so xbuild builds it on the
GH200 over ssh, with the HIP from step 1, and copies the library back.

## 3. Bundle

Assemble both bundles:

```bash
cd $X
make bundle TARGET=rhino  BUNDLE=rhino-bundle CATALYST=$C
make bundle TARGET=vpk120 BUNDLE=vpk-bundle   CATALYST=$C
ls build/bundles/rhino-bundle     # 11 entries, including libcatalyst_transport_gpu_verbs_coprocessor.so
```

`rhino-bundle` warns that `libcudart.so.12` is missing. That is expected: the GH200 loads it from
`/usr/local/cuda`.

## 4. Before a session

As mentioned before, the VPK120's 100G port is connected to the GH200's `enp1s0f1np1` interface (`mlx5_1`).

Run these on the GH200. If `pgrep` lists executors of yours, kill them. If anything else differs,
redo "After every boot" in [step 1](#1-set-up-the-gh200).

| Check | Expect |
|---|---|
| `ip -br link show enp1s0f1np1` | `UP` |
| `ip -br addr show enp1s0f1np1` | `192.168.1.10/24 192.168.0.1/24` |
| `cat /sys/devices/system/cpu/isolated` | `24-26` |
| `cat /sys/class/net/enp1s0f1np1/device/iommu_group/type` | `identity` |
| `pgrep -af catalyst-executor` | nothing |

Then check the board with the [checks](../INSTALL.FPGA.md#2-check-the-image) for its image. With the ERNIC
image, the board also needs a permanent ARP entry for the GH200 after every boot. On the board, with
the MAC address of `enp1s0f1np1`:

```bash
sudo ip neigh replace 192.168.1.10 lladdr <MAC> dev eth0 nud permanent
```

## 5. Run

On the laptop, with the venv active, point backline at the GH200's machines file:

```bash
export BACKLINE_MACHINES=config/machines.rhino.toml
```

Set `[vpk] bitstream` in `config/machines.rhino.toml` to the image on the board: `"hsb"`,
`"balboa"` or `"ernic"`.

First a smoke test of 1000 rounds:

```bash
cd ~/backline/benchmarks
./bench.py --ctrl hw-handshake-sw-loop --coproc cpu-echo --iters 1000 -o /tmp/smoke.csv
```

Then the four cells. The board writes each hw-loop trace, so copy it off after the run:

```bash
cd ~/backline/benchmarks
B=$(python3 -c 'import placement; print(placement.VPK_BITSTREAM)')
BOARD=petalinux@<board address>
for P in cpu-echo gpu-echo; do
  ./bench.py --ctrl hw-handshake-sw-loop --coproc "$P" --iters 1000000 -o "$B.sw-for-loop.$P.csv"
  ./bench.py --ctrl hw-handshake-hw-loop --coproc "$P" --iters 1000000 --pacer-freq 0 \
      --pacer-trace-out /tmp/rtt_trace.csv
  scp "$BOARD:/tmp/rtt_trace.csv" "$B.hw-for-loop.$P.b2b.csv"
done
```

Run this once per image: boot the other image, change `[vpk] bitstream`, and run it again.

Each sw-loop run prints its percentiles. Each hw-loop run prints `engine ran 1000000 round(s)` and
`pacer_cnt=1000000 timeouts=0 compare_errors=0`. For the numbers, drop round 0 of each CSV and take
the percentiles of `rtt_us` (sw-loop) or `ns` (hw-loop).

## If something goes wrong

| Symptom | Cause |
|---|---|
| The handshake never completes, and `ping 192.168.0.2` from the GH200 gets no reply | The link to the board is down |
| The next run hangs, or picks a port other than 9811 | An executor is left from an earlier run: `pgrep -af catalyst-executor` on the GH200 and on the board, then kill it |
| `bench.py` ends in a segmentation fault after the coprocessor fails | It leaves executors running on the GH200 and on the board. Kill them before the next run |
| ERNIC: the handshake completes, then nothing | The board has no permanent ARP entry for 192.168.1.10 ([step 4](#4-before-a-session)) |
| HSB: the handshake completes, then every round times out | The board carries the stock HSB image, which sends WRITE_WITH_IMM. Boot the `hsb_hwhs/` image ([Bitstreams](#bitstreams)) |
| BALBOA: every round times out after an earlier run failed | A failed session leaves BALBOA's send path stuck until the board is programmed again. Run `make boot` again, and start the next run with `--iters 1` |
| A result that does not match | Run the checks in [`INSTALL.FPGA.md`](../INSTALL.FPGA.md#2-check-the-image) |
| GPU runs die with `libcatalyst_transport_gpu_verbs_coprocessor.so: cannot open shared object file` | The GPU backend is not in `rhino-bundle` ([step 3](#3-bundle)) |
| Every 64th round about 0.6 µs slow | `LD_LIBRARY_PATH` does not reach `/opt/shared/rdma-core-v65/build/lib` |
