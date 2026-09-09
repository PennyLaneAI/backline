#!/usr/bin/env python3
"""Demo 2a: demo 2 with the transport round written out call by call.

    controller    lightning.qubit running on a remote host
    coprocessor   a belief-propagation qLDPC decoder on the remote host's GPU

This computes exactly what demo 2 computes, and prints the same four lines. The difference is
that ``qp.backline.decode``, one call that hides the whole exchange, is replaced by the runtime
calls it lowers to:

    get_session   find the controller's open session with the named coprocessor
    stage_payload write the packed syndrome into the outgoing slot
    post          hand the slot to the transport, which writes it to the coprocessor
    collect       block until the correction lands in the reply slot

Read it alongside demo 2 to see what the frontend does on your behalf, or as a starting point for
driving the transport directly. The circuit either side of the decode is unchanged.

The code and the circuit follow https://pennylane.ai/demos/tutorial_qldpc_codes
"""

import jax.numpy as jnp
import numpy as np
import pennylane as qp
from pennylane.backline import css_bp_decoder

from codes import AUX, Hx, Hz, LX, LZ, N, TAU
from placement import REMOTE_CPU_CTRL, REMOTE_GPU_COPROC

# The transport's C entry points, declared with the types the compiler must emit for each call.
# "buf" is an input buffer, "out" an output one, and "ptr" the opaque session handle.
GET_SESSION = qp.runtime_declare("__catalyst__transport__get_session__call", "(i32, str) -> ptr")
STAGE_PAYLOAD = qp.runtime_declare(
    "__catalyst__transport__stage_payload__call", "(ptr, buf, u64, u32) -> i32"
)
POST = qp.runtime_declare("__catalyst__transport__post__call", "(ptr, u32) -> i32")
COLLECT = qp.runtime_declare("__catalyst__transport__collect__call", "(ptr, out, u64) -> i32")

# Which end of the link this program is. The controller sends syndromes and waits for corrections.
ROLE_CONTROLLER = 0
# Which pre-registered send slot to use. One is enough, the round being strictly request-reply.
WORK_ITEM = 0
# A bitpacked syndrome is one 8-byte word each way, and the reply unpacks to 64 bits.
PACKED_BYTES = 8
PACKED_BITS = 64

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


def decode(syndrome, decoder_id, session):
    """One transport round: the calls ``qp.backline.decode`` expands to.

    Args:
        syndrome: the measured bits, one per stabilizer row.
        decoder_id: which decoder the coprocessor runs, indexing the tuple it was built from.
        session: the controller session ``get_session`` resolved.

    Returns:
        A 64-entry bit vector, of which the first ``N`` entries are the correction.
    """
    # Pack the bits into the 8-byte payload the wire carries, little-endian.
    packed = jnp.pad(jnp.packbits(jnp.array(syndrome), bitorder="little"), (0, PACKED_BYTES))[
        :PACKED_BYTES
    ]
    qp.runtime_call(STAGE_PAYLOAD, session, packed, PACKED_BYTES, decoder_id)
    qp.runtime_call(POST, session, WORK_ITEM)
    _status, correction = qp.runtime_call(
        COLLECT, session, PACKED_BYTES, out_bytes=PACKED_BYTES
    )
    return jnp.unpackbits(correction, bitorder="little", count=PACKED_BITS).astype(bool)


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

    session = qp.runtime_call(GET_SESSION, ROLE_CONTROLLER, "gpu-coproc")

    for error_qubit in range(N):
        add_error(error_qubit, error_kind)

        z_syndrome, x_syndrome = extract_syndromes()

        correction_z = decode(x_syndrome, 0, session)
        correction_x = decode(z_syndrome, 1, session)

        apply_correction(correction_x, qp.X)
        apply_correction(correction_z, qp.Z)

    return (qp.expval(mean_stabilizer(Hz, qp.Z)), qp.expval(mean_stabilizer(Hx, qp.X)))


if __name__ == "__main__":
    error_names = ["I", "X", "Y", "Z"]
    for error_kind, error_name in enumerate(error_names):
        print(error_name, encoded_decoded_circuit(error_kind))
