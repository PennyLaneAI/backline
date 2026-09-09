#!/usr/bin/env python3
"""Latency of the syndrome -> correction round trip, measured where it runs.

One invocation measures one cell of a matrix: ``--ctrl`` selects what drives the round, ``--coproc``
selects what answers it::

    ./bench.py --ctrl hw-handshake-sw-loop --coproc gpu-steane -o rtt.csv

``--help-cells`` lists the accepted values. The controller posts an 8-byte syndrome, the
coprocessor replies with an 8-byte correction, and the controller times the round trip in its own
clock domain. The host issues one call and is not in the measured path. A run writes one CSV of
per-round samples and prints a percentile summary.

The transport is driven through ``qp.runtime_call`` against its C ABI rather than through a
compiled backline placement, so the timed loop is the runtime's own with no compiler-inserted code
between the measurement and the wire.

Outline:

    command line      argument parsing and the verbosity helper
    transport ABI     the C entry points and the wrapper that dispatches one
    cells             the controller and coprocessor catalogues, and their selection
    resolved cell     the libraries, symbols and endpoints the selection implies
    measurement       round count, message sizes, and the clock samples are reported in
    reporting         the CSV writer and the percentile summary
    execution         executor construction and the timed program
"""
import argparse
import importlib.util
import os
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pennylane as qp
from catalyst import qjit
from catalyst.executor import Executor

import placement
from placement import (
    REMOTE_CPU_COPROC,
    REMOTE_GPU_COPROC,
    REMOTE_VPK_CTRL,
    REMOTE_VPK_CTRL_SWHS,
    VPK_CTRL_HOST,
)

# ------------------------------------------ command line ------------------------------------------

VERBOSE = 0


def say(message, level=1):
    """Print ``message`` when ``-v`` was given at least ``level`` times."""
    if VERBOSE >= level:
        print(message)


def integer(text):
    """An integer argument, decimal or 0x hex, the masks below reading better in hex."""
    return int(text, 0)


def _parse_args():
    """Every knob this benchmark takes. Run with --help-cells to list the cells."""
    ap = argparse.ArgumentParser(
        description="Time the syndrome -> correction round trip and write one CSV of samples.",
    )
    ap.add_argument(
        "--ctrl",
        default="hw-handshake-sw-loop",
        choices=sorted(_CTRLS),
        metavar="CELL",
        help="what drives the round (default: %(default)s)",
    )
    ap.add_argument(
        "--coproc",
        default=None,
        choices=sorted(_COPROCS),
        metavar="CELL",
        help=f"what answers it (default: {COPROC_DEFAULT})",
    )
    ap.add_argument(
        "--iters",
        type=integer,
        default=1_000_000,
        help="rounds to run, in every cell: the host loop measures that many, and the "
        "pacer stops after that many (default: %(default)s)",
    )
    ap.add_argument(
        "--flags",
        type=integer,
        default=0,
        help="extra start_benchmark flags, or-ed with the cell's own",
    )
    ap.add_argument(
        "--gpu-platform",
        default="hip:gfx90a:64",
        metavar="SPEC",
        help="what a generated decoder is compiled for, as backend:arch:warp_size "
        "(default: %(default)s)",
    )
    ap.add_argument(
        "-o",
        "--out",
        metavar="PATH",
        help="where to write the samples (default: rtt_<coproc>_<ctrl>.csv here)",
    )
    ap.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="report progress; twice to dump the resolved cell",
    )
    ap.add_argument(
        "--help-cells",
        action="store_true",
        help="list the cells this benchmark accepts, and exit",
    )

    pacer = ap.add_argument_group(
        "pacer",
        "Only for --ctrl hw-handshake-hw-loop, where the fabric issues the rounds. "
        "All in core-clock cycles at 200 MHz, so 1 cycle = 5 ns.",
    )
    pacer.add_argument(
        "--pacer-freq",
        type=integer,
        default=placement.PACER_FREQ_DEFAULT,
        help="cycles between sends (default: %(default)s)",
    )
    pacer.add_argument(
        "--pacer-span",
        type=integer,
        default=placement.PACER_SPAN_DEFAULT,
        help="jitter mask, which must be 2^N-1 (default: %(default)s)",
    )
    pacer.add_argument(
        "--pacer-seed",
        type=integer,
        default=placement.PACER_SEED_DEFAULT,
        help="LFSR seed for the jitter (default: %(default)s)",
    )
    pacer.add_argument(
        "--pacer-trace-out",
        default=placement.PACER_TRACE_OUT_DEFAULT,
        metavar="PATH",
        help="where on the board the trace lands " "(default: %(default)s)",
    )
    return ap.parse_args()


# -------------------------------------- transport ABI ---------------------------------------------

PREFIX = "__catalyst__transport__"

OPERATIONS = {
    "create": "(str, str, i32, str) -> ptr",  # backend_lib, config, role, key
    "connect": "(ptr, str, u16) -> i32",  # session, peer, oob_port
    "connect_async": "(ptr, str, u16) -> i64",  # ... -> token
    "exchange_keys": "(ptr) -> i32",
    "exchange_keys_async": "(ptr) -> i64",  # -> token
    "await": "(i64) -> i32",  # token
    "establish_channel": "(ptr, str) -> i32",  # session, transport
    "set_coprocessor_fn": "(ptr, str) -> i32",  # session, symbol
    "set_message_sizes": "(ptr, u32, u64, u64) -> i32",  # session, work_item, in, out
    "start": "(ptr) -> i32",
    # session, iters, decoder_id, flags, then one RTT per round and the rounds actually run
    "start_benchmark": "(ptr, u32, u32, u32, out, u64, out) -> i32",
    "stop": "(ptr) -> i32",
    "destroy": "(ptr) -> i32",
}
for _name, _spec in OPERATIONS.items():
    qp.runtime_declare(f"{PREFIX}{_name}__wrapper", _spec)


def call(op, *args, at, out_bytes=0):
    """One dispatched transport call, on the executor at ``at``."""
    return qp.runtime_call(
        f"{PREFIX}{op}__wrapper", *args, address=at, out_bytes=out_bytes
    )


ROLE_CONTROLLER = 0
ROLE_COPROCESSOR = 1

# ------------------------------------------- cells ------------------------------------------------

# CTRL names how much of the round the FPGA does for itself, along two steps.
#
# The handshake is the posting of the syndrome and the detection of the reply:
#
#   sw-handshake   the CPU posts through ibverbs and polls for the reply, the swhs backend.
#   hw-handshake   the hwhs engine posts the syndrome and detects the reply itself, so the RTT is
#                  measured in the engine's own clock domain rather than around a host call.
#
# The loop is the issuing of one round after another:
#
#   sw-loop        the host calls into the transport once per round.
#   hw-loop        the PL pacer engine issues every round from a BRAM table at its own
#                  cadence, and the host waits for the run to finish rather than stepping it. The
#                  RTT is taken between the engine's two AXIS handshakes, and every round lands in
#                  the trace RAM instead of coming back as samples. Cadence comes from PACER_FREQ /
#                  PACER_SPAN / PACER_SEED (see placement.py).
# ``node`` is a function of the parsed arguments, uniformly: the first two ignore them and the
# paced cell builds its controller from the pacer knobs.
HWHS_CTRL_LIB = "libcatalyst_transport_hwhs_controller.so"
VERBS_CTRL_LIB = "libcatalyst_transport_fpga_verbs_controller.so"

_CTRLS = {
    "sw-handshake": dict(
        node=lambda args: REMOTE_VPK_CTRL_SWHS, flags=0, lib=VERBS_CTRL_LIB
    ),
    "hw-handshake-sw-loop": dict(
        node=lambda args: REMOTE_VPK_CTRL, flags=0, lib=HWHS_CTRL_LIB
    ),
    "hw-handshake-hw-loop": dict(
        node=lambda args: placement.paced_controller(
            freq=args.pacer_freq,
            span=args.pacer_span,
            seed=args.pacer_seed,
            rounds=args.iters,
            trace_out=args.pacer_trace_out,
        ),
        flags=0,
        lib=HWHS_CTRL_LIB,
    ),
}

# The cell the pacer drives. The host collects no samples in it, the engine having recorded them.
PACER_CELL = "hw-handshake-hw-loop"

# What answers a round when nothing else is asked for.
COPROC_DEFAULT = "cpu-echo"

# Where a coprocessor runs. The library is the transport backend for that hardware, and the decode
# function it resolves is chosen separately, below.
_COPROC_HOSTS = {
    "cpu": dict(
        node=REMOTE_CPU_COPROC,
        name="cpu-coproc",
        lib="libcatalyst_transport_cpu_verbs_coprocessor.so",
    ),
    "gpu": dict(
        node=REMOTE_GPU_COPROC,
        name="gpu-coproc",
        lib="libcatalyst_transport_gpu_verbs_coprocessor.so",
    ),
}

# What the coprocessor computes, per hardware: the symbol it resolves at set_coprocessor_fn.
# An empty symbol leaves the backend's own echo in place, which is the cheapest possible reply and
# so measures the fabric alone. None marks a decoder with no prebuilt library, compiled on demand.
_DECODERS = {
    "echo": {"cpu": "", "gpu": "gpu_echo_launcher"},
    "steane": {"cpu": "steane_coprocessor", "gpu": "gpu_steane_launcher"},
    # qLDPC is GPU-only: it is the Triton decoder demo 2 builds, and nothing compiles it for a CPU.
    "qldpc": {"gpu": None},
}

# One cell per (hardware, decoder) pair the tables above define, named "<hardware>-<decoder>".
_COPROCS = {
    f"{hw}-{decoder}": dict(**_COPROC_HOSTS[hw], fn=fn, decoder=decoder)
    for decoder, per_hw in _DECODERS.items()
    for hw, fn in per_hw.items()
}

# Which of syndrome_table's tables the pacer replays to each decoder
_SYNDROME_TABLES = {"steane": "STEANE", "qldpc": "HGP_Z"}

# The code definition lives with the demos, so the benchmark decodes the same code they encode
# into. It is loaded by path rather than imported by name, the two directories not being a package
# and neither being on the other's import path.
_CODES_PY = Path(__file__).resolve().parent.parent / "demos" / "codes.py"


def _load_codes():
    """The demos' ``codes`` module, loaded from ``demos/codes.py``.

    Raises:
        SystemExit: If the file is missing, which means the checkout is incomplete.
    """
    if not _CODES_PY.is_file():
        raise SystemExit(
            f"{_CODES_PY} not found: the qLDPC cell decodes the code the demos define"
        )
    spec = importlib.util.spec_from_file_location("codes", _CODES_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _build_qldpc(platform):
    """Compile the qLDPC decoder for ``platform`` and return its symbol and library.

    The decoder is generated from the code's parity checks rather than shipped prebuilt, so its
    symbol name is only known after compiling. The library lands in a temporary directory and is
    deployed to the coprocessor host alongside the rest of that node's stack.
    """
    from pennylane.backline import (
        css_bp_decoder,
    )  # pylint: disable=import-outside-toplevel

    codes = _load_codes()
    fn = css_bp_decoder(
        codes.Hx, codes.Hz, postprocess="osd", num_iters=10, platform=platform
    )
    return fn.name, fn.lib_path


# ------------------------------------------- one run ----------------------------------------------

# Fixed by the wire protocol and the board, so the same for every cell.
TRANSPORT = (
    "rdma"  # every rdma backend frames alike, so establish_channel takes the family
)
MESSAGE_BYTES = 8  # one 8-byte word each way per round
SYNDROME_BYTES = MESSAGE_BYTES
CORRECTION_BYTES = MESSAGE_BYTES
SAMPLE_BYTES = 8  # start_benchmark returns one 8-byte RTT per round
ROUNDS_BYTES = 8  # and one 8-byte count of the rounds that actually ran
WORK_ITEM = 0
DECODER_ID = 0
CLK_MHZ = 200.0  # the controller's core clock, which the CSV reports cycles against


@dataclass(frozen=True)
class Run:
    """Everything one invocation needs, resolved from the command line by :func:`resolve`."""

    ctrl: str  # the CTRL cell name
    coproc: str  # the COPROC cell name
    ctrl_lib: str  # transport backend library, per role
    ctrl_cfg: str  # backend config string
    ctrl_options: dict  # executor options for the controller's node
    coproc_lib: str
    coproc_cfg: str
    coproc_options: dict
    coproc_name: str  # the session key both sides create under
    coproc_fn: str  # decode symbol the coprocessor resolves, "" for its own echo
    coproc_fn_lib: str  # library a generated decoder lives in, None when prebuilt
    peer: str  # coprocessor address for the out-of-band handshake
    oob_port: int
    flags: int  # start_benchmark flags
    iters: int
    csv: str  # where the samples land
    decoder: str  # coprocessor decoder name; "echo" uses its built-in echo
    syndromes: list  # syndromes replayed by the pacer, or None if none are staged
    corrections: list  # expected replies, or None if they cannot be predicted
    table_image: str  # BRAM image staged for paced decoding, or None otherwise
    args: argparse.Namespace  # the pacer knobs, which only the paced cell reads


# The hwhs controller reserves capacity for its RTT vector up front so that appending a sample does
# not allocate memory on the timed path. Once that capacity is exhausted, std::vector reallocates
# mid-run, and copying the existing samples introduces a latency spike of tens of milliseconds into
# the measured distribution. The fpga_verbs controller keeps no such vector, so sw-handshake has no
# equivalent limit. Its only bound is the u32 used for iters; the operand encoder rejects
# out-of-range values instead of wrapping them.
RTT_SAMPLES_RESERVE = 3_000_000

# A config reaches the backend through a fixed 256-byte string operand (STR_OPERAND_BYTES in
# pennylane.backline.runtime.operands). One byte is reserved for the NUL terminator.
CFG_MAX = 255


def _check_iters(ctrl, iters):
    """Reject a run that exceeds the capacity of the component recording it."""
    if ctrl == PACER_CELL:
        if iters > placement.PACER_TRACE_ENTRIES:
            raise SystemExit(
                f"--iters {iters:,} exceeds the PL trace capacity "
                f"({placement.PACER_TRACE_ENTRIES:,}); "
                f"{iters - placement.PACER_TRACE_ENTRIES:,} round(s) would go unrecorded."
            )
    elif _CTRLS[ctrl]["lib"] == HWHS_CTRL_LIB and iters > RTT_SAMPLES_RESERVE:
        raise SystemExit(
            f"--iters {iters:,} exceeds the hwhs RTT reserve ({RTT_SAMPLES_RESERVE:,}); "
            f"std::vector would reallocate mid-run.\n"
            f"  Increase kRttSamplesReserve and rebuild. --ctrl {PACER_CELL} is limited to "
            f"{placement.PACER_TRACE_ENTRIES:,} rounds."
        )


def _check_config(what, cfg):
    """Reject a config that exceeds the string operand capacity and identify its longest fields.

    An oversized config fails inside the traced program with an argument position rather than the
    offending field. The paced config can exceed the limit when --pacer-trace-out becomes longer.
    """
    if len(cfg) > CFG_MAX:
        longest_fields = sorted(cfg.split(";"), key=len, reverse=True)[:3]
        raise SystemExit(
            f"{what} config: {len(cfg)}B > {CFG_MAX}B.\n"
            f"  longest: "
            + ", ".join(
                f"{field.split('=')[0]} ({len(field)}B)" for field in longest_fields
            )
            + "\n  shorten --pacer-trace-out or remove a field."
        )


def resolve(args):
    """The cell ``args`` selects, with its libraries, endpoints and decoder settled.

    Compiles a generated decoder if the cell needs one, so this is the point at which a qLDPC run
    pays for its kernel.
    """
    ctrl = args.ctrl
    coproc = args.coproc or COPROC_DEFAULT

    ctrl_node = _CTRLS[ctrl]["node"](args)
    cell = _COPROCS[coproc]
    coproc_node = cell["node"]
    decoder = cell["decoder"]

    fn, fn_lib = cell["fn"], None
    if fn is None:
        say(f"[config] compiling the qLDPC decoder for {args.gpu_platform}")
        fn, fn_lib = _build_qldpc(args.gpu_platform)

    _check_iters(ctrl, args.iters)

    # Under the pacer the engine sends from BRAM, so a decoder's syndromes have to be there before
    # the run starts: build the image, name it in the config, and deploy it with the controller so
    # the file is beside the executor when it opens it.
    syndromes, corrections, table_image = None, None, None
    ctrl_cfg = ctrl_node["init_args"]["config"]
    if ctrl == PACER_CELL and decoder in _SYNDROME_TABLES:
        import syndrome_table  # pylint: disable=import-outside-toplevel

        prefix = _SYNDROME_TABLES[decoder]
        syndromes = getattr(syndrome_table, f"{prefix}_SYNDROMES")
        corrections = getattr(syndrome_table, f"{prefix}_CORRECTIONS", None)
        table_image = syndrome_table.build(syndromes, corrections)
        ctrl_cfg += f";demo_table={os.path.basename(table_image)}"

    _check_config("controller", ctrl_cfg)
    _check_config("coprocessor", coproc_node["init_args"]["config"])

    return Run(
        ctrl=ctrl,
        coproc=coproc,
        ctrl_lib=_CTRLS[ctrl]["lib"],
        ctrl_cfg=ctrl_cfg,
        ctrl_options=ctrl_node["executor_options"],
        coproc_lib=cell["lib"],
        coproc_cfg=coproc_node["init_args"]["config"],
        coproc_options=coproc_node["executor_options"],
        coproc_name=cell["name"],
        coproc_fn=fn,
        coproc_fn_lib=fn_lib,
        peer=coproc_node["endpoint"].host,
        oob_port=coproc_node["endpoint"].port,
        flags=_CTRLS[ctrl]["flags"] | args.flags,
        iters=args.iters,
        csv=args.out or f"rtt_{coproc}_{ctrl}.csv",
        decoder=decoder,
        syndromes=syndromes,
        corrections=corrections,
        table_image=table_image,
        args=args,
    )


# ----------------------------------------- reporting ----------------------------------------------


def report_config(run):
    """Print the selected cell, and for a paced run the cadence and where the trace lands."""
    print(
        f"[config] ctrl={run.ctrl} coproc={run.coproc} flags={run.flags} "
        f"iters={run.iters} -> {run.csv}"
    )
    say(f"[config] controller  {run.ctrl_lib}\n[config]   {run.ctrl_cfg}", 2)
    say(
        f"[config] coprocessor {run.coproc_lib} fn={run.coproc_fn!r}\n"
        f"[config]   {run.coproc_cfg}",
        2,
    )
    say(
        f"[config] peer {run.peer}:{run.oob_port} transport={TRANSPORT} key={run.coproc_name}",
        2,
    )

    if run.ctrl != PACER_CELL:
        if run.decoder == "echo":
            say(f"[config] {run.coproc}: echo transport latency")
        else:
            print(f"[config] {run.coproc}: decoding round counters; correction ignored")
        return
    args = run.args

    lo_us = args.pacer_freq / CLK_MHZ
    hi_us = (args.pacer_freq + args.pacer_span) / CLK_MHZ
    print(
        f"[config] pacer: {lo_us:.4g}..{hi_us:.4g} us, seed={args.pacer_seed}, "
        f"period=max(interval, RTT)"
    )
    if run.table_image is not None:
        print(
            f"[config] table: {len(run.syndromes)} {run.decoder} syndromes "
            f"({os.path.basename(run.table_image)})"
        )
        if run.corrections is not None:
            print("[config] reply check: expected compare_errors=0")
        else:
            print(f"[config] reply check: compare_errors={run.iters:,} expected")
    elif run.decoder != "echo":
        print(f"[config] no {run.decoder} syndrome table; reporting latency only")
    print(f"[config] trace: {args.pacer_trace_out} ({run.iters:,} rounds)")
    say(f"[config]   fetch with: scp {VPK_CTRL_HOST}:{args.pacer_trace_out} .")


def write_csv(run, rtt_ns):
    """Write one row per round to ``run.csv``: sample index, RTT in core-clock cycles, RTT in us.

    Two comment lines carry the clock the cycles are derived from and the cell that produced them,
    so a plot can label itself from the file alone.
    """
    with open(run.csv, "w") as f:
        f.write(
            f"# clk_mhz={CLK_MHZ:.1f}\n# source=ctrl={run.ctrl} coproc={run.coproc}\n"
        )
        f.write("sample,rtt_cycles,rtt_us\n")
        for i, ns in enumerate(rtt_ns):
            f.write(f"{i},{round(int(ns) * CLK_MHZ / 1000.0)},{int(ns) / 1000.0:.4f}\n")
    return run.csv


def summarize(rtt_ns):
    """Print the percentiles of ``rtt_ns``, which it sorts."""
    n = len(rtt_ns)
    rtt = np.sort(rtt_ns)
    print(f"\n=== engine RTT (n={n}, start_benchmark) ===")
    for label, value in (
        ("min", rtt[0]),
        ("p50", rtt[int(0.50 * (n - 1))]),
        ("p95", rtt[int(0.95 * (n - 1))]),
        ("p99", rtt[int(0.99 * (n - 1))]),
        ("p99.9", rtt[int(0.999 * (n - 1))]),
        ("max", rtt[-1]),
        ("mean", int(rtt.mean())),
    ):
        print(f"  {label:<8} {int(value):8d} ns")


# ----------------------------------------- execution ----------------------------------------------

# Driving the transport through raw ``runtime_call``s means no backline placement is compiled, so
# the compiler never infers an executor's plugins. This benchmark names them itself.
_RUNTIME_LIBS = ["librt_transport.so", "librt_capi.so"]
_DEVICE_RUNTIME = "librtd_null_qubit.so"


def _executor(name, options, *, device_runtime=False):
    """An ``Executor`` over ``options``, carrying the libraries the raw path needs."""
    plugins = [*(options.get("plugins") or []), *_RUNTIME_LIBS]
    if device_runtime:
        plugins.append(_DEVICE_RUNTIME)
    return Executor(name=name, **{**options, "plugins": plugins})


def _controller_options(run):
    """The controller's executor options, carrying the syndrome image when the pacer replays one.

    Deployed as a file rather than left where it was built, so the engine finds it beside the
    executor under the name the config gives.
    """
    options = run.ctrl_options
    if run.table_image is None:
        return options
    return {**options, "deploy": [*options.get("deploy", []), run.table_image]}


def _coprocessor_executor(run):
    """The coprocessor executor, carrying a generated decoder's library when there is one."""
    options = run.coproc_options
    if run.coproc_fn_lib is not None:
        # Named among the plugins so its symbol resolves, and deployed so the file is there to open.
        options = {
            **options,
            "deploy": [*options.get("deploy", []), run.coproc_fn_lib],
            "plugins": [*(options.get("plugins") or []), Path(run.coproc_fn_lib).name],
        }
    return _executor(run.coproc_name, options)


def main():
    global VERBOSE  # pylint: disable=global-statement

    args = _parse_args()
    if args.help_cells:
        print("--ctrl   (how the round is driven):\n  " + "\n  ".join(sorted(_CTRLS)))
        print("--coproc (what answers it):\n  " + "\n  ".join(sorted(_COPROCS)))
        return
    VERBOSE = args.verbose

    run = resolve(args)
    report_config(run)

    controller = _executor(
        "fpga-controller", _controller_options(run), device_runtime=True
    )
    coprocessor = _coprocessor_executor(run)

    with controller.launch(), coprocessor.launch():
        ctrl, coproc = controller.address, coprocessor.address
        say(f"controller  {ctrl}\ncoprocessor {coproc}\n")

        @qjit
        def remote_benchmark():
            co = call(
                "create",
                run.coproc_lib,
                run.coproc_cfg,
                ROLE_COPROCESSOR,
                run.coproc_name,
                at=coproc,
            )
            ct = call(
                "create",
                run.ctrl_lib,
                run.ctrl_cfg,
                ROLE_CONTROLLER,
                run.coproc_name,
                at=ctrl,
            )

            # handshake
            token = call("connect_async", co, run.peer, run.oob_port, at=coproc)
            call("connect", ct, run.peer, run.oob_port, at=ctrl)
            call("await", token, at=coproc)

            token = call("exchange_keys_async", co, at=coproc)
            call("exchange_keys", ct, at=ctrl)
            call("await", token, at=coproc)

            call("establish_channel", co, TRANSPORT, at=coproc)
            call("establish_channel", ct, TRANSPORT, at=ctrl)
            call("set_coprocessor_fn", co, run.coproc_fn, at=coproc)
            call(
                "set_message_sizes",
                ct,
                WORK_ITEM,
                SYNDROME_BYTES,
                CORRECTION_BYTES,
                at=ctrl,
            )
            call("start", co, at=coproc)
            call("start", ct, at=ctrl)

            # benchmark
            status, samples, rounds = call(
                "start_benchmark",
                ct,
                run.iters,
                DECODER_ID,
                run.flags,
                run.iters * SAMPLE_BYTES,
                at=ctrl,
                out_bytes=(run.iters * SAMPLE_BYTES, ROUNDS_BYTES),
            )

            call("stop", co, at=coproc)
            call("destroy", co, at=coproc)
            call("stop", ct, at=ctrl)
            call("destroy", ct, at=ctrl)
            return status, samples, rounds

        say("running")
        t0 = time.perf_counter()
        status, samples, rounds = remote_benchmark()
        elapsed = time.perf_counter() - t0

    n = int(np.asarray(rounds).view(np.uint64)[0])
    rc = int(status)

    # A paced run returns no samples at all: the PL writes every round into the trace RAM itself,
    # so n is always 0 here and there is no host-side CSV to build. Keyed off the cell rather than
    # off n == 0, because on a host-driven run n == 0 is a real failure. rc is reported, not
    # judged. Whether the run finished is answered by the controller's own "engine ran N round(s)
    # [run complete]" line, which reads the engine's done bit directly, and by the entries and
    # full counters in the trace header.
    if run.ctrl == PACER_CELL:
        print(
            f"start_benchmark returned {rc} for a {run.iters:,}-round paced run, "
            f"{elapsed:.3f} s wall"
        )
        print(f"every round the engine ran is in {args.pacer_trace_out} ON THE BOARD")
        print(f"  scp {VPK_CTRL_HOST}:{args.pacer_trace_out} .")
        return

    print(
        f"start_benchmark returned {rc}, {n}/{run.iters} rounds, {elapsed:.3f} s wall"
    )
    if n == 0:
        raise SystemExit("no samples collected: nothing to report")

    raw = np.asarray(samples).view(np.uint64)[:n]
    print(f"wrote {n} samples to {write_csv(run, raw)}")
    summarize(raw)


if __name__ == "__main__":
    main()
