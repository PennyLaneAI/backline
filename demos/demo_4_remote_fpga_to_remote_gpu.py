#!/usr/bin/env python3
"""Demo 4: remote FPGA to remote GPU, precompiled decoder.

    controller    a Xilinx VPK120 board (aarch64) on its own remote host
    coprocessor   a precompiled HIP Steane decoder kernel on a second host's MI210

Demo 3 with the controller moved onto an FPGA, which makes this the full heterogeneous path: two
different architectures on two different machines, exchanging syndromes and corrections directly
over the fabric. This host cross-compiles both roles, ships each to its own box, and then stands
aside.

The controller is the VPK120's aarch64 processor driving a hardware handshake engine in the FPGA
fabric. The engine posts the syndrome and detects the reply itself, driving ERNIC™, the RDMA NIC in
the fabric beside it, so the handshake is done in hardware and the round trip is timestamped there
rather than around a host call.

``qec_code="steane"`` means the stabilizer measurements and the decode are inserted by the compiler.
"""
import pennylane as qp

from placement import REMOTE_GPU_COPROC, REMOTE_VPK_CTRL

ctrl = qp.Controller(name="fpga-controller", **REMOTE_VPK_CTRL)
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
