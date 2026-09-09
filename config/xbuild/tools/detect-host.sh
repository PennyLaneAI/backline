#!/usr/bin/env bash
#
# detect-host.sh — answer questions about the BUILD machine by asking the tools,
# never by pattern-matching a distro.
#
# WHY
# ---
# The original tree contained:
#
#     LLVM_TOOLCHAIN ?= /usr/lib/llvm-18
#
# That path is a Debian/Ubuntu packaging convention. It does not exist on Fedora
# (/usr, versionless), Arch (/usr), Homebrew (/opt/homebrew/opt/llvm), Nix (a hash
# path), or a self-built LLVM (wherever you installed it). Encoding it made the
# build system silently Ubuntu-only, and the failure mode was a confusing
# "no such file" for clang++ rather than "your LLVM is somewhere else".
#
# The general fix is to ask the tool where it is, not to know where it should be.
# `clang -print-resource-dir` is stable across every LLVM ≥ 3.8 and every distro,
# because clang computes it from its own argv[0] at runtime.
#
# USAGE
#   detect-host.sh triple                  # host triple, e.g. x86_64-linux-gnu
#   detect-host.sh normalize-triple [t]    # canonical form of t (default: the host)
#   detect-host.sh multiarch-triple [t]    # t with the vendor field dropped, for DIRECTORY names
#   detect-host.sh arch                    # host uname -m
#   detect-host.sh llvm-root               # install prefix containing bin/clang
#   detect-host.sh libc-version
#   detect-host.sh report                  # everything, human-readable

set -uo pipefail

# ── which compiler to ask ────────────────────────────────────────────────────
# Honour CC/CXX if the user set them (they may have several toolchains), else try
# a sensible list. Order puts clang first because this tree defaults to LLVM.
pick_cc() {
  if [[ -n ${CC:-} ]] && command -v "$CC" >/dev/null 2>&1; then echo "$CC"; return; fi
  for c in clang cc gcc; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  return 1
}

host_triple() {
  local cc
  cc=$(pick_cc) || return 1
  # -dumpmachine is understood by both gcc and clang and prints the triple the
  # compiler natively targets. That is precisely the definition of "host triple".
  "$cc" -dumpmachine 2>/dev/null
}

host_arch() { uname -m; }

# ── triple canonicalisation ──────────────────────────────────────────────────
#
# WHY THIS EXISTS
# Two spellings of the same machine are not string-equal. This host's compiler
# reports x86_64-pc-linux-gnu (arch-vendor-os-abi); Debian's convention, and what
# every target description here uses, is x86_64-linux-gnu (vendor elided). Comparing
# those two directly makes a native build look like a cross build, which made
# COMPONENT_REQUIRES_NATIVE components refuse to build ON THE VERY MACHINE they
# require.
#
# Same principle as the rest of this file: ask the compiler rather than keep a table.
# `clang --target=X -print-target-triple` expands X to LLVM's canonical four-field
# arch-vendor-os-abi form, filling in whatever X elided. That alone is NOT enough:
# clang preserves a vendor you spelled out, so x86_64-pc-linux-gnu stays 'pc' while
# x86_64-linux-gnu becomes 'unknown', and the two still compare unequal. So we take
# the compiler's expansion — which gets the field COUNT and the arch/os/abi spellings
# right, and does so for triples this script has never heard of — and then force the
# vendor field to 'unknown', because vendor is the one field that names nothing a
# build cares about.
vendor_agnostic() {
  awk -F- 'BEGIN { OFS = "-" } { if (NF >= 3) $2 = "unknown"; print }'
}
canon_triple_text() {
  # Fallback for a gcc-only host: gcc has no -print-target-triple. The vendor field
  # is the only optional one, and the only one that differs between spellings of one
  # machine, so drop known vendor tokens and compare what remains. This is the same
  # set config.sub treats as vendors. Deliberately NOT a full triple parser: the
  # 3-field form is ambiguous (arch-vendor-os vs arch-os-abi) and guessing wrong is
  # worse than comparing a field short.
  # The trailing '-' names stdin EXPLICITLY. GNU paste defaults to stdin when given no
  # file operand; BSD paste (macOS, the *BSDs) does not — it prints its usage and exits 1.
  # Without it this function returned the string
  #     usage: paste [-s] [-d delimiters] file ...
  # as though it were a triple. That value became TRIPLE_ALT in tools/sysroot-inspect.sh
  # and was then used to build candidate directory names, so a sysroot's multiarch
  # directory was never found on a Mac. Nothing failed; the -isystem and -B flags were
  # simply absent, which surfaces later as a missing bits/c++config.h.
  # '-' is accepted by GNU paste too, so one spelling works everywhere.
  printf '%s\n' "$1" | tr '-' '\n' \
    | grep -vxE 'pc|unknown|none|redhat|suse|w64|apple|poky|oe|linaro|xilinx|amd|intel' \
    | paste -sd- -
}

# The spelling used for DIRECTORY names, which is not the same question as
# normalize-triple. Debian/Ubuntu name their multiarch directories with the vendor field
# omitted — /usr/lib/x86_64-linux-gnu, /usr/include/aarch64-linux-gnu — so a description or
# a compiler saying x86_64-pc-linux-gnu must still find them. normalize-triple answers
# "are these the same machine" and deliberately fills the vendor in as 'unknown', which
# names no directory anywhere; this answers "what is this tree's directory called".
#
# Shares canon_triple_text with normalize-triple so the vendor-token list exists once.
multiarch_triple() {
  local t=${1:-} cc
  if [[ -z $t ]]; then
    cc=$(pick_cc) || return 1
    t=$("$cc" -dumpmachine 2>/dev/null)
  fi
  [[ -n $t ]] || return 1
  canon_triple_text "$t"
}

normalize_triple() {
  local t=${1:-} cc out
  cc=$(pick_cc) || { canon_triple_text "$t"; return 0; }

  # Resolve the host's own triple first, then normalise it by the SAME route as an
  # explicit argument. A bare `-print-target-triple` echoes the compiler's default
  # spelling verbatim (x86_64-pc-linux-gnu here) while `--target=X -print-target-triple`
  # canonicalises (x86_64-unknown-linux-gnu) — so the two forms of this query would
  # disagree about one machine, which is exactly the bug this function exists to kill.
  [[ -n $t ]] || t=$("$cc" -dumpmachine 2>/dev/null)

  if [[ -n $t ]]; then
    out=$("$cc" --target="$t" -print-target-triple 2>/dev/null | vendor_agnostic)
    [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
  fi

  # No -print-target-triple (gcc, or a clang older than 3.9).
  canon_triple_text "$t"
}

llvm_root() {
  # Preferred: ask clang. The resource dir is <prefix>/lib/clang/<ver>, so two
  # path components up is the install prefix.
  local rd
  if command -v clang >/dev/null 2>&1; then
    rd=$(clang -print-resource-dir 2>/dev/null) || rd=""
    if [[ -n $rd ]]; then
      # Walk up until we find a directory containing bin/clang. Doing this by
      # search rather than by counting '..' survives layout differences between
      # LLVM versions (the resource dir gained/lost a component historically).
      local d=$rd
      for _ in 1 2 3 4 5; do
        d=$(dirname "$d")
        if [[ -x $d/bin/clang ]]; then echo "$d"; return 0; fi
      done
    fi
    # Fallback: derive from the clang binary's own location.
    local cpath
    cpath=$(command -v clang)
    cpath=$(cd "$(dirname "$(readlink -f "$cpath")")/.." && pwd)
    [[ -x $cpath/bin/clang ]] && { echo "$cpath"; return 0; }
  fi
  return 1
}

libc_version() {
  # getconf is the portable interface; ldd --version is the fallback. Both are
  # absent on musl-based build hosts, where the answer is legitimately "musl".
  local v
  v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
  [[ -n $v ]] && { echo "$v"; return 0; }
  v=$(ldd --version 2>&1 | head -n1 | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  [[ -n $v ]] && { echo "$v"; return 0; }
  echo unknown
}

case ${1:-report} in
  triple)           host_triple ;;
  normalize-triple) normalize_triple "${2:-}" ;;
  multiarch-triple) multiarch_triple "${2:-}" ;;
  arch)         host_arch ;;
  llvm-root)    llvm_root ;;
  libc-version) libc_version ;;
  report)
    printf 'host triple : %s\n' "$(host_triple || echo unknown)"
    printf 'host arch   : %s\n' "$(host_arch)"
    printf 'llvm root   : %s\n' "$(llvm_root || echo 'not found')"
    printf 'libc        : %s\n' "$(libc_version)"
    printf 'cmake       : %s\n' "$(command -v cmake || echo 'not found')"
    printf 'ninja       : %s\n' "$(command -v ninja || echo 'not found')"
    printf 'rsync       : %s\n' "$(command -v rsync || echo 'not found')"
    ;;
  *)
    echo "detect-host.sh: unknown query '${1}'" >&2
    echo "usage: detect-host.sh {triple|normalize-triple [t]|multiarch-triple [t]|arch|llvm-root|libc-version|report}" >&2
    exit 2
    ;;
esac
