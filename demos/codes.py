"""The [[13,1,3]] hypergraph-product code the qLDPC demos encode into.

    N       number of data wires, numbered 0 to N-1
    AUX     the one auxiliary wire every stabilizer measurement reuses
    Hx, Hz  the X- and Z-type parity checks, one stabilizer per row
    LX, LZ  the data wires supporting the logical X and Z operators
    TAU     wire pairs to swap for the logical Hadamard, which transposes each sector's grid

From https://pennylane.ai/demos/tutorial_qldpc_codes
"""

import numpy as np

N = 13

AUX = N

Hx = np.array(
    [
        [1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0],
        [0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0],
        [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0],
        [0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1],
        [0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1],
    ]
)

Hz = np.array(
    [
        [1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0],
        [0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0],
        [0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0],
        [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1],
        [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0],
        [0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1],
    ]
)

LX = [6, 7, 8]

LZ = [2, 5, 8]

TAU = [(1, 3), (2, 6), (5, 7), (10, 11)]
