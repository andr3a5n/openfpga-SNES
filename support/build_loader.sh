#!/usr/bin/env bash
# Assemble the chip32 loaders with bass (github.com/ARM9/bass) and the chip32
# architecture (github.com/open-fpga/bass-chip32). bass is built on first use
# and cached in $TOOLS.
#   support/loader.bin                                   normal core
#   pkg/probe/Cores/andr3a5n.SNESMSUProbe/loader.bin     MSU-1 probe core
#   pkg/msu/Cores/andr3a5n.SNESMSU/loader.bin            MSU-1 core
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${TOOLS:-${TMPDIR:-/tmp}/bass-chip32}"

if [ ! -x "$TOOLS/bass" ]; then
  rm -rf "$TOOLS"
  mkdir -p "$TOOLS/src"
  git clone --depth=1 https://github.com/ARM9/bass.git "$TOOLS/src/bass"
  git clone --depth=1 https://github.com/open-fpga/bass-chip32.git "$TOOLS/src/chip32"
  # Newer compilers no longer pull these headers in transitively
  make -C "$TOOLS/src/bass/bass" compiler="g++ -include stdexcept -include limits -include cstdint"
  cp "$TOOLS/src/bass/bass/out/bass" "$TOOLS/bass"
  cp -r "$TOOLS/src/chip32/architectures" "$TOOLS/"
fi

cp "$ROOT"/support/*.asm "$TOOLS/"
cd "$TOOLS"

./bass loader.asm
cp loader.bin "$ROOT/support/loader.bin"
cp loader.bin "$ROOT/pkg/pocket/Cores/agg23.SNES/loader.bin"

./bass -d MSU_PROBE=1 loader.asm
cp loader.bin "$ROOT/pkg/probe/Cores/andr3a5n.SNESMSUProbe/loader.bin"

./bass -d MSU=1 loader.asm
mkdir -p "$ROOT/pkg/msu/Cores/andr3a5n.SNESMSU"
cp loader.bin "$ROOT/pkg/msu/Cores/andr3a5n.SNESMSU/loader.bin"

echo "Loaders built"
