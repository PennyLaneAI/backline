#!/usr/bin/env bash
#
# doctor.sh — check whether this build host can cross-compile, and say precisely
# what to install if not.
#
# WHY
# Cross-compilation fails in ways that do not name the missing piece. A missing
# `lld` reports "unable to execute command"; a missing cmake reports nothing until
# a component that needs it is reached, an hour into a build. Front-loading the
# check turns a confusing mid-build failure into a checklist.
#
# Reports three tiers, and the distinction matters: a REQUIRED tool blocks
# everything, a RECOMMENDED one blocks some component kinds, and an OPTIONAL one
# only affects specific providers you may never use.
#
# USAGE
#   doctor.sh [root-dir]

set -uo pipefail

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

RED=""; GRN=""; YLW=""; RST=""
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
fi

missing_required=0
missing_recommended=0

check() {
  local tier=$1 tool=$2 why=$3 install=$4
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  %sok%s    %-14s %s\n' "$GRN" "$RST" "$tool" "$(command -v "$tool")"
    return 0
  fi
  case $tier in
    required)
      printf '  %sMISS%s  %-14s %s\n' "$RED" "$RST" "$tool" "$why"
      printf '        %sinstall: %s%s\n' "$YLW" "$install" "$RST"
      missing_required=$((missing_required+1)) ;;
    recommended)
      printf '  %swarn%s  %-14s %s\n' "$YLW" "$RST" "$tool" "$why"
      printf '        %sinstall: %s%s\n' "$YLW" "$install" "$RST"
      missing_recommended=$((missing_recommended+1)) ;;
    optional)
      printf '  %s--%s    %-14s %s\n' "$YLW" "$RST" "$tool" "$why" ;;
  esac
  return 1
}

echo
echo "═══ crossbuild doctor ═══"
echo
HOST_TRIPLE=$("$ROOT/tools/detect-host.sh" triple 2>/dev/null || echo unknown)
# The format this host's own compiler produces. It decides which reader verification needs
# here, and it is the difference between "you are missing a required tool" and "you are on
# a Mac", which the verdict used to confuse.
HOST_BINFMT=$("$ROOT/tools/arch-table.sh" binfmt "$HOST_TRIPLE" 2>/dev/null || echo elf)

echo "build host"
printf '  %-16s %s\n' "os"     "$(uname -srm)"
printf '  %-16s %s\n' "triple" "$HOST_TRIPLE"
printf '  %-16s %s\n' "format" "$HOST_BINFMT"
printf '  %-16s %s\n' "libc"   "$("$ROOT/tools/detect-host.sh" libc-version 2>/dev/null || echo unknown)"
printf '  %-16s %s\n' "cores"  "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
# The shell and make versions are reported because both have caused silent misbehaviour and
# neither is visible in any error they produce. Nothing here requires a newer bash — the
# scripts are written for 3.2, which is what macOS ships as /bin/bash — but when a
# description does come back truncated, this line is the first thing worth reading.
printf '  %-16s %s\n' "bash"   "${BASH_VERSION:-unknown} ($(command -v bash 2>/dev/null || echo '?'))"
printf '  %-16s %s\n' "make"   "$(make --version 2>/dev/null | head -1 || echo unknown)"
echo

echo "required — nothing builds without these"
check required make "GNU Make drives the build" "apt install build-essential | dnf install make"
echo

echo "toolchain — one clang that can emit every target you care about"
if check required clang "the cross compiler" "apt install clang lld | dnf install clang lld"; then
  llvmroot=$("$ROOT/tools/detect-host.sh" llvm-root 2>/dev/null || echo "")
  printf '        root: %s\n' "${llvmroot:-<could not determine>}"
  printf '        %s\n' "$(clang --version 2>/dev/null | head -1)"
  # A clang that was built without the target's backend produces "error: unable to
  # create target". Listing the registered targets up front is far kinder than
  # discovering it during a build.
  if targets=$(llc --version 2>/dev/null | sed -n '/Registered Targets:/,$p' | tail -n +2 | awk '{print $1}' | tr '\n' ' '); then
    [[ -n $targets ]] && printf '        can emit: %s\n' "$targets"
  else
    printf '        (install llvm to list which architectures this clang can emit)\n'
  fi
fi
check required clang++ "the C++ cross compiler" "apt install clang | dnf install clang"
# NOTE: ld.lld is NOT checked here any more. It was graded `recommended`, so a Mac with no
# lld was told "VERDICT: usable" while being unable to link a single one of the board's
# artifacts — every ELF target here resolves TARGET_LINKER to lld, and the failure is a
# compiler-driver message naming no package (`invalid linker name in argument
# '-fuse-ld=lld'`). Whether it is required depends on the targets described, exactly as with
# readelf, so the question is asked once, below, against what those targets actually need.
# NOTE: the reader for ABI verification is NOT checked here any more. This probed the bare
# name on PATH and warned whenever it was absent, which contradicted the real answer: on a
# Mach-O host no readelf is needed at all, and Homebrew's is installed but keg-only. Two
# lines disagreeing about the same tool is worse than either alone, so the question is
# asked once, against the formats the described targets actually use, under
# "artifact verification" below.
check recommended llvm-strip "strips artifacts for BUNDLE_STRIP=yes" "apt install llvm"
echo

echo "for cmake-driven components"
check recommended cmake "COMPONENT_KIND=cmake-project needs it" "apt install cmake | pip install cmake"
check recommended ninja "much faster than make for large cmake projects" "apt install ninja-build | pip install ninja"
echo

echo "for sysroot providers — you only need the ones you use"
# The `deb` provider was missing from this list entirely, and it is the one the shipped board
# target uses — so `make doctor` could pass on a host where the very next documented command,
# `make sysroot TARGET=<that target>`, dies on a tool nobody asked about.
check optional curl     "provider deb — downloads the packages"              "apt install curl"
check optional ar       "provider deb — a .deb is an ar archive"             "apt install binutils"
check optional tar      "provider deb — unpacks data.tar.*"                  "apt install tar"
check optional zstd     "provider deb — modern .deb payloads are zstd"       "apt install zstd"
check optional rsync    "provider ssh-rsync (recommended) and dir mode=copy" "apt install rsync"
check optional ssh      "provider ssh-rsync, and 'make probe'"               "apt install openssh-client"
check optional skopeo   "provider oci, daemonless and rootless"              "apt install skopeo"
check optional podman   "provider oci, fallback"                             "apt install podman"
# PRESENCE IS NOT USABILITY, and for docker the gap is wider than for anything else here: the
# CLI installs on its own, and without a daemon every command it forwards fails with a socket
# error that names neither docker nor the provider that chose it. Reporting `ok` on the binary
# alone is the same fail-open this file already refuses to commit for readelf.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    printf '  %sok%s    %-14s %s\n' "$GRN" "$RST" "docker" "$(command -v docker)"
  else
    printf '  %s--%s    %-14s %s\n' "$YLW" "$RST" "docker" "$(command -v docker)"
    printf '                       installed, but no daemon is responding — `docker info` fails.\n'
    printf '                       provider oci and `make pseudo-remote` will not work until it is.\n'
  fi
else
  check optional docker "provider oci, fallback (needs a daemon)"            "apt install docker.io"
fi
check optional debootstrap "provider debootstrap (needs root; Debian targets only)" "apt install debootstrap"
check optional python3  "sysroot symlink normalisation — important for correctness" "apt install python3"
echo

# ── verification readers, per format actually needed ─────────────────────────
#
# ABI verification is the most valuable single feature here, so what it needs is checked
# explicitly rather than assumed. What it needs depends on the FORMAT of the artifacts, and
# a host may legitimately need one reader, the other, or both:
#
#   ELF targets   -> readelf (any spelling, including a triple-prefixed cross-binutils)
#   Mach-O targets-> otool, which ships with the Xcode Command Line Tools
#
# This used to demand readelf unconditionally, so a Mac that could build and verify its own
# artifacts perfectly well was told "1 required tool missing — cross-building will not work
# yet" and `make doctor` exited non-zero. Reporting a real gap as a blocker is right;
# reporting a non-gap as one trains people to ignore the tool.
echo "what the described targets actually need — their linker, and their verification reader"

have_readelf=""
for r in llvm-readelf readelf eu-readelf "${HOST_TRIPLE}-readelf"; do
  command -v "$r" >/dev/null 2>&1 && { have_readelf=$r; break; }
done
# INSTALLED SOMEWHERE IS NOT THE SAME AS USABLE, and this check must not confuse them.
# Homebrew's llvm is keg-only, so llvm-readelf exists and is not on PATH. Reporting that as
# `ok` — which this did — made `make doctor` print "this host is ready" and `make verify`
# then die with "no readelf found" in the same shell. Every consumer in the tree resolves
# tools through PATH, so a tool off PATH is a tool the build cannot use.
#
# It is still worth FINDING, because "install it" is the wrong advice when it is already
# installed. So it is reported separately, as the missing thing it is, with the one command
# that fixes it.
readelf_offpath=""
if [[ -z $have_readelf ]] && command -v brew >/dev/null 2>&1; then
  _bp=$(brew --prefix llvm 2>/dev/null || echo "")
  [[ -n $_bp && -x "$_bp/bin/llvm-readelf" ]] && readelf_offpath="$_bp/bin/llvm-readelf"
fi

# Which formats do the described targets actually span? A blank triple means native.
#
# TARGET= narrows this to one target, and that is not a convenience — it is the difference
# between a true and a false verdict. Scanning every described target means a Mac with only
# the Xcode Command Line Tools is told it is missing a required tool, because SOME described
# target is an ELF one and needs readelf. That is correct for that target and wrong for the smoke
# test, which builds Mach-O for this host, needs no readelf, and is introduced as "nothing to
# install" — so the first command of it failed on exactly the machine state it promises to
# work from. `make doctor TARGET=example-native` now grades the host for THAT job.
scan_confs=()
if [[ -n ${TARGET:-} && -e "$ROOT/targets/$TARGET.conf" ]]; then
  scan_confs=("$ROOT/targets/$TARGET.conf")
  printf '  (scoped to TARGET=%s; run `make doctor` with no TARGET= to grade every target)\n' "$TARGET"
else
  scan_confs=("$ROOT"/targets/*.conf)
fi

needs_elf=0; needs_macho=0; needs_lld=0; lld_targets=""
for conf in "${scan_confs[@]}"; do
  [[ -e $conf ]] || continue
  case $conf in *TEMPLATE*) continue ;; esac
  # Read the triple and the linker from the same eval, so the two answers cannot disagree.
  _pair=$(
    TARGET_TRIPLE=""; TARGET_LINKER=""
    eval "$("$ROOT/tools/conf2mk.sh" --shell "$conf" 2>/dev/null)" 2>/dev/null
    printf '%s\n%s' "${TARGET_TRIPLE:-$HOST_TRIPLE}" "$TARGET_LINKER"
  )
  _t=${_pair%%$'\n'*}
  _linker=${_pair#*$'\n'}
  _fmt=$("$ROOT/tools/arch-table.sh" binfmt "$_t" 2>/dev/null)

  # Mirror mk/derive.mk: an empty TARGET_LINKER resolves to lld for an ELF target under an
  # llvm toolchain, and to the compiler's own default for Mach-O. Deriving it the same way
  # here is the point — a target that never mentions lld can still require it, and grading
  # only the explicit ones would reproduce the fail-open this replaced.
  if [[ $_linker == lld ]] || { [[ -z $_linker && $_fmt != macho ]]; }; then
    needs_lld=1
    lld_targets="$lld_targets $(basename "${conf%.conf}")"
  fi

  case $_fmt in
    macho) needs_macho=1 ;;
    *)     needs_elf=1 ;;
  esac
done

# ── the linker, graded against the targets that actually need it ─────────────
if [[ $needs_lld -eq 1 ]]; then
  if command -v ld.lld >/dev/null 2>&1; then
    printf '  %sok%s    %-14s %s\n' "$GRN" "$RST" "ld.lld" "$(command -v ld.lld)"
  else
    printf '  %sMISS%s  %-14s these targets link with it:%s\n' "$RED" "$RST" "ld.lld" "$lld_targets"
    printf '        Without it the build dies at the LINK step, and the message names no\n'
    printf '        package: clang++: error: invalid linker name in argument -fuse-ld=lld\n'
    printf '        %sinstall: brew install lld | apt install lld | dnf install lld%s\n' "$YLW" "$RST"
    printf '        (Homebrew ships lld as its OWN formula — `brew install llvm` gives you\n'
    printf '         lldb, the debugger, and no linker. Unlike llvm, lld is not keg-only.)\n'
    missing_required=$((missing_required+1))
  fi
fi

if [[ $needs_elf -eq 1 ]]; then
  if [[ -n $have_readelf ]]; then
    printf '  %sok%s    %-14s %s\n' "$GRN" "$RST" "readelf" "$have_readelf"
  elif [[ -n $readelf_offpath ]]; then
    # Installed, and unreachable. Naming the exact command is the whole value here: the
    # answer is not "install it".
    printf '  %sMISS%s  %-14s found at %s\n' "$RED" "$RST" "readelf" "$readelf_offpath"
    printf '        but NOT on PATH, so nothing in this tree can use it — `make verify`\n'
    printf '        will report "no readelf found" even though it is on this machine.\n'
    printf '        %sfix: export PATH="$(brew --prefix llvm)/bin:$PATH"%s\n' "$YLW" "$RST"
    missing_required=$((missing_required+1))
  else
    printf '  %sMISS%s  %-14s ELF targets are described, and none of their artifacts can be verified.\n' "$RED" "$RST" "readelf"
    printf '        This is the check that stops you shipping a binary the target cannot load.\n'
    printf '        %sinstall: apt install binutils | dnf install binutils | brew install llvm%s\n' "$YLW" "$RST"
    printf '        (Homebrew keg-only: export PATH="$(brew --prefix llvm)/bin:$PATH")\n'
    missing_required=$((missing_required+1))
  fi
fi
if [[ $needs_macho -eq 1 ]]; then
  if command -v otool >/dev/null 2>&1; then
    printf '  %sok%s    %-14s %s\n' "$GRN" "$RST" "otool" "$(command -v otool)"
  else
    printf '  %sMISS%s  %-14s Mach-O targets are described and cannot be verified.\n' "$RED" "$RST" "otool"
    printf '        %sinstall: xcode-select --install%s\n' "$YLW" "$RST"
    missing_required=$((missing_required+1))
  fi
fi
echo

# ── target readiness ─────────────────────────────────────────────────────────
echo "described targets"
for conf in "$ROOT"/targets/*.conf; do
  [[ -e $conf ]] || continue
  name=$(basename "$conf" .conf)
  # Read through the generated shell view, not with an ad-hoc sed. AGENTS.md names this
  # exact defect shape, and one of these three was a live instance of it: a description
  # written as
  #     TARGET_LIBC_VERSION=      # unknown, ask the board
  # reached the emptiness test below as a non-empty string, so the "the ABI ceiling check
  # is disabled" warning was suppressed for the very target whose ceiling was unset. The
  # generated view strips trailing comments and quotes, so the value read is the value used.
  triple="" ; prov="" ; libcver=""
  eval "$(
    TARGET_TRIPLE=""; SYSROOT_PROVIDER=""; TARGET_LIBC_VERSION=""
    eval "$("$ROOT/tools/conf2mk.sh" --shell "$conf" 2>/dev/null)" 2>/dev/null
    printf 'triple=%s\nprov=%s\nlibcver=%s\n' \
      "'${TARGET_TRIPLE//\'/\'\\\'\'}'" "'${SYSROOT_PROVIDER//\'/\'\\\'\'}'" "'${TARGET_LIBC_VERSION//\'/\'\\\'\'}'"
  )"
  sr="$ROOT/build/sysroots/$name"
  if [[ -e $sr ]]; then srstate="${GRN}sysroot ready${RST}"; else srstate="no sysroot"; fi
  printf '  %-26s %-22s %-13s %s\n' "$name" "${triple:-<blank: native>}" "${prov:-none}" "$srstate"
  if [[ -z $libcver ]]; then
    printf '  %-26s %sno TARGET_LIBC_VERSION — the ABI ceiling check is disabled%s\n' "" "$YLW" "$RST"
  fi
done
echo

# ── verdict ──────────────────────────────────────────────────────────────────
if [[ $missing_required -gt 0 ]]; then
  # Name the STEP that is blocked, not a bare count in red. The three tiers of "required"
  # block different things, and a first-timer who reads "N required tool(s) missing" assumes
  # the whole build is dead when often only the last step is:
  #   make / clang / clang++ missing  -> nothing builds at all
  #   lld missing                     -> compiles, but ELF targets fail at the LINK step
  #   readelf missing                 -> builds and links; `make verify`/`make bundle` blocked
  _compile_blocked=0
  for _t in make clang clang++; do command -v "$_t" >/dev/null 2>&1 || _compile_blocked=1; done
  if [[ $_compile_blocked -eq 1 ]]; then
    printf '%sVERDICT: cannot build — a compile-critical tool is missing (see MISS above).%s\n' "$RED" "$RST"
    exit 1
  elif [[ $needs_lld -eq 1 ]] && ! command -v ld.lld >/dev/null 2>&1; then
    printf '%sVERDICT: can compile, but ELF targets fail at the LINK step until lld is installed.%s\n' "$RED" "$RST"
    printf '         Everything up to linking works; see the ld.lld line above.\n'
    exit 1
  elif [[ $needs_elf -eq 1 && -z $have_readelf ]]; then
    # Exit 0, deliberately. The host can build and link; only ship-time verification needs a
    # tool that is one `export`/install away. Exiting non-zero here contradicted this very
    # verdict ("nothing else is blocked") and aborted `&&` chains — including the onboarding
    # one-liner — before a native build that needs no readelf at all. A usable host with a
    # recoverable caveat is exit 0, the same tier as a missing *recommended* tool.
    printf '%sVERDICT: can build and link. Only `make verify` and `make bundle` are blocked,%s\n' "$YLW" "$RST"
    printf '         for the ELF targets above, until readelf is on PATH — nothing else is.\n'
    printf '         (This is exit 0: the host is usable; add readelf before you verify/ship.)\n'
    exit 0
  else
    printf '%sVERDICT: %d required tool(s) missing (see above).%s\n' "$RED" "$missing_required" "$RST"
    exit 1
  fi
fi
if [[ $missing_recommended -gt 0 ]]; then
  printf '%sVERDICT: usable, but %d recommended tool(s) are missing (see above).%s\n' \
         "$YLW" "$missing_recommended" "$RST"
  exit 0
fi
printf '%sVERDICT: this host is ready to cross-compile.%s\n' "$GRN" "$RST"
echo
echo "Next:  make quickstart"
