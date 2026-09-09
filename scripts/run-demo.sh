#!/usr/bin/env bash
# run-demo.sh: run a demo and collect its output as the reference log for that demo.
#
#   ./run-demo.sh demo_1_local_cpu_to_local_cpu_memcpy.py
#   CATALYST_REMOTE_VERBOSE=1 ./run-demo.sh demo_4_remote_fpga_to_remote_gpu.py
#
# A demo writes its executors' logs relative to the working directory, so this runs it from
# ../demos/expected_logs/<demo>/ and everything lands there beside driver.log. That directory is emptied
# first, so a run replaces the reference rather than accumulating beside it. Git is the undo.
#
# PYTHON selects the interpreter when no venv is active.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <demo.py> [args...]" >&2
    exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demos_dir="$here/../demos"
demo="$1"; shift

# Accept either a bare name or a path, so tab-completion from any directory works.
if [[ -f $demo ]]; then
    demo_path="$(cd "$(dirname "$demo")" && pwd)/$(basename "$demo")"
elif [[ -f "$demos_dir/$demo" ]]; then
    demo_path="$demos_dir/$demo"
else
    echo "error: no such demo: $demo" >&2
    exit 2
fi
demo_name="$(basename "$demo_path" .py)"

out_dir="$demos_dir/expected_logs/$demo_name"
rm -rf "$out_dir"
mkdir -p "$out_dir"
echo "=== $demo_name -> demos/expected_logs/$demo_name/"

# The demo pins no versions: the transport, the runtime and the decoder all live in other trees, so
# a log is only attributable with those recorded beside it.
#
# The modified count excludes the generated log directories. This script has just emptied the one it
# is about to write, so counting them would report its own output as a change to the tree that
# produced the log. expected_logs/README.md is not generated, so it still counts.
generated=':(exclude)demos/expected_logs/*/*'
{
    echo "# $(date -Is)"
    echo "# command: $(basename "$demo_path") $*"
    for repo in "$here/.." "${CATALYST_ROOT:-$HOME/catalyst}" "$HOME/pennylane"; do
        [[ -d "$repo/.git" ]] || continue
        printf '%-12s %-10s %s  %s modified\n' \
            "$(basename "$(cd "$repo" && pwd)")" \
            "$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')" \
            "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')" \
            "$(git -C "$repo" status --porcelain -- . "$generated" 2>/dev/null | grep -cv '^??' || true)"
    done
} > "$out_dir/provenance.txt"
sed 's/^/    /' "$out_dir/provenance.txt"

# An activated venv puts its own `python` first; fall back for shells without one.
py="${PYTHON:-$(command -v python || command -v python3 || true)}"
if [[ -z $py ]]; then
    echo "error: no python found; set PYTHON=/path/to/python" >&2
    exit 2
fi

# `-u` because stdout is a pipe into tee, where Python would otherwise block-buffer it: progress
# would sit unseen in a 4 KB buffer and the run would look stuck.
cd "$out_dir"
set +e
PYTHONPATH="$(dirname "$demo_path")${PYTHONPATH:+:$PYTHONPATH}" \
    "$py" -u "$demo_path" "$@" 2>&1 | tee driver.log
status=${PIPESTATUS[0]}
set -e

echo "=== exit $status; $(ls | wc -l) file(s) in demos/expected_logs/$demo_name/"
exit "$status"
