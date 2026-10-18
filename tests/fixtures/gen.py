"""Regenerates the `.sp` fixtures from the salvaged net2schem PySpice scripts.

Usage: python3 gen.py <salvage>/crates/net2schem/tests/fixture
Writes `<category>/<name>.sp` next to this file (the scripts themselves are not vendored).
"""
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1]
env = dict(os.environ, PYTHONPATH=here)
for category in sorted(os.listdir(src)):
    folder = os.path.join(src, category)
    if not os.path.isdir(folder):
        continue
    os.makedirs(os.path.join(here, category), exist_ok=True)
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".py"):
            continue
        out = subprocess.run([sys.executable, os.path.join(folder, name)],
                             env=env, check=True, capture_output=True, text=True).stdout
        with open(os.path.join(here, category, name[:-3] + ".sp"), "w") as f:
            f.write(out)
