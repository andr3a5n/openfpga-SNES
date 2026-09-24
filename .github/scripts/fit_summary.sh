#!/usr/bin/env bash
# Print the Quartus fit and timing results as Markdown, for the job summary.
OUT="${1:-projects/output_files}"

echo "### Fit"
echo '```'
if [ -f "$OUT/snes_pocket.fit.summary" ]; then
  grep -E "Status|Logic utilization|Total registers|block memory|DSP|PLLs" "$OUT/snes_pocket.fit.summary"
else
  echo "No fit summary (the compile failed earlier)"
fi
echo '```'

echo "### Timing (worst slack per clock, negative means a violation)"
echo '```'
if [ -f "$OUT/snes_pocket.sta.summary" ]; then
  awk '/^Type/ {type=$0} /^Slack/ {print type " -> " $0}' "$OUT/snes_pocket.sta.summary" |
    sed 's/Type  *: //' | grep -E "Setup|Hold" | sort -t: -k3 -n | head -n 20
else
  echo "No timing summary"
fi
echo '```'
