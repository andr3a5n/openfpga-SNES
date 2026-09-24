#!/usr/bin/env bash
# Print the Quartus fit and timing results as Markdown, for the job summary.
OUT="${1:-projects/output_files}"

echo "### Fit"
echo '```'
if [ -f "$OUT/snes_pocket.fit.summary" ]; then
  grep -E "Status|Logic utilization|Total registers|block memory|RAM Blocks|DSP|PLLs" \
    "$OUT/snes_pocket.fit.summary"
else
  echo "No fit summary (the compile failed earlier)"
fi
echo '```'

echo "### Timing: worst slack per clock over all corners (negative = violation)"
echo '```'
if [ -f "$OUT/snes_pocket.sta.summary" ]; then
  python3 - "$OUT/snes_pocket.sta.summary" <<'PY'
import re, sys
worst = {}
kind = clock = None
for line in open(sys.argv[1]):
    m = re.match(r"Type\s*:\s*.* Model (Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(.*)'", line)
    if m:
        kind, clock = m.groups()
        continue
    m = re.match(r"Slack\s*:\s*(-?[\d.]+)", line)
    if m and kind:
        key = (clock, kind)
        worst[key] = min(worst.get(key, float("inf")), float(m.group(1)))
names = {"general[0]": "clk_mem (85.9 MHz)", "general[1]": "clk_sys (21.5 MHz)",
         "general[2]": "clk_video", "general[3]": "clk_video_90"}
for (clock, kind), slack in sorted(worst.items(), key=lambda kv: kv[1]):
    if kind not in ("Setup", "Hold"):
        continue
    label = next((v for k, v in names.items() if k in clock), clock)
    print("%-7s %-22s %9.3f ns" % (kind, label, slack))
PY
else
  echo "No timing summary"
fi
echo '```'
