# Installation and system tuning for GH200 (rhino)

Use this guide to prepare a GH200 coprocessor and VPK120 controller for
[`benchmarks/reproduce-gh200.md`](benchmarks/reproduce-gh200.md). It is self-contained,
including the source branches, CUDA/HIP versions, and latency tuning used for those experiments.
We will use our set-up as an example, and this can be adapted to your own test set-up.

For backline installation on x86 systems or to reproduce the original manuscript
results, use [`INSTALL.md`](INSTALL.md) instead.

After installation, follow
[`benchmarks/reproduce-gh200.md`](benchmarks/reproduce-gh200.md) to run the echo experiments.
Before each session, repeat [Session setup and checks](#6-session-setup-and-checks).

## Machines and software

| Machine | Role | Requirements |
|---|---|---|
| Build machine (laptop or Linux host) | Builds Catalyst and cross-compiles the Linux bundles; drives the experiments | Build tools below and SSH access to both remote machines |
| GH200 (`rhino`) | Runs the CPU or GPU coprocessor; compiles the GPU backend locally | CUDA, HIP, RDMA libraries, CMake, make, Git, C/C++ development tools, Python 3, rsync, and sudo for system tuning |
| VPK120 board | Runs the FPGA controller | Provisioned board, SSH access as `petalinux`, and sudo for its executor |

The board's 100G port connects to Rhino's ConnectX-7 port `enp1s0f1np1` (`mlx5_1`).
That port carries two addresses:

| FPGA image | Rhino fabric address | RoCE v2 GID |
|---|---|---|
| ERNIC | `192.168.1.10/24` | 3: `::ffff:192.168.1.10` |
| HSB or BALBOA | `192.168.0.1/24` | 5: `::ffff:192.168.0.1` |

Start with the GH200's OS, NVIDIA driver, CUDA toolkit, and OFED provisioned. The reference
Rhino installation uses:

| Software | Reference version |
|---|---|
| OS | Ubuntu 22.04.4 LTS, aarch64 |
| Kernel | `6.8.0-1040-nvidia-64k` |
| MLNX OFED package | `24.07-0.6.1.0` |
| CUDA toolkit package | `12.4.1-1` |
| NVIDIA open driver package and DKMS | `550.144.03` |
| Additional RDMA userspace libraries | rdma-core `v65.0`, built below |
| HIP for NVIDIA | `rocm-7.0.2` sources, assembled below |

Use these source branches for the software and board images:

| Repository | Branch |
|---|---|
| [catalyst](https://github.com/PennyLaneAI/catalyst) | `rniczh/transport-balboa` ([#3469](https://github.com/PennyLaneAI/catalyst/pull/3469)) |
| [backline](https://github.com/PennyLaneAI/backline) | `rniczh/support-hsb-and-balboa` |
| [backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120) | `rniczh/add-balboa-hwhs-sw` |

Board images and provisioning live in `backline-vpk120`.
[`INSTALL_FPGA.md`](INSTALL_FPGA.md) covers booting and checking each image.

## 1. Prepare the build machine

Run this section on the laptop or Linux host that will drive the experiments.

### 1.1. Build tools

Follow the subsection for your build machine's operating system.

#### 1.1.1. macOS with Homebrew

```bash
brew install llvm@22 lld@22
export PATH="$(brew --prefix llvm@22)/bin:$(brew --prefix lld@22)/bin:$PATH"
```

Both packages are keg-only. Keep this `PATH` when building and verifying artifacts; the
verification tools must be available too. You also need Git, make, Python 3, and rsync.

#### 1.1.2. Debian or Ubuntu

```bash
sudo apt update && sudo apt install -y \
    clang lld llvm g++ ccache make git \
    python3 python3-venv python3-dev python3-pip \
    libibverbs-dev ibverbs-providers ibverbs-utils rdma-core \
    ca-certificates curl wget zstd binutils rsync openssh-client
```

Other Linux distributions need equivalent packages. Catalyst's requirements install below
provides CMake and Ninja inside the virtual environment. Catalyst and `make catalyst-llvm`
require Ninja even though their entry point is `make`.

### 1.2. Catalyst and PennyLane

Build Catalyst from source with the branch above and the transport and executor enabled:

#### 1.2.1. Clone Catalyst

```bash
export CATALYST_ROOT=~/catalyst
git clone --branch rniczh/transport-balboa --recurse-submodules --shallow-submodules \
    https://github.com/PennyLaneAI/catalyst.git "$CATALYST_ROOT"
```

#### 1.2.2. Create the virtual environment and install requirements

```bash
cd "$CATALYST_ROOT"
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

#### 1.2.3. Build Catalyst and install PennyLane

```bash
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
make all
```

`make all` installs the PennyLane version pinned by Catalyst. Keep this virtual environment
active for the remaining build steps. Catalyst remains a separate checkout; xbuild reads it
through `CATALYST=`, while the demos and benchmarks use `CATALYST_ROOT`.

### 1.3. backline and machine addresses

#### 1.3.1. Clone backline

```bash
git clone --branch rniczh/support-hsb-and-balboa https://github.com/PennyLaneAI/backline.git ~/backline
```

#### 1.3.2. Set the build paths and SSH destinations

```bash
C=$CATALYST_ROOT
XBUILD_DIR=~/backline/config/xbuild
SERVER=you@192.168.3.12          # your GH200 SSH account and management address
BOARD=petalinux@192.168.3.15    # your board's SSH account and management address
```

The addresses shown are the reference machines' management addresses. Use your own account
and addresses, and put the same values in the configuration files in
[step 3](#3-configure-the-build-and-runtime).

## 2. Install the GH200 libraries

Run this section **on the GH200**. On Rhino, `/opt/shared` is writable by everyone. Build
rdma-core and HIP there as your normal user, without `sudo`. The commands use CMake with make.

### 2.1. rdma-core v65

Older libmlx5 builds, such as MLNX_OFED 24.07's may cause performance issue (we observed
a delay every 64th send by about 0.6 µs); v65's does not.
The runtime configuration loads it from `/opt/shared/rdma-core-v65`.
`IN_PLACE` compiles the build's own path into the libraries, so build it where it will stay:

#### 2.1.1. Clone rdma-core

```bash
git clone --depth 1 -b v65.0 https://github.com/linux-rdma/rdma-core /opt/shared/rdma-core-v65
```

#### 2.1.2. Configure and build in place

```bash
cd /opt/shared/rdma-core-v65 && mkdir build && cd build
cmake -G "Unix Makefiles" -DIN_PLACE=1 -DNO_MAN_PAGES=1 -DNO_PYVERBS=1 -DENABLE_STATIC=0 .. && make
```

### 2.2. CUDA and HIP for NVIDIA

Rhino uses CUDA 12.4 at `/usr/local/cuda-12.4/`. xbuild expects HIP at
`/opt/shared/hip-nv/hip-install` and uses its hipcc to compile the GPU backend on the GH200.
If that HIP installation is missing, install it below.

These commands use the `rocm-7.0.2` tags for compatibility with Rhino's CUDA 12.4. ROCm 7.1
needs CUDA 12.8, which is not installed on Rhino. If your CUDA version differs, use a compatible
HIP release and update the paths in [step 3](#3-configure-the-build-and-runtime).

#### 2.2.1. Fetch the HIP sources

```bash
H=/opt/shared/hip-nv; V=$H/rocm-7.0.2; P=$H/hip-install
mkdir -p $V && cd $V
git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hip
git clone --depth 1 -b rocm-7.0.2 https://github.com/ROCm/hipother
git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/clr
(cd clr && git sparse-checkout set hipamd/include)
cd $H && git clone --depth 1 --filter=blob:none --sparse -b rocm-7.0.2 https://github.com/ROCm/llvm-project hipcc-src
(cd hipcc-src && git sparse-checkout set amd/hipcc)
```

#### 2.2.2. Build and install hipcc

```bash
cmake -S hipcc-src/amd/hipcc -B hipcc-src/amd/hipcc/build -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$P
make -C hipcc-src/amd/hipcc/build install
```

#### 2.2.3. Install the HIP headers

```bash
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

## 3. Configure the build and runtime

### 3.1. Machine addresses

Edit these files in the backline checkout **on the build machine**:

| File | Settings |
|---|---|
| [`config/xbuild/targets/rhino.conf`](config/xbuild/targets/rhino.conf) | Set `TARGET_BUILD_HOST` and `host=` in `SYSROOT_PROVIDER_ARGS` to the GH200 SSH destination. `TARGET_GPU_ARCH=sm_90` selects its GPU; `TARGET_GPU_SDK=/opt/shared/hip-nv/hip-install` selects the HIP installation. |
| [`config/machines.rhino.toml`](config/machines.rhino.toml) | Set `[server.executor] host` and both `[vpk.hsb] coproc_endpoint` and `[vpk.balboa] coproc_endpoint` to the GH200 management address. Set `[vpk.executor] host` to the board. |

The GH200 SSH user defaults to your build-machine login. If it differs, add `user = "<user>"`
under `[server.executor]` and use `user@host` in the target's two SSH settings.

### 3.2. Runtime settings

In `config/machines.rhino.toml`, also check:

#### 3.2.1. Set the CUDA toolkit path

`[server.executor.env] CUDA_HOME` points to your CUDA toolkit. The checked-in
`/usr/local/cuda-12.4/` matches Rhino.

#### 3.2.2. Set the runtime library path

`[server.executor.env] LD_LIBRARY_PATH` includes `.:/opt/shared/rdma-core-v65/build/lib`.
The leading `.` is the deployed bundle.

#### 3.2.3. Set the RDMA device, GIDs, and polling core

`[server] config` uses `dev=mlx5_1;gid=3;cpu_pin=24;rt=0`, and `[server] fabric` is
`192.168.1.10`. HSB and BALBOA use GID 5 in their `coproc_config` entries.
Update the device, GIDs, polling core, and fabric address together if your wiring differs.

#### 3.2.4. Set the executor privileges

`[server.executor] sudo = false` keeps the GH200 executor under your login account.
Its polling thread is pinned to isolated core 24 with `rt=0`; the board executor uses sudo.

#### 3.2.5. Set the bundle directory

`[paths] bundles` is `config/xbuild/build/bundles`, where xbuild publishes the bundles.

### 3.3. Refresh target facts if needed

If the GH200 does not run the reference Ubuntu 22.04 environment, refresh its target facts:

```bash
cd "$XBUILD_DIR"
make probe TARGET=rhino SSH="$SERVER"
```

This reaches the named GH200 over SSH and updates its target description. Keep changes for
your own machines local.

## 4. Build and bundle

Run this section **on the build machine**, with Catalyst's virtual environment active and
`C` and `X` set as in step 1.

### 4.1. Sysroots

Obtain the target headers and libraries before cross-compiling LLVM or the components.
The board's sysroot comes from distribution packages; the GH200's is copied from it over SSH.

#### 4.1.1. Obtain the VPK120 sysroot

```bash
cd "$CATALYST_ROOT"
make sysroot TARGET=vpk120
```

#### 4.1.2. Copy the GH200 sysroot

```bash
make sysroot TARGET=rhino
```

### 4.2. LLVM for the two executors

Both targets are aarch64, but their C libraries differ, so each needs its own LLVM build.
Each build takes about an hour. Give the GH200 build its own output directory so it does not
overwrite the board's:

#### 4.2.1. Build LLVM for the VPK120

```bash
cd "$CATALYST_ROOT"
make catalyst-llvm TARGET=vpk120 CATALYST="$CATALYST_ROOT"
```

#### 4.2.2. Build LLVM for the GH200

```bash
make catalyst-llvm TARGET=rhino CATALYST="$CATALYST_ROOT" LLVM_OUTDIR="$C/mlir/llvm-project/build-aarch64-rhino"
```

### 4.3. Components

The GH200 executor needs an explicit `-DLLVM_DIR`; without it, xbuild can select the board's
aarch64 LLVM. Name the components in each build:

#### 4.3.1. Build the VPK120 components

```bash
cd "$CATALYST_ROOT"
make build TARGET=vpk120 CATALYST="$CATALYST_ROOT" COMPONENT="executor rt-capi rtd-null-qubit rt-transport \
    hwhs-capi-backend hwhs-controller-session swhs-capi-backend hsb-hwhs-capi-backend \
    balboa-hwhs-capi-backend"
```

#### 4.3.2. Build the GH200 runtime and backends

```bash
make build TARGET=rhino CATALYST="$CATALYST_ROOT" COMPONENT="rt-transport rt-capi rtd-null-qubit \
    cpu-verbs-controller cpu-verbs-coprocessor echo-coprocessor-cpu steane-coprocessor-cpu gpu-coprocessor"
```

#### 4.3.3. Build the GH200 executor

```bash
make build TARGET=rhino CATALYST="$CATALYST_ROOT" COMPONENT=executor \
    COMPONENT_CMAKE_ARGS="-DCATALYST_SRC=$C -DLLVM_DIR=$C/mlir/llvm-project/build-aarch64-rhino/lib/cmake/llvm"
```

`gpu-coprocessor` contains GPU code that nvcc does not cross-compile. xbuild builds it on the
GH200 over SSH with the HIP installation from step 2, then copies the library back.

### 4.4. Bundles

#### 4.4.1. Assemble both bundles

```bash
cd "$CATALYST_ROOT"
make bundle TARGET=rhino BUNDLE=rhino-bundle CATALYST="$CATALYST_ROOT"
make bundle TARGET=vpk120 BUNDLE=vpk-bundle CATALYST="$CATALYST_ROOT"
```

#### 4.4.2. Check the Rhino bundle and GPU backend

```bash
ls build/bundles/rhino-bundle
ls build/bundles/rhino-bundle/libcatalyst_transport_gpu_verbs_coprocessor.so
```

The Rhino bundle must contain the GPU backend for GPU experiments. `rhino-bundle` warns that
`libcudart.so.12` is missing; that is expected because the GH200 supplies the CUDA runtime.
It must be visible to the loader there, through its system configuration or `LD_LIBRARY_PATH`.

The machines file uses the published bundles under `config/xbuild/build/bundles` directly.
[`config/xbuild/README.md`](config/xbuild/README.md) documents the build system and verification.

## 5. System tuning

This section is optional, and only include for reference on optimizations performed on our set-up.

### 5.1. Isolate the polling cores

#### 5.1.1. Set the kernel arguments

On the GH200, append these arguments to the existing `GRUB_CMDLINE_LINUX` in
`/etc/default/grub`:

```text
isolcpus=managed_irq,domain,24-26 nohz_full=24-26 rcu_nocbs=24-26 irqaffinity=0-23,27-71
```

These are Rhino's CPU lists. The coprocessor polls on core 24, matching `cpu_pin=24` in the
machines file.

#### 5.1.2. Apply the boot configuration and reboot

```bash
sudo update-grub
sudo reboot
```

### 5.2. Copy the runtime tuning script

On the build machine, copy [`config/rt_tune.sh`](config/rt_tune.sh) to the GH200:

```bash
scp ~/backline/config/rt_tune.sh "$SERVER:~/rt_tune.sh"
```

### 5.3. After every GH200 boot

Run these commands **on the GH200**. Put the port to the board in an identity IOMMU domain.
It must be the only device in its IOMMU group.

#### 5.3.1. Inspect the IOMMU group

Inspect the group before unbinding:

```bash
NIC=enp1s0f1np1
PCI=$(basename "$(readlink /sys/class/net/$NIC/device)")
GRP=$(basename "$(readlink /sys/class/net/$NIC/device/iommu_group)")
ls /sys/kernel/iommu_groups/$GRP/devices
```

#### 5.3.2. Rebind the NIC and restore its fabric addresses

If the group contains only that PCI device, rebind it, restore its addresses, and apply the
runtime tuning. Add `192.168.1.10` first so it gets GID 3, then `192.168.0.1` for GID 5:

```bash
echo $PCI     | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind
echo identity | sudo tee /sys/kernel/iommu_groups/$GRP/type
echo $PCI     | sudo tee /sys/bus/pci/drivers/mlx5_core/bind
sudo ip link set $NIC mtu 4200 up
sudo ip addr add 192.168.1.10/24 dev $NIC
sudo ip addr add 192.168.0.1/24 dev $NIC
```

#### 5.3.3. Apply runtime tuning

```bash
sudo bash ~/rt_tune.sh 24,25,26 $NIC
```

The script removes RT throttling, requests performance frequency settings and reduced CPU
idle states where supported, stops `irqbalance`, and moves writable NIC IRQ affinities to the
remaining CPUs (`0-23,27-71`). It also disables automatic NUMA balancing, requests transparent
hugepages `never`, and attempts to move unbound workqueues off the isolated cores.

Several operations are best effort. Check the resulting settings and IRQ/workqueue affinities;
the script's workqueue write can fail. These runtime changes must be reapplied after reboot.

### 5.4. After every ERNIC board boot

With the ERNIC image, the board needs a permanent ARP entry for the GH200.

#### 5.4.1. Get the GH200 fabric MAC address

Run on the GH200:

```bash
cat /sys/class/net/enp1s0f1np1/address
```

#### 5.4.2. Install the permanent ARP entry

Run this **on the board**, replacing `<MAC>` with that address:

```bash
sudo ip neigh replace 192.168.1.10 lladdr "<MAC>" dev eth0 nud permanent
```

## 6. Session setup and checks

### 6.1. Activate the environment

In each new shell **on the build machine**, select the Catalyst environment, Rhino machines
file, and the bundles built above:

```bash
export CATALYST_ROOT=~/catalyst
source "$CATALYST_ROOT/.venv/bin/activate"
export BACKLINE_MACHINES=config/machines.rhino.toml
export BACKLINE_BUNDLES=~/backline/config/xbuild/build/bundles
```

`BACKLINE_MACHINES` is resolved relative to the repository root. `BACKLINE_BUNDLES` overrides
`[paths] bundles`, including any value left over from the general installation guide.

### 6.2. Check the running machines

On the GH200, check the following before running experiments:

| Check | Expect |
|---|---|
| `ip -br link show enp1s0f1np1` | `UP` |
| `ip -br addr show enp1s0f1np1` | `192.168.1.10/24 192.168.0.1/24` |
| `cat /sys/devices/system/cpu/isolated` | `24-26` |
| `cat /sys/devices/system/cpu/nohz_full` | `24-26` |
| `cat /sys/class/net/enp1s0f1np1/device/iommu_group/type` | `identity` |
| `sysctl kernel.sched_rt_runtime_us kernel.numa_balancing` | `-1` and `0`, respectively |
| `cat /sys/kernel/mm/transparent_hugepage/enabled` | `[never]` selected |
| `pgrep -af catalyst-executor` | No executors left from your previous runs |

Also check for leftover executors on the board. Stop executors belonging to your previous
runs before starting another. If the other checks differ, revisit
[System tuning](#5-system-tuning); missing CPU isolation requires a boot-configuration change
and reboot.

### 6.3. Select and check the board image

Check the board using [`INSTALL_FPGA.md`](INSTALL_FPGA.md#checks), and set
`[vpk] bitstream` in `config/machines.rhino.toml` to the installed image: `"hsb"`, `"balboa"`,
or `"ernic"`. Reapply the ERNIC ARP entry whenever that image is booted.

The installation is ready for the commands in
[`benchmarks/reproduce-gh200.md`](benchmarks/reproduce-gh200.md) to reproduce
our measured benchmarking results.
