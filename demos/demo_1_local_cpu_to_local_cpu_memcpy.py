#!/usr/bin/env python3
"""Demo 1: local CPU to local CPU over the memcpy transport.

    controller    null.qubit running locally
    coprocessor   a precompiled Steane decoder library, also local

The smallest complete backline program, and the one to run first. Both roles live in this process
and the memcpy transport carries a round by copying between two buffers, so nothing here needs a
verbs device, a loopback route, or an out-of-band handshake. If this runs, the software stack is
installed correctly.

The circuit below is written on three logical qubits, and ``qec_code="steane"`` asks the compiler
to run it encoded. Each logical gate is expanded into its physical circuit with a round of error
correction around it: extract the stabilizers, decode the syndrome, apply the correction. None of
that is written here. It is the decode inside each of those rounds that becomes a transport round
to the coprocessor.
"""
import pennylane as qp

from placement import STEANE_CPU_DECODER_LIB_PATH

steane_decode = qp.CoprocessorFunction("steane_coprocessor", lib_path=STEANE_CPU_DECODER_LIB_PATH)

# Neither node needs describing. Both run in this process, and the memcpy transport pairs them by
# the session key the compiler emits, so there is no device, address or port to name.
ctrl = qp.Controller(name="cpu-controller", device=qp.device("null.qubit", wires=3))
coproc = qp.Coprocessor(name="cpu-coproc", coprocessor_fn=steane_decode)
dev = qp.Backline(controller=ctrl, coprocessors=[coproc], transport="memcpy", qec_code="steane")


@qp.qjit(capture=True)
@qp.set_shots(10)
@qp.qnode(dev, mcm_method="one-shot")
def ghz():
    qp.Hadamard(0)
    qp.CNOT([0, 1])
    qp.CNOT([1, 2])
    return qp.sample([qp.measure(0), qp.measure(1), qp.measure(2)])


print("samples:", ghz())
