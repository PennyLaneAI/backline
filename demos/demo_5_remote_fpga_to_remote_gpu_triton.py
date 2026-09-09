#!/usr/bin/env python3
"""Demo 5: remote FPGA to remote GPU, Python-defined Steane decoder.

    controller    a Xilinx VPK120 board (aarch64) on its own remote host
    coprocessor   a Triton decoder kernel on a second host's GPU

The same FPGA-to-GPU path as demo 4, with the decoder written in Python. The Triton kernel below
is shipped to the coprocessor host with the rest of its stack, and resolved there by symbol, so
the decoding rule is part of the program rather than part of the backend.
"""

import pennylane as qp
import triton
import triton.language as tl
from pennylane.backline import triton_decoder

from placement import REMOTE_GPU_COPROC, REMOTE_VPK_CTRL


def _pack_lookup_table(values, no_error=0xF):
    """Pack the lookup table into one integer, four bits per entry."""
    word = 0
    for i, value in enumerate(values):
        word |= (no_error if value < 0 else value) << (4 * i)
    return word


# The Steane decoding table: the qubit to flip for each three-bit syndrome, with -1 meaning the
# syndrome was zero and nothing needs correcting.
STEANE_QUBIT_BY_SYNDROME = (-1, 0, 4, 1, 6, 3, 5, 2)
# A compile-time constant, so the lookup below becomes a shift and a mask with no memory access.
STEANE_LUT = tl.constexpr(_pack_lookup_table(STEANE_QUBIT_BY_SYNDROME))  # = 0x2536140F


def steane_lookup(syndrome):
    """Return the qubit to correct for one syndrome, or -1 if there is nothing to do."""
    idx = tl.cast(0, tl.uint32)
    for i in tl.static_range(3):
        idx |= tl.cast((syndrome >> (8 * i)) & 1, tl.uint32) << i
    qubit = (tl.cast(STEANE_LUT, tl.uint32) >> (idx * 4)) & 0xF

    # All ones is -1 read as unsigned, which is how the controller recognises "no correction".
    no_error = tl.cast(0xFFFFFFFFFFFFFFFF, tl.uint64)
    return tl.where(qubit == 0xF, no_error, tl.cast(qubit, tl.uint64))


# One kernel per stabilizer type, selected at run time by the decode's ``decoder_id``. The Steane
# code is self-dual, so the same lookup serves the Hx and Hz checks and the kernel is given twice.
steane_triton_decoder = triton_decoder(
    (steane_lookup, steane_lookup),
    platform="hip:gfx90a:64",
)


ctrl = qp.Controller(name="fpga-controller", **REMOTE_VPK_CTRL)
coproc = qp.Coprocessor(name="gpu-coproc", coprocessor_fn=steane_triton_decoder,
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
