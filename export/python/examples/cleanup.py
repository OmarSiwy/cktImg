"""SPICE -> schematic, then inspect the placed geometry (the SINA cleanup seam).

Run after building the module (maturin develop, or see the bottom of this file
for the no-maturin path):

    python examples/cleanup.py
"""

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
assert {d["class"] for d in sch["devices"]} == {"res", "nmos"}
assert any(w["net"] == "out" for w in sch["wires"]), "routed wire present"
print("\nschematic() round-trips: devices, pins, nets, routed wires all present")
