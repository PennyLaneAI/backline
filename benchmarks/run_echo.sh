#!/usr/bin/env bash
# The CPU and GPU echo cells, sw-loop and hw-loop, into one directory, on the machines in
# ../config/machines.toml:
#     ./run_echo.sh data-hsb-rhino            # 10^6 rounds per cell
#     ITERS=1000 ./run_echo.sh /tmp/smoke
#     SLOTS=512 ./run_echo.sh data-x          # hw-loop cells with a 512-entry pacer table
set -euo pipefail
cd "$(dirname "$0")"

OUT=${1:?usage: run_echo.sh <output directory>}
ITERS=${ITERS:-1000000}
SLOTS=${SLOTS:-512}
TRACE=/tmp/rtt_trace.csv    # where the board writes a hw-loop run's trace
BOARD=$(python3 -c 'import placement; print(placement.VPK_CTRL_HOST)')

mkdir -p "$OUT"
for coproc in cpu-echo gpu-echo; do
  ./bench.py --ctrl hw-handshake-sw-loop --coproc "$coproc" --iters "$ITERS" \
    -o "$OUT/sw-for-loop.$coproc.csv"
  ./bench.py --ctrl hw-handshake-hw-loop --coproc "$coproc" --iters "$ITERS" \
    --pacer-freq 0 --pacer-slots "$SLOTS" --pacer-trace-out "$TRACE"
  scp "$BOARD:$TRACE" "$OUT/hw-for-loop.$coproc.b2b.csv"
done
