# Installation

Use this guide for an x86 backline installation, from a local CPU demo through a
GPU server and VPK120 board. You can also use this to reproduce the original
manuscript results. After installation, follow
[`demos/README.md`](demos/README.md) to run the demos.

To test and reproduce benchmarking results for a [`grace-hopper
system`](benchmarks/reproduce-gh200.md), use
[`INSTALL_GH200.md`](INSTALL_GH200.md) instead. That self-contained guide
includes the source branches, software versions, and system tuning for the GH200
experiments.

## Machines and software

The demos come in four tiers. Each adds hardware to the one before it, so complete the
steps for the tier you have and stop there.

| Tier | Setup | Requirements | Demos |
|---|---|---|---|
| 1 | Local CPU-to-CPU | Linux machine, PennyLane, and Catalyst | [1](demos/demo_1_local_cpu_to_local_cpu_memcpy.py) |
| 2 | Local CPU-to-CPU over RDMA | Tier 1 plus a verbs device; Soft-RoCE works without an RDMA NIC | [1a](demos/demo_1a_local_cpu_to_local_cpu_rdma.py) |
| 3 | Remote CPU-to-GPU | Tier 2 plus a GPU server with an RDMA NIC, accessible over SSH | [2](demos/demo_2_remote_cpu_to_remote_gpu_triton.py), [2a](demos/demo_2a_remote_cpu_to_remote_gpu_triton_runtime_calls.py), [3](demos/demo_3_remote_cpu_to_remote_gpu.py) |
| 4 | Remote FPGA-to-GPU | Tier 3 plus a [Xilinx VPK120](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/vpk120.html) connected to the server over RDMA | [4](demos/demo_4_remote_fpga_to_remote_gpu.py), [5](demos/demo_5_remote_fpga_to_remote_gpu_triton.py), [benchmarks](benchmarks/README.md) |

All deployed artifacts target Linux. A macOS machine can drive the cross-builds and remote
runs; the local CPU and RDMA demos require Linux.

| Requirement | Needed for | Notes |
|---|---|---|
| Debian or Ubuntu | Linux machines | Other distributions work with equivalent packages |
| `clang`, `lld`, `g++` | Source builds | `g++` builds Catalyst's frontend on Linux |
| `python3-venv`, `python3-dev` | Python environment | Installed by the Linux command below |
| `libibverbs-dev` | Tier 2 onward | `rdma-core-devel` on Fedora, `rdma-core` on Arch |
| A verbs device | Tier 2 onward | Soft-RoCE counts; `ibv_devices` must list one |
| `wget`, `gnupg`, `rsync` | Tier 3 onward | Add the ROCm repository and copy the server's sysroot |
| ROCm 6 or newer | Tier 3 onward | For an NVIDIA card, also install CUDA 12.8 or newer |
| A second host with a GPU | Tier 3 onward | SSH access and sudo for realtime scheduling; see [server runtime settings](#32-server-runtime-settings) |
| A VPK120 board | Tier 4 | Provisioned board on the same fabric |

The GPU toolchain is required on the machine that builds the GPU backend. The GPU itself is
required on the server that runs it. When the build machine cannot compile GPU code for the
server, xbuild can build that component on the server over SSH.

## 1. Prepare the build machine

Run this section on the machine that will build the software and drive the demos.

### 1.1. Build tools

Follow the subsection for your build machine's operating system.

#### 1.1.1. Debian or Ubuntu

This installs the tools for all four tiers, including the RDMA headers so Catalyst can detect
them on its first build.

```bash
sudo apt update && sudo apt install -y \
    clang lld llvm g++ ccache make cmake ninja-build git \
    python3 python3-venv python3-dev python3-pip \
    libibverbs-dev ibverbs-providers ibverbs-utils rdma-core \
    ca-certificates curl wget gnupg zstd binutils rsync numactl openssh-client
```

#### 1.1.2. macOS with Homebrew

```bash
brew install llvm@22 lld@22
export PATH="$(brew --prefix llvm@22)/bin:$(brew --prefix lld@22)/bin:$PATH"
```

Both packages are keg-only. Keep this `PATH` when building and verifying artifacts. You also
need Git, make, Python 3, and rsync. Catalyst's requirements install below provides CMake and
Ninja inside the virtual environment.

### 1.2. GPU build tools (tiers 3 and 4)

Install these tools on the Linux machine that will build the GPU backend. If that is your
build machine, do this before building Catalyst. A GPU is not required to compile the backend:
the target description names its architecture.

For a macOS build machine, install the GPU tools on the server and set `TARGET_BUILD_HOST`
in its target description to the server's SSH destination. xbuild builds `gpu-coprocessor`
there and copies the library back. Set `TARGET_GPU_SDK` to the HIP installation on that host.

#### 1.2.1. ROCm

```bash
sudo mkdir -p --mode=0755 /etc/apt/keyrings
wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/latest noble main' \
    | sudo tee /etc/apt/sources.list.d/rocm.list
printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 900\n' \
    | sudo tee /etc/apt/preferences.d/rocm-pin-900
sudo apt update && sudo apt install -y hip-dev rocm-device-libs
export PATH=/opt/rocm/bin:$PATH
```

These commands add AMD's Debian and Ubuntu repository. The build requires `hipcc` on `PATH`
and the device libraries, however you obtain them.

| Distribution | Repository |
|---|---|
| Debian, Ubuntu | The commands above use `noble` for Ubuntu 24.04; use `jammy` for 22.04. `. /etc/os-release && echo $VERSION_CODENAME` prints your codename, and <https://repo.radeon.com/rocm/apt/latest/dists/> lists those AMD publishes |
| RHEL, Rocky, Alma, SLES, Azure Linux | See AMD's repositories at <https://repo.radeon.com/rocm/> |
| Other distributions | See the [ROCm installation guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/) |

`latest` in the repository URL selects the newest ROCm. Replace it with a version to pin one,
for example `.../rocm/apt/7.2.4`.

The apt pin is required because Ubuntu's older `hipcc` otherwise outranks ROCm's by version
number. Keep `/opt/rocm/bin` on `PATH`; CMake locates the toolchain by running `hipconfig`.

#### 1.2.2. NVIDIA GPUs

For an NVIDIA card, install `hip-dev` and CUDA 12.8 or newer, and put both `/opt/rocm/bin` and
`/usr/local/cuda/bin` on `PATH`.

### 1.3. Catalyst and PennyLane

Demo 1 can use either [pre-built wheels](#131-from-wheel) or a
[source build](#132-from-source). All remaining demos require building from source.

#### 1.3.1. From wheel

Create and activate a virtual environment, then install the release wheels:

```bash
python3 -m venv ~/backline-venv
source ~/backline-venv/bin/activate
pip install pennylane-catalyst==0.16.0b1 \
    -f https://github.com/PennyLaneAI/pennylane/releases/expanded_assets/v0.46.0b1 \
    -f https://github.com/PennyLaneAI/pennylane-lightning/releases/expanded_assets/v0.46.0b1 \
    -f https://github.com/PennyLaneAI/catalyst/releases/expanded_assets/v0.16.0b1
```

Continue with the [backline checkout](#15-backline).

#### 1.3.2. From source

Clone Catalyst:

```bash
export CATALYST_ROOT=~/catalyst          # your own path
git clone --branch v0.16.0b1 --recurse-submodules --shallow-submodules \
    https://github.com/PennyLaneAI/catalyst.git "$CATALYST_ROOT"
```

Put `CATALYST_ROOT` in your shell profile. The demos and benchmarks read it to find Catalyst's
decoder libraries; otherwise they use `[paths] catalyst` in
[`config/machines.toml`](config/machines.toml). The cross-build uses the separate `CATALYST=`
make argument shown in the bundle commands below.

Create the virtual environment and install the requirements:

```bash
cd "$CATALYST_ROOT"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Build with the settings backline requires:

```bash
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
make all
```

`make all` installs the PennyLane version pinned in Catalyst's `.dep-versions`. Keep this
virtual environment active for the remaining steps.

| Setting | Needed from | Purpose |
|---|---|---|
| `ENABLE_TRANSPORT=ON` | Demo 1 | The transport runtime and its backends |
| `ENABLE_EXECUTOR=ON` | Demo 2 | `catalyst-executor`, the process each remote node runs |
| `LLVM_TARGETS_TO_BUILD` | Demo 2 | `host` is the build machine, `AArch64` the board, and `X86` the server when building on another architecture |

Demo 1 needs only `ENABLE_TRANSPORT=ON`. The other flags are set now to avoid rebuilding LLVM
when moving to remote demos. Catalyst's
[from-source instructions](https://docs.pennylane.ai/projects/catalyst/en/stable/dev/installation.html)
cover the upstream build in more detail.

### 1.4. Triton

Triton generates the decoders for demos 2, 2a, and 5. For those demos, install it with the
Catalyst virtual environment active:

```bash
pip install triton
```

Without it, those demos stop with
`ImportError: Triton decoders require installed 'triton' Python package`.

### 1.5. backline

```bash
git clone --branch v0.1.0b1 https://github.com/PennyLaneAI/backline.git ~/backline
```

### 1.6. Check the local installation (tier 1)

Check the Python installation:

```bash
python -c "import pennylane as qp; print(qp.__version__, qp.Controller, qp.Backline)"
```

On Linux, run demo 1:

```bash
cd ~/backline/demos
./demo_1_local_cpu_to_local_cpu_memcpy.py
```

## 2. Local RDMA (tier 2, demo 1a)

Demo 1a performs an RDMA round trip through Soft-RoCE or loopback, with both ends in one process.
Run this section on Linux.

### 2.1. Check the verbs device

The Linux packages in step 1 include the RDMA libraries and tools. Confirm a device is visible:

```bash
ibv_devices
```

If the list is empty, load [Soft-RoCE](https://github.com/linux-rdma/rdma-core/blob/master/Documentation/rxe.md),
which presents an ordinary network interface as a verbs device. Replace `<interface>` with
that interface's name:

```bash
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev <interface>
```

### 2.2. Rebuild after adding development libraries

If `libibverbs-dev` arrived after Catalyst was built, rebuild the runtime. CMake caches its
choice of RDMA backends, so delete the runtime build directory before rebuilding:

```bash
cd "$CATALYST_ROOT"
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
rm -rf runtime/build && make runtime
```

This also applies when adding ROCm after the first build.

Subsequent builds repeat Catalyst's patch step and may print `error: patch failed` and
`patch does not apply` for patches already applied. Those messages are expected and do not
stop the build.

## 3. GPU server (tier 3, demos 2, 2a, and 3)

Tier 3 uses two machines. The build machine compiles and drives the run. On the server, the
controller and coprocessor run as separate processes, exchange the syndrome through that
machine's NIC, and decode it on its GPU.

### 3.1. Configure the server

The server is described in two files: one for building its binaries and one for running them.
Both contain the reference hardware's settings, so update both for your own server.

| File | Purpose | Settings |
|---|---|---|
| [`config/xbuild/targets/threadripper.conf`](config/xbuild/targets/threadripper.conf) | Describes the build target | CPU triple, glibc version, C++ ABI ceiling, loader path, GPU architecture, and sysroot source |
| [`config/machines.toml`](config/machines.toml), `[server]` | Describes how the demos reach and run on it | SSH and fabric addresses, ports, bundle, executor command, and environment |

Keep these settings consistent:

| Setting | Must agree |
|---|---|
| SSH destination | `host=` in the target's `SYSROOT_PROVIDER_ARGS` and `[server.executor] host` must reach the same machine. Both default to `192.168.3.14` |
| Bundle | `[server.executor] deploy = ["threadripper-bundle"]` must name the bundle built for that target |
| GPU | `TARGET_GPU_ARCH` must match the server's GPU, for example `gfx90a` for AMD or `sm_80` for NVIDIA; the spelling selects the vendor |

`threadripper` is the build target's name; `[server]` is the runtime node's name. The bundle
name connects them.

For a machine without a target description, probe it over SSH:

```bash
cd ~/backline/config/xbuild
make probe TARGET=<name> SSH=you@host
```

This writes `targets/<name>.conf`, including `TARGET_GPU_ARCH`. Fill in the matching
`[server]` entry in `machines.toml` yourself. The commands below use the reference
`threadripper` target and bundle; substitute your target and bundle names if you create new ones.
Keep machine addresses and usernames local to your checkout.

### 3.2. Server runtime settings

The server needs its GPU runtime where the loader can find it: `/opt/rocm/lib` for AMD or
`/usr/local/cuda/lib64` for NVIDIA, registered with `ldconfig` or on `LD_LIBRARY_PATH`.
Otherwise the GPU backend fails to load.

The executor uses sudo to pin threads and run at realtime priority. `NOPASSWD` sudo needs
no additional setup. Otherwise, name an environment variable holding the password in the
machine's `[<machine>.executor]` table, then set it without writing the password to shell history:

```bash
# config/machines.toml:  sudo_password_env = "SERVER_SUDO_PW"
read -rsp "server sudo password: " SERVER_SUDO_PW && export SERVER_SUDO_PW; echo
```

If the variable is unset, the launch prompts for the password. Setting `sudo = false` runs
without sudo, at the cost of the pinning and scheduling used for the latency measurements.

### 3.3. Build and bundle

Run these steps on the build machine with Catalyst's virtual environment active.

#### 3.3.1. Copy the server's sysroot

The sysroot contains the headers and libraries the build will link against:

```bash
SERVER=you@192.168.3.14                  # your server's SSH destination
cd ~/backline/config/xbuild
make sysroot TARGET=threadripper SYSROOT_PROVIDER_ARGS="host=$SERVER port=22"
```

#### 3.3.2. Build the components

Name the components explicitly:

```bash
make build TARGET=threadripper CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-transport rt-capi rtd-null-qubit cpu-verbs-controller \
               cpu-verbs-coprocessor steane-coprocessor-cpu echo-coprocessor-cpu gpu-coprocessor"
```

If the executor reports that no suitable LLVM is available for the target, build Catalyst's
pinned LLVM, then repeat the component build:

```bash
make catalyst-llvm TARGET=threadripper CATALYST="$CATALYST_ROOT"
```

#### 3.3.3. Assemble and collect the bundle

`make bundle` gathers and verifies the built artifacts and writes a deploy script:

```bash
make bundle TARGET=threadripper BUNDLE=threadripper-bundle CATALYST="$CATALYST_ROOT"

mkdir -p ~/bundles
cp -R build/threadripper/bundles/threadripper-bundle ~/bundles/
export BACKLINE_BUNDLES=~/bundles
```

`BACKLINE_BUNDLES` names one directory containing an entry per bundle. A relative path is
resolved against the repository root. The demos deploy the bundles when they run.

## 4. VPK120 board (tier 4, demos 4 and 5)

These run the controller on a VPK120 board, which posts the syndrome and detects the reply in
hardware. The round trip crosses
the fabric between the board and This.
server assumes your VPK120 board is installed with the ERNIC image and in a correct state.
See https://github.com/PennylaneAI/backline-vpk120/tree/v0.1.0 for more information on setting the FPGA up.
The board can also utilize NVIDIA's Holoscan Sensor Bridge or ETH Zurich's BALBOA instead. To boot
the board from one of those images, follow [`INSTALL_FPGA.md`](INSTALL_FPGA.md).

### 4.1. Prepare the board

Provision the board using
[`backline-vpk120`](https://github.com/PennyLaneAI/backline-vpk120/tree/v0.1.0).
The board can also run NVIDIA's Holoscan Sensor Bridge or ETH Zurich's BALBOA; see
[`docs/bitstreams.md`](docs/bitstreams.md) to boot and check those images.

The controller needs `/dev/mem` and a character device from an out-of-tree kernel module,
both present on a provisioned board. Set the board's address and account in
[`config/machines.toml`](config/machines.toml).

### 4.2. Build and bundle

Run these steps on the build machine with Catalyst's virtual environment active.

#### 4.2.1. Obtain the sysroot

The board's sysroot comes from distribution packages:

```bash
cd ~/backline/config/xbuild
make sysroot TARGET=vpk120
```

#### 4.2.2. Build LLVM for the executor

```bash
make catalyst-llvm TARGET=vpk120 CATALYST="$CATALYST_ROOT"
```

#### 4.2.3. Build the components

```bash
make build TARGET=vpk120 CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-capi rtd-null-qubit hwhs-capi-backend \
               hwhs-controller-session swhs-capi-backend hsb-hwhs-capi-backend \
               balboa-hwhs-capi-backend rt-transport"
```

#### 4.2.4. Assemble and collect the bundle

```bash
make bundle TARGET=vpk120 BUNDLE=vpk-bundle CATALYST="$CATALYST_ROOT"
cp -R build/vpk120/bundles/vpk-bundle ~/bundles/
```

After installation, follow [`demos/README.md`](demos/README.md) to configure and run the demos,
or [`benchmarks/README.md`](benchmarks/README.md) for the benchmarks.

## Reference

[`config/xbuild/README.md`](config/xbuild/README.md) covers targets, components, bundles,
verification, and every make goal. For build errors, see
[`config/xbuild/docs/05-troubleshooting.md`](config/xbuild/docs/05-troubleshooting.md).
