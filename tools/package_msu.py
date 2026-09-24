#!/usr/bin/env python3
"""Package the MSU-1 beta core as an SD card tree.

  package_msu.py BITSTREAM_DIR OUTDIR

BITSTREAM_DIR holds the Quartus outputs snes_msu.rbf, snes_msu_sa1.rbf,
snes_msu_gsu.rbf, snes_spc.rbf and snes_pal.rbf (see generate.tcl: msu,
msu_sa1, msu_gsu, ntsc_spc, pal). OUTDIR receives Cores/andr3a5n.SNESMSU,
Platforms and the MSU-1 test pack in Assets/snes/common/msu1test. Copy its
contents to the root of the SD card.
"""

import os
import shutil
import sys

import msu_testpack

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = "andr3a5n.SNESMSU"

# Files shared with the normal core
SHARED = ["audio.json", "input.json", "interact.json", "variants.json", "video.json", "icon.bin"]

# Bitstreams by core.json file name
BITSTREAMS = ["snes_msu", "snes_msu_sa1", "snes_msu_gsu", "snes_spc", "snes_pal"]

REVERSE = bytes(int("{:08b}".format(b)[::-1], 2) for b in range(256))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]

    missing = [n for n in BITSTREAMS if not os.path.exists(os.path.join(src, n + ".rbf"))]
    if missing:
        sys.exit("Missing bitstreams in %s: %s" % (src, ", ".join(n + ".rbf" for n in missing)))

    core_dir = os.path.join(out, "Cores", CORE)
    os.makedirs(core_dir, exist_ok=True)

    for name in SHARED:
        shutil.copy(os.path.join(ROOT, "pkg", "pocket", "Cores", "agg23.SNES", name), core_dir)
    msu_pkg = os.path.join(ROOT, "pkg", "msu", "Cores", CORE)
    for name in os.listdir(msu_pkg):
        shutil.copy(os.path.join(msu_pkg, name), core_dir)

    # Pocket bitstreams are the .rbf with every byte bit-reversed
    for name in BITSTREAMS:
        data = open(os.path.join(src, name + ".rbf"), "rb").read().translate(REVERSE)
        with open(os.path.join(core_dir, name + ".rev"), "wb") as f:
            f.write(data)

    shutil.copytree(os.path.join(ROOT, "pkg", "pocket", "Platforms"),
                    os.path.join(out, "Platforms"), dirs_exist_ok=True)

    class Args:
        outdir = os.path.join(out, "Assets", "snes", "common", "msu1test")

    msu_testpack.cmd_hw(Args)
    print("Packaged", CORE, "in", out)


if __name__ == "__main__":
    main()
