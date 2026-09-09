#!/usr/bin/env bash
# Run the benchmark once per cell and collect the CSVs into one directory.
#
# The matrix is every way of driving the round crossed with every way of answering it. Cells the
# hardware cannot provide are skipped rather than failed: qLDPC has no CPU decoder, and the pacer
# supplies its own coprocessor.
#
#   ./sweep-bench.sh                  every cell, into ./sweep-<date>/
#   ./sweep-bench.sh -o results       every cell, into ./results/
#   ./sweep-bench.sh -c hw-handshake-sw-loop   one row of the matrix
#   ./sweep-bench.sh -n               print what would run, run nothing
#
# Anything after `--` is passed to every bench.py run, so a shorter sweep is
#
#   ./sweep-bench.sh -- --iters 100000
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BENCH=$HERE/../benchmarks/bench.py

CTRLS=(sw-handshake hw-handshake-sw-loop hw-handshake-hw-loop)
COPROCS=(cpu-echo gpu-echo cpu-steane gpu-steane gpu-qldpc)

OUT=""
DRY=0
ONLY_CTRL=""
VERBOSE=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while getopts ":o:c:nvh" opt; do
    case $opt in
        o) OUT=$OPTARG ;;
        c) ONLY_CTRL=$OPTARG ;;
        n) DRY=1 ;;
        v) VERBOSE="-v" ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ -f $BENCH ]] || { echo "no bench.py at $BENCH" >&2; exit 1; }
[[ -n $OUT ]] || OUT=sweep-$(date +%Y%m%d-%H%M%S)

if [[ -n $ONLY_CTRL ]]; then
    [[ " ${CTRLS[*]} " == *" $ONLY_CTRL "* ]] || {
        echo "unknown CTRL '$ONLY_CTRL', expected one of: ${CTRLS[*]}" >&2; exit 1; }
    CTRLS=("$ONLY_CTRL")
fi

(( DRY )) || mkdir -p "$OUT"
ran=0 failed=0

for ctrl in "${CTRLS[@]}"; do
    for coproc in "${COPROCS[@]}"; do
        # One cell rather than a row: the pacer is swept with the echo responder only.
        if [[ $ctrl == hw-handshake-hw-loop ]]; then
            [[ $coproc == cpu-echo ]] || continue
        fi
        csv=$OUT/rtt_${coproc}_${ctrl}.csv
        if (( DRY )); then
            echo "would run  --ctrl $ctrl --coproc $coproc -> $csv"
            continue
        fi
        echo "=== --ctrl $ctrl --coproc $coproc ==="
        if "$BENCH" --ctrl "$ctrl" --coproc "$coproc" $VERBOSE -o "$csv" "$@"; then
            ran=$((ran + 1))
        else
            # A cell whose hardware is absent reports and is stepped over, so one missing
            # decoder or board does not end the sweep.
            echo "!!! --ctrl $ctrl --coproc $coproc did not complete" >&2
            failed=$((failed + 1))
        fi
        echo
    done
done

(( DRY )) && exit 0

echo "$ran cell(s) written to $OUT"
if (( failed )); then
    echo "$failed cell(s) failed, listed above" >&2
    exit 1
fi
