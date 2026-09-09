#!/usr/bin/env python3
"""Demo 1a: local CPU to local CPU over RDMA loopback.

    controller    null.qubit running locally
    coprocessor   a precompiled Steane decoder library, also local

Demo 1 with the RDMA transport underneath. Both roles still run in this process, but they now reach
each other through a verbs device, so queue pairs, memory registration and the out-of-band handshake
all happen exactly as they would between two machines. It is the last demo that needs no second
host, which makes it the place to confirm the RDMA path works before any of the remote demos.

The device the placement names is soft-RoCE, which implements RoCE in the kernel rather than
offloading it to a NIC. The verbs path is therefore genuine while the transport under it is
software, so what this demo establishes is that the path works, not what it costs.

As in demo 1, ``qec_code="steane"`` means the stabilizer measurements and the decode are inserted
by the compiler and do not appear below.
"""
import pennylane as qp

from placement import LOCAL_COPROC, LOCAL_CTRL, STEANE_CPU_DECODER_LIB_PATH

steane_decode = qp.CoprocessorFunction("steane_coprocessor", lib_path=STEANE_CPU_DECODER_LIB_PATH)

ctrl = qp.Controller(
    name="cpu-controller",
    device=qp.device("null.qubit", wires=3),
    **LOCAL_CTRL,
)
coproc = qp.Coprocessor(name="cpu-coproc", coprocessor_fn=steane_decode, **LOCAL_COPROC)
dev = qp.Backline(controller=ctrl, coprocessors=[coproc], transport="rdma", qec_code="steane")


@qp.qjit(capture=True)
@qp.set_shots(10)
@qp.qnode(dev, mcm_method="one-shot")
def ghz():
    qp.Hadamard(0)
    qp.CNOT([0, 1])
    qp.CNOT([1, 2])
    return qp.sample([qp.measure(0), qp.measure(1), qp.measure(2)])


print("samples:", ghz())
