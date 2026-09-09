#!/usr/bin/env bash
#
# build-catalyst-llvm.sh — cross-build the LLVM inside a Catalyst checkout FOR A TARGET.
#
# WHY THIS EXISTS
# ---------------
# Some components link LLVM itself: catalyst-executor is an ORC EPC executor, so it runs on
# the target and JITs code there. That means it needs LLVM libraries for the TARGET's
# architecture, and it needs them at the SAME version as the host side it talks to — ORC's
# wire protocol and runtime are not guaranteed stable across LLVM majors, and a mismatch is
# the worst kind of bug: it builds, deploys, and fails when the two ends connect.
#
# Neither of the obvious shortcuts satisfies both constraints:
#
#   * Catalyst's own mlir/llvm-project/build is the right VERSION but the wrong
#     ARCHITECTURE — those are build-host archives, and linking them into an aarch64
#     binary fails deep inside lld with "incompatible with elf64-littleaarch64".
#   * A distro llvm-<N>-dev in the target's rootfs is the right architecture but rarely the
#     right version. Ubuntu 24.04 offers up to LLVM 20 while Catalyst tracks 22.
#
# So the LLVM checkout Catalyst already pins gets cross-compiled with the same toolchain
# and sysroot the rest of the tree uses. One version, correct architecture.
#
# USAGE
#   build-catalyst-llvm.sh <root-dir> <target-name> <catalyst-dir> <toolchain-file> [outdir]
#
# Normally invoked as:  make catalyst-llvm TARGET=<t> CATALYST=<dir>
#
# ENVIRONMENT (all optional)
#   COMPILER_LAUNCHER    ccache-style launcher; defaults to ccache when installed, and the
#                        variable is spelled the same as in catalyst/mlir/Makefile so one
#                        habit covers both trees. Set it empty to build without.
#   LLVM_BUILD_TARGETS   ninja targets to build; default is the ORC set the executor needs
#   LLVM_JOBS            parallel compile jobs; default nproc
#   LLVM_EXTRA_CMAKE     extra -D arguments appended verbatim, last word wins

set -uo pipefail

ROOT=${1:?usage: build-catalyst-llvm.sh <root> <target> <catalyst> <toolchain-file> [outdir]}
TARGET=${2:?target name required}
CATALYST=${3:?path to the Catalyst checkout required}
TOOLCHAIN=${4:?generated cmake toolchain file required}
OUTDIR=${5:-}

die() { printf '\n[catalyst-llvm] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[catalyst-llvm] %s\n' "$*"; }

LLVM_SRC="$CATALYST/mlir/llvm-project/llvm"
HOST_BUILD="$CATALYST/mlir/llvm-project/build"

[[ -d $LLVM_SRC ]] || die "no LLVM source at '$LLVM_SRC'.
       CATALYST must point at a Catalyst checkout that includes mlir/llvm-project."
[[ -r $TOOLCHAIN ]] || die "no generated toolchain file at '$TOOLCHAIN'."

command -v cmake >/dev/null || die "cmake not found in PATH."
command -v ninja >/dev/null || die "ninja not found in PATH (this build is far too large for make)."

# ── the architecture we are building FOR ─────────────────────────────────────
# Taken from the resolved target settings (mk/exports.mk), never guessed from the host.
ARCH=${TARGET_ARCH:-}
TRIPLE=${TARGET_TRIPLE:-}
[[ -n $ARCH ]] || die "TARGET_ARCH is not set. Invoke via 'make catalyst-llvm TARGET=...' so the
       target description is resolved first."

# LLVM spells its backends differently from uname. Only the mapping is special-cased; an
# unknown arch is an error naming what to add rather than a silent empty LLVM_TARGETS_TO_BUILD
# (which would build every backend — an hour of compiling for a result you did not ask for).
case $ARCH in
  aarch64|arm64) LLVM_BACKEND=AArch64 ;;
  x86_64|amd64)  LLVM_BACKEND=X86 ;;
  arm*)          LLVM_BACKEND=ARM ;;
  riscv64|riscv) LLVM_BACKEND=RISCV ;;
  ppc64*|powerpc*) LLVM_BACKEND=PowerPC ;;
  *) die "no LLVM backend name known for TARGET_ARCH='$ARCH'.
       Add it to the case in tools/build-catalyst-llvm.sh — the LLVM name is the directory
       under llvm/lib/Target (e.g. 'LoongArch' for loongarch64)." ;;
esac

# Default the output beside Catalyst's host build, named for the architecture. The name
# matters: recipes/catalyst-executor/CMakeLists.txt looks for a build directory whose name contains
# the target processor, which is what lets a cross build find this automatically.
if [[ -z $OUTDIR ]]; then
  OUTDIR="$CATALYST/mlir/llvm-project/build-$ARCH"
fi

# ── the host tablegen ────────────────────────────────────────────────────────
# Cross-building LLVM needs llvm-tblgen that RUNS HERE: the build generates source with it.
# Catalyst's existing host build already has one, so we reuse it rather than building a
# second copy — which would double the build time for an identical binary.
TBLGEN="$HOST_BUILD/bin/llvm-tblgen"
if [[ ! -x $TBLGEN ]]; then
  die "no host llvm-tblgen at '$TBLGEN'.
       A cross build of LLVM needs a tablegen binary that runs on THIS machine to generate
       source. Build Catalyst's host LLVM first (see catalyst/mlir/Makefile), or point this
       at an existing LLVM ${LLVM_BACKEND} build of the same version with
         LLVM_EXTRA_CMAKE='-DLLVM_TABLEGEN=/path/to/llvm-tblgen -DLLVM_NATIVE_TOOL_DIR=/path/to/bin'"
fi

# What to build. The default is the ORC set catalyst-executor links; ninja pulls in every
# dependency of these, so the list stays short. Deliberately NOT everything: a full LLVM is
# tens of GB of objects and most of it is never linked into this artifact.
BUILD_TARGETS=${LLVM_BUILD_TARGETS:-"LLVMOrcJIT LLVMOrcTargetProcess LLVMOrcShared LLVMOrcDebugging LLVMSupport"}
JOBS=${LLVM_JOBS:-$(nproc 2>/dev/null || echo 4)}

# ── compiler launcher ────────────────────────────────────────────────────────
# Default to ccache when it is installed, matching catalyst/mlir/Makefile, which does
# `COMPILER_LAUNCHER ?= $(shell which ccache)` and passes it as the two CMake launcher
# variables. Same variable name and same mechanism on purpose: this build compiles much of
# the same source as Catalyst's own, so a shared cache is most of the point — and someone who
# has already set COMPILER_LAUNCHER for Catalyst gets it honoured here without learning a
# second knob. Set COMPILER_LAUNCHER= (empty) to opt out.
if [[ -z ${COMPILER_LAUNCHER+x} ]]; then
  COMPILER_LAUNCHER=$(command -v ccache 2>/dev/null || echo "")
fi

printf '\n'
printf '═══ cross-building Catalyst'"'"'s LLVM for %s ═══\n' "$TARGET"
printf 'source     : %s\n' "$LLVM_SRC"
printf 'into       : %s\n' "$OUTDIR"
printf 'arch       : %s  (LLVM backend %s, triple %s)\n' "$ARCH" "$LLVM_BACKEND" "${TRIPLE:-<unset>}"
printf 'toolchain  : %s\n' "$TOOLCHAIN"
printf 'host tblgen: %s\n' "$TBLGEN"
printf 'targets    : %s\n' "$BUILD_TARGETS"
printf 'jobs       : %s\n' "$JOBS"
printf 'launcher   : %s\n' "${COMPILER_LAUNCHER:-<none: building without ccache>}"
printf '\n'

# ── configure ────────────────────────────────────────────────────────────────
#
# The optional dependencies are all OFF on purpose, and it is not only about build time:
# each one that is ON puts an imported target into the installed LLVMExports.cmake
# (ZLIB::ZLIB, zstd::libzstd_shared, Terminfo::terminfo). Anything later consuming this LLVM
# must then satisfy those from the sysroot, and a rootfs without the matching -dev packages
# fails at CONFIGURE time with "the link interface of target LLVMSupport contains ZLIB::ZLIB
# but the target was not found" — an error about a target nobody wrote. Off here means the
# consumer needs nothing but libc and libstdc++.
cmake_args=(
  -S "$LLVM_SRC" -B "$OUTDIR" -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_TARGETS_TO_BUILD="$LLVM_BACKEND"
  -DLLVM_TABLEGEN="$TBLGEN"
  -DLLVM_NATIVE_TOOL_DIR="$HOST_BUILD/bin"
  -DLLVM_ENABLE_ZLIB=OFF
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBPFM=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_BUILD_TOOLS=OFF
  -DLLVM_BUILD_UTILS=OFF
  -DBUILD_SHARED_LIBS=OFF
)
# The default triple is what a JIT assumes when nothing tells it otherwise, so it must be
# the TARGET's — the LLVM default would be this build host's.
[[ -n $TRIPLE ]] && cmake_args+=(-DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE" -DLLVM_HOST_TRIPLE="$TRIPLE")
# Both languages: LLVM compiles C as well as C++, and launching only one of them halves the
# cache's usefulness for no reason.
if [[ -n $COMPILER_LAUNCHER ]]; then
  cmake_args+=(-DCMAKE_C_COMPILER_LAUNCHER="$COMPILER_LAUNCHER"
               -DCMAKE_CXX_COMPILER_LAUNCHER="$COMPILER_LAUNCHER")
fi
# shellcheck disable=SC2206  # deliberate word splitting: these are separate -D arguments
[[ -n ${LLVM_EXTRA_CMAKE:-} ]] && cmake_args+=(${LLVM_EXTRA_CMAKE})

log "configuring"
cmake "${cmake_args[@]}" || die "cmake configure failed (see above)."

log "building: $BUILD_TARGETS"
# shellcheck disable=SC2086  # deliberate word splitting: a list of ninja target names
cmake --build "$OUTDIR" -j "$JOBS" --target $BUILD_TARGETS \
  || die "the LLVM build failed (see above).
       If it ran out of disk, note that a Release static build of one backend still needs
       several GB. If it ran out of memory, lower the parallelism: LLVM_JOBS=4."

CMAKE_PKG="$OUTDIR/lib/cmake/llvm"
[[ -f $CMAKE_PKG/LLVMConfig.cmake ]] \
  || die "the build finished but '$CMAKE_PKG/LLVMConfig.cmake' is missing, so nothing can
       consume this LLVM. Check the configure output above for a fatal warning."

printf '\n'
log "done -> $CMAKE_PKG"
printf '\n'
printf 'This is found automatically by components that look for a target-architecture LLVM in\n'
printf 'the Catalyst tree (the directory name carries the arch). To pin it explicitly:\n'
printf '\n'
printf '  make build TARGET=%s COMPONENT=example-executor \\\n' "$TARGET"
printf '      CATALYST=%s \\\n' "$CATALYST"
printf '      COMPONENT_CMAKE_ARGS="-DCATALYST_SRC=%s -DLLVM_DIR=%s"\n' "$CATALYST" "$CMAKE_PKG"
printf '\n'
