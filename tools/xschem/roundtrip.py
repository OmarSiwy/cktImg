#!/usr/bin/env python3
"""The xschem target's proof: SPICE -> cktimg-xschem -> .sch -> xschem's own
netlister -> SPICE, and the nets must be the ones we started with.

    python3 roundtrip.py <cktimg-xschem> <xschem> <netlist.cir>...

For every device, pin by pin, the net xschem reports must correspond to the
input's net one to one (names may differ; the partition may not). Exits 1 on
any difference.
"""
import os
import subprocess
import sys
import tempfile

# Element letter -> pins, for the cards the tests use.
PINS = {"r": 2, "c": 2, "l": 2, "v": 2, "i": 2, "d": 2, "b": 2, "f": 2, "h": 2,
        "e": 4, "g": 4, "m": 4, "j": 3, "s": 4, "w": 2}


def cards(text, skip_title):
    lines = text.splitlines()[1 if skip_title else 0:]
    out, depth = [], 0
    for raw in lines:
        line = raw.split(";")[0].strip().lower()
        if not line or line.startswith("*"):
            continue
        if line.startswith("+") and out:
            out[-1] += " " + line[1:]
            continue
        head = line.split()[0]
        if head == ".subckt":
            depth += 1
        if head == ".ends":
            depth -= 1
            continue
        if depth or head.startswith("."):
            continue
        out.append(line)
    return out


def devices(text, skip_title, models):
    got = {}
    for line in cards(text, skip_title):
        f = line.replace("(", " ").replace(")", " ").split()
        name, letter = f[0], f[0][0]
        if letter == "q":
            n = 4 if len(f) > 5 and f[5] in models else 3
        elif letter in ("e", "g") and len(f) > 3 and ("value" in f[3] or "=" in line.split()[3:4][0] if len(line.split()) > 3 else False):
            n = 2
        else:
            n = PINS.get(letter)
        if n is None:
            continue
        got[name] = f[1:1 + n]
    return got


def main(exporter, xschem, paths):
    bad = 0
    for path in paths:
        text = open(path).read()
        models = {l.split()[1].lower() for l in text.splitlines() if l.lower().startswith(".model")}
        want = devices(text, True, models)
        with tempfile.TemporaryDirectory() as d:
            sch = os.path.join(d, "t.sch")
            subprocess.run([exporter, path, sch], check=True)
            subprocess.run([xschem, "-x", "-q", "-r", "-n", "-s", "-o", d, sch], capture_output=True)
            spice = open(os.path.join(d, "t.spice")).read()
        have = devices(spice, False, models)
        fwd, back, problems = {}, {}, []
        for name, nets in want.items():
            if name not in have:
                problems.append(f"{name} missing")
                continue
            for k, (a, b) in enumerate(zip(nets, have[name])):
                if fwd.setdefault(a, b) != b or back.setdefault(b, a) != a:
                    problems.append(f"{name} pin {k}: {a} became {b} (expected {fwd[a]})")
        status = "ok" if not problems else "FAIL"
        print(f"{status:4} {os.path.basename(path)}: {len(want)} devices")
        for p in problems[:8]:
            print("     ", p)
        bad += bool(problems)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
