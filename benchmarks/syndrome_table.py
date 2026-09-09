#!/usr/bin/env python3
"""The BRAM image the pacer replays, built from a code's syndromes.

A paced run has no host in the loop, so it cannot stage a syndrome per round the way the sw-loop
cells do. The engine reads them from BRAM instead: one table of what to send, and one of what the
reply should be, laid out back to back. The controller loads the image at start-up through
``demo_table=<file>`` and the engine walks it on its own, comparing every reply against the second
half and counting the mismatches, which is where a paced run's correctness result comes from.

The image is a file rather than config values because the controller's config is one 255-byte
string, and inlining even eight syndromes would crowd out the pacer's own settings.

    from syndrome_table import build
    build([0x0, 0x1, 0x3], corrections=[-1, 0, 1])

Run this file directly to build the Steane table and read back the first entries.
"""
import os
import struct
import sys
import tempfile

SLOT = 64
"""sizeof(PayloadSlot), which is also the engine's stride through both tables."""

SLOTS = 512
"""Entries in each of the two tables. The engine walks this many before repeating, and placement
passes the byte size below to the backend as demo_depth, so the two cannot disagree."""

SYN_DEPTH = SLOTS * SLOT

# Field offsets within Payload, from WireProtocol.hpp. The engine overwrites seq_num with its own
# round counter on the way out and excludes it when checking the reply, so what is stored there is
# only ever read by a human dumping the BRAM.
OFF_VALUE = 0
OFF_DECODER_ID = 8
OFF_SEQ_NUM = 12


# --------------------------------- what the pacer replays ----------------------------------------
# Check bitmaps, bit i carrying check i, which build() spreads to the one-byte-per-check form a
# memref<?xi1> lowers to. They live here rather than with the code definitions the demos share,
# because replaying a fixed table is a benchmark's problem: a demo encodes a circuit and gets its
# syndromes from it.

STEANE_SYNDROMES = [  # [[7,1,3]], one per outcome the kernel's lookup table can report
    0x0,  # no error   checks [0,0,0]
    0x1,  # q0         checks [1,0,0]
    0x3,  # q1         checks [1,1,0]
    0x7,  # q2         checks [1,1,1]
    0x5,  # q3         checks [1,0,1]
    0x2,  # q4         checks [0,1,0]
    0x6,  # q5         checks [0,1,1]
    0x4,  # q6         checks [0,0,1]
]

STEANE_CORRECTIONS = [-1, 0, 1, 2, 3, 4, 5, 6]
"""The error qubit each STEANE_SYNDROMES entry decodes to, -1 being no error. Both Steane
coprocessors answer with this index, so pairing the two tables turns the engine's per-round
comparison into a check that the decode was right rather than merely that a reply arrived."""

HGP_Z_SYNDROMES = [  # [[13,1,3]] Hz checks, from seeded depolarising errors
    0x14,  # seed   0   q11:X   z=[0,0,1,0,1,0]
    0x05,  # seed   3   q9:Y    z=[1,0,1,0,0,0]
    0x00,  # seed  10   q11:Z   clean in this basis
    0x02,  # seed  43   q2:Y    z=[0,1,0,0,0,0]
    0x30,  # seed  51   q7:X    z=[0,0,0,0,1,1]
    0x10,  # seed  91   q6:Y    z=[0,0,0,0,1,0]
    0x04,  # seed 109   q3:X    z=[0,0,1,0,0,0]
]
"""Real syndromes for the code above, with no companion correction table: BP+OSD's output cannot
be predicted without running the decoder, so a qLDPC run replays real input but its reply cannot
be checked -- read the trace, not the comparison count."""


def spread(bits, checks=8):
    """Expand a check bitmap into the byte-per-check form the decoders read.

    A syndrome is a ``memref<?xi1>``, which lowers to one byte per element, so check ``i`` lands in
    the low bit of byte ``i`` rather than packed beside its neighbours in byte 0. Writing the
    tables as bitmaps and spreading here keeps the constants above legible.
    """
    return sum(((bits >> i) & 1) << (8 * i) for i in range(checks))


def slot(value, decoder_id=0, seq_num=0):
    """Pack one 64-byte PayloadSlot holding ``value``."""
    buf = bytearray(SLOT)
    struct.pack_into("<Q", buf, OFF_VALUE, value & 0xFFFF_FFFF_FFFF_FFFF)
    struct.pack_into("<I", buf, OFF_DECODER_ID, decoder_id)
    struct.pack_into("<I", buf, OFF_SEQ_NUM, seq_num)
    return bytes(buf)


def build(
    syndromes,
    corrections=None,
    *,
    raw=False,
    decoder_id=0,
    path=None,
    slots=SLOTS,
    depth=SYN_DEPTH,
):
    """Write the image and return its path.

    ``syndromes`` are check bitmaps, or finished wire words when ``raw``. They repeat until every
    slot is filled, so a table may be shorter than the run: only the data cycles.

    ``corrections`` are the replies those syndromes should draw, in the same order. Signed values
    are accepted, the Steane no-error answer of -1 being stored as 0xFFFF_FFFF_FFFF_FFFF. Omitting
    them fills the second table with the syndromes themselves, which is the right expectation for
    an echo and the wrong one for a decoder -- a decoder without known corrections will therefore
    mismatch every round, and its comparison count means nothing.

    The file lands in a temporary directory by default, to be deployed alongside the controller.
    """
    if not syndromes:
        raise ValueError("no syndromes given")
    if corrections is not None and len(corrections) != len(syndromes):
        raise ValueError(
            f"expected one correction per syndrome, got {len(corrections)} correction(s) "
            f"for {len(syndromes)} syndrome(s)"
        )

    sent_half, expected_half = bytearray(), bytearray()
    for i in range(slots):
        bits = syndromes[i % len(syndromes)]
        sent = bits if raw else spread(bits)
        back = sent if corrections is None else corrections[i % len(corrections)]
        # The slot index goes in seq_num so a BRAM dump reads in order; the engine replaces it.
        sent_half += slot(sent, decoder_id, i + 1)
        expected_half += slot(back, decoder_id, i + 1)

    for half, name in ((sent_half, "syndrome"), (expected_half, "expected")):
        if len(half) != depth:
            raise ValueError(
                f"{name} table is {len(half)} bytes, expected {depth}: "
                f"slots * {SLOT} must equal SYN_DEPTH"
            )

    out = path or os.path.join(
        tempfile.mkdtemp(prefix="syndrome_table_"), "syndrome_table.bin"
    )
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(sent_half)
        f.write(expected_half)
    return out


def dump(path, n=4, depth=SYN_DEPTH):
    """Print the first ``n`` entries of both tables, as a human check on an image."""
    with open(path, "rb") as f:
        image = f.read()

    print(f"[table] {path} ({len(image)} bytes)")
    print(
        f"\n{'slot':>5} {'syndrome (wire)':>20} {'expected reply':>20} {'signed':>10}"
    )
    for i in range(n):
        sent = struct.unpack_from("<Q", image, i * SLOT)[0]
        back = struct.unpack_from("<Q", image, depth + i * SLOT)[0]
        signed = back - (1 << 64) if back >> 63 else back
        print(f"{i:5d} {f'0x{sent:X}':>20} {f'0x{back:X}':>20} {signed:10d}")


if __name__ == "__main__":
    written = build(
        STEANE_SYNDROMES,
        STEANE_CORRECTIONS,
        path=sys.argv[1] if len(sys.argv) > 1 else None,
    )
    dump(written)
    print(f"\n[table] controller option: demo_table={os.path.basename(written)}")
