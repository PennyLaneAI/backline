# Benchmarks

[`bench.py`](bench.py) times the syndrome-to-correction round trip and writes one CSV of per-round
samples plus a percentile summary. One run measures one cell of a matrix.

Assumes [`../INSTALL.md`](../INSTALL.md) is done, with the virtual environment active. The demos in
[`../demos/`](../demos) are the same round trip without the timing, and are the place to start.

## Prerequisites

The reference coprocessor server is an AMD WRX90 system configured as NPS4, which exposes four
NUMA domains. The MI210 and ConnectX-7 are attached to the same domain. At run time,
[`../config/machines.toml`](../config/machines.toml) launches the executor with `numactl`, keeps
its CPU and memory allocation on that domain, pins the polling thread, and requests real-time
scheduling.

### WRX90 kernel boot parameters

Check the system's core count, logical CPU numbering, and NUMA placement first:

```bash
lscpu -e=CPU,CORE,NODE,ONLINE
numactl -H
```

On the reference host, this reports 32 physical cores, 64 logical CPUs, and four NUMA nodes:
node 0 contains CPUs `0-7,32-39`, node 1 contains `16-23,48-55`, node 2 contains
`24-31,56-63`, and node 3 contains `8-15,40-47`. The benchmark executor, MI210, and ConnectX-7
use node 0.

The reference measurements use the following kernel command line to isolate the polling cores,
offload their kernel work, steer interrupts to the remaining cores, and limit deep CPU idle
states. Add these options to the existing `GRUB_CMDLINE_LINUX` entry in `/etc/default/grub`.

```bash
GRUB_CMDLINE_LINUX="quiet splash pci=realloc=off iommu=pt isolcpus=0-7,32-39 nohz_full=0-7,32-39 rcu_nocbs=0-7,32-39 irqaffinity=8-31,40-63 processor.max_cstate=1 tsc=reliable"
```

The options serve the following roles:

- `pci=realloc=off` preserves the firmware PCIe BAR layout used by the MI210 and ConnectX-7.
- `iommu=pt` enables IOMMU pass-through for GPUDirect and peer DMA.
- `isolcpus=0-7,32-39` removes the polling cores and their SMT siblings from normal scheduling.
- `nohz_full=0-7,32-39` enables full tickless operation on the isolated cores.
- `rcu_nocbs=0-7,32-39` offloads RCU callbacks from the isolated cores.
- `irqaffinity=8-31,40-63` directs IRQs to non-isolated cores.
- `processor.max_cstate=1` limits deep idle states and their exit latency.
- `tsc=reliable` directs Linux to treat the TSC as a reliable timing source.

Apply the change and reboot:

```bash
sudo update-grub
sudo reboot
```

After rebooting, verify the active command line and NUMA layout:

```bash
cat /proc/cmdline
lscpu
numactl -H
```

The CPU lists above are specific to the reference NPS4 topology. If the processor topology, NPS
mode, or SMT setting differs, derive the isolated cores and their siblings again before using
these options.

## Running

```bash
cd benchmarks
./bench.py --ctrl hw-handshake-sw-loop --coproc gpu-steane -o rtt.csv
./bench.py --help-cells     # the accepted values
./bench.py --help           # every option
```

## The matrix

`--ctrl` specifies which part is performed on the FPGA PL. The handshake is the posting of the
syndrome and the detection of the reply; the loop is the issuing of one round after the next.

| `--ctrl` | Handshake | Loop |
|---|---|---|
| `hw-handshake-sw-loop` | the FPGA engine posts and detects the reply | the host, once per round |
| `hw-handshake-hw-loop` | the FPGA engine posts and detects the reply | the FPGA, from a table at its own cadence |
| `sw-handshake`  | the CPU posts through ibverbs and polls for the reply | the host, once per round |

`hw-handshake-sw-loop` is the arrangement demos 4 and 5 run, so its numbers are the latency those
demos see.

`--coproc` names the hardware and the decoder it runs.

| `--coproc` | Runs on | Decoder |
|---|---|---|
| `cpu-echo`, `gpu-echo` | CPU, GPU | the backend replies with what it received |
| `cpu-steane`, `gpu-steane` | CPU, GPU | Steane, precompiled |
| `gpu-qldpc` | GPU | qLDPC, compiled from the parity checks by Triton |

The echo cells reply as cheaply as anything can, so they measure the fabric alone. qLDPC is GPU
only.

`--gpu-platform` names the card `gpu-qldpc` is compiled for, passed to Triton as
`backend:arch:warp_size`. The default is `hip:gfx90a:64`:

```bash
./bench.py --coproc gpu-qldpc --gpu-platform hip:gfx942:64
```

That compile happens on the machine running the benchmark, which requires Triton. The precompiled
kernels take their architecture from the bundle instead.

## Sweeping

[`../scripts/sweep-bench.sh`](../scripts/sweep-bench.sh) runs every cell and collects the CSVs. Run
it from the repository root:

```bash
cd ..
./scripts/sweep-bench.sh -o results          # all of them
./scripts/sweep-bench.sh -n                  # print what would run
./scripts/sweep-bench.sh -- --iters 100000   # anything after -- goes to every run
```

## What is measured

The controller posts an 8-byte syndrome as part of a 16-byte payload, the coprocessor replies with
an 8-byte correction in a 16-byte payload, and the controller times the round trip in its own clock
domain. The host issues one call for the whole run and stays out of the measured path.

The transport is driven through `qp.runtime_call` against its C ABI rather than through a compiled
placement, so the timed loop is the runtime's own. That is the one way this differs from the demos.

`hw-handshake-hw-loop` records differently. The FPGA writes every round's latency into a trace RAM
on the board rather than returning samples, so the results stay on the VPK120 and the benchmark
prints the `scp` command to fetch them. `--pacer-trace-out` sets where on the board the trace lands.

`--iters` sets the number of rounds here. The trace RAM bounds it at 1,048,576 entries, a larger
value is refused.

## Choosing the pacer cadence

`--pacer-freq`, `--pacer-span` and `--pacer-seed` are in core-clock cycles at 200 MHz, so one cycle
is 5 ns and one millisecond is 200,000 cycles.

The fabric computes each interval as `freq + (lfsr & span)`, so `span` is a bit mask rather than a
width: it has to be `2^N-1`. Most ranges are therefore not representable exactly.
[`pacer_span.py`](pacer_span.py) converts a wanted interval into what the
hardware can do:

```bash
./pacer_span.py 3ms                      # a fixed interval, without jitter
./pacer_span.py 1ms 10ms                 # a range, uniform between the bounds
./pacer_span.py 200us 5ms --iters 10000  # ... and how long that many rounds will take
./pacer_span.py 1ms 10ms --all           # every candidate mask, not just the nearest two
```

For a range it prints the candidate below and the candidate above, with the error in each, and
marks the nearer one:

```text
   N          span                actual range  width error
  --  ------------  --------------------------  ---------
  20  0x000FFFFF             1 ms ~ 6.243 ms    -41.7%
  21  0x001FFFFF             1 ms ~ 11.49 ms    +16.5%  <- closest
```

Pick by which error you can live with. The lower bound is always exact, since it is `freq` alone;
only the upper bound is quantised. A single argument gives a fixed interval: `span=0` masks the
LFSR away and every interval is exactly `freq`.

It warns when a choice will not behave: an upper bound past the host's 5 s collect timeout returns
`kErrStuck` rather than waiting, a width error over 25% means the mask is the wrong tool for that
range, and `--iters` turns the average interval into a wall-clock estimate.

The `demo_freq` / `demo_span` it recommends are the firmware's ABI key names, which is what
[`placement.py`](placement.py) writes into the config string. On the command
line they are `--pacer-freq` and `--pacer-span`, with the same values.
