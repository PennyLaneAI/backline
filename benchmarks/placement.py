"""The machines and transport configurations the benchmark drives.

One dictionary per node of the fabric, each spread directly into a node constructor:

.. code-block::

    ctrl = qp.Controller(name="fpga-controller", **REMOTE_VPK_CTRL)

The machines and ports come from ``../config/machines.toml``, which the demos read too. What this
module adds is the nodes only the benchmark drives, together with the libraries they load: a
coprocessor on the server's CPU, a second arrangement of the VPK120 controller, and the PL pacer
that issues the rounds from the fabric rather than the host. The field-by-field account of what a
node dictionary holds is in ``demos/placement.py``.
"""

import getpass
import os
import tomllib
from pathlib import Path

import pennylane as qp

# --------------------------------------------- config ---------------------------------------------

_MACHINES_TOML = Path(__file__).resolve().parent.parent / "config" / "machines.toml"

if not _MACHINES_TOML.is_file():
    raise SystemExit(
        f"{_MACHINES_TOML} not found: it describes the machines these nodes run on"
    )

_CONFIG = tomllib.loads(_MACHINES_TOML.read_text())

_PORTS = _CONFIG["ports"]

USER = getpass.getuser()
"""The SSH account on the remote machines."""

OOB_PORT = _PORTS["oob"]
"""The port a coprocessor listens on for the out-of-band handshake."""

_BUNDLES_ENV = "BACKLINE_BUNDLES"
_bundles = os.environ.get(_BUNDLES_ENV, "").strip() or _CONFIG["paths"].get("bundles", "")
if not _bundles:
    raise SystemExit(
        f"{_BUNDLES_ENV} is not set and machines.toml names no bundles directory. It holds one\n"
        f"subdirectory per node, the names each node deploys:\n"
        f"    export {_BUNDLES_ENV}=/path/to/that/directory"
    )

_BUNDLES = _MACHINES_TOML.parent.parent / Path(_bundles).expanduser()
if not _BUNDLES.is_dir():
    raise SystemExit(f"{_BUNDLES_ENV}={_bundles!r} is not a directory")


def _executor(machine, port):
    """``executor_options`` for ``machine``, with its executor listening on ``port``.

    A machine that names no ``user`` is reached as the current login account, and each of its
    ``deploy`` entries is a bundle subdirectory name resolved against the bundle root.
    """
    options = {**_CONFIG[machine]["executor"], "port": port}
    options.setdefault("user", USER)
    options["deploy"] = [str(_BUNDLES / name) for name in options["deploy"]]
    return options


# -------------------------------------------- machines --------------------------------------------

_SERVER_CFG = _CONFIG["server"]["config"]

_SERVER_ENDPOINT = qp.Endpoint(_CONFIG["server"]["fabric"], OOB_PORT)

_VPK_CFG = _CONFIG["vpk"]["config"]

_VPK_CFG_SWHS = _CONFIG["vpk"]["config_swhs"]

# Three ways to drive the same board, so they share one executor and are never used together.
_VPK_EXEC = _executor("vpk", _PORTS["vpk"])

# ------------------------------------------- libraries --------------------------------------------
# Named by filename, the bundle having been deployed alongside the executor that opens it.

# The cpu_verbs decoder and the echo coprocessor, both shipped in the server's bundle. gpu_verbs
# needs neither, its decoder being compiled together with the backend.
_STEANE_CPU_LIB = "libsteane_coprocessor_cpu.so"
_ECHO_CPU_LIB = "libecho_coprocessor_cpu.so"

# The controller reached over ibverbs rather than the board's engine, a hardware/transport pair the
# compiler's mapping cannot name, so a node selects it through init_args["backend_lib"]. The
# filename keeps the device's older fpga_verbs spelling, being what the deployed bundles carry.
_SWHS_CTRL_LIB = "libcatalyst_transport_fpga_verbs_controller.so"

# ------------------------------------- node configurations ----------------------------------------

REMOTE_CPU_COPROC = dict(
    remote=True,
    endpoint=_SERVER_ENDPOINT,
    executor_options={
        **_executor("server", _PORTS["cpu_coproc"]),
        "plugins": [_STEANE_CPU_LIB, _ECHO_CPU_LIB],
    },
    init_args={"config": _SERVER_CFG},
)
"""A coprocessor on the x86_64 server's CPU, decoding as a host function."""

REMOTE_GPU_COPROC = dict(
    remote=True,
    endpoint=_SERVER_ENDPOINT,
    executor_options=_executor("server", _PORTS["gpu_coproc"]),
    hardware="gpu",
    init_args={"config": f"{_SERVER_CFG};gpu=0"},
)
"""A coprocessor on that server's GPU, decoding in a kernel launched once."""

REMOTE_VPK_CTRL = dict(
    remote=True,
    executor_options=_VPK_EXEC,
    hardware="fpga",
    init_args={"config": _VPK_CFG},
)
"""The controller on the VPK120 board: the hwhs engine posts the syndrome and detects the reply
itself, the host issuing one round at a time (``CTRL=hw-handshake-sw-loop``)."""

REMOTE_VPK_CTRL_SWHS = dict(
    remote=True,
    executor_options=_VPK_EXEC,
    hardware="fpga",
    init_args={"config": _VPK_CFG_SWHS, "backend_lib": _SWHS_CTRL_LIB})
"""The same board with the CPU posting the syndrome itself through ibverbs and polling for the
reply (``CTRL=sw-handshake``)."""

# ------------------------------------------- pacer -----------------------------------------------
# The PL pacer drives the rounds instead of the host. One W1P write latches the run and the fabric
# emits a send every `freq + (lfsr & span)` core-clock cycles by itself, which keeps host scheduling
# jitter out of the tail being measured. Every knob is in raw hardware units, cycles and bit masks,
# what the registers take. The core clock is 200 MHz, so 1 cycle = 5 ns and 1 ms = 200_000 cycles.

# Defaults for the knobs, shared with the benchmark's command line so both agree.
PACER_FREQ_DEFAULT = 0  # cycles between sends; 0 = back-to-back, and 200_000 = 1 ms apart
PACER_SPAN_DEFAULT = 0  # jitter mask, 2^N-1, where 0 = a fixed interval
PACER_SEED_DEFAULT = 1  # a fixed seed gives a repeatable interval sequence
# Absolute, and on the board: the controller writes it and the controller runs on the VPK120.
# A relative path lands in an exec directory the framework deletes at teardown.
PACER_TRACE_OUT_DEFAULT = "/tmp/rtt_trace.csv"

# The engine writes every round's RTT into this RAM itself, and that is the only record a paced
# run produces: nothing is sampled, nothing is missed, and the order survives.
PACER_TRACE_PA = 0x9200_0000  # must match assign_bd_address for the trace axi_bram_ctrl
PACER_TRACE_ENTRIES = 1 << 20  # must match hw_handshake's C_TRACE_AW

# The engine reads syndromes from 0x8000_0000 and expected replies from one PACER_SYN_DEPTH above
# it, so BRAM has to hold both. Slot i holds Payload{ value = i+1, decoder_id = 0 }, and its
# seq_num does not matter, because the engine overwrites that with its own round counter on the
# way out (hh_orchestrator S_DAT_ISS). The table may be shorter than the run, since only the data
# repeats.
from syndrome_table import (
    SYN_DEPTH as PACER_SYN_DEPTH,
)  # noqa: E402  pylint: disable=wrong-import-position


def paced_controller(
    rounds,
    freq=PACER_FREQ_DEFAULT,
    span=PACER_SPAN_DEFAULT,
    seed=PACER_SEED_DEFAULT,
    trace_out=PACER_TRACE_OUT_DEFAULT,
):
    """The VPK120 controller with the PL pacer driving the rounds and recording every one.

    Args:
        freq: core-clock cycles between sends.
        span: jitter mask, which must be 2^N-1.
        seed: LFSR seed for the jitter.
        rounds: rounds to run before the pacer stops.
        trace_out: where on the board to write the trace.

    Returns:
        dict: spread into a ``qp.Controller``.

    Raises:
        SystemExit: If a knob is out of range. Failing here beats a bare -EINVAL once the run is
            already set up.
    """
    if freq < 0:
        raise SystemExit(f"pacer freq {freq}: must not be negative")
    if span >> 32:
        raise SystemExit(f"pacer span 0x{span:X}: REG_FREQ_SPAN is 32-bit")
    if span & (span + 1):
        pop = bin(span).count("1")
        raise SystemExit(
            f"pacer span 0x{span:X}: must be 2^N-1. The interval is freq + (lfsr & span), so a "
            f"mask with holes reaches only 2^{pop} = {1 << pop} values instead of "
            f"{span + 1}, and they are not contiguous. Run pacer_span.py to pick one."
        )

    # The backend calls this mode "demo" and its keys keep that spelling, being the firmware's ABI.
    config = (
        _VPK_CFG + ";demo=hw"
        + (f";demo_freq={freq}" if freq else "")
        + (f";demo_span=0x{span:X}" if span else "")
        + f";demo_seed={seed}"
        + f";demo_cnt={rounds}"
        + f";demo_depth={PACER_SYN_DEPTH}"
        + f";demo_trace=0x{PACER_TRACE_PA:X}"
        + f";demo_trace_out={trace_out}"
    )
    return {
        **REMOTE_VPK_CTRL,
        "init_args": {**REMOTE_VPK_CTRL["init_args"], "config": config},
    }


VPK_CTRL_HOST = f"{_VPK_EXEC['user']}@{_VPK_EXEC['host']}"
"""user@host of the machine the controller runs on, so the benchmark can say where a file it wrote
actually landed."""
