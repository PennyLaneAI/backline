# Demos

Each demo showcase complete quantum error correction round(s) locally or across a real fabric. They are ordered so
that each requires additional hardware to the one before it: start at demo 1 and stop wherever your hardware
does.

Assumes [`../INSTALL.md`](../INSTALL.md) is done, with the virtual environment active. That page
lists what each tier requires; this README describes how to run them.

| | Controller | Coprocessor | Transport | Decoder | Tier |
|---|---|---|---|---|---|
| [1](demo_1_local_cpu_to_local_cpu_memcpy.py) | local CPU | local CPU | memcpy, within one process | Steane, precompiled | 1 |
| [1a](demo_1a_local_cpu_to_local_cpu_rdma.py) | local CPU | local CPU | RDMA, within one process | Steane, precompiled | 2 |
| [2](demo_2_remote_cpu_to_remote_gpu_triton.py) | remote CPU | remote GPU | RDMA, across one host's NIC | qLDPC, from Python | 3 |
| [2a](demo_2a_remote_cpu_to_remote_gpu_triton_runtime_calls.py) | remote CPU | remote GPU | RDMA, across one host's NIC | qLDPC, from Python | 3 |
| [3](demo_3_remote_cpu_to_remote_gpu.py) | remote CPU | remote GPU | RDMA, across one host's NIC | Steane, precompiled | 3 |
| [4](demo_4_remote_fpga_to_remote_gpu.py) | remote FPGA | remote GPU | RDMA, between two machines | Steane, precompiled | 4 |
| [5](demo_5_remote_fpga_to_remote_gpu_triton.py) | remote FPGA | remote GPU | RDMA, between two machines | Steane, from Python | 4 |

The demos have been tested with an AMD MI210 GPU, an mlx5 NIC (ConnectX-7) and a VPK120 board.

Three machines appear in these demos:

| | what it is | in [`../config/machines.toml`](../config/machines.toml) |
|---|---|---|
| this machine | where you launch. It compiles the program and drives the run | `[local]`, when it runs nodes itself |
| the server | a remote x86-64 Linux machine with a GPU and an RDMA NIC | `[server]` |
| the board | a VPK120 | `[vpk]` |

Which machine runs which node:

| demos | this machine | the server | the board | machines needed |
|---|---|---|---|---|
| 1, 1a | controller **and** coprocessor, both in this one process | — | — | one |
| 2, 2a, 3 | compiling and launching | controller and coprocessor, as two processes, the syndrome crossing its NIC | — | two |
| 4, 5 | compiling and launching | coprocessor | controller | three |

From demo 2 onward this machine runs no node of its own: it compiles the program, ships each
node's code to the machine that runs it, and starts the run.

## Running demos

Run from the `demos` directory, which is where each script looks for `placement.py`:

```bash
cd demos
./demo_1_local_cpu_to_local_cpu_memcpy.py
```

Each demo reads two paths when it starts. Both have defaults in the `[paths]` table of
[`../config/machines.toml`](../config/machines.toml), and the environment variables override them,
so set a variable only where the default does not match your layout.

| | needed by | what it points at |
|---|---|---|
| `CATALYST_ROOT` | demos 1 and 1a | the Catalyst tree. They load the Steane decoder from `$CATALYST_ROOT/runtime/build/lib` |
| `BACKLINE_BUNDLES` | demos 2 to 5 | the directory holding the bundles, one entry per bundle name. Each remote node deploys the bundle named there. A relative path resolves against the repository root |

They are read on every run, not once at install, so export them from your shell profile or set them
on each command.

## Tier 1 — demo 1

```bash
./demo_1_local_cpu_to_local_cpu_memcpy.py
```

Ten three-bit rows, all zeros:

```text
samples: [[0 0 0]
 [0 0 0]
 ...
 [0 0 0]]
```

The controller runs on `null.qubit`, which returns zeros rather than simulating. If we reach that
output, the transport, the runtime and the decoder are all in place. An exception means it failed.

What this checks is that the whole stack ran. The circuit is written in logical qubits and run
encoded with the Steane code, so each shot goes through several rounds of measure, decode and
correct, and every decode is a round trip to the coprocessor.

## Tier 2 — demo 1a

```bash
./demo_1a_local_cpu_to_local_cpu_rdma.py
```

The same ten rows, over a real RDMA round trip with both ends on one machine.

The device comes from the `[local]` table of [`../config/machines.toml`](../config/machines.toml),
which carries it as `config = "dev=rxe0;gid=1"`. The `gid` is an index into that device's GID table,
and the entry you want is its IPv4 RoCE v2 one, which sits at a different index on different
devices. `ibv_devinfo` and `/sys/class/infiniband/<dev>/ports/1/gids/` report which.

## Tier 3 — GPU demos

```bash
./demo_3_remote_cpu_to_remote_gpu.py
./demo_2_remote_cpu_to_remote_gpu_triton.py
./demo_2a_remote_cpu_to_remote_gpu_triton_runtime_calls.py
```

Start with demo 3: it loads a precompiled Steane decoder, so it exercises the fabric without
involving Triton.

Demo 3 prints ten zero rows, as above.

Demo 2 checks the decoding rather than sampling it. It applies each of I, X, Y and Z to every data
qubit in turn and prints two mean stabilizer values per error, which are `1.0` when every error was
corrected:

```text
I (Array(1., dtype=float64), Array(1., dtype=float64))
X (Array(1., dtype=float64), Array(1., dtype=float64))
Y (Array(1., dtype=float64), Array(1., dtype=float64))
Z (Array(1., dtype=float64), Array(1., dtype=float64))
```

Demo 2a computes what demo 2 computes and prints the same four lines, with `qp.backline.decode`
replaced by the runtime calls it lowers to: `get_session`, `stage_payload`, `post`, `collect`. Read
it alongside demo 2 to see what the frontend does on your behalf.

Demos 2, 2a and 5 compile their decoder with Triton on the machine you launch from, for whichever
card the `platform=` string names:

```python
platform="hip:gfx90a:64"        # backend:arch:warp_size. This is for AMD MI210
platform="cuda:80:32"           # an NVIDIA card, where the warp size changes too
```

The string alone decides the architecture. That machine requires Triton and the compiler matching
the backend the string names, `hipcc` or `nvcc`.

## Tier 4 — FPGA demos

```bash
./demo_4_remote_fpga_to_remote_gpu.py
./demo_5_remote_fpga_to_remote_gpu_triton.py
```

The controller runs on the VPK120, whose engine posts the syndrome and detects the reply in
hardware, so the host CPU stays out of the round trip. Both print ten zero rows.

## Reference logs

One captured run per demo lives in [`expected_logs/`](expected_logs), with the driver output, each
executor's log, and a provenance file recording the three commits it was taken at. To refresh one,
from the repository root:

```bash
./scripts/run-demo.sh demo_1_local_cpu_to_local_cpu_memcpy.py
```

## Pointing it at your own machines

Hosts, ports, devices and deployment paths are all in
[`../config/machines.toml`](../config/machines.toml), which `demos/placement.py` and
`benchmarks/placement.py` read and turn into one node per entry. Editing that file is what runs the
demos on your own hardware.

## Words used throughout

| | |
|---|---|
| controller | the machine that runs the circuit and sends out a syndrome |
| coprocessor | the machine running a decoding function and returning a reply |
| syndrome | the 8-byte message sent by the controller |
| correction | the 8-byte message returned by the coprocessor |
| decoder | a function accepting the syndrome and returning the correction |
| fabric | the RDMA network the two talk over, separate from the network used to log into a machine |
| machine | one of the machines available, described in [`../config/machines.toml`](../config/machines.toml) |
| node | one role, controller or coprocessor, placed on one machine |
| executor | the process backline starts on a remote machine to execute a controller or coprocessor workflow |

Timing these round trips is [`../benchmarks/README.md`](../benchmarks/README.md).
