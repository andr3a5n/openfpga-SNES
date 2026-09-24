#!/usr/bin/env python3
"""Package the MSU-1 probe core as an SD card tree.

  package_probe.py BITSTREAM.rbf OUTDIR

OUTDIR receives Cores/andr3a5n.SNESMSUProbe, Platforms and the test files in
Assets/snes/common/msuprobe. Copy its contents to the root of the SD card.
"""

import os
import shutil
import sys

import msu_probe

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = "andr3a5n.SNESMSUProbe"

# Files shared with the normal core
SHARED = ["audio.json", "input.json", "interact.json", "variants.json", "video.json", "icon.bin"]

REVERSE = bytes(int("{:08b}".format(b)[::-1], 2) for b in range(256))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rbf, out = sys.argv[1], sys.argv[2]

    core_dir = os.path.join(out, "Cores", CORE)
    os.makedirs(core_dir, exist_ok=True)

    for name in SHARED:
        shutil.copy(os.path.join(ROOT, "pkg", "pocket", "Cores", "agg23.SNES", name), core_dir)
    probe_pkg = os.path.join(ROOT, "pkg", "probe", "Cores", CORE)
    for name in os.listdir(probe_pkg):
        shutil.copy(os.path.join(probe_pkg, name), core_dir)

    # Pocket bitstreams are the .rbf with every byte bit-reversed. The loader
    # picks one of three cores by ROM type; the probe uses the same one for all.
    data = open(rbf, "rb").read().translate(REVERSE)
    for name in ("snes_main.rev", "snes_spc.rev", "snes_pal.rev"):
        with open(os.path.join(core_dir, name), "wb") as f:
            f.write(data)

    shutil.copytree(os.path.join(ROOT, "pkg", "pocket", "Platforms"),
                    os.path.join(out, "Platforms"), dirs_exist_ok=True)

    class Args:
        outdir = os.path.join(out, "Assets", "snes", "common", "msuprobe")

    msu_probe.cmd_files(Args)
    print("Packaged", CORE, "in", out)


if __name__ == "__main__":
    main()
