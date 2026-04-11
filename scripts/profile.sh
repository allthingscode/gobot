#!/bin/bash
# gobot Binary Footprint Profiler (Linux/macOS)
# Usage: ./scripts/profile.sh

set -e

BINARY="./gobot"
FOOTPRINT_FILE="docs/footprint.txt"
THRESHOLD_BINARY=0.15 # 15%
THRESHOLD_RSS=0.20    # 20%

echo "Building gobot..."
go build -o $BINARY ./cmd/gobot/

BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY")
BINARY_SIZE_MB=$(echo "scale=2; $BINARY_SIZE / 1048576" | bc)

echo "Starting gobot for RSS measurement..."
$BINARY run &
PID=$!

sleep 10

RSS_KB=0
if ps -p $PID > /dev/null; then
    RSS_KB=$(ps -o rss= -p $PID | tr -d ' ')
    kill $PID || true
else
    echo "Warning: Could not capture RSS. Process may have exited early."
fi

RSS_MB=$(echo "scale=2; $RSS_KB / 1024" | bc)

echo ""
echo "Results:"
echo "  Binary Size: $BINARY_SIZE_MB MB"
echo "  Steady RSS:  $RSS_MB MB"
echo ""

NOW=$(date +"%Y-%m-%d %H:%M:%S")
NEW_ENTRY="$NOW | Size: $BINARY_SIZE_MB MB | RSS: $RSS_MB MB"

if [ -f "$FOOTPRINT_FILE" ]; then
    LAST_LINE=$(tail -n 1 "$FOOTPRINT_FILE")
    if [[ $LAST_LINE =~ Size:[[:space:]]([0-9.]+)[[:space:]]MB[[:space:]]\|[[:space:]]RSS:[[:space:]]([0-9.]+)[[:space:]]MB ]]; then
        OLD_SIZE=${BASH_REMATCH[1]}
        OLD_RSS=${BASH_REMATCH[2]}

        if (( $(echo "$OLD_SIZE > 0" | bc -l) )); then
            SIZE_DIFF=$(echo "($BINARY_SIZE_MB - $OLD_SIZE) / $OLD_SIZE" | bc -l)
            if (( $(echo "$SIZE_DIFF > $THRESHOLD_BINARY" | bc -l) )); then
                PERCENT=$(echo "$SIZE_DIFF * 100" | bc -l | xargs printf "%.1f")
                echo "WARNING: Binary size increased by $PERCENT% (Threshold: $(echo "$THRESHOLD_BINARY * 100" | bc -l)%)"
            fi
        fi

        if (( $(echo "$OLD_RSS > 0" | bc -l) )); then
            RSS_DIFF=$(echo "($RSS_MB - $OLD_RSS) / $OLD_RSS" | bc -l)
            if (( $(echo "$RSS_DIFF > $THRESHOLD_RSS" | bc -l) )); then
                PERCENT=$(echo "$RSS_DIFF * 100" | bc -l | xargs printf "%.1f")
                echo "WARNING: Steady RSS increased by $PERCENT% (Threshold: $(echo "$THRESHOLD_RSS * 100" | bc -l)%)"
            fi
        fi
    fi
else
    mkdir -p docs
    echo "Timestamp           | Binary Size | Steady RSS" > "$FOOTPRINT_FILE"
    echo "--------------------|-------------|------------" >> "$FOOTPRINT_FILE"
fi

echo "$NEW_ENTRY" >> "$FOOTPRINT_FILE"
echo "Baseline updated in $FOOTPRINT_FILE"
