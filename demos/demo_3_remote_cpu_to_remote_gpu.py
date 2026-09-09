#!/usr/bin/env python3
"""Demo 3: remote CPU to remote GPU, precompiled decoder.

    controller    null.qubit running on a remote host
    coprocessor   a precompiled HIP Steane decoder kernel on that host's MI210

The first demo that leaves this machine. Both roles are cross-compiled here, shipped over SSH, and
run by a catalyst-executor on the GPU host, so this machine compiles and orchestrates but takes no
part in the round trip once the program starts.

The decoder is a HIP kernel already built into the coprocessor's backend, so it is named by its
symbol, ``gpu_steane_launcher``, rather than defined in Python. It is launched once at start and
then runs until the session stops, so no round pays for a kernel launch. A syndrome arrives by RDMA
write into GPU memory, the kernel picks it up from the ring and publishes the correction into a
handoff slot, and a thread pinned to one core spins on that slot and posts the reply.

Demo 5 builds the same decoder from Python instead.

``qec_code="steane"`` means the stabilizer measurements and the decode are inserted by the compiler.
"""
import pennylane as qp

from placement import REMOTE_CPU_CTRL, REMOTE_GPU_COPROC

ctrl = qp.Controller(name="cpu-controller", **REMOTE_CPU_CTRL)
coproc = qp.Coprocessor(name="gpu-coproc", coprocessor_fn="gpu_steane_launcher",
                        **REMOTE_GPU_COPROC)
dev = qp.Backline(controller=ctrl, coprocessors=[coproc], transport="rdma", qec_code="steane")


@qp.qjit(capture=True)
@qp.set_shots(1000)
@qp.qnode(dev, mcm_method="one-shot")
def ghz():
    qp.Hadamard(0)
    qp.CNOT([0, 1])
    qp.CNOT([1, 2])
    return qp.sample([qp.measure(0), qp.measure(1), qp.measure(2)])


print("samples:", ghz())
