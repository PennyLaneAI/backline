#!/usr/bin/env bash
#
# gen-cmake-toolchain.sh — emit a CMake toolchain file from the resolved target
# variables, so that cmake-driven components compile with exactly the same flags
# as directly-compiled ones.
#
# THE PROBLEM THIS SOLVES
# -----------------------
# A tree with both direct-compiler and cmake-driven components has two consumers of
# the same facts — the CPU flag, the interpreter path, the sysroot. Writing them
# twice and asking a human to keep the copies aligned is the obvious approach, and
# it is a defect: two copies of a fact will diverge, and the only questions are when,
# and whether the divergence fails loudly (a link error) or quietly (a binary tuned
# for the wrong CPU, or carrying the wrong interpreter, which fails only on the
# device).
#
# Generating one representation from the other removes the invariant entirely.
# There is no second copy to drift, and no "KEEP IN SYNC" comment to obey.
#
# The generated file lives under build/ and is regenerated whenever the target
# description changes, so it is never edited and never committed.
#
# USAGE
#   Invoked by mk/rules.mk with the target variables already exported.
#   Writes the toolchain file to stdout.

set -euo pipefail

req() {
  local name=$1
  if [[ -z ${!name:-} ]]; then
    echo "gen-cmake-toolchain: $name is not set; this script must be invoked by mk/rules.mk" >&2
    exit 1
  fi
}
req TARGET_NAME
req TARGET_TRIPLE
req SYSROOT_DIR

# CMake wants its own spelling of the processor. It is not the triple's arch field
# in every case, but for Linux targets it is close enough that passing the arch is
# correct, and CMake only uses it for CMAKE_SYSTEM_PROCESSOR (informational for
# most projects).
cmake_processor=${TARGET_ARCH:-${TARGET_TRIPLE%%-*}}

# The OS name CMake uses to decide what a shared library is called, whether an install
# name exists, and which linker conventions apply. Taken from the target's binary format,
# which mk/derive.mk resolves through tools/arch-table.sh and mk/exports.mk passes in.
#
# It was hardcoded to Linux. On a Mach-O target that is not a cosmetic inaccuracy: CMake
# then expects .so rather than .dylib, and knows nothing of install names, so a cmake
# component's library could not be found by the very bundle that shipped it. Recomputed
# here rather than exported as a name, so that adding a platform stays one table entry.
case ${TARGET_BINFMT:-elf} in
  macho) cmake_system_name=Darwin ;;
  *)     cmake_system_name=Linux ;;
esac

# Facts a cmake-driven component cannot work out for itself, emitted so it does not have to
# guess. The canonical architecture name goes through tools/arch-table.sh so a project comparing
# architectures never has to know that aarch64 and arm64 are one machine.
_here=$(cd "${0%/*}" && pwd)
crossbuild_cmake_dir=$(cd "$_here/../cmake" 2>/dev/null && pwd || echo "")
canon_arch=$("$_here/arch-table.sh" deb-arch "$cmake_processor" 2>/dev/null || echo "")
: "${canon_arch:=$cmake_processor}"

cat <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — do not edit, and do not commit.
#
# Produced by tools/gen-cmake-toolchain.sh from:
#   ${TARGET_CONF_FILE:-<target description>}
#
# Every value below is derived from that one description, which is also the source
# of the flags used by the direct-compiler build path. That is deliberate: two
# hand-maintained copies of a target's CPU and interpreter path will eventually
# disagree, and the resulting binary fails only on the device.
#
# Regenerate:  make show-target TARGET=$TARGET_NAME   (or just rebuild)
# ─────────────────────────────────────────────────────────────────────────────

set(CMAKE_SYSTEM_NAME      $cmake_system_name)
set(CMAKE_SYSTEM_PROCESSOR $cmake_processor)

# For components that need to reason about the target: the architecture in canonical form, and
# where this tree's cmake modules live (see cmake/CrossbuildFindLLVM.cmake).
set(CROSSBUILD_TARGET_ARCH "$canon_arch")
set(CROSSBUILD_CMAKE_DIR   "$crossbuild_cmake_dir")

# Telling CMake we are cross-compiling stops it from trying to RUN test binaries
# it has just built for another architecture — which fails with "Exec format
# error" during configure and looks like a broken compiler.
set(CMAKE_CROSSCOMPILING TRUE)

set(CMAKE_SYSROOT "$SYSROOT_DIR")

# ── compilers ────────────────────────────────────────────────────────────────
set(CMAKE_C_COMPILER   "${TARGET_CC}")
set(CMAKE_CXX_COMPILER "${TARGET_CXX}")
set(CMAKE_ASM_COMPILER "${TARGET_CC}")
EOF

# The triple is passed as a compiler *target* only for LLVM. A prefixed GCC has
# its target built in, and setting CMAKE_*_COMPILER_TARGET makes it pass an
# unrecognised --target= flag and fail at configure time.
if [[ ${TOOLCHAIN_KIND:-llvm} == llvm ]]; then
cat <<EOF

# clang is a cross-compiler by construction: one binary, target chosen by flag.
set(CMAKE_C_COMPILER_TARGET   "$TARGET_TRIPLE")
set(CMAKE_CXX_COMPILER_TARGET "$TARGET_TRIPLE")
set(CMAKE_ASM_COMPILER_TARGET "$TARGET_TRIPLE")
EOF
fi

cat <<EOF

set(CMAKE_AR      "${TARGET_AR}"      CACHE FILEPATH "")
set(CMAKE_RANLIB  "${TARGET_RANLIB}"  CACHE FILEPATH "")
set(CMAKE_STRIP   "${TARGET_STRIP}"   CACHE FILEPATH "")
set(CMAKE_OBJCOPY "${TARGET_OBJCOPY}" CACHE FILEPATH "")

# ── flags ────────────────────────────────────────────────────────────────────
# _INIT variants seed the cache without overriding a value the user passes on the
# cmake command line, which keeps -DCMAKE_CXX_FLAGS=... working as expected.
EOF

# Assemble the same flag pieces the direct path uses. Sourced from the environment
# that mk/rules.mk exported, so there is exactly one origin for each.
cpu_flag=""
if [[ -n ${TARGET_CPU:-} ]]; then
  cpu_flag="-${TARGET_CPU_FLAG:-march}=${TARGET_CPU}"
fi

linker_flag=""
case ${TARGET_LINKER:-lld} in
  lld)  linker_flag="-fuse-ld=lld" ;;
  bfd)  linker_flag="-fuse-ld=bfd" ;;
  gold) linker_flag="-fuse-ld=gold" ;;
  mold) linker_flag="-fuse-ld=mold" ;;
esac

stdlib_flag=""
[[ ${TARGET_STDLIB:-libstdc++} == libc++ ]] && stdlib_flag="-stdlib=libc++"

# Collapse runs of whitespace WITHOUT running the value through a shell-quoting
# tool. The obvious `$(echo "$x" | xargs)` is wrong here in three separate ways, all
# silent:
#
#   * xargs performs shell-style quote REMOVAL, so -Wl,-rpath,'$ORIGIN' loses its
#     quotes; the emitted flag then splits and cmake receives a rpath entry that is
#     EMPTY. An empty RPATH entry means "search the current working directory" — a
#     wrong-library hazard and a load-path injection vector. (Observed in a built
#     artifact as: Library rpath: [:$ORIGIN].)
#   * -DGREETING="hello world" becomes two arguments.
#   * an unbalanced quote makes xargs exit 1, and because this runs inside a command
#     substitution in a printf argument, `set -e` does NOT catch it — the flag is
#     silently emptied.
#
# sed does none of that: it is a pure textual transformation.
squash() { printf '%s' "$1" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }

# The C++ standard and the sysroot's include/library paths must be here too. They are
# part of what derive.mk composes for the direct path, so omitting them means a
# cmake-driven component compiles against DIFFERENT headers than a directly-compiled
# one — the exact divergence this generated file exists to prevent.
# Take the flag mk/derive.mk composed, so the cmake path cannot spell the standard differently
# from the direct path. The fallback matches derive.mk's floor (20) for a direct call to this
# script with nothing exported.
std_flag="${TARGET_STD_FLAG:--std=gnu++${TARGET_CXX_STANDARD:-20}}"

common_flags="$cpu_flag ${TARGET_CFLAGS:-} ${SYSROOT_CXX_FLAGS:-}"
cxx_flags="$cpu_flag $stdlib_flag $std_flag ${TARGET_CXXFLAGS:-} ${SYSROOT_CXX_FLAGS:-}"

printf 'set(CMAKE_C_FLAGS_INIT   "%s")\n'   "$(squash "$common_flags")"
printf 'set(CMAKE_CXX_FLAGS_INIT "%s")\n'   "$(squash "$cxx_flags")"
printf 'set(CMAKE_ASM_FLAGS_INIT "%s")\n'   "$(squash "$cpu_flag")"

# Link flags. The dynamic-linker override applies only to executables — a shared
# library has no interpreter, and passing it there is silently ignored by some
# linkers and an error in others.
link_common="$linker_flag ${TARGET_LDFLAGS:-} ${SYSROOT_LINK_FLAGS:-}"
exe_link="$link_common"
[[ -n ${TARGET_DYNAMIC_LINKER:-} ]] && exe_link="$exe_link -Wl,--dynamic-linker=${TARGET_DYNAMIC_LINKER}"

# NOTE: no -Wl,-rpath here on purpose. CMake owns RPATH and discards linker-flag
# attempts to set it; the supported mechanism (CMAKE_BUILD_WITH_INSTALL_RPATH +
# CMAKE_INSTALL_RPATH) is emitted further down. Passing it here as well is what
# produced the empty leading RPATH entry described above.
#
# --disable-new-dtags is ELF-only, and this is the SECOND place it was composed — the
# first being mk/derive.mk. That duplication is what this tree exists to remove, and it
# cost exactly what duplication costs: derive.mk learned that ld64 rejects the flag and
# this file did not, so every cmake component failed on macOS at the compiler-probe stage
# with
#     ld: unknown options: --disable-new-dtags
#     The C++ compiler ... is not able to compile a simple test program
# which reads as a broken clang install rather than as one flag from one line here.
# Both places now branch on the same exported TARGET_BINFMT.
if [[ -n ${TARGET_RPATH:-} && ${TARGET_BINFMT:-elf} != macho ]]; then
  link_common="$link_common -Wl,--disable-new-dtags"
  exe_link="$exe_link -Wl,--disable-new-dtags"
fi

echo
printf 'set(CMAKE_EXE_LINKER_FLAGS_INIT    "%s")\n' "$(squash "$exe_link")"
printf 'set(CMAKE_SHARED_LINKER_FLAGS_INIT "%s")\n' "$(squash "$link_common")"
printf 'set(CMAKE_MODULE_LINKER_FLAGS_INIT "%s")\n' "$(squash "$link_common")"

# ── RPATH, the CMake way ─────────────────────────────────────────────────────
# CMake OWNS the RPATH of everything it links. It rewrites what the linker flags
# asked for: during a build it inserts absolute paths to the build tree, and on
# `install` it strips them. So passing -Wl,-rpath in the linker flags above is not
# enough — CMake silently discards it, and the artifact comes out with no RPATH at
# all. (Observed: a cmake-built binary with the flag present verified as
# "RPATH: none set".)
#
# The two settings below are the supported way to say what we mean: build the
# binary with its FINAL RPATH from the start, and make that RPATH the target's.
# Doing it here means every cmake-driven component gets the same relocatable
# $ORIGIN behaviour as the directly-compiled ones, without each upstream project
# having to cooperate.
if [[ -n ${TARGET_RPATH:-} ]]; then
  # Un-double the '$' that Make requires in the description; CMake wants a literal
  # single '$' here, and CMake does not re-expand it.
  rpath_literal=${TARGET_RPATH//\$\$/\$}
  cat <<EOF

set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
set(CMAKE_INSTALL_RPATH "$rpath_literal")
# Do not let CMake append the absolute paths of linked libraries: those are
# build-host paths and would both break relocatability and leak local directory
# names into a shipped binary.
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)
EOF
fi

cat <<'EOF'

# ── search behaviour ─────────────────────────────────────────────────────────
# This block is what stops CMake from finding the BUILD machine's libraries and
# happily linking them into a target binary. Without it, find_library() searches
# the host's /usr/lib, finds a same-named library of the wrong architecture, and
# the failure appears at link time as an incompatible-format error — or worse, on
# a same-arch cross-libc build, it succeeds and produces a subtly wrong binary.
#
#   PROGRAM NEVER  — host tools (cmake, python, protoc) must come from the host;
#                    a target-architecture binary cannot execute here.
#   LIBRARY ONLY   — libraries must come from the sysroot, never the host.
#   INCLUDE ONLY   — likewise headers.
#   PACKAGE ONLY   — likewise CMake package configs.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# For a native target these restrictions are wrong: the sysroot IS the host, and
# forcing ONLY breaks find_package for anything outside it.
# Resolve symlinks first: a native target commonly reaches "/" through
# build/sysroots/<name> being a symlink to it (the `dir` provider in reference
# mode), and a literal string comparison would miss that and leave the
# cross-compilation restrictions in place for a native build.
_sysroot_real=$(cd "$SYSROOT_DIR" 2>/dev/null && pwd -P || echo "$SYSROOT_DIR")
if [[ $_sysroot_real == "/" ]]; then
cat <<'EOF'

# Native build (sysroot is "/"): relax the search restrictions, since "the host"
# and "the target" are the same machine and confining the search would only stop
# find_package from working.
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
set(CMAKE_CROSSCOMPILING FALSE)
EOF
fi
