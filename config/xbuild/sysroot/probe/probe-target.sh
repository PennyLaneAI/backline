#!/bin/sh
#
# probe-target.sh — run this ON a target machine; it prints a ready-to-use target
# description to stdout.
#
# WHAT IT IS FOR
# Writing a target description by hand means looking up your board's glibc version,
# its C++ ABI level, and its ELF interpreter path. Guessing any of the three
# produces a build that links cleanly and then fails on the device, so this script
# reads them off the machine itself and prints the exact lines to paste.
#
# It is deliberately POSIX sh with no dependencies beyond coreutils. An embedded
# target may have busybox and nothing else — no bash, no python, no gcc — and this
# still has to work there. (The original probe was invoked from a whiptail TUI on
# the build host, which meant the *build host* needed a TUI toolkit installed to
# obtain information about a remote machine. The dependency was in the wrong place.)
#
# USAGE, on the target:
#     sh probe-target.sh                        # print a description to stdout
#     sh probe-target.sh --raw                  # print every fact, for debugging
#
# Or from the build host, without copying anything by hand:
#     make probe TARGET=<name> SSH=user@host
#
# Nothing is written and nothing is installed; it only reads.

NAME_HINT=${TARGET_NAME_HINT:-}
RAW=0
for a in "$@"; do
    case $a in
        --raw)   RAW=1 ;;
        --name=*) NAME_HINT=${a#--name=} ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# ── architecture ─────────────────────────────────────────────────────────────
arch=$(uname -m 2>/dev/null || echo unknown)

# ── libc family and version ──────────────────────────────────────────────────
# Determining this correctly matters more than anything else here, because
# TARGET_LIBC_VERSION is what the build-time ABI check compares against.
#
# Four methods, in decreasing reliability, because embedded systems are missing
# different things:
#   1. getconf   — the standard interface; absent on busybox.
#   2. ldd --version — present with glibc; on musl it prints "musl libc" and exits 1.
#   3. running the loader directly — glibc's libc.so.6 is executable and self-reports.
#   4. reading the highest GLIBC_x.y version tag out of the binary with strings.
libc_family=unknown
libc_version=

if have getconf; then
    v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$v" ]; then libc_family=glibc; libc_version=$v; fi
fi

if [ "$libc_family" = unknown ] && have ldd; then
    lddout=$(ldd --version 2>&1 | head -n1)
    case $lddout in
        *musl*) libc_family=musl ;;
        *GLIBC*|*GNU\ libc*|*glibc*)
            libc_family=glibc
            libc_version=$(printf '%s' "$lddout" | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p') ;;
    esac
fi

# Locate the libc binary; also used below for the interpreter path.
libc_path=
for p in /lib/libc.so.6 /lib64/libc.so.6 \
         /lib/"$arch"-linux-gnu/libc.so.6 /usr/lib/"$arch"-linux-gnu/libc.so.6 \
         /usr/lib/libc.so.6 /usr/lib64/libc.so.6 \
         /lib/ld-musl-"$arch".so.1 /lib/libc.musl-"$arch".so.1; do
    [ -e "$p" ] && { libc_path=$p; break; }
done

# The FILENAME is evidence of the family, and on a minimal system it is the only evidence
# there is. Methods 3 and 4 below are both gated on knowing the family is glibc, but only
# methods 1 and 2 could set it — so on a machine with neither getconf nor ldd, the two
# fallbacks written for exactly that machine were unreachable and the probe reported
#     TARGET_LIBC=unknown
#     TARGET_LIBC_VERSION=
# which disables the ABI ceiling check, the most valuable one in the tree.
#
# Measured on a real Yocto-derived embedded root: no getconf, no ldd, and
# /lib/libc.so.6 present and executable, self-reporting "GNU C Library (GNU libc) stable
# release version 2.39." Method 3 would have answered correctly had it been allowed to run.
#
# libc.so.6 is a glibc-only soname — musl's is ld-musl-<arch>.so.1, matched just above — so
# recognising it here costs nothing and cannot misfire on the musl case.
case $libc_path in
    *musl*)        [ "$libc_family" = unknown ] && libc_family=musl ;;
    */libc.so.6)   [ "$libc_family" = unknown ] && libc_family=glibc ;;
esac

if [ -z "$libc_version" ] && [ -x "$libc_path" ]; then
    libc_version=$("$libc_path" 2>&1 | head -n1 \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
fi

if [ -z "$libc_version" ] && [ -n "$libc_path" ] && have strings; then
    # The highest GLIBC_x.y symbol version present is the libc's own version.
    libc_version=$(strings "$libc_path" 2>/dev/null \
        | grep '^GLIBC_[0-9]' | sed 's/^GLIBC_//' | sort -t. -k1,1n -k2,2n | tail -n1)
fi

# ── C++ ABI ceilings ─────────────────────────────────────────────────────────
# The highest tag in the target's libstdc++, in BOTH of the namespaces it versions:
#   GLIBCXX_3.4.NN   the library's own interface
#   CXXABI_1.3.NN    the Itanium C++ ABI runtime (typeinfo, __cxa_*, guard variables)
# If you link dynamically against libstdc++ and your build host's is newer, the binary
# references a tag the target does not have and dies with
#   "version GLIBCXX_3.4.33 not found"   (or "version CXXABI_1.3.15 not found")
# These values are what let the build catch that at build time instead.
#
# Both are reported because they advance independently: measured on a real device,
# GLIBCXX_3.4.32 alongside CXXABI_1.3.14. Reporting only the first —
# which this script did, while the probe it replaced reported both — leaves the CXXABI
# axis unchecked, and an artifact that exceeds it fails on the device exactly as one that
# exceeds the other does.
libstdcxx_path=
for p in /usr/lib/libstdc++.so.6 /usr/lib64/libstdc++.so.6 \
         /usr/lib/"$arch"-linux-gnu/libstdc++.so.6 /lib/libstdc++.so.6; do
    [ -e "$p" ] && { libstdcxx_path=$p; break; }
done
cxxabi_max=
if [ -n "$libstdcxx_path" ]; then
    # Extract the printable strings from libstdc++.so.6. `strings` is the obvious tool, but a
    # minimal target (busybox, a stripped embedded rootfs) often has no binutils — and this
    # used to leave the ceiling SILENTLY blank, which then silently disabled the libstdc++
    # check in `make verify`. So fall back to a portable stand-in: `tr` turns every run of
    # printable characters into its own line, which is all `strings` does for this purpose,
    # and `tr` is present on busybox. Only if neither works is the value left blank — and then
    # a WARNING is emitted below, rather than the gap passing unremarked.
    if have strings; then
        _dump() { strings "$1" 2>/dev/null; }
    else
        _dump() { LC_ALL=C tr -c '[:print:]' '\n' < "$1" 2>/dev/null; }
    fi
    _glibcxx=$(_dump "$libstdcxx_path" | grep '^GLIBCXX_[0-9]' | sort -V | tail -n1)
    _cxxabi=$(_dump "$libstdcxx_path" | grep '^CXXABI_[0-9]' | sort -V | tail -n1)
    # Space-separated, each tag naming its own namespace, so a reader and the verifier can
    # both tell which ceiling is which without being told the order.
    cxxabi_max=$(printf '%s %s' "$_glibcxx" "$_cxxabi" | sed 's/^ *//; s/ *$//')
fi

# ── ELF interpreter ──────────────────────────────────────────────────────────
# The absolute path of the dynamic loader, as recorded in every dynamic binary on
# this machine. Read it from a real binary rather than guessing from convention:
# Yocto-derived roots put it at /lib, Debian multiarch at /lib/<triple>, musl uses a
# different name entirely. A wrong value means "No such file or directory" when
# running a binary that visibly exists — the most confusing error in the field.
interp=
for probe_bin in /bin/sh /bin/busybox /bin/true /usr/bin/env; do
    [ -x "$probe_bin" ] || continue
    if have readelf; then
        interp=$(readelf -l "$probe_bin" 2>/dev/null \
            | sed -n 's/.*interpreter: \([^]]*\)\].*/\1/p' | head -n1)
    fi
    if [ -z "$interp" ] && have strings; then
        interp=$(strings "$probe_bin" 2>/dev/null | grep -m1 '^/lib.*ld-')
    fi
    [ -n "$interp" ] && break
done
# Last resort: look for the loader on disk by its conventional names.
if [ -z "$interp" ]; then
    for p in /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-x86-64.so.2 \
             /lib/ld-linux-armhf.so.3 /lib/ld-musl-"$arch".so.1 \
             /lib/"$arch"-linux-gnu/ld-linux-"$arch".so.1; do
        [ -e "$p" ] && { interp=$p; break; }
    done
fi

# ── CPU ──────────────────────────────────────────────────────────────────────
# Reported for information. NOT emitted as TARGET_CPU, on purpose: baking a
# specific microarchitecture into every binary makes it SIGILL on any older chip
# in the fleet, and that is a decision a human should make deliberately rather
# than inherit from whichever machine happened to get probed.
cpu_model=unknown
if [ -r /proc/cpuinfo ]; then
    cpu_model=$(awk -F: '/^(model name|Model|cpu model)[ \t]*:/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
    if [ -z "$cpu_model" ]; then
        part=$(awk -F: '/^CPU part/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
        case $part in
            0xd03) cpu_model="Cortex-A53" ;;
            0xd07) cpu_model="Cortex-A57" ;;
            0xd08) cpu_model="Cortex-A72" ;;
            0xd0b) cpu_model="Cortex-A76" ;;
            0xd44) cpu_model="Cortex-X1"  ;;
            # 0x000 is what qemu's emulated CPU reports — it is not a real part id, so do not
            # render it as "ARM part 0x000", which reads as a genuine (wrong) part if pasted
            # into a note. Emulation is exactly the case where the CPU is not the deploy
            # target's anyway, so say so plainly.
            0x000|"") cpu_model="unknown ARM (emulated or unreported CPU)" ;;
            *)     cpu_model="ARM part $part" ;;
        esac
    fi
fi

# ── endianness, measured rather than assumed ─────────────────────────────────
endian=little
if have od; then
    case $(printf '\001\000\000\000' | od -An -tx4 2>/dev/null | tr -d ' \n') in
        00000001) endian=little ;;
        01000000) endian=big ;;
    esac
fi

# ── the triple ───────────────────────────────────────────────────────────────
# Ask a local compiler if there is one, since its answer is authoritative.
# Otherwise compose from the measured arch and libc family.
triple=
for cc in gcc cc clang; do
    if have "$cc"; then
        triple=$("$cc" -dumpmachine 2>/dev/null)
        [ -n "$triple" ] && break
    fi
done
if [ -z "$triple" ]; then
    case $libc_family in
        musl) abi=musl ;;
        *)    abi=gnu ;;
    esac
    case $arch in
        armv7l|armv7*) triple="arm-linux-${abi}eabihf" ;;
        armv6l|armv6*) triple="arm-linux-${abi}eabi" ;;
        *)             triple="$arch-linux-$abi" ;;
    esac
fi

# ── extras worth knowing about ───────────────────────────────────────────────
distro="unknown"
if [ -r /etc/os-release ]; then
    distro=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' /etc/os-release | head -n1)
fi
[ -r /etc/petalinux-release ] && distro="PetaLinux $(head -n1 /etc/petalinux-release 2>/dev/null)"
cpu_count=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
rdma=no
have ibv_devices && [ -n "$(ibv_devices 2>/dev/null | awk 'NR>2 {print $1}')" ] && rdma=yes

# The GPU this machine carries, as a fact about the machine. Detected HERE, on the target,
# because the machine that compiles device code need not hold this card or any card — so
# the build host is exactly the wrong place to ask.
#
# rocminfo is tried before amdgpu-arch on purpose: rocminfo installs into /usr/bin, while
# amdgpu-arch lives under /opt/rocm*/llvm/bin, which a non-login ssh PATH does not carry.
# Only the bare gfx name is taken, not rocminfo's full target-id: --offload-arch wants
# gfx90a, and the :sramecc/:xnack features differ between two cards of the same arch.
gpu_arch=
if have rocminfo; then
    gpu_arch=$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\).*/\1/p' | head -1)
fi
if [ -z "$gpu_arch" ]; then
    for _c in /opt/rocm/llvm/bin/amdgpu-arch /opt/rocm-*/llvm/bin/amdgpu-arch; do
        [ -x "$_c" ] || continue
        gpu_arch=$("$_c" 2>/dev/null | head -1)
        [ -n "$gpu_arch" ] && break
    done
fi
if [ -z "$gpu_arch" ] && have nvidia-smi; then
    _cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
    [ -n "$_cc" ] && gpu_arch="sm_$(echo "$_cc" | tr -d ' .')"
fi

if [ "$RAW" = 1 ]; then
    printf 'arch=%s\ntriple=%s\nlibc_family=%s\nlibc_version=%s\nlibc_path=%s\n' \
        "$arch" "$triple" "$libc_family" "$libc_version" "$libc_path"
    printf 'libstdcxx_path=%s\ncxxabi_max=%s\ninterp=%s\n' \
        "$libstdcxx_path" "$cxxabi_max" "$interp"
    printf 'gpu_arch=%s\n' "$gpu_arch"
    printf 'cpu_model=%s\ncpu_count=%s\nendian=%s\ndistro=%s\nrdma=%s\n' \
        "$cpu_model" "$cpu_count" "$endian" "$distro" "$rdma"
    printf 'kernel=%s\n' "$(uname -r 2>/dev/null)"
    exit 0
fi

name=${NAME_HINT:-$(hostname 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')}
[ -n "$name" ] || name="$arch-target"

# ── can this machine serve as its own sysroot? ───────────────────────────────
#
# ssh-rsync copies what is here, and what is here is only a sysroot if it can be LINKED
# against. Running a program needs libc.so.6. Linking one needs the headers, the crt
# startup objects and the libc.so linker name, which ship in separate -dev packages and
# which a device rootfs routinely lacks. PetaLinux has no package manager to add them.
#
# Suggesting ssh-rsync anyway produces a fetch that succeeds and a build that fails much
# later with "cannot open Scrt1.o" and "unable to find library -lc", naming the linker
# rather than the sysroot. So the provider is a conclusion drawn from what is actually
# present, not a constant.
#
# SYSROOT_CHECK_ROOT exists for the test suite. On a real target it is empty and every
# path below is absolute, as it must be.
_r=${SYSROOT_CHECK_ROOT:-}
_libdirs="$_r/usr/lib $_r/usr/lib64 $_r/usr/lib/$arch-linux-gnu $_r/lib $_r/lib64 $_r/lib/$arch-linux-gnu"

lacks=
[ -f "$_r/usr/include/stdio.h" ] || lacks="$lacks headers"

_found=
for d in $_libdirs; do
    for f in Scrt1.o crt1.o; do
        if [ -f "$d/$f" ]; then _found=$d/$f; break 2; fi
    done
done
[ -n "$_found" ] || lacks="$lacks crt-objects"

_found=
for d in $_libdirs; do
    if [ -f "$d/libc.so" ]; then _found=$d/libc.so; break; fi
done
[ -n "$_found" ] || lacks="$lacks libc.so-linker-name"

command -v rsync >/dev/null 2>&1 || lacks="$lacks rsync"

if [ -z "$lacks" ]; then
    provider_block="# Copy the sysroot straight off this machine. The libraries here are by definition
# the ones your binaries will meet at runtime.
SYSROOT_PROVIDER=ssh-rsync
SYSROOT_PROVIDER_ARGS=\"host=$(id -un 2>/dev/null || echo user)@$(hostname 2>/dev/null || echo HOSTNAME) port=22\""
else
    provider_block="# This machine cannot serve as its own sysroot. Checked over ssh, it lacks:
#$lacks
# so a copy of it could run programs and not link them. Choose a source instead:
#
#   deb          assemble a matching root from distribution packages. Needs no root,
#                no Linux and no qemu, and records every version it resolved.
#                  SYSROOT_PROVIDER=deb
#                  SYSROOT_PROVIDER_ARGS=\"suite=<codename> add=<extra,packages>\"
#   dir          a vendor SDK, Yocto or Buildroot staging tree you already have. The
#                only source that matches a device toolchain exactly.
#                  SYSROOT_PROVIDER=dir
#                  SYSROOT_PROVIDER_ARGS=\"path=<...>\"
#   tar          an archive of a rootfs that does carry its -dev files.
#
# config/xbuild/docs/04-sysroot-providers.md covers the choice.
SYSROOT_PROVIDER=none"
fi

# ── emit a description ───────────────────────────────────────────────────────
cat <<EOF
# Target description generated by probe-target.sh on $(date 2>/dev/null || echo 'unknown date')
#
# Probed machine:
#   host    : $(hostname 2>/dev/null || echo unknown)
#   distro  : $distro
#   kernel  : $(uname -r 2>/dev/null || echo unknown)
#   cpu     : $cpu_model  ($cpu_count core(s))
#   RDMA    : $rdma
#
# probe-sysroot-capable: $( [ -z "$lacks" ] && echo yes || echo "no (lacks:$lacks)" )
# probe-gpu-arch: ${gpu_arch:-none}
#
# Save as targets/<name>.conf, and make TARGET_NAME match the filename.

TARGET_NAME=$name
TARGET_DESC="$distro on $cpu_model"

TARGET_TRIPLE=$triple
TARGET_ARCH=$arch
TARGET_ENDIAN=$endian

# TARGET_CPU is left EMPTY deliberately, even though this machine is a
# "$cpu_model". Setting it makes binaries that crash with SIGILL on older chips of
# the same family. Set it only if the whole fleet is this exact part and you have
# measured a benefit.
TARGET_CPU=
$( [ "$arch" = aarch64 ] || [ "$arch" = arm64 ] && echo "TARGET_CPU_FLAG=mcpu" || echo "TARGET_CPU_FLAG=march" )

# The GPU a component compiling device code emits for. Pre-filled from what this machine
# reports, but a DECISION, not a fact: re-probing leaves whatever is here alone, because
# one bundle may deliberately target a different card than the machine it was probed from.
# The '# probe-gpu-arch:' comment above records what was actually seen, and a re-probe says
# so if the two stop agreeing. GPU_ARCH=<arch> on the make command line overrides it once.
TARGET_GPU_ARCH=$gpu_arch

TARGET_LIBC=$libc_family
TARGET_LIBC_VERSION=$libc_version
TARGET_CXXABI_MAX=$cxxabi_max
TARGET_DYNAMIC_LINKER=$interp

$provider_block

TOOLCHAIN_KIND=llvm
TARGET_LINKER=lld
TARGET_STDLIB=$( [ "$libc_family" = musl ] && echo libc++ || echo libstdc++ )
# 20, and not something probed: the C++ standard is a property of the SOURCE you intend
# to build, which a machine probe cannot see. It is written as 20 because that is this
# tree's minimum (Catalyst's headers use C++20 concepts). mk/derive.mk raises anything
# lower anyway, so editing this down does not achieve what it looks like it achieves.
TARGET_CXX_STANDARD=20

TARGET_RPATH=\$\$ORIGIN
TARGET_DEPLOY_DIR=${HOME:-/tmp}/workspace
EOF

# Warn on stderr so the emitted description stays clean and pipeable, while a
# human still sees the caveat.
if [ -n "$lacks" ]; then
    echo "" >&2
    echo "WARNING: this machine cannot be its own sysroot. It lacks:$lacks" >&2
    echo "         SYSROOT_PROVIDER is set to 'none' rather than ssh-rsync, because" >&2
    echo "         copying this rootfs would give you a sysroot that can RUN programs" >&2
    echo "         but not LINK them. The description lists the alternatives." >&2
fi
if [ -z "$libc_version" ] && [ "$libc_family" = glibc ]; then
    echo "" >&2
    echo "WARNING: could not determine the glibc version on this machine." >&2
    echo "         TARGET_LIBC_VERSION is empty, which disables the build-time" >&2
    echo "         symbol-version check. Fill it in by hand if you can." >&2
fi
if [ -z "$interp" ]; then
    echo "" >&2
    echo "WARNING: could not determine the ELF interpreter path." >&2
    echo "         TARGET_DYNAMIC_LINKER is empty; the compiler will guess from the" >&2
    echo "         sysroot. If binaries fail to start with 'No such file or" >&2
    echo "         directory', that guess was wrong — find the real path with:" >&2
    echo "           readelf -l /bin/sh | grep interpreter" >&2
fi
# The C++ ABI ceiling has the SAME failure mode as the two above, and used to warn about
# neither the cause nor the consequence. If libstdc++ is present but its symbols could not be
# read, say why and what it disables — this is the check that stops a too-new GLIBCXX/CXXABI
# symbol reaching the board, and an empty ceiling turns it off.
if [ -z "$cxxabi_max" ] && [ -n "$libstdcxx_path" ]; then
    echo "" >&2
    echo "WARNING: could not read the C++ ABI ceiling from $libstdcxx_path." >&2
    echo "         This machine has no 'strings' or 'tr' able to read the symbol tags," >&2
    echo "         so TARGET_CXXABI_MAX is empty — which DISABLES the libstdc++ symbol-" >&2
    echo "         version check in 'make verify'. That check is what catches a too-new" >&2
    echo "         GLIBCXX_/CXXABI_ symbol before it fails on the device. To close the gap:" >&2
    echo "           * install binutils on the target and re-probe, or" >&2
    echo "           * read it once by hand and paste it in, e.g. on any host with the" >&2
    echo "             same libstdc++:  strings libstdc++.so.6 | grep -E '^(GLIBCXX|CXXABI)_' | sort -V | tail" >&2
    echo "         (Building against the target's OWN sysroot is inherently safe; the risk" >&2
    echo "          is only when this description is later paired with an approximation.)" >&2
fi
