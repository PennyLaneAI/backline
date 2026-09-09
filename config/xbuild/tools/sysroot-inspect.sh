#!/usr/bin/env bash
#
# sysroot-inspect.sh — discover a sysroot's layout by looking at it, instead of
# assuming a layout and failing obscurely when the assumption is wrong.
#
# WHY THIS IS THE MOST IMPORTANT TOOL IN THE TREE
# -----------------------------------------------
# The original design assumed one sysroot shape throughout — Debian multiarch,
# glibc, GCC 13:
#
#     MYBOARD_SYSROOT_LIBC := $(SYSROOT)/usr/lib/aarch64-linux-gnu/libc.a
#     GCC_VERSION ?= 13
#     -isystem $(SYSROOT)/usr/include/c++/13
#     -isystem $(SYSROOT)/usr/include/aarch64-linux-gnu/c++/13
#
# Every one of those four lines is false for a sysroot that is not
# Debian-derived-with-GCC-13:
#
#   * `libc.a` is a STATIC library. A rootfs copied off a real running board
#     normally has no static libs at all — they are a -dev package. So the check
#     "is this sysroot usable" failed on the most authoritative sysroot available,
#     the actual device's filesystem.
#   * `usr/lib/<triple>/` is Debian multiarch. Fedora/RHEL use `usr/lib64`,
#     Yocto/Buildroot use `usr/lib`, Alpine uses `usr/lib`.
#   * `usr/include/c++/13` pins one GCC. A sysroot with GCC 12 or 14 produced
#     "fatal error: 'vector' file not found" — an error that mentions neither GCC
#     nor a version and sends you looking in the wrong place entirely.
#
# This script replaces all of that with discovery: glob for what is actually
# present, pick it, and if nothing suitable is present say so in a sentence that
# names the missing thing.
#
# USAGE
#   sysroot-inspect.sh probe    <sysroot> <triple>                       # exit 0 if usable
#   sysroot-inspect.sh libdir   <sysroot> <triple>                       # print the lib dir
#   sysroot-inspect.sh gccver   <sysroot> <triple> [pin]                 # print C++ hdr version
#   sysroot-inspect.sh cxxflags <sysroot> <triple> <stdlib> [gcc-pin]
#   sysroot-inspect.sh ldflags  <sysroot> <triple> <stdlib> [gcc-pin]
#   sysroot-inspect.sh report   <sysroot> <triple>                       # human-readable
#   sysroot-inspect.sh linkability <sysroot> <triple>                    # warn if it can only RUN
#   sysroot-inspect.sh haslib   <sysroot> <triple> <name>                 # can -l<name> be linked?
#
# The cxxflags/ldflags forms print nothing and exit 0 on an absent sysroot, so
# that Make can expand them harmlessly during a `make help`. The `probe` form is
# what a recipe uses to fail loudly before compiling.

set -uo pipefail

MODE=${1:-report}
SYSROOT=${2:-}
TRIPLE=${3:-}
STDLIB=${4:-libstdc++}
GCC_PIN=${5:-}

[[ -n $SYSROOT ]] || { echo "sysroot-inspect: no sysroot given" >&2; exit 2; }

# Normalise the sysroot into a prefix that concatenates cleanly.
#
# We build paths as "$SYSROOT/usr/lib", so a native sysroot of "/" would yield
# "//usr/lib". That is harmless to the compiler but it makes every emitted command
# line harder to read, and the readability of the actual compiler invocation is a
# real debugging asset. A native root therefore becomes the empty prefix, which
# concatenates to "/usr/lib" exactly as intended.
#
# SYSROOT_ARG keeps the value suitable for --sysroot= (never empty).
SYSROOT_ARG=$SYSROOT
while [[ ${#SYSROOT} -gt 1 && ${SYSROOT: -1} == / ]]; do SYSROOT=${SYSROOT%/}; done
if [[ $SYSROOT == / ]]; then SYSROOT=""; fi

# For messages and existence tests, "" must read back as "/".
sysroot_display() { printf '%s' "${SYSROOT:-/}"; }
sysroot_exists()  { [[ -d "${SYSROOT:-/}" ]]; }

# The gccver mode documents its optional pin as the 4th argument, while the
# cxxflags/ldflags modes take <stdlib> there and the pin 5th. Reconcile them here
# so both documented call forms work; a silently-ignored pin would defeat the
# whole point of pinning.
if [[ $MODE == gccver && -n ${4:-} ]]; then GCC_PIN=$4; fi

# ── candidate library directories, most specific first ───────────────────────
# Order is deliberate: a Debian multiarch dir is more specific than lib64, which
# is more specific than lib. Taking the first that exists means a multiarch
# sysroot resolves to the multiarch path (correct) while a Yocto sysroot falls
# through to usr/lib (also correct).
# ── the triple spellings a sysroot's directories might use ───────────────────
#
# A description may legitimately name the machine differently from the way the sysroot's
# distro named its directories. detect-host.sh reports this host as x86_64-pc-linux-gnu,
# while every Debian/Ubuntu tree calls the same directory x86_64-linux-gnu (multiarch omits
# the vendor field). Looking only for the spelling we were handed made a perfectly good
# sysroot report "contains no C library", and silently dropped the -isystem/-B/-L paths
# below on any target whose triple carried a vendor.
#
# STRICTLY ADDITIVE: the spelling passed in is always tried FIRST, so anything that resolves
# today resolves the same way. The vendorless form is only consulted where the exact one
# found nothing, and is emitted only when it actually differs.
TRIPLE_ALT=""
if [[ -n $TRIPLE ]]; then
  TRIPLE_ALT=$("$(dirname "$0")/detect-host.sh" multiarch-triple "$TRIPLE" 2>/dev/null || echo "")
  [[ $TRIPLE_ALT == "$TRIPLE" ]] && TRIPLE_ALT=""
fi

# ── which kind of sysroot are we looking at? ─────────────────────────────────
# From tools/arch-table.sh, the one place platform facts live, so this file does not
# acquire a second opinion about what a triple means.
#
# It matters here because "does this directory contain a C library" has a different
# answer per platform, and the ELF-only answer rejected a perfectly good Darwin SDK for
# lacking a libc.so — the same class of mistake as the original tree's hardcoded
# libc.a probe, which rejected a real device rootfs for lacking a STATIC library.
BINFMT=$("$(dirname "$0")/arch-table.sh" binfmt "${TRIPLE:-}" 2>/dev/null || echo elf)

# Prints each distinct spelling, most-authoritative first. Callers loop over it instead of
# interpolating $TRIPLE directly.
triple_variants() {
  printf '%s\n' "$TRIPLE"
  [[ -n $TRIPLE_ALT ]] && printf '%s\n' "$TRIPLE_ALT"
  return 0
}

libdir_candidates() {
  local s=$1 t=$2 tv
  # Both triple spellings before falling back to the non-multiarch layouts: a vendorless
  # multiarch dir is still more specific evidence than a bare usr/lib.
  for tv in "$t" ${TRIPLE_ALT:+"$TRIPLE_ALT"}; do
    [[ -n $tv ]] && printf '%s\n' "$s/usr/lib/$tv"
  done
  printf '%s\n' \
    "$s/usr/lib64" \
    "$s/usr/lib"
  for tv in "$t" ${TRIPLE_ALT:+"$TRIPLE_ALT"}; do
    [[ -n $tv ]] && printf '%s\n' "$s/lib/$tv"
  done
  printf '%s\n' \
    "$s/lib64" \
    "$s/lib"
}

# The filenames that prove a directory holds this platform's C library.
#
# Darwin's are text stubs, not libraries. Since Big Sur the system libraries do not exist
# as files at all — they live only inside the dyld shared cache — so what an SDK ships is
# a .tbd (text-based dylib) describing the symbols. That is the authoritative thing to
# link against on a Mac, and it is what an ELF-shaped search for libc.so* can never find:
#     ERROR: '/' exists but contains no C library, so it cannot be a sysroot.
# on a machine whose C library is working perfectly.
libdir_has_libc() {
  local d=$1
  if [[ $BINFMT == macho ]]; then
    # [[ -e ]] for exact names; see the NOTE in linkability_report about compgen -G.
    [[ -e "$d/libSystem.tbd" || -e "$d/libSystem.B.tbd" || -e "$d/libc.tbd" ]] && return 0
    [[ -e "$d/libSystem.dylib" || -e "$d/libSystem.B.dylib" ]] && return 0
    return 1
  fi
  compgen -G "$d/libc.so*"      >/dev/null 2>&1 && return 0
  compgen -G "$d/libc.a"        >/dev/null 2>&1 && return 0
  compgen -G "$d/libc-*.so"     >/dev/null 2>&1 && return 0
  compgen -G "$d/ld-musl-*.so*" >/dev/null 2>&1 && return 0
  return 1
}

# What the probe says it looked for, so the message names this platform's files and not
# another platform's.
libc_names_wanted() {
  if [[ $BINFMT == macho ]]; then
    printf 'libSystem.tbd, libSystem.B.tbd, libc.tbd or libSystem.dylib'
  else
    printf 'libc.so*, libc.a or ld-musl-*.so*'
  fi
}

# ── where the compiler's own support objects live ────────────────────────────
#
# crtbegin.o / crtend.o come from the compiler, not from libc, and -B is what points clang
# at the TARGET's copies. This one is worth discovering rather than assuming, because when
# it is missing clang does not fail — it falls back to the BUILD HOST's copies, whose
# architecture is wrong, and the error arrives much later and names none of this.
#
# Two layouts, measured:
#   Debian/Ubuntu    usr/lib/gcc/<triple>/<ver>/crtbegin.o
#   OpenEmbedded     usr/lib/<vendor-triple>/<ver>/crtbegin.o
# and in a Yocto/OpenEmbedded vendor SDK the directory carries the TOOLCHAIN's triple, which
# embeds the vendor (aarch64-<vendor>-linux) while the description quite correctly says
# aarch64-linux-gnu — so matching on the triple we were handed finds nothing. Glob the version directory instead and confirm by looking
# for the object itself, which identifies the directory without naming any vendor.
# ── the architecture-specific C++ include directory ──────────────────────────
#
# bits/c++config.h is generated per architecture and lives in a directory whose position
# depends on who built the sysroot:
#   Debian/Ubuntu    usr/include/<triple>/c++/<ver>/bits/c++config.h   (a SIBLING of the
#                                                                       version directory)
#   OpenEmbedded     usr/include/c++/<ver>/<triple>/bits/c++config.h   (a CHILD of it)
# and the triple inside is the toolchain's, not the description's — aarch64-<vendor>-linux in
# a Yocto SDK whose target is described, correctly, as aarch64-linux-gnu. So it cannot be
# built by substitution; it has to be found. Measured against a real vendor SDK.
#
# Without this the -isystem is silently absent and the compile fails inside libstdc++ with
# a missing bits/c++config.h, which reads as a broken sysroot rather than a missing flag.
find_cxx_archinc() {
  local s=$1 ver=$2 d
  for d in "$s"/usr/include/*/c++/"$ver" "$s"/usr/include/c++/"$ver"/*; do
    [[ -d $d ]] || continue
    [[ -e "$d/bits/c++config.h" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

find_gccsupport() {
  local s=$1 ver=$2 d
  for d in "$s"/usr/lib/gcc/*/"$ver" "$s"/usr/lib/gcc-cross/*/"$ver" "$s"/usr/lib/*/"$ver"; do
    [[ -d $d ]] || continue
    if compgen -G "$d/crtbegin*.o" >/dev/null 2>&1; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

find_libdir() {
  local d
  while read -r d; do
    [[ -d $d ]] || continue
    # A directory only counts if it holds a libc. Otherwise an empty
    # /usr/lib that exists on almost every tree would win and produce a link
    # failure far from the cause.
    if libdir_has_libc "$d"; then
      echo "$d"; return 0
    fi
  done < <(libdir_candidates "$1" "$2")
  return 1
}

# ── the C++ header version present in the sysroot ────────────────────────────
# Globbed, then version-sorted, then the newest is taken — unless the target
# description pinned one, in which case we honour the pin but verify it exists so
# a stale pin is an immediate, named error instead of a missing-header mystery.
find_gccver() {
  local s=$1 pin=${2:-}
  local base="$s/usr/include/c++"
  [[ -d $base ]] || return 1
  if [[ -n $pin ]]; then
    if [[ -d "$base/$pin" ]]; then echo "$pin"; return 0; fi
    echo "sysroot-inspect: TARGET_SYSROOT_GCC_VERSION=$pin was requested but $base/$pin does not exist." >&2
    echo "                 present: $(cd "$base" && ls -1 | tr '\n' ' ')" >&2
    return 1
  fi
  local newest
  newest=$(cd "$base" && ls -1 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -n1)
  [[ -n $newest ]] || return 1
  echo "$newest"
}

# ── is the C++ header tree whole? ────────────────────────────────────────────
#
# A sysroot can hold a complete libc and a C++ tree with a directory missing from the
# middle of it. That failure surfaces as a fatal error pointing INSIDE libstdc++ —
#
#     usr/include/c++/14/bits/stl_iterator_base_funcs.h:65:10:
#         fatal error: 'debug/assertions.h' file not found
#
# — which reads as a broken compiler rather than as an incomplete copy, and sends
# people to check their clang install. Observed in the field from an rsync exclude
# pattern that pruned debug/ at every depth.
#
# Prints what is missing and returns 0 when the tree is BROKEN; returns 1 when there is
# nothing to complain about. A sysroot with no C++ tree at all is not broken — plenty
# of targets legitimately build only C — so that returns 1 too.
cxx_tree_missing() {
  local s=$1 t=$2 ver base
  ver=$(find_gccver "$s" "" 2>/dev/null) || return 1
  base="$s/usr/include/c++/$ver"

  # debug/ is not optional despite the name: the ordinary headers include
  # <debug/assertions.h> unconditionally, so #include <string> cannot compile without it.
  [[ -d "$base/debug" ]] || { printf 'debug/ (the libstdc++ debug-mode headers)'; return 0; }

  # c++config.h is generated per-architecture. Debian/Ubuntu keep it ONLY in the
  # multiarch tree, everyone else keeps it in the arch-independent one, so either
  # location counts. The glob rather than the exact triple is deliberate: a description
  # may spell the triple differently from the directory the sysroot's distro created
  # (x86_64-pc-linux-gnu vs x86_64-linux-gnu), and that is not a missing header.
  if [[ ! -e "$base/bits/c++config.h" ]] && ! find_cxx_archinc "$s" "$ver" >/dev/null; then
    printf 'bits/c++config.h (the per-architecture libstdc++ configuration)'
    return 0
  fi

  return 1
}

# ── can this sysroot be LINKED against, or only run on? ──────────────────────
#
# A rootfs copied off a device that has no -dev packages installed holds every runtime
# soname (libc.so.6, libstdc++.so.6) and none of the development files. It passes the
# probe — it really does contain a C library — and then fails at the first compile with
# a wall of output that names none of this:
#
#     fatal error: 'cstdio' file not found
#     ld.lld: error: cannot open Scrt1.o: No such file or directory
#     ld.lld: error: unable to find library -lc
#
# This is deliberately a WARNING and not a probe failure: 'contains a C library' and
# 'contains development files' are different claims, and a runtime-only rootfs is a
# legitimate thing to hold (verification and bundling both work against one — only
# compiling does not). So the probe's contract is left alone and this reports instead.
#
# Prints the findings and returns 0 when something is missing; returns 1 when the tree
# is fit to link against, having printed nothing.
# ── is this tree INTACT? ─────────────────────────────────────────────────────
#
# Asked before "can it link", because an interrupted fetch presents as a capability problem and
# sends you to fix the wrong machine. A half-copied tree reported "missing development files —
# the fix is on the TARGET", when the target was fine and the copy had simply stopped partway.
#
# Two signals, both cheap:
#   * no .crossbuild-sysroot-ready — get-sysroot.sh writes that marker last, after normalising
#     and validating, so its absence means the fetch did not reach the end. Skipped for a
#     symlinked sysroot, where there is deliberately no marker to write.
#   * a dangling symlink at the top level — usually a merged-/usr link whose destination was
#     never copied. lld reports that as "cannot find /lib64/ld-linux-x86-64.so.2 inside
#     <sysroot>", quoting a linker script, which names neither the link nor the fetch.
#
# Prints and returns 0 when something is wrong; returns 1 when the tree looks intact.
sysroot_integrity_report() {
  local s=$1 problems=() l
  [[ -L "${s:-/}" ]] || [[ -e "${s:-/}/.crossbuild-sysroot-ready" ]] \
    || problems+=("no completion marker (.crossbuild-sysroot-ready): the last fetch did not finish")

  for l in "$s"/*; do
    [[ -L $l ]] || continue
    [[ -e $l ]] && continue
    problems+=("$(basename "$l") -> $(readlink "$l") is a dangling symlink: its destination was never copied")
  done

  [[ ${#problems[@]} -gt 0 ]] || return 1

  cat <<EOF
WARNING: '$(sysroot_display)' is not a complete sysroot.

$(printf '    * %s\n' "${problems[@]}")
  Fix this before believing anything else about the tree — an interrupted copy looks exactly
  like a target that is missing packages, and only one of those is true here.

         make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>

  If the fetch keeps stopping, the provider's own error is the thing to read; run it again and
  look at the last path it was copying.
EOF
  return 0
}

linkability_report() {
  local s=$1 t=$2 libdir ver gccdir missing=() headline
  libdir=$(find_libdir "$s" "$t") || return 1   # no libc at all: probe's job, not ours

  # A Mach-O sysroot is an SDK, and an SDK is development files BY DEFINITION — the
  # runtime-rootfs failure this function exists to catch cannot happen there. Nor do any
  # of the ELF markers below exist on one: there are no crt*.o startup objects (the
  # toolchain supplies those), no libc.so linker name (a .tbd stub stands in for it), and
  # no usr/lib/gcc tree. Running the ELF checks against an SDK reported four things
  # missing and concluded "looks like a RUNTIME rootfs, not a development sysroot" about
  # the only sysroot a Mac has — advice that would send someone installing libc6-dev on
  # macOS. So the criteria change with the format, and stay honest about what they check.
  if [[ $BINFMT == macho ]]; then
    [[ -e "$s/usr/include/stdio.h" ]] \
      || missing+=("C headers (usr/include/stdio.h) — every #include fails")
    if [[ $STDLIB == libc++ ]]; then
      # libc++'s headers are UNVERSIONED: usr/include/c++/v1, where 'v1' is the ABI
      # version and not a compiler version. find_gccver globs for a numeric directory
      # and correctly finds nothing here, which is why this is checked separately.
      [[ -e "$s/usr/include/c++/v1/cstdio" ]] \
        || missing+=("libc++ headers (usr/include/c++/v1) — no C++ can be compiled")
    fi
    [[ ${#missing[@]} -gt 0 ]] || return 1
    cat <<EOF
WARNING: '$(sysroot_display)' is missing development files.

  Missing:
$(printf '    * %s\n' "${missing[@]}")

  On macOS these come from the Command Line Tools, so the fix is on the BUILD HOST:

         xcode-select --install
         make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>
EOF
    return 0
  fi

  # NOTE for anyone extending this: use [[ -e ]] for an exact path and reserve
  # `compgen -G` for patterns that actually contain a wildcard. Given a pattern with no
  # metacharacters, compgen echoes it back and exits 0 whether or not the file exists —
  # so `compgen -G .../Scrt1.o` reports every sysroot as complete. (The pre-existing
  # uses in find_libdir are all globs, which is why they behave.)

  # Startup objects. Scrt1.o is the PIE form and crt1.o the non-PIE one; either proves
  # the -dev package is installed. Without them no executable can be linked at all.
  [[ -e "$libdir/Scrt1.o" || -e "$libdir/crt1.o" ]] \
    || missing+=("C startup objects (Scrt1.o / crt1.o) — nothing can be linked")

  # The LINKER name, not the soname: -lc resolves libc.so (a symlink or linker script),
  # never libc.so.6. This is the single most common difference between a rootfs and a
  # sysroot, and the one whose error message ('unable to find library -lc') is least
  # suggestive of the real cause.
  [[ -e "$libdir/libc.so" || -e "$libdir/libc.a" ]] \
    || missing+=("libc.so linker name (only the runtime soname is present) — -lc fails")

  # libstdc++.so lives in usr/lib/gcc/<triple>/<ver>/ on Debian and in the library dir
  # elsewhere, so accept it anywhere under the tree rather than asserting one layout.
  if [[ $STDLIB != libc++ ]]; then
    [[ -e "$libdir/libstdc++.so" || -e "$s/usr/lib/libstdc++.so" ]] \
      || compgen -G "$s/usr/lib/gcc/*/*/libstdc++.so" >/dev/null 2>&1 \
      || compgen -G "$s/usr/lib/gcc-cross/*/*/libstdc++.so" >/dev/null 2>&1 \
      || missing+=("libstdc++.so linker name — -lstdc++ fails")
  fi

  # crtbegin/crtend come from the compiler's support directory, which is what the -B
  # flag in a compile line points at. Absent, clang falls back to the HOST's copy and
  # the architectures disagree.
  ver=$(find_gccver "$s" "" 2>/dev/null) || ver=""
  { [[ -n $ver ]] && find_gccsupport "$s" "$ver" >/dev/null; } \
    || missing+=("crtbegin*.o (the -B path; clang otherwise falls back to the HOST's, wrong architecture). Looked under usr/lib/gcc/*/<ver>, usr/lib/gcc-cross/*/<ver> and usr/lib/*/<ver>")

  [[ -e "$s/usr/include/stdio.h" ]] \
    || missing+=("C headers (usr/include/stdio.h) — every #include fails")

  ver=$(find_gccver "$s" "" 2>/dev/null) \
    || missing+=("C++ headers (usr/include/c++/<ver>) — no C++ can be compiled")

  [[ ${#missing[@]} -gt 0 ]] || return 1

  # Wording tracks severity: everything absent means somebody copied a running system,
  # which is a different mistake from a sysroot that is merely short a package.
  if [[ ${#missing[@]} -ge 4 ]]; then
    headline="looks like a RUNTIME rootfs, not a development sysroot — it can RUN programs but not LINK them"
  else
    headline="is missing development files"
  fi

  cat <<EOF
WARNING: '$(sysroot_display)' $headline.

  Missing:
$(printf '    * %s\n' "${missing[@]}")

  Everything above ships in the target's development packages, so the fix is on the
  TARGET, not here:

         apt install libc6-dev libstdc++-<ver>-dev      # or the distro equivalent
         make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>

  Verifying and bundling still work against this tree. Only compiling does not.
EOF
  return 0
}

case $MODE in

probe)
  # The one authoritative usability test. Deliberately checks for a SHARED libc or
  # a musl loader — not a static libc.a — because a device rootfs is the best
  # sysroot you can have and it has no static libs.
  if ! sysroot_exists; then
    cat >&2 <<EOF
ERROR: sysroot directory does not exist:
         $(sysroot_display)

  Materialise it first:
         make sysroot TARGET=<name>

  (Which provider that uses is set by SYSROOT_PROVIDER in the target
   description; see docs/04-sysroot-providers.md.)
EOF
    exit 1
  fi
  if ! find_libdir "$SYSROOT" "$TRIPLE" >/dev/null; then
    cat >&2 <<EOF
ERROR: '$(sysroot_display)' exists but contains no C library, so it cannot be a sysroot.

  Looked for $(libc_names_wanted) in:
$(libdir_candidates "$SYSROOT" "$TRIPLE" | sed 's/^/         /')

  (Those are the $BINFMT filenames, chosen from TARGET_TRIPLE=$TRIPLE.)

  Most likely causes:
    * the fetch was interrupted, leaving a partial tree  -> make sysroot-clean TARGET=... && make sysroot TARGET=...
    * the provider copied the wrong directory (a subdir, not the rootfs root)
    * TARGET_TRIPLE does not match this tree's actual layout
EOF
    exit 1
  fi
  if missing=$(cxx_tree_missing "$SYSROOT" "$TRIPLE"); then
    cat >&2 <<EOF
ERROR: '$(sysroot_display)' has an INCOMPLETE C++ header tree.

  Missing: $missing

  The C library and the rest of the C++ headers are present, so this is a partial
  copy, not the wrong directory. Caught here on purpose: left to the compiler, the
  same problem appears as a fatal error inside libstdc++ itself —

    usr/include/c++/<ver>/bits/stl_iterator_base_funcs.h:
        fatal error: 'debug/assertions.h' file not found

  — which reads as a broken toolchain and sends you to look at clang.

  Most likely causes:
    * the provider pruned it: an rsync/tar exclude pattern with no leading '/'
      matches that directory name at EVERY depth, header trees included
    * the fetch was interrupted partway through /usr/include
    * the target genuinely has no C++ development files (install libstdc++-dev there,
      then re-fetch)

  Re-fetch after fixing the cause:
         make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>
EOF
    exit 1
  fi
  exit 0
  ;;

libdir)
  find_libdir "$SYSROOT" "$TRIPLE" || exit 1
  ;;

gccver)
  find_gccver "$SYSROOT" "$GCC_PIN" || exit 1
  ;;

cxxflags)
  # Silent no-op when the sysroot is absent: Make expands this during `help` and
  # `list-targets`, where noise would be actively misleading.
  sysroot_exists || exit 0

  out=()
  if [[ $STDLIB == libstdc++ ]]; then
    if ver=$(find_gccver "$SYSROOT" "$GCC_PIN"); then
      # Both include dirs are needed: the arch-independent headers, and the
      # arch-specific ones holding bits/c++config.h. Omitting the second gives
      # "bits/c++config.h: No such file", which reads like a broken sysroot
      # rather than a missing -isystem.
      out+=("-isystem" "$SYSROOT/usr/include/c++/$ver")
      # Every path here is guarded by [[ -d ]], so a triple spelling that names no
      # directory contributes nothing. That is what made the vendor mismatch so quiet:
      # nothing failed, the flags were simply absent, and the error arrived later as a
      # missing bits/c++config.h or a crtbegin from the host's wrong architecture.
      # Discovered, not spelled from the triple: see find_cxx_archinc.
      if archinc=$(find_cxx_archinc "$SYSROOT" "$ver"); then
        out+=("-isystem" "$archinc")
      fi
      # -B points clang at the sysroot's compiler support files (crtbegin.o etc.) rather
      # than the host's, which would be the wrong architecture. Discovered rather than
      # built from the triple: an OpenEmbedded SDK puts these under
      # usr/lib/<vendor-triple>/<ver> with a triple the description never mentions.
      if gccsup=$(find_gccsupport "$SYSROOT" "$ver"); then out+=("-B$gccsup"); fi
    fi
  fi
  printf '%s ' "${out[@]+"${out[@]}"}"
  ;;

ldflags)
  sysroot_exists || exit 0
  out=()
  if libdir=$(find_libdir "$SYSROOT" "$TRIPLE"); then
    out+=("-L$libdir")
    # -rpath-link is a BUILD-TIME search path only; it tells the linker where to
    # find transitive dependencies to validate the link. It is NOT written into
    # the binary, so it cannot leak a host path onto the target. (Contrast with
    # -rpath, which is written in — that one comes from TARGET_RPATH.)
    #
    # It is also GNU-ld only, and Mach-O needs no equivalent: a dylib records the
    # install name of everything it links, so the linker follows those rather than
    # searching a supplied path. Passing it anyway is fatal, not ignored:
    #     ld64.lld: error: unknown argument '-rpath-link'
    if [[ $BINFMT != macho ]]; then
      out+=("-Wl,-rpath-link,$libdir")
    fi
  fi
  if [[ $STDLIB == libstdc++ ]]; then
    if ver=$(find_gccver "$SYSROOT" "$GCC_PIN"); then
      # Same discovery as the -B above: libstdc++.so lives beside crtbegin.o in both
      # layouts, and neither is reachable by spelling the description's triple.
      if gccsup=$(find_gccsupport "$SYSROOT" "$ver"); then out+=("-L$gccsup"); fi
    fi
  fi
  printf '%s ' "${out[@]+"${out[@]}"}"
  ;;

report)
  echo "sysroot : $(sysroot_display)"
  echo "triple  : $TRIPLE"
  if ! sysroot_exists; then echo "status  : ABSENT"; exit 0; fi
  echo "format  : $BINFMT"
  if libdir=$(find_libdir "$SYSROOT" "$TRIPLE"); then
    echo "libdir  : $libdir"
    if [[ $BINFMT == macho ]]; then
      echo "libc    : $(cd "$libdir" && ls -1 libSystem.tbd libSystem.B.tbd libc.tbd libSystem.dylib 2>/dev/null | tr '\n' ' ')"
    else
      echo "libc    : $(cd "$libdir" && ls -1 libc.so* libc-*.so ld-musl-*.so* 2>/dev/null | tr '\n' ' ')"
    fi
  else
    echo "libdir  : NOT FOUND (no $(libc_names_wanted) under any candidate path)"
  fi
  if ver=$(find_gccver "$SYSROOT" "$GCC_PIN" 2>/dev/null); then
    echo "c++ hdrs: version $ver"
  else
    echo "c++ hdrs: none under usr/include/c++ (fine if TARGET_STDLIB=libc++ or C-only)"
  fi
  # Report the interpreter actually present, so a TARGET_DYNAMIC_LINKER mismatch
  # can be spotted before it becomes a runtime failure on the device.
  echo -n "interp  : "
  if [[ $BINFMT == macho ]]; then
    # Mach-O has no PT_INTERP and no interpreter path to get wrong: dyld is named by the
    # kernel, not by the binary. Saying so beats printing "none found", which reads as a
    # missing file on a platform that has no such file to miss.
    echo "n/a (Mach-O names no interpreter; dyld is chosen by the kernel)"
  else
  found=""
  for p in "$SYSROOT"/lib/ld-linux*.so* "$SYSROOT"/lib64/ld-linux*.so* \
           "$SYSROOT"/lib/ld-musl-*.so* "$SYSROOT/lib/$TRIPLE"/ld-linux*.so* \
           ${TRIPLE_ALT:+"$SYSROOT/lib/$TRIPLE_ALT"/ld-linux*.so*}; do
    [[ -e $p ]] && found+="${p#"$SYSROOT"} "
  done
  echo "${found:-none found}"
  fi
  # Last, and only when there is something to say, so a healthy sysroot's report stays
  # the short summary it is meant to be.
  #
  # '|| true' and not '&& true': the function returns 1 for a HEALTHY tree, and a recipe's
  # exit status is its last command's, so the wrong one of these made `make sysroot-info`
  # print a clean report and then report Error 1.
  # Integrity first: a partial tree explains the capability findings that follow.
  sysroot_integrity_report "$SYSROOT" || true
  linkability_report "$SYSROOT" "$TRIPLE" || true
  ;;

linkability)
  # Always exits 0. This is advice, not a verdict — callers wire it in beside the probe
  # without having to decide whether a warning should stop a build.
  sysroot_exists || exit 0
  # Integrity first: a partial tree explains the capability findings that follow.
  sysroot_integrity_report "$SYSROOT" || true
  linkability_report "$SYSROOT" "$TRIPLE" || true
  exit 0
  ;;

haslib)
  # Can '-l<name>' actually be satisfied by this sysroot? Answered here, rather than in
  # mk/rules.mk, because it is a question about a sysroot's LAYOUT and that knowledge lives in
  # exactly one file.
  #
  # WHY IT MATTERS: a component declares COMPONENT_LIBS=ibverbs, the target lacks
  # libibverbs-dev, and the build fails with seven copies of
  #     fatal error: 'infiniband/verbs.h' file not found
  # pointing inside a vendor header — naming neither the library, nor the sysroot, nor the
  # target. This turns that into one sentence, before anything compiles.
  #
  # Exit 0 = linkable. Exit 1 = definitely not, with the reason on stdout. Exit 0 is also the
  # answer when we cannot tell (no sysroot, no library directory): a check that blocks builds
  # it does not understand is worse than the error it replaces.
  LIBNAME=${4:-}
  [[ -n $LIBNAME ]] || { echo "sysroot-inspect: haslib needs a library name" >&2; exit 2; }
  sysroot_exists || exit 0
  libdir=$(find_libdir "$SYSROOT" "$TRIPLE") || exit 0

  # Where a linker would look. The gcc support directory matters: on Debian, libstdc++.so
  # lives there and nowhere else.
  searched=("$libdir" "$SYSROOT/usr/lib" "$SYSROOT/lib")
  if ver=$(find_gccver "$SYSROOT" "$GCC_PIN" 2>/dev/null); then
    while read -r tv; do
      searched+=("$SYSROOT/usr/lib/gcc/$tv/$ver" "$SYSROOT/usr/lib/gcc-cross/$tv/$ver")
    done < <(triple_variants)
  fi

  # '.so' OR '.a' — both are linkable, and which one exists is not the component's business.
  # This is also why glibc's absorbed libraries pass: since glibc 2.34 libpthread.so, libdl.so
  # and librt.so are gone (their code moved into libc), but the '.a' stubs remain, so
  # '-lpthread' still resolves and this check still says yes.
  runtime_only=""
  for d in "${searched[@]}"; do
    [[ -d $d ]] || continue
    if [[ -e "$d/lib$LIBNAME.so" || -e "$d/lib$LIBNAME.a" ]]; then
      exit 0
    fi
    # The same question, spelled for Mach-O. '-lfoo' there resolves libfoo.dylib or, in an
    # SDK, the libfoo.tbd stub that stands in for it. Without these a component declaring
    # COMPONENT_LIBS=z was refused on macOS with "the sysroot cannot link it", pointing at
    # an apt-get command, while libz.tbd sat in the SDK and the link would have succeeded.
    if [[ $BINFMT == macho ]] \
       && { [[ -e "$d/lib$LIBNAME.dylib" || -e "$d/lib$LIBNAME.tbd" ]]; }; then
      exit 0
    fi
    # Remember a runtime-only hit so the message can distinguish "you have no such library"
    # from "you have it but not its development package" — different fixes.
    if compgen -G "$d/lib$LIBNAME.so.*" >/dev/null 2>&1; then
      runtime_only=$d
    fi
  done

  if [[ -n $runtime_only ]]; then
    cat <<EOF
'$LIBNAME' is present in the sysroot only as a runtime library:
         $(cd "$runtime_only" && ls -1 "lib$LIBNAME.so."* 2>/dev/null | tr '\n' ' ')
  but '-l$LIBNAME' resolves lib$LIBNAME.so (or lib$LIBNAME.a), which is absent. That linker
  name ships in the development package.

  On the target:  apt install lib${LIBNAME}-dev      (or the distro equivalent)
  Then:           make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>
EOF
  else
    cat <<EOF
'$LIBNAME' was not found in the sysroot at all. Looked in:
$(printf '         %s\n' "${searched[@]}")

  Install the package providing lib$LIBNAME on the target (usually lib${LIBNAME}-dev), then
  re-fetch:  make sysroot-clean TARGET=<name> && make sysroot TARGET=<name>
EOF
  fi
  exit 1
  ;;

*)
  echo "sysroot-inspect: unknown mode '$MODE'" >&2
  exit 2
  ;;
esac
