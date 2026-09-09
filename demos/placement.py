"""Node placements for the backline demos.

This module declares one dictionary per node of the demo fabric. Each is spread directly into a node
constructor:

.. code-block::

    ctrl = qp.Controller(name="cpu-controller", **REMOTE_CPU_CTRL)
    coproc = qp.Coprocessor(name="gpu-coproc", coprocessor_fn=..., **REMOTE_GPU_COPROC)

A node is characterized by the machine on which its compiled code executes, together with the
libraries it loads there. The machines come from ``../config/machines.toml``, which the benchmarks
read too, and are spread into the nodes below.

Node fields
~~~~~~~~~~~

``hardware``
    What the node executes on: ``"cpu"``, ``"gpu"`` or ``"fpga"``. The compiler pairs it with the
    placement's ``transport`` to pick a concrete backend, resolved per role to
    ``libcatalyst_transport_<backend>_<role>.so``, so one pair serves both a
    ``Controller`` and a ``Coprocessor``. A backend built outside the Catalyst tree is
    located through ``CATALYST_TRANSPORT_PATH``. Because the library is loaded through this pair, it
    is never additionally listed in ``plugins``. The default is ``"cpu"``, so the nodes below state
    it only where they differ. A pair the mapping cannot name, such as the board's
    software-handshake controller reached over ibverbs rather than through its engine, is selected
    by ``init_args["backend_lib"]`` instead.

``endpoint``
    The ``Endpoint`` at which a coprocessor accepts the controller's out-of-band handshake,
    during which the two exchange queue-pair numbers and memory keys prior to execution. This is an
    address on the RDMA fabric, a distinct network from the one used for deployment. Only a
    coprocessor carries it, since the coprocessor listens and the controller initiates.

``executor_options``
    The means of reaching the ``catalyst-executor`` process that runs this node's compiled code.
    Omitted for a node executing in the present process. The following keys are used:

    ``host``, ``user``
        The SSH destination, which is distinct from the fabric address above.
    ``port``
        The executor's port, one per node. ``ssh -L port:localhost:port`` applies the value at both
        ends of the tunnel, so every tunnel listens on it locally and two nodes sharing one collide
        on the compiling machine even when they execute on different hosts. Pinning the value
        permits the compiler to settle an executor's address prior to deployment.
    ``triple``
        The cross-compilation target. It is pinned for the same reason: an unpinned triple is
        detected over SSH, which settling the address in advance is intended to avoid.
    ``deploy``
        Directories and files placed in the remote workspace before the executor starts there. A
        directory contributes the files inside it, and a file is copied as itself.
    ``sudo``
        Start the executor as root, required where the target's devices are not world-accessible.
    ``env``, ``executor_bin``
        The environment of the executor process, and the command that starts it.
    ``plugins``
        Libraries to ``dlopen`` at startup into the global namespace. Only what the compiler cannot
        infer is listed: it already adds the transport runtime, a controller's device runtime, and a
        decoder given as a ``CoprocessorFunction``. What remains is a decoder named by symbol
        alone, whose library nothing points to.

``init_args``
    Arguments interpreted by the backend itself. ``config`` is its ``key=value;...`` string, and
    ``backend_lib`` names a library outright, bypassing the ``transport``/``hardware`` choice.
"""
import getpass
import importlib.util
import os
import sys
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
"""The port a remote coprocessor listens on for the out-of-band handshake."""

LOCAL_OOB_PORT = _PORTS["local_oob"]
"""The same, for a coprocessor running in this process and reached over the loopback interface."""

_CATALYST = Path(os.environ.get("CATALYST_ROOT") or _CONFIG["paths"]["catalyst"]).expanduser()

_BUNDLES = _MACHINES_TOML.parent.parent / Path(
    os.environ.get("BACKLINE_BUNDLES") or _CONFIG["paths"]["bundles"]
).expanduser()
_LIB = _CATALYST / "runtime/build/lib"


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

_LOCAL_CFG = _CONFIG["local"]["config"]
_LOCAL_ENDPOINT = qp.Endpoint(_CONFIG["local"]["fabric"], LOCAL_OOB_PORT)

_SERVER_CFG = _CONFIG["server"]["config"]
_SERVER_ENDPOINT = qp.Endpoint(_CONFIG["server"]["fabric"], OOB_PORT)

_VPK_CFG = _CONFIG["vpk"]["config"]

# ------------------------------------------- libraries --------------------------------------------
# A remote node identifies a library by filename, the bundle having been deployed alongside the
# executor. A local node identifies it by path into the build tree.

# The cpu_verbs decoder, shipped as a library of its own. gpu_verbs requires none, its decoder being
# compiled together with the backend.
_SHLIB_SUFFIX = ".dylib" if sys.platform == "darwin" else ".so"
_STEANE_CPU_LIB = f"libsteane_coprocessor_cpu{_SHLIB_SUFFIX}"

STEANE_CPU_DECODER_LIB_PATH = str(_LIB / _STEANE_CPU_LIB)
"""Path to the Steane decoder, for a coprocessor function loaded in this process."""

# ------------------------------------- node configurations ----------------------------------------

LOCAL_CTRL = dict(
    init_args={"config": _LOCAL_CFG})
"""The controller, in this process, over the soft-RoCE device."""

LOCAL_COPROC = dict(
    endpoint=_LOCAL_ENDPOINT,
    init_args={"config": _LOCAL_CFG})
"""A coprocessor, in this process, over the same soft-RoCE device."""


def _lightning_runtime_files():
    """The files a remote ``lightning.qubit`` controller needs in its workspace."""
    # A namespace package has no __file__, so its directory comes from the spec.
    spec = importlib.util.find_spec("pennylane_lightning")
    if spec is None or not spec.submodule_search_locations:
        return []
    pkg = Path(list(spec.submodule_search_locations)[0])
    found = [pkg / "liblightning_qubit_catalyst.so"]
    found += sorted((pkg.parent / "pennylane_lightning.libs").glob("libgomp-*.so*"))
    return [str(p) for p in found if p.is_file()]


_CPU_CTRL_EXECUTOR = _executor("server", _PORTS["cpu_ctrl"])
_CPU_CTRL_EXECUTOR["deploy"] = _CPU_CTRL_EXECUTOR["deploy"] + _lightning_runtime_files()

REMOTE_CPU_CTRL = dict(
    remote=True,
    executor_options=_CPU_CTRL_EXECUTOR,
    init_args={"config": _SERVER_CFG})
"""The controller on the x86_64 server, over cpu_verbs."""

REMOTE_GPU_COPROC = dict(
    remote=True,
    endpoint=_SERVER_ENDPOINT,
    executor_options=_executor("server", _PORTS["gpu_coproc"]),
    hardware="gpu",
    init_args={"config": f"{_SERVER_CFG};gpu=0"})
"""A coprocessor on that server's GPU, decoding in a kernel launched once."""

REMOTE_VPK_CTRL = dict(
    remote=True,
    executor_options=_executor("vpk", _PORTS["vpk"]),
    hardware="fpga",
    init_args={"config": _VPK_CFG})
"""The controller on the VPK120 board. The hwhs engine posts the syndrome and detects the reply in
hardware, so no CPU is in the round trip."""
