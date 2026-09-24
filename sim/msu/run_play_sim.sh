#!/usr/bin/env bash
# Simulate MSU-1 playback end to end: upstream MSU.sv, msu_audio.v and
# msu_data_store.sv served by target/pocket/msu against a model of the Pocket
# firmware. Needs Icarus Verilog 12+ and Python 3.
#   COMPILE_ONLY=1  build the simulation without running it
#   extra arguments go to vvp, e.g. +hostdebug for msu_host's queue decisions
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-$ROOT/sim/msu/work}"
mkdir -p "$WORK"

python3 "$ROOT/tools/msu_testpack.py" sim "$WORK/msutest" > /dev/null

# MSU.sv assigns its track_request output from an always block without
# declaring it reg. Quartus accepts that, Icarus does not: simulate a copy.
sed -E 's/^(\s*)output(\s+)track_request,/\1output reg track_request,/' \
  "$ROOT/rtl/upstream/chip/MSU1/MSU.sv" > "$WORK/MSU_sim.sv"

iverilog -g2012 -Wall -Wno-timescale -Wno-implicit-dimensions -o "$WORK/tb_msu_play.vvp" \
  -s tb_msu_play \
  -I "$ROOT/sim/msu" \
  "$ROOT/sim/msu/tb_msu_play.sv" \
  "$ROOT/sim/msu/mf_datatable_sim.v" \
  "$ROOT/sim/msu/synch_3_sim.v" \
  "$ROOT/sim/msu/dcfifo_sim.v" \
  "$ROOT/sim/msu/cegen_sim.v" \
  "$ROOT/target/pocket/core_bridge_cmd.v" \
  "$ROOT/target/pocket/msu/msu_ev.sv" \
  "$ROOT/target/pocket/msu/msu_tgt_cmd.sv" \
  "$ROOT/target/pocket/msu/msu_path.sv" \
  "$ROOT/target/pocket/msu/msu_sram.sv" \
  "$ROOT/target/pocket/msu/msu_host.sv" \
  "$ROOT/target/pocket/msu/msu_log.sv" \
  "$ROOT/target/pocket/msu/msu_fader.sv" \
  "$ROOT/target/pocket/msu/msu_pocket.sv" \
  "$WORK/MSU_sim.sv" \
  "$ROOT/rtl/upstream/chip/MSU1/msu_audio.v" \
  "$ROOT/rtl/upstream/chip/MSU1/msu_fifo.v" \
  "$ROOT/rtl/upstream/chip/MSU1/msu_data_store.sv"

[ -n "${COMPILE_ONLY:-}" ] && exit 0
vvp -n "$WORK/tb_msu_play.vvp" +dir="$WORK/msutest" +nomsu | tee "$WORK/tb_msu_nomsu.log" |
  grep -v "APF 0180"
grep -q "^PASS" "$WORK/tb_msu_nomsu.log"

vvp -n "$WORK/tb_msu_play.vvp" +dir="$WORK/msutest" +log="$WORK/msu_play.msulog" "$@" |
  tee "$WORK/tb_msu_play.log" | grep -v "APF 0180"
grep -q "^PASS" "$WORK/tb_msu_play.log"

python3 "$ROOT/tools/msu_log.py" "$WORK/msu_play.msulog" > "$WORK/msu_play_log.txt"
echo "Event log decoded to $WORK/msu_play_log.txt"
