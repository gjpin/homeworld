#!/usr/bin/env bash
# Prints "<since> <left>": the minutes since the current DeepSeek API off-peak
# period began and the minutes left before the next peak window, or "0 0"
# during one. Off-peak tokens cost half. Peak hours are 01:00-04:00 and
# 06:00-10:00 UTC, Monday to Friday
# (https://api-docs.deepseek.com/quick_start/pricing/). Chinese public holidays
# are off-peak as well, but are treated as ordinary days here.
#
# Usage: deepseek-off-peak.sh [EPOCH_SECONDS]   (default: now)
set -euo pipefail

now="${1:-$(date -u +%s)}"
today=$((now - now % 86400))
prev_end=0
next_start=0
for d in $(seq -8 8); do
  day=$((today + d * 86400))
  # 1970-01-01 was a Thursday; 1 is Monday, 7 is Sunday.
  [ $(((day / 86400 + 3) % 7 + 1)) -le 5 ] || continue
  for window in 1-4 6-10; do
    start=$((day + ${window%-*} * 3600))
    end=$((day + ${window#*-} * 3600))
    if [ "$start" -le "$now" ] && [ "$now" -lt "$end" ]; then
      echo "0 0"
      exit 0
    fi
    if [ "$end" -le "$now" ] && [ "$end" -gt "$prev_end" ]; then
      prev_end=$end
    fi
    if [ "$start" -gt "$now" ] && { [ "$next_start" -eq 0 ] || [ "$start" -lt "$next_start" ]; }; then
      next_start=$start
    fi
  done
done
echo "$(((now - prev_end) / 60)) $(((next_start - now) / 60))"
