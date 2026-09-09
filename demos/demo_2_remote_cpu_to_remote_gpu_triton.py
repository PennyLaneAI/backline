#!/usr/bin/env python3
"""Demo 2: remote CPU to remote GPU, Python-defined qLDPC decoder.

    controller    lightning.qubit running on a remote host
    coprocessor   a Python-defined belief-propagation qLDPC decoder on the remote host's GPU

A full round of quantum error correction on a [[13,1,3]] hypergraph-product code, with the decoder
written in Python and compiled to a GPU kernel.

The circuit encodes a logical zero, applies a logical operation to it, injects an
error on one random data qubit, and then measures the stabilizers. Those measurement outcomes are
the syndrome. ``qp.backline.decode`` sends the syndrome to the coprocessor and blocks until the
correction comes back, all inside the shot, so the correction is applied to live qubits rather than
worked out afterwards. Reading the logical Z operator at the end tells you whether the round
succeeded.

Two decoders run on the coprocessor, one per stabilizer type, selected by ``decoder_id``. X errors
are caught by the Z stabilizers and vice versa.

The code and the circuit follow https://pennylane.ai/demos/tutorial_qldpc_codes
"""

import numpy as np
import pennylane as qp
from pennylane.backline import css_bp_decoder

from codes import AUX, Hx, Hz, LX, LZ, N, TAU
from placement import REMOTE_CPU_CTRL, REMOTE_GPU_COPROC

hgp_bp_osd_decoder = css_bp_decoder(
    Hx,
    Hz,
    postprocess="osd",
    num_iters=10,
    platform="hip:gfx90a:64",
)

ctrl = qp.Controller(
    name="cpu-controller", device=qp.device("lightning.qubit", wires=N + 1), **REMOTE_CPU_CTRL
)
coproc = qp.Coprocessor(name="gpu-coproc", coprocessor_fn=hgp_bp_osd_decoder, **REMOTE_GPU_COPROC)
dev = qp.Backline(controller=ctrl, coprocessors=[coproc], transport="rdma")


def mean_stabilizer(checks, pauli):
    return qp.dot(
        [1 / len(checks)] * len(checks),
        [qp.prod(*(pauli(wires=int(q)) for q in np.flatnonzero(row))) for row in checks],
    )

def encode_logical_zero():
    encoder = {
        0: [6, 9, 11],
        1: [7, 9, 10, 11, 12],
        2: [8, 10, 12],
        3: [6, 11],
        4: [7, 11, 12],
        5: [8, 12],
    }
    cnots = np.array([[pivot, target] for pivot, targets in encoder.items() for target in targets])
    for pivot in sorted(encoder):
        qp.Hadamard(wires=pivot)
    for control, target in cnots:
        qp.CNOT(wires=[control, target])


def logical_X():
    for w in LX:
        qp.X(wires=w)


def logical_Z():
    for w in LZ:
        qp.Z(wires=w)


def logical_H():
    for w in range(N):
        qp.Hadamard(wires=w)
    for a, b in TAU:
        qp.SWAP(wires=[a, b])


def logical_circuit():
    logical_X()
    logical_H()
    logical_Z()
    logical_H()


def add_error(error_qubit, error_kind):
    """Apply I/X/Y/Z to one chosen data qubit.

    error_kind: 0=I, 1=X, 2=Y, 3=Z
    """
    if error_kind == 1:
        qp.X(wires=error_qubit)
    elif error_kind == 2:
        qp.Y(wires=error_qubit)
    elif error_kind == 3:
        qp.Z(wires=error_qubit)

def extract_syndromes():
    """Measure every stabilizer and return the Z and X syndrome bits."""
    z_syndrome = np.zeros(len(Hz), dtype=int)
    for check, row in enumerate(Hz):
        for q in range(N):
            if row[q]:
                qp.CNOT(wires=[q, AUX])
        z_syndrome[check] = qp.measure(AUX, reset=True)

    x_syndrome = np.zeros(len(Hx), dtype=int)
    for check, row in enumerate(Hx):
        qp.Hadamard(wires=AUX)
        for q in range(N):
            if row[q]:
                qp.CNOT(wires=[AUX, q])
        qp.Hadamard(wires=AUX)
        x_syndrome[check] = qp.measure(AUX, reset=True)

    return z_syndrome, x_syndrome


def apply_correction(correction, pauli):
    """Apply ``pauli`` to every data qubit whose correction bit is set."""
    for q in range(N):
        if correction[q]:
            pauli(wires=q)


@qp.qjit(capture=True, autograph=True)
@qp.set_shots(1)
@qp.qnode(dev, mcm_method="one-shot")
def encoded_decoded_circuit(error_kind):
    encode_logical_zero()
    logical_circuit()

    for error_qubit in range(N):
        add_error(error_qubit, error_kind)

        z_syndrome, x_syndrome = extract_syndromes()

        correction_z = qp.backline.decode(x_syndrome, decoder_id=0)
        correction_x = qp.backline.decode(z_syndrome, decoder_id=1)

        apply_correction(correction_x, qp.X)
        apply_correction(correction_z, qp.Z)

    return (qp.expval(mean_stabilizer(Hz, qp.Z)), qp.expval(mean_stabilizer(Hx, qp.X)))


if __name__ == "__main__":
    error_names = ["I", "X", "Y", "Z"]
    for error_kind, error_name in enumerate(error_names):
        print(error_name, encoded_decoded_circuit(error_kind))
