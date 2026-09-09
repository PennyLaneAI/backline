#!/usr/bin/env bash
#
# component-output.sh — print the artifact FILENAME a component produces.
#
# Needed because a component's dependencies are declared by NAME
# (COMPONENT_DEPENDS=example-transport-session) while the linker needs the
# resulting filename (libtransport_session.so) to form -l flags and to express the
# make dependency.
#
# This tiny indirection is what lets one component refer to another without
# knowing anything about its output naming, its directory layout, or which target
# is being built. The design it replaces hardcoded the whole path:
#
#     SESSION_LIB := $(CURDIR)/../some-dependency/build/<target>/libsome_dependency.so
#
# which embeds the sibling's directory, its build-dir convention, its output name
# AND the board name in one string — four coupling points where one is enough.
#
# USAGE
#   component-output.sh <root-dir> <component-name>

set -uo pipefail

ROOT=${1:?usage: component-output.sh <root-dir> <component-name>}
NAME=${2:?usage: component-output.sh <root-dir> <component-name>}

CONF="$ROOT/components/$NAME.conf"
if [[ ! -r $CONF ]]; then
  # Print nothing and fail: the caller (Make) then produces an empty dependency,
  # and the top-level build reports the unknown component by name. Emitting a
  # guessed filename here would be worse — it would produce a confident,
  # wrong dependency.
  echo "component-output: no such component '$NAME' (looked for $CONF)" >&2
  exit 1
fi

# Read through the generated shell view, which is the only description parser in the tree.
#
# This was a second reader — sed for the line, then `tr -d` to remove quotes — and it
# disagreed with the real one in a way that lands in a FILENAME. It did not strip trailing
# comments, so
#     COMPONENT_OUTPUT=libdemo.so  # the plugin
# was read as the eleven-word string 'libdemo.so  # the plugin' while the compiler was told
# to produce 'libdemo.so'. A dependent component then looked for an artifact under the
# commented name, and Make reported "No rule to make target" naming a path with a comment
# in it. `tr -d` was also indiscriminate: it removed quotes from anywhere in the value,
# not just a matched outer pair.
#
# The cost is one short bash process per dependency edge inside a Make expansion, which is
# the reason the original avoided it. That is a few milliseconds against a compile, and the
# alternative is a filename that two parts of the build spell differently.
out=$(
  COMPONENT_OUTPUT=""
  eval "$("$(dirname "$0")/conf2mk.sh" --shell "$CONF" 2>/dev/null)" 2>/dev/null
  printf '%s' "$COMPONENT_OUTPUT"
)
if [[ -z $out ]]; then
  # Documented default from components/SCHEMA.md: COMPONENT_OUTPUT defaults to the
  # component name. Reproduced here so the two agree.
  out=$NAME
fi
printf '%s' "$out"
