# Adding hardware to Backline

This covers two kinds of new hardware: a network IP on the FPGA, the way HSB and BALBOA joined
ERNIC, and a new coprocessor host, the way the GH200 joined the threadripper.

[HSB](https://github.com/nvidia-holoscan/holoscan-sensor-bridge), NVIDIA's Holoscan Sensor Bridge,
is open-source FPGA IP that sends sensor data to a host over Ethernet as RoCE v2 traffic.
[BALBOA](https://github.com/fpgasystems/Coyote) is the open-source RoCE v2 stack in ETH Zurich's
Coyote. The FPGA steps name the files HSB touched, so you can copy from a working example. BALBOA
was added the same way, and the table lists its files too.

## What lives where

| Piece | Repository | HSB's | BALBOA's |
|---|---|---|---|
| The bitstream: the network IP and the engine in front of it | the hardware repository, [backline-vpk120](https://github.com/PennyLaneAI/backline-vpk120) | `hsb_hwhs/` | `balboa_hwhs/` |
| The controller backend, on the board's A72 | catalyst, `runtime/lib/transport/rdma/fpga_<ip>/` | `fpga_hsb/` | `fpga_balboa/` |
| The wire the coprocessor speaks to it | catalyst, `common/interface/<Ip>Wire.hpp` and `rdma/common/<Ip>Link.*` | `HsbWire.hpp`, `HsbLink.*` | `BalboaWire.hpp`, `BalboaLink.*` |
| Build recipes and bundles | this repository, `config/xbuild/` | `components/hsb-hwhs-capi-backend.conf` | `components/balboa-hwhs-capi-backend.conf` |
| Machines and placement | this repository, `config/machines.toml` | `[vpk.hsb]` | `[vpk.balboa]` |
| Measurements and how to reproduce them | this repository, `benchmarks/`, `data/` | [`benchmarks/reproduce-gh200.md`](../benchmarks/reproduce-gh200.md) | the same |

## A new network IP on the FPGA

### 1. The bitstream

The controller backends expect the engine to do what hwhs does on ERNIC:

- stamp the round's seq, counting from 1, into the request's BL16 frame, then send it;
- recognize the reply by that seq, time the round in its own clock, and give up after a timeout;
- count rounds done, rounds timed out and rounds run;
- for hw-loop runs, carry a pacer that sends from a table in BRAM and an RTT trace RAM.

hwhs-hsb's register map is `hwhs_regs.h` in its backend. If you reuse it, you can start from the HSB
controller session.

The hardware repository also needs:

- A handshake header with the HostInfo, FpgaInfo and Ready structs. Catalyst's wire header copies
  it byte for byte.
- Its own control tool and echo coprocessor (HSB's are `hsbctl` and `hsb-echo`, BALBOA's
  `balboactl` and `balboa-echo`), so you can bring the board up without Catalyst.

[`bitstreams.md`](bitstreams.md) shows how to boot and check the existing images.

### 2. The controller backend in Catalyst

Add `runtime/lib/transport/rdma/fpga_<ip>/`, starting from a copy of `fpga_hsb/`:

- `<Ip>Device.{hpp,cpp}` maps the engine's windows with `map_phys_window`
  (`rdma/common/PhysWindow.hpp`: UIO, else `/dev/mem`) and reads and writes registers. There is
  no kernel module.
- `<Ip>ControllerSession.{hpp,cpp}` implements `ControllerSession` from
  `runtime/include/Transport.hpp`. `exchange_keys` receives HostInfo and answers with FpgaInfo;
  `kick` and `collect` run one round; `run_paced` runs the pacer, and `self_paced` says whether it
  is on.
- `<Ip>Backend.cpp` parses the config (`reply_to_us`, the `pacer*` keys) and exports the factory
  and the capabilities with `GENERATE_TRANSPORT_CONTROLLER_FACTORY` and
  `CATALYST_TRANSPORT_BACKEND_CAPS`.
- `CMakeLists.txt` lists `../common/PhysWindow.cpp` among its sources. Add the directory to
  `runtime/lib/transport/CMakeLists.txt` with `add_subdirectory`, under `ENABLE_TRANSPORT_FPGA`
  and aarch64.

Then register the backend in `frontend/catalyst/backline.py`'s `_REGISTRY` with `default=False`,
and add it to the backend list in `doc/dev/backline.rst`.

The library name is part of the interface: `libcatalyst_transport_<name>_controller.so`, where
`<name>` is what a node passes as `backend=`.

If you change the session interface itself, follow the rules at the top of
`runtime/include/TransportBackend.h`: append virtual methods only, raise
`CATALYST_TRANSPORT_ABI_VERSION`, and never call a new method on a backend that reports an older
version.

### 3. The peer, if the IP needs a new one

First check whether the IP's traffic matches an existing peer (`catalyst`, `hsb` or `balboa`, listed
in `doc/dev/backline.rst`). If it does, set that peer and skip this step. Otherwise:

- `runtime/lib/transport/common/interface/<Ip>Wire.hpp` describes the wire: where request n
  lands in the coprocessor's ring and from which IOVA, how the reply goes back (SEND or WRITE),
  the handshake structs, and the ring the coprocessor allocates (`ring_from_config`).
- `rdma/common/<Ip>Link.{hpp,cpp}` is a `final` subclass of `PeerLink`: `connect`, `ring_iova`,
  `exchange`, `establish`, `send_frame`, `send(seq)`, `idle` and `drain`. `send` is the hot path.
- Hook it in: the `Peer` enum and `peer_from_config` in `rdma/common/BackendConfig.hpp`,
  `make_coprocessor_link` in `rdma/common/PeerLink.cpp`, the `switch` in
  `CpuCoprocessorSession::run` and `GpuCoprocessorSession::run`, the `verbs_links` library in
  `rdma/common/CMakeLists.txt`, and the peer list in `doc/dev/backline.rst`.

You don't change the coprocessor sessions. They poll the frame's seq and reply with the request's
own seq through whatever link they get.

### 4. Build and place it here

- Add `config/xbuild/components/<name>-capi-backend.conf`, a copy of
  `hsb-hwhs-capi-backend.conf`. `COMPONENT_OUTPUT` must be the library name above. Add the
  component to `BUNDLE_COMPONENTS` in `config/xbuild/bundles/vpk-bundle.conf`.
- For a new peer, add `<Ip>Link.cpp` to `COMPONENT_SOURCES` in
  `components/cpu-verbs-coprocessor.conf` and `components/gpu-coprocessor.conf`.
- Add a `[vpk.<bitstream>]` table to `config/machines.toml` and to each `config/machines.*.toml`,
  with `backend`, `config`, `clk_mhz`, and the coprocessor's `coproc_config` (with `peer=`) and
  `coproc_endpoint`. `[vpk] bitstream` selects it. Nothing in `benchmarks/` or `demos/` names an
  IP; they read this table.
- Run `make check` in `config/xbuild`.

### 5. Bring it up and measure

Go in this order and stop at the first failure:

1. Run the hardware repository's own bring-up checks, then its echo tool.
2. Do a smoke run of 1000 rounds from `benchmarks/`, first per round, then paced:

   ```bash
   ./bench.py --ctrl hw-handshake-sw-loop --coproc cpu-echo --iters 1000 -o /tmp/smoke.csv
   ./bench.py --ctrl hw-handshake-hw-loop --coproc cpu-echo --iters 1000 --pacer-freq 0 \
       --pacer-trace-out /tmp/rtt_trace.csv
   ```

3. Run CPU and GPU echo, sw-loop and hw-loop, 10^6 rounds each, as in
   [`benchmarks/reproduce-gh200.md`, Run](../benchmarks/reproduce-gh200.md#5-run). Every run must
   end with `timeouts=0` and `compare_errors=0`.

## A new coprocessor host

### 1. Build

Add a target in `config/xbuild/targets/`
([`config/xbuild/docs/02-adding-a-target.md`](../config/xbuild/docs/02-adding-a-target.md)) and a
bundle in `config/xbuild/bundles/`. The GPU backend builds on the host itself, with hipcc on AMD or
hipcc over nvcc on NVIDIA. `benchmarks/reproduce-gh200.md` shows the NVIDIA case.

### 2. Placement

Copy `config/machines.toml` to `config/machines.<host>.toml`, as
[`config/machines.rhino.toml`](../config/machines.rhino.toml) does for rhino, and fill in its
`[server]` tables: the backend `config` (`dev`, `gid`, `cpu_pin`, `rt`), `fabric`, and
`[server.executor]` with `host`, `triple`, `sudo`, `deploy`, `executor_bin` and `env`. If a
`[vpk.*]` table reaches the host over a different link than `[server]`, it sets its own
`coproc_config` and `coproc_endpoint`. `BACKLINE_MACHINES=config/machines.<host>.toml` selects the
file.

### 3. Locality

Put the NIC, the GPU, the polling core and the executor's memory on one NUMA node. Check
`/sys/class/infiniband/<dev>/device/numa_node`, the GPU's `numa_node`, and `lscpu`. Keep the
executor's other threads off the polling core's CCD, which is the set of cores in
`/sys/devices/system/cpu/cpu<N>/cache/index3/shared_cpu_list`.

### 4. Tuning

Isolate the polling core (`isolcpus`, `nohz_full` and `rcu_nocbs` on the kernel command line), and
stop endpoint agents during a session.

### 5. Verify

Follow the order in [Bring it up and measure](#5-bring-it-up-and-measure).
