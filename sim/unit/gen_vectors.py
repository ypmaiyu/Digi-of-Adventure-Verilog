#!/usr/bin/env python3
"""Reference vectors for the unit testbenches, computed with the Pygame code's own algorithms."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))


def lfsr_step(q):                       # stage1_demo.py / stage2_demo.py Game.lfsr_step
    fb = ((q >> 15) ^ (q >> 14) ^ (q >> 12) ^ (q >> 3)) & 1
    q = ((q << 1) | fb) & 0xFFFF
    return q if q else 0xACE1


with open(os.path.join(HERE, "lfsr_vectors.mem"), "w") as f:
    q = 0xACE1
    for i in range(1000):
        q = lfsr_step(q)
        f.write("%04x\n" % q)
print("wrote lfsr_vectors.mem")
