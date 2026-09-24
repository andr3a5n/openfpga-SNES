#!/usr/bin/env bash
# Simulate the MSU-1 phase 0 probe against a model of the Pocket firmware.
# Needs Icarus Verilog 12+ and Python 3. Extra arguments go to vvp as plusargs,
# e.g. +dtupdate or +clampfail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-$ROOT/sim/msu/work}"
mkdir -p "$WORK"

if [ ! -f "$WORK/msuprobe/msuprobe-1.pcm" ]; then
  python3 "$ROOT/tools/msu_probe.py" files "$WORK/msuprobe"
fi

iverilog -g2012 -Wall -Wno-timescale -o "$WORK/tb_msu_probe.vvp" \
  -s tb_msu_probe \
  -I "$ROOT/sim/msu" \
  "$ROOT/sim/msu/tb_msu_probe.sv" \
  "$ROOT/sim/msu/mf_datatable_sim.v" \
  "$ROOT/target/pocket/core_bridge_cmd.v" \
  "$ROOT/sim/msu/synch_3_sim.v" \
  "$ROOT/target/pocket/msu/msu_tgt_cmd.sv" \
  "$ROOT/target/pocket/msu/msu_path.sv" \
  "$ROOT/target/pocket/msu/msu_read_sink.sv" \
  "$ROOT/target/pocket/msu/msu_probe_rom.sv" \
  "$ROOT/target/pocket/msu/msu_probe.sv"

vvp -n "$WORK/tb_msu_probe.vvp" +dir="$WORK/msuprobe" +log="$WORK/msuprobe.msulog" "$@"

python3 "$ROOT/tools/msu_probe.py" decode "$WORK/msuprobe.msulog"
