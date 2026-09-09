# Installation

Install once, then follow [`demos/README.md`](demos/README.md) to run the demos.

The demos come in four tiers. Each adds hardware to the one before it, so install down to the
tier you have and stop there.

| Tier | Features and usage | Requirements | Corresponding Demo |
| --- | --- | --- | --- |
| 1 | Local CPU-CPU interactions on any Linux CPU machine | PennyLane and Catalyst | [1](demos/demo_1_local_cpu_to_local_cpu_memcpy.py) |
| 2 | Local CPU-CPU interactions over RDMA | As above, plus a device that supports the `libibverbs` interface; soft-RoCE will do, an RDMA NIC is optional | [1a](demos/demo_1a_local_cpu_to_local_cpu_rdma.py) |
| 3 | Remote CPU-GPU interactions | As above, plus a server containing a GPU and an RDMA NIC, accessible over SSH | [2](demos/demo_2_remote_cpu_to_remote_gpu_triton.py), [2a](demos/demo_2a_remote_cpu_to_remote_gpu_triton_runtime_calls.py), [3](demos/demo_3_remote_cpu_to_remote_gpu.py) |
| 4 | Remote CPU-FPGA or GPU-FPGA interactions | As above, plus a [Xilinx VPK120](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/vpk120.html) board connected to the server via RDMA | [4](demos/demo_4_remote_fpga_to_remote_gpu.py), [5](demos/demo_5_remote_fpga_to_remote_gpu_triton.py), [benchmarks](benchmarks/README.md) |

## Requirements

| | needed for | notes |
|---|---|---|
| Debian or Ubuntu | all | other distributions work with equivalent packages |
| `clang`, `lld`, `g++` | all | `g++` builds Catalyst's frontend |
| `python3-venv`, `python3-dev` | all | |
| `libibverbs-dev` | tier 2 on | `rdma-core-devel` on Fedora, `rdma-core` on Arch |
| a verbs device | tier 2 on | soft-RoCE counts; `ibv_devices` must list one |
| `wget`, `gnupg`, `rsync` | tier 3 on | to add the ROCm repository, and to copy the server's sysroot |
| ROCm 6 or newer | tier 3 on | from AMD's apt repository. For an NVIDIA card, CUDA 12.8 or newer |
| a second host with a GPU | tier 3 on | reached over SSH, with `NOPASSWD` sudo. Tier 3 cannot run on one machine |
| a VPK120 board | tier 4 | on the same fabric |

ROCm is required on the machine that builds a GPU backend. The machine that runs it
requires the GPU. For the remote demos (demo 2 onwards) these are different machines.

## Quickstart

Follow these instructions to get started. `SERVER` and `BOARD` are the server and the VPK120 board.
The steps below build Catalyst from source. To run demo 1 only, you can instead install pre-built
wheels for PennyLane, Lightning, and Catalyst — see [From wheel](#from-wheel) below.

```bash
# your own addresses; these are the reference hardware's
SERVER=you@192.168.3.14
BOARD=petalinux@192.168.3.15
export CATALYST_ROOT=~/catalyst

# 1. system packages
sudo apt update && sudo apt install -y \
    clang lld g++ ccache make cmake ninja-build git \
    python3 python3-venv python3-dev python3-pip \
    libibverbs-dev ibverbs-providers ibverbs-utils rdma-core \
    ca-certificates curl wget gnupg zstd binutils rsync numactl openssh-client

# 2. ROCm, for tier 3 on
sudo mkdir -p --mode=0755 /etc/apt/keyrings
wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
# Debian/Ubuntu repository; `noble` is Ubuntu 24.04. Other distributions: see Tier 3.
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/latest noble main' \
    | sudo tee /etc/apt/sources.list.d/rocm.list
printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 900\n' \
    | sudo tee /etc/apt/preferences.d/rocm-pin-900
sudo apt update && sudo apt install -y hip-dev rocm-device-libs
export PATH=/opt/rocm/bin:$PATH

# 3. Catalyst
git clone --branch v0.16.0b1 --recurse-submodules --shallow-submodules \
    https://github.com/PennyLaneAI/catalyst.git "$CATALYST_ROOT"
cd "$CATALYST_ROOT"
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
make all

# 4. Triton, for the Python decoders. PennyLane arrives with Catalyst above.
pip install triton

# 5. backline
git clone --branch v0.1.0b1 https://github.com/PennyLaneAI/backline.git ~/backline

# 6. bundles for the remote machines, for tier 3 on
cd ~/backline/config/xbuild
# sysroot: copy the machine's headers and libraries here. build: cross-compile the components.
# bundle: gather and check them, and write a deploy script.
make sysroot TARGET=threadripper SYSROOT_PROVIDER_ARGS="host=$SERVER port=22"
make build TARGET=threadripper CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-transport rt-capi rtd-null-qubit cpu-verbs-controller \
               cpu-verbs-coprocessor steane-coprocessor-cpu echo-coprocessor-cpu gpu-coprocessor"
make bundle TARGET=threadripper BUNDLE=threadripper-bundle CATALYST="$CATALYST_ROOT"

make sysroot TARGET=vpk120                                    # tier 4 only
make build TARGET=vpk120 CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-capi rtd-null-qubit hwhs-capi-backend \
               hwhs-controller-session swhs-capi-backend rt-transport"
make bundle TARGET=vpk120 BUNDLE=vpk-bundle CATALYST="$CATALYST_ROOT"

# 7. collect the bundles where the demos look for them
mkdir -p ~/bundles
cp -R build/threadripper/bundles/threadripper-bundle ~/bundles/
cp -R build/vpk120/bundles/vpk-bundle               ~/bundles/   # tier 4 only
export BACKLINE_BUNDLES=~/bundles
```

Then [`demos/README.md`](demos/README.md).

[`config/xbuild/README.md`](config/xbuild/README.md) documents the cross-build makefile in full:
targets, components, bundles, and how to describe a machine that is not listed yet.

## Tier 1 — demo 1

### System packages

```bash
sudo apt install clang lld g++ ccache make git python3-venv python3-dev
```

`cmake` and `ninja` arrive through Catalyst's requirements file.

### Catalyst
Demo 1 runs on pre-built wheels for PennyLane, Lightning, and Catalyst, so it can be installed
either [from wheel](#from-wheel) or [from source](#from-source). Every other demo (1a, 2, 2a, 3,
4, and 5) needs the build flags set below, so those require [from source](#from-source).

#### From wheel

```bash
pip install pennylane-catalyst==0.16.0b1 -f https://github.com/PennyLaneAI/pennylane-lightning/releases/expanded_assets/v0.46.0b1 -f https://github.com/PennyLaneAI/pennylane/releases/expanded_assets/v0.46.0b1 -f https://github.com/PennyLaneAI/catalyst/releases/expanded_assets/v0.16.0b1
```

#### From source 
```bash
export CATALYST_ROOT=~/catalyst          # your own path

git clone --branch v0.16.0b1 --recurse-submodules --shallow-submodules \
    https://github.com/PennyLaneAI/catalyst.git "$CATALYST_ROOT"
```

Put `CATALYST_ROOT` in your shell profile. The demos read it to find a decoder library that
Catalyst builds; unset, they fall back to the `catalyst` path in
[`config/machines.toml`](config/machines.toml).

Build it, following Catalyst's
[from-source instructions](https://docs.pennylane.ai/projects/catalyst/en/stable/dev/installation.html)
with the settings backline requires:

```bash
cd "$CATALYST_ROOT"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
make all
```

Demo 1 needs only `ENABLE_TRANSPORT=ON`. The other flags are required only for demo 2 onward, and are set
here because adding either later requires rebuilding LLVM.

| | needed from | |
|---|---|---|
| `ENABLE_TRANSPORT=ON` | demo 1 | the transport runtime and its backends |
| `ENABLE_EXECUTOR=ON` | demo 2 | `catalyst-executor`, the process each remote node runs |
| `LLVM_TARGETS_TO_BUILD` | demo 2 | `host` is this machine, `AArch64` the board, `X86` the server when you are not building on one |

### PennyLane and Triton

`make frontend` above installs the PennyLane that Catalyst pins in its `.dep-versions`, which is
the development build carrying backline's frontend. Nothing more is needed for it.

Triton generates the decoders for demos 2, 2a and 5. With the virtual environment still active:

```bash
pip install triton
```

Install it now to avoid a second pass.

> **Warning**
> Without Triton, demos 2, 2a and 5 stop at
> `ImportError: Triton decoders require installed 'triton' Python package`.

### backline

```bash
git clone https://github.com/PennyLaneAI/backline.git ~/backline
```

### Check

```bash
python -c "import pennylane as qp; print(qp.__version__, qp.Controller, qp.Backline)"
```

Then run demo 1, which is the real check:

```bash
cd ~/backline/demos
./demo_1_local_cpu_to_local_cpu_memcpy.py
```

## Tier 2 — demo 1a

Demo 1a performs a real RDMA round trip through Soft-RoCE or loopback, with both ends in one process.

```bash
sudo apt install libibverbs-dev ibverbs-providers ibverbs-utils rdma-core
```

Confirm a device is visible:

```bash
ibv_devices
```

If the list is empty, load [soft-RoCE](https://github.com/linux-rdma/rdma-core/blob/master/Documentation/rxe.md), which presents an ordinary network interface
as a verbs device:

```bash
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev <interface>
```

If `libibverbs-dev` arrived after Catalyst was built, rebuild the runtime. CMake selects the RDMA
backends by what it finds, and it caches that decision, so delete the build directory before running
`make runtime`:

```bash
cd "$CATALYST_ROOT"
export ENABLE_TRANSPORT=ON ENABLE_EXECUTOR=ON LLVM_TARGETS_TO_BUILD="host;AArch64;X86"
rm -rf runtime/build && make runtime
```

This applies whenever tooling changes between tiers, ROCm included.

Every rebuild past the first re-runs Catalyst's own patch step and prints
`error: patch failed` and `patch does not apply` for patches already applied. Those lines are
expected and do not stop the build.

## Tier 3 — GPU demos (2, 2a, 3)

These run on a second machine, called the server. Both nodes run there: the controller as one
process and the coprocessor as another, with the syndrome crossing that machine's NIC between them.
The decoder runs on its GPU. This machine compiles and drives the run, and runs no node itself.

**Tier 3 requires two machines.** The demos place both nodes on the server and cross its NIC
between two processes there, so a single machine cannot run them. This machine builds; that one
runs.

### Packages

```bash
sudo apt install wget gnupg rsync
```

`wget` and `gnupg` add the ROCm repository below. `rsync` copies the server's
sysroot; without it `make sysroot` fails.

### ROCm on this machine

Required to build the GPU backend. A GPU is not required here: the architecture is named rather
than detected.

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

Those commands add AMD's Debian and Ubuntu repository. What the build actually requires is
`hipcc` on `PATH` and the device libraries, however you obtain them.

| | |
|---|---|
| Debian, Ubuntu | the commands above. `noble` is the codename for 24.04; use `jammy` for 22.04. `. /etc/os-release && echo $VERSION_CODENAME` prints yours, and <https://repo.radeon.com/rocm/apt/latest/dists/> lists the ones AMD publishes |
| RHEL, Rocky, Alma, SLES, Azure Linux | AMD ships these too, under `el8`, `el9`, `el10` and `azurelinux3` at <https://repo.radeon.com/rocm/> |
| anything else | AMD's installation guide covers every supported distribution: <https://rocm.docs.amd.com/projects/install-on-linux/en/latest/> |

`latest` in the repository URL takes the newest ROCm. Replace it with a version to pin one, for
example `.../rocm/apt/7.2.4`.

The apt pin is required, otherwise Ubuntu's older `hipcc` outranks ROCm's by version number.
`/opt/rocm/bin` must be on `PATH`, because CMake locates the toolchain by running `hipconfig`.

For an NVIDIA card, install `hip-dev` and CUDA 12.8 or newer, and put both `/opt/rocm/bin` and
`/usr/local/cuda/bin` on `PATH`.

### The server

That one machine is described in two files, because two different things need to know about it.
Both files filled in for the reference hardware, so edit both when you point this at your own.

| | [`config/xbuild/targets/threadripper.conf`](config/xbuild/targets/threadripper.conf) | [`config/machines.toml`](config/machines.toml), `[server]` |
|---|---|---|
| read by | the cross-build, when compiling | the demos, when running |
| answers | what the machine **is**, so binaries can be built to run on it | how to **reach** it, and what to start there |
| holds | CPU triple, glibc version, C++ ABI ceiling, loader path, `TARGET_GPU_ARCH`, and where to fetch its sysroot | SSH address, fabric address, per-node ports, the bundle to deploy, the executor command and its environment |

Nothing keeps the two in step automatically, so three values have to agree:

| | |
|---|---|
| the SSH address | `SYSROOT_PROVIDER_ARGS="host=..."` in the target description and `[server.executor] host` in `machines.toml` are the same machine, written twice. Both ship set to the reference hardware's `192.168.3.14`, so both need changing for your own |
| the bundle | `deploy = ["threadripper-bundle"]` must name a bundle you built with `TARGET=threadripper`. A bundle built for another target deploys without complaint and fails on the device |
| the GPU | `TARGET_GPU_ARCH` must be the card that machine actually holds — `gfx90a` for AMD, `sm_80` for NVIDIA, the spelling selecting the vendor |

The two also use different names for it: `threadripper` is the target's name, `[server]` is the
node's. They are connected only through the bundle name.

For a machine with no target description yet, let it describe itself rather than writing the
values by hand:

```bash
cd ~/backline/config/xbuild
make probe TARGET=<name> SSH=you@host
```

That writes `targets/<name>.conf`, including `TARGET_GPU_ARCH`. Its `[server]` entry in
`machines.toml` is still yours to fill in.

That host also requires the vendor runtime where the loader can find it, `/opt/rocm/lib` for AMD
or `/usr/local/cuda/lib64` for NVIDIA, either registered with `ldconfig` or on
`LD_LIBRARY_PATH`. Otherwise the backend fails to load and the coprocessor does not start.

`NOPASSWD` sudo is required there: the executor pins threads and runs at realtime priority.
Setting `sudo = false` in `config/machines.toml` produces a working run without it, at the cost
of the pinning and scheduling the latency figures depend on.

### Build and deploy its bundle

A bundle is the stack built for one machine and deployed to it.

```bash
SERVER=you@192.168.3.14                  # your own address for the server
cd ~/backline/config/xbuild

# copy that machine's headers and libraries here, so the build links against what it really has
make sysroot TARGET=threadripper SYSROOT_PROVIDER_ARGS="host=$SERVER port=22"

# cross-compile each component for that machine
make build TARGET=threadripper CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-transport rt-capi rtd-null-qubit cpu-verbs-controller \
               cpu-verbs-coprocessor steane-coprocessor-cpu echo-coprocessor-cpu gpu-coprocessor"

# gather those artifacts, check each one against the target, and write a deploy script
make bundle TARGET=threadripper BUNDLE=threadripper-bundle CATALYST="$CATALYST_ROOT"

# put the bundle where the demos look for it
mkdir -p ~/bundles
cp -R build/threadripper/bundles/threadripper-bundle ~/bundles/
export BACKLINE_BUNDLES=~/bundles
```

The sysroot is copied off the machine itself, which is why that step takes an SSH address.
`make bundle` gathers what `make build` produced, so build the components first.

`BACKLINE_BUNDLES` is one directory holding one entry per bundle name. A relative path is
resolved against the repository root.

## Tier 4 — FPGA demos (4, 5)

Tier 4 requires three machines: this one, the server from tier 3, and the VPK120 board. The
controller moves to the board, so the round trip crosses the fabric between the board and the host.

These run the controller on a VPK120 board, which posts the syndrome and detects the reply in
hardware. This assumes your VPK120 board is installed with the correct image and in a correct state.
See https://github.com/PennylaneAI/backline-vpk120/tree/v0.1.0b1 for more information on setting the FPGA up.

The board's sysroot comes from distribution packages:

```bash
cd ~/backline/config/xbuild
make sysroot TARGET=vpk120
make build TARGET=vpk120 CATALYST="$CATALYST_ROOT" \
    COMPONENT="executor rt-capi rtd-null-qubit hwhs-capi-backend \
               hwhs-controller-session swhs-capi-backend rt-transport"
make bundle TARGET=vpk120 BUNDLE=vpk-bundle CATALYST="$CATALYST_ROOT"

cp -R build/vpk120/bundles/vpk-bundle ~/bundles/
```

The board requires `/dev/mem` and a character device from an out-of-tree kernel module, both
already present on a provisioned board. Its address and account go in
[`config/machines.toml`](config/machines.toml).

## Reference

[`config/xbuild/README.md`](config/xbuild/README.md) covers the cross-build system: what a
target, component and bundle are, every make goal, and how to add a machine.
