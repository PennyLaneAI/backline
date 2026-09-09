#!/usr/bin/env bash
#
# arch-table.sh — the ONE place where architecture facts live.
#
# WHY THIS FILE EXISTS
# An independent review of this tree correctly pointed out that the "adding a target is
# one file" claim did not hold for a NEW ARCHITECTURE: two engine files each carried
# their own arch knowledge —
#
#   mk/derive.mk          the list deciding -mcpu vs -march
#   tools/verify-artifact.sh   the arch -> ELF-machine-name mapping
#
# and the second one failing open was dangerous: an architecture missing from that
# table made `make verify` print "no expectation" and PASS, so an x86-64 binary
# verified clean against a loongarch64 target.
#
# Both tables now live here, in one place, read by both consumers. Adding an
# architecture is one entry in this file — which keeps it data, consistent with the
# rest of the design.
#
# USAGE
#   arch-table.sh cpu-flag <arch>      -> mcpu | march
#   arch-table.sh elf-machine <arch>   -> the substring readelf prints, or empty
#   arch-table.sh macho-arch <arch>    -> the substring otool prints, or empty
#   arch-table.sh deb-arch <arch>      -> the Debian architecture name, or empty
#   arch-table.sh known                -> every architecture this table knows
#   arch-table.sh binfmt <triple>      -> elf | macho
#   arch-table.sh known-os             -> every OS token this table knows

set -uo pipefail

MODE=${1:-known}
ARCH=${2:-}

# ── the table ────────────────────────────────────────────────────────────────
# Fields:  arch | cpu-flag | elf-machine-substring | debian-arch | macho-arch
#
# macho-arch is the name Mach-O tools print for the same architecture — `otool -hv`
# and `file` both say "arm64" where readelf says "AArch64". Empty means this
# architecture does not exist as a Mach-O target, which is true of all but two.
#
# elf-machine is matched as a SUBSTRING of readelf's output, because different
# readelf versions word it differently ("Advanced Micro Devices X86-64" vs
# "AMD x86-64").
# Pipe-delimited so that a field containing spaces ("IBM S/390", "Intel 80386")
# cannot be mis-split. Whitespace-column parsing was tried first and silently bled the
# next field into the previous one, which produced an elf-machine string that could
# never match — an ABI check that appears to run and cannot ever succeed.
TABLE='
aarch64|mcpu|AArch64|arm64|arm64
arm64|mcpu|AArch64|arm64|arm64
x86_64|march|X86-64|amd64|x86_64
amd64|march|X86-64|amd64|x86_64
i386|march|Intel 80386|i386|
i686|march|Intel 80386|i386|
arm|mcpu|ARM|armhf|
armv6|mcpu|ARM|armel|
armv6l|mcpu|ARM|armel|
armv7|mcpu|ARM|armhf|
armv7l|mcpu|ARM|armhf|
riscv64|march|RISC-V|riscv64|
ppc64le|mcpu|PowerPC64|ppc64el|
ppc64el|mcpu|PowerPC64|ppc64el|
s390x|march|IBM S/390|s390x|
mips64el|march|MIPS|mips64el|
loongarch64|march|LoongArch|loong64|
'

# ── the OS table ─────────────────────────────────────────────────────────────
# Fields:  os-token | binary-format
#
# WHY THIS IS HERE AND NOT IN mk/derive.mk. The format a platform uses is a FACT about
# the platform, in the same class as "which flag selects a CPU". Which flags follow from
# it is a separate question, and that one stays in derive.mk. Keeping the fact here means
# adding a platform is an entry in this file, exactly as adding an architecture is.
#
# Matched as a SUBSTRING of the whole triple, because the OS field carries a version on
# some platforms (arm64-apple-darwin25.5.0) and is in a different position depending on
# whether the triple names a vendor (aarch64-linux-gnu vs aarch64-unknown-linux-gnu).
# Longest-token-first is not needed: no token here is a substring of another.
OS_TABLE='
darwin|macho
linux|elf
freebsd|elf
netbsd|elf
openbsd|elf
solaris|elf
elf|elf
eabi|elf
'

lookup() {
  local want=$1 col=$2 line a cflag elf deb macho
  while IFS='|' read -r a cflag elf deb macho; do
    [[ -z ${a:-} ]] && continue
    if [[ $a == "$want" ]]; then
      case $col in
        cpu-flag)    printf '%s' "$cflag" ;;
        elf-machine) printf '%s' "$elf" ;;
        deb-arch)    printf '%s' "$deb" ;;
        macho-arch)  printf '%s' "${macho:-}" ;;
      esac
      return 0
    fi
  done <<< "$TABLE"
  return 1
}

lookup_binfmt() {
  local triple=$1 os fmt
  while IFS='|' read -r os fmt; do
    [[ -z ${os:-} ]] && continue
    case $triple in
      *"$os"*) printf '%s' "$fmt"; return 0 ;;
    esac
  done <<< "$OS_TABLE"
  return 1
}

case $MODE in
  cpu-flag)
    # Default to march: it is correct for every non-ARM architecture, and an unknown
    # architecture is far more likely to be a new x86/RISC-V-like one than a new ARM.
    lookup "$ARCH" cpu-flag || printf 'march' ;;
  elf-machine)
    # Deliberately prints NOTHING for an unknown arch, so the caller can tell the
    # difference between "checked and matched" and "could not check". The verifier
    # turns the empty result into a WARNING rather than a silent pass.
    lookup "$ARCH" elf-machine || true ;;
  macho-arch)
    # Same contract as elf-machine: empty means "cannot check", never "fine".
    lookup "$ARCH" macho-arch || true ;;
  deb-arch)
    lookup "$ARCH" deb-arch || true ;;
  binfmt)
    # The second argument is a TRIPLE here, not an arch, because the format follows from
    # the OS and not from the machine.
    #
    # Defaults to elf for an unlisted OS, and that default is safe in a way the
    # elf-machine default would NOT have been. Getting the ARCHITECTURE wrong produces a
    # binary that verifies clean and cannot execute, so that lookup must fail closed.
    # Getting the FORMAT wrong cannot be quiet: ELF flags handed to a non-ELF linker are
    # rejected by name (ld64.lld: error: unknown argument '--disable-new-dtags'), and
    # every platform this tree can target other than Darwin does use ELF. So the failure
    # mode of this default is a loud link error, not a wrong binary.
    lookup_binfmt "${2:-}" || printf 'elf' ;;
  known)
    printf '%s\n' "$TABLE" | awk -F'|' 'NF>1 {printf "%s ", $1}' ;;
  known-os)
    printf '%s\n' "$OS_TABLE" | awk -F'|' 'NF>1 {printf "%s ", $1}' ;;
  *)
    echo "arch-table.sh: unknown query '$MODE'" >&2
    echo "usage: arch-table.sh {cpu-flag|elf-machine|macho-arch|deb-arch|known} <arch>" >&2
    echo "       arch-table.sh binfmt <triple>" >&2
    echo "       arch-table.sh known-os" >&2
    exit 2 ;;
esac
