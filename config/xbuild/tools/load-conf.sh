#!/usr/bin/env bash
#
# load-conf.sh — the ONE safe way for a shell script to read a description.
#
# Source this, then call `load_conf <file>`.
#
# WHY NOT JUST `source foo.conf`
# ------------------------------
# Because a description is data in a format that only *resembles* shell. Sourcing
# it directly is wrong in two ways, one loud and one silent:
#
#   BUNDLE_COMPONENTS=app lib helper
#
#   LOUD:   shell parses this as "assign app to BUNDLE_COMPONENTS, then execute the
#           command `lib` with argument `helper`" -> "lib: command not found".
#   SILENT: the variable ends up holding only "app". The bundle then quietly
#           contains one file instead of three, and you discover it on the target.
#
# The silent half is the dangerous one. A build system that silently drops two of
# your three libraries has done something worse than crashing.
#
# The fix is not "remember to quote every multi-word value in every .conf" — that
# is another human-maintained invariant, and those decay. Instead every shell
# consumer reads a GENERATED view in which every value is already single-quoted,
# so correctness does not depend on how the description was written.
#
# USAGE
#   . "$ROOT/tools/load-conf.sh"
#   load_conf "$ROOT/targets/my-board.conf"
#   echo "$TARGET_TRIPLE"

# shellcheck shell=bash

load_conf() {
  local conf=$1
  local root tmp

  if [[ ! -r $conf ]]; then
    printf 'load_conf: cannot read %s\n' "$conf" >&2
    return 1
  fi

  # Locate conf2mk.sh relative to this file, so callers need not pass paths.
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

  tmp=$(mktemp "${TMPDIR:-/tmp}/crossbuild-conf-XXXXXX") || return 1

  # Validation happens here too: the generator rejects unknown keys, shell
  # constructs and command substitution. So a malformed description cannot reach a
  # consumer at all, no matter which entry point was used.
  #
  # --check as well as the exit status: a truncated view is the dangerous case here,
  # because the values that DID arrive are individually valid. The verifier reading a
  # description whose TARGET_ARCH went missing does not fail — it reports "cannot
  # check" and passes, which is the one outcome this tree refuses to produce.
  if ! "$root/tools/conf2mk.sh" --shell "$conf" > "$tmp" 2>"$tmp.err" \
     || ! "$root/tools/conf2mk.sh" --check "$tmp" 2>>"$tmp.err"; then
    printf 'load_conf: %s could not be read:\n' "$conf" >&2
    sed 's/^/  /' "$tmp.err" >&2
    rm -f "$tmp" "$tmp.err"
    return 1
  fi

  # The status of the source itself is checked, not assumed. This used to end in a
  # hardcoded `return 0`, so a view that was generated correctly and then failed to LOAD —
  # a full /tmp, a read error, a value the shell refused — was reported to the caller as a
  # successful load, and the caller went on with whatever variables it already had. Every
  # consumer of this function reads target expectations with it, and the verifier treats a
  # missing expectation as "cannot check" rather than as an error.
  # shellcheck disable=SC1090
  if ! . "$tmp"; then
    printf 'load_conf: the generated view of %s could not be loaded\n' "$conf" >&2
    rm -f "$tmp" "$tmp.err"
    return 1
  fi
  rm -f "$tmp" "$tmp.err"
  return 0
}
