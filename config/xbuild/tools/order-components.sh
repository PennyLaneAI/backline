#!/usr/bin/env bash
#
# order-components.sh — topologically sort components so dependencies build first.
#
# WHY THIS IS NEEDED
# mk/rules.mk lists each dependency's ARTIFACT as a prerequisite but deliberately does
# not provide a rule to build it (each component is built by its own sub-make, for
# variable isolation). So the artifact must already exist when a dependent component
# is built.
#
# Building in the order `ls` happens to return is therefore wrong. With
# `aa-user` depending on `zz-dep`, the alphabetical order builds aa-user first and it
# fails with "No rule to make target .../zz-dep/libzz.so". If aa-user is marked
# COMPONENT_OPTIONAL=yes, that failure is downgraded to "skipped (optional)" and the
# component is then silently missing from the bundle — the failure mode this whole
# tree is built to prevent.
#
# USAGE
#   order-components.sh <root> <name>...              sort these
#   order-components.sh <root> --with-deps <name>...  sort these plus their deps
#
# Prints names in build order, space-separated. A dependency cycle is an error.

set -uo pipefail

ROOT=${1:?usage: order-components.sh <root> [--with-deps] <name>...}
shift

WITH_DEPS=0
if [[ ${1:-} == --with-deps ]]; then WITH_DEPS=1; shift; fi

deps_of() {
  local c=$1 f="$ROOT/components/$1.conf"
  [[ -r $f ]] || return 0
  # sed rather than sourcing: this runs inside a Make expansion, so it must be quick
  # and must not execute the file.
  sed -n 's/^COMPONENT_DEPENDS=//p' "$f" | tr -d '"'"'" | tr '\n' ' '
}

# The DFS visited-set, as two space-delimited strings rather than one associative array.
#
# `declare -A` needs bash 4.0, and macOS still ships 3.2.57 as /bin/bash — where it fails
# twice over. The declaration is rejected, and then STATE[$c] falls back to INDEXED-array
# semantics, which evaluate the subscript as arithmetic: a component named
# 'example-native' is read as a subtraction, so every invocation printed
#     order-components.sh: line 40: declare: -A: invalid option
#     order-components.sh: line 46: example: unbound variable
# before `make help` had said anything. Both lines appeared on every goal in the tree.
#
# The surrounding spaces are what make membership an exact-word test, so a name that is a
# PREFIX of another ('greet' inside 'greet-app') is not falsely reported as visited. Same
# idiom as _seen_keys in tools/conf2mk.sh, which tracks duplicate keys the same way.
#
# A node is never removed from VISITING once DONE, and does not need to be: the DONE test
# runs first, so a finished node never reaches the cycle test.
STATE_VISITING=" "
STATE_DONE=" "
ORDER=()
CYCLE=""

visit() {
  local c=$1 d
  case $STATE_DONE in
    *" $c "*) return 0 ;;
  esac
  case $STATE_VISITING in
    *" $c "*) CYCLE="$CYCLE $c"; return 1 ;;   # back-edge: a cycle
  esac
  STATE_VISITING="$STATE_VISITING$c "
  for d in $(deps_of "$c"); do
    [[ -z $d ]] && continue
    # An unknown dependency is not this script's problem to report — `make check`
    # names it precisely. Skip it here so ordering still succeeds and the real
    # error surfaces from the validator rather than from a sort utility.
    [[ -r "$ROOT/components/$d.conf" ]] || continue
    visit "$d" || { CYCLE="$CYCLE <- $c"; return 1; }
  done
  STATE_DONE="$STATE_DONE$c "
  ORDER+=("$c")
  return 0
}

# Guarded array expansions throughout. Under `set -u`, bash before 4.4 treats an EMPTY
# array's "${arr[@]}" as an unbound variable and aborts — so `make build` with no
# components described, or a graph that produced no order, would die here with
# 'ORDER[@]: unbound variable' rather than printing nothing.
REQUESTED=("$@")
for c in ${REQUESTED[@]+"${REQUESTED[@]}"}; do
  visit "$c" || {
    echo "order-components: dependency cycle involving:$CYCLE" >&2
    exit 1
  }
done

# When a single component was requested WITHOUT --with-deps, emit only it; the sort
# was still useful because it validated the dependency graph.
if [[ $WITH_DEPS -eq 0 && ${#REQUESTED[@]} -eq 1 ]]; then
  printf '%s' "${REQUESTED[0]}"
  exit 0
fi

# `exit 0` explicitly: with an empty ORDER the test is the last command run, and a
# recipe's exit status is its last command's, so `make build` on a tree with no
# components would report Error 1 after printing a correct (empty) list.
if [[ ${#ORDER[@]} -gt 0 ]]; then
  printf '%s ' "${ORDER[@]}"
fi
exit 0
