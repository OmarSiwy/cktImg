"""SPICE -> schematic, then inspect the placed geometry (the SINA cleanup seam).

Run after building the module, from export/python/:

    maturin develop && python examples/cleanup.py

No-maturin path (plain cargo):

    cargo build && cp target/debug/libcktimg.so cktimg.so
    python examples/cleanup.py
"""

import pathlib
import sys

# no-maturin path: pick up cktimg.so from export/python/ (this file's parent dir)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import cktimg

spice = "R1 vdd out 5k\nM1 out in 0 0 nmos\n"

# Placed schematic as a dict — what SINA would post-process.
sch = cktimg.schematic(spice)
print("nets:", sch["nets"])
for d in sch["devices"]:
    print(f"  {d['name']:4} {d['class']:5} @ {d['pos']}  pins={[p['net'] for p in d['pins']]}")
print("wires:")
for w in sch["wires"]:
    print(f"  {w['net']}: {w['segments']}")

# The dict is plain Python data — mutate it however you like before re-rendering.
assert {d["class"] for d in sch["devices"]} == {"res", "nmos", "vdd", "gnd"}  # rails auto-inserted
assert sch["wires"], "routed wires present"
print("\nschematic() round-trips: devices, pins, nets, routed wires all present")
