#!/usr/bin/env bash
#
# verify-artifact.sh — check that a built binary will actually run on the target,
# BEFORE you copy it there.
#
# WHY THIS EXISTS
# ---------------
# The design being replaced had no verification at all. If a cross-build produced
# a binary that could not run on the board, you found out by copying it to the
# board and running it. The failure modes at that point are, in increasing order of
# time wasted:
#
#   "Exec format error"
#       Wrong architecture. Fast to diagnose.
#
#   "No such file or directory" — on a file that plainly exists
#       Wrong ELF interpreter path baked in. This one wastes hours the first time
#       you see it, because every instinct says the message is about the binary.
#       It is actually about the loader named inside it.
#
#   "version `GLIBC_2.38' not found (required by ./libfoo.so)"
#       The build host's sysroot was newer than the target. The binary links and
#       loads and then dies. This is the failure the original design's
#       glibc-to-codename guessing table made *likely*: pick `noble` for a board
#       running something else and this is what you get.
#
#   No error at all, wrong answers
#       Same architecture, same libc version, but a library resolved from the build
#       host instead of the sysroot. Nothing complains, ever.
#
# All four are detectable on the build host in milliseconds by reading the ELF
# headers. Doing so converts a class of remote, confusing runtime failures into
# local, specific build failures. That trade is always worth making.
#
# USAGE
#   verify-artifact.sh <artifact> [--target-conf <file>] [--strict]
#                                 [--triple <t>] [--arch <a>]
#
#   --strict   treat warnings as errors (recommended in CI)
#   --triple   the RESOLVED triple, overriding a blank one in the description
#   --arch     the RESOLVED architecture, likewise
#
# Reads the target's expectations from the description: TARGET_ARCH,
# TARGET_LIBC_VERSION, TARGET_CXXABI_MAX, TARGET_DYNAMIC_LINKER. A field left
# empty means "no expectation", and that check is skipped with a note — so
# verification degrades gracefully rather than blocking a build.
#
# WHY --triple AND --arch EXIST. A native target legitimately leaves both blank and lets
# mk/derive.mk fill them from the host compiler, which is what makes one
# targets/example-native.conf work on every machine. This script reads the DESCRIPTION,
# so it saw the blanks and disabled the architecture check on exactly the targets whose
# answer was never in doubt — reporting "cannot check" while the build knew perfectly
# well. Worse once formats entered the picture: with no triple there is no way to tell
# which format was wanted, so a correct artifact was reported as a format mismatch.
# The Makefile passes the resolved values, exactly as it already does for get-sysroot.sh.

set -uo pipefail

ART=""
CONF=""
STRICT=0
ARG_TRIPLE=""
ARG_ARCH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --target-conf) CONF=$2; shift 2 ;;
    --triple)      ARG_TRIPLE=$2; shift 2 ;;
    --arch)        ARG_ARCH=$2; shift 2 ;;
    --strict)      STRICT=1; shift ;;
    -h|--help)     sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             ART=$1; shift ;;
  esac
done

[[ -n $ART ]]  || { echo "verify-artifact: no artifact given" >&2; exit 2; }
[[ -e $ART ]]  || { echo "verify-artifact: no such file: $ART" >&2; exit 2; }

# Load expectations through load_conf (see tools/load-conf.sh) rather than sourcing
# the description directly, so multi-word values cannot be truncated or executed.
TARGET_NAME="" TARGET_ARCH="" TARGET_LIBC="" TARGET_LIBC_VERSION=""
TARGET_CXXABI_MAX="" TARGET_DYNAMIC_LINKER="" TARGET_TRIPLE=""
if [[ -n $CONF && -r $CONF ]]; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/load-conf.sh"
  load_conf "$CONF" || exit 1
fi

# The resolved values win over the description's, because they ARE the description's —
# resolved. Only applied when non-empty, so a caller that passes nothing changes nothing.
[[ -n $ARG_TRIPLE ]] && TARGET_TRIPLE=$ARG_TRIPLE
[[ -n $ARG_ARCH   ]] && TARGET_ARCH=$ARG_ARCH
# And derive the arch from the triple if only the triple is known, by the same rule
# mk/derive.mk uses (the first field), so the two cannot disagree.
if [[ -z ${TARGET_ARCH:-} && -n ${TARGET_TRIPLE:-} ]]; then
  TARGET_ARCH=${TARGET_TRIPLE%%-*}
fi

FAIL=0
WARN=0
err()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  WARN  %s\n' "$*"; WARN=$((WARN+1)); }
ok()   { printf '  ok    %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }

_TOOLDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ARCH_TABLE="$_TOOLDIR/arch-table.sh"

# The verdict, shared by every format's checks so that one exit convention exists.
verdict() {
  printf '\n'
  if [[ $FAIL -gt 0 ]]; then
    printf 'RESULT: FAIL  (%d error(s), %d warning(s))\n' "$FAIL" "$WARN"
    printf 'This artifact will not work correctly on %s. Do not deploy it.\n' "${TARGET_NAME:-the target}"
    exit 1
  fi
  if [[ $WARN -gt 0 && $STRICT -eq 1 ]]; then
    printf 'RESULT: FAIL  (%d warning(s), --strict)\n' "$WARN"
    exit 1
  fi
  printf 'RESULT: PASS  (%d warning(s))\n' "$WARN"
  exit 0
}

printf '\nverifying %s\n' "$ART"
[[ -n $TARGET_NAME ]] && printf 'against target: %s\n' "$TARGET_NAME"
printf '\n'

# ── which format is this, and which SHOULD it be? ────────────────────────────
#
# Read from the first four bytes rather than from `file`, whose wording differs between
# platforms and versions far more than a magic number does, and which is not guaranteed
# present. `od` is POSIX and is on every host this tree runs on.
artifact_format() {
  local magic
  magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
  case $magic in
    7f454c46)          printf 'elf' ;;    # \x7f E L F
    cffaedfe|cefaedfe) printf 'macho' ;;  # MH_MAGIC_64 / MH_MAGIC, little-endian
    feedfacf|feedface) printf 'macho' ;;  # ...and the big-endian spellings
    cafebabe|bebafeca) printf 'macho' ;;  # a universal ("fat") binary
    *)                 printf 'unknown' ;;
  esac
}

EXPECT_FMT=$("$_ARCH_TABLE" binfmt "${TARGET_TRIPLE:-}" 2>/dev/null || printf 'elf')
ACTUAL_FMT=$(artifact_format "$ART")

# A format mismatch is the coarsest possible wrong answer, and worth its own check with
# its own message. Before this existed, a Mach-O artifact met "not an ELF file (or
# unreadable)" — accurate but it reads as a corrupt file rather than as a binary built
# for the wrong operating system — and an ELF artifact aimed at a Darwin target was not
# checked at all.
if [[ $ACTUAL_FMT == unknown ]]; then
  err "unrecognised binary format: '$ART' is not ELF and not Mach-O.
        A component's COMPONENT_OUTPUT may be naming something that is not a binary at
        all (a script, an archive, a stale text file), or the file is truncated."
  verdict
fi
if [[ $ACTUAL_FMT != "$EXPECT_FMT" ]]; then
  err "binary format mismatch: this artifact is $ACTUAL_FMT, but target
        '${TARGET_NAME:-?}' (${TARGET_TRIPLE:-triple unknown}) needs $EXPECT_FMT.
        Nothing about this binary can load on that machine — the kernel rejects it
        before any library or symbol question arises ('Exec format error', or on
        macOS a SIGKILL with no message at all).
        Usually this means a NATIVE compiler produced it for a cross target: check
        that the component is not marked COMPONENT_REQUIRES_NATIVE=yes, and that
        TARGET_TRIPLE names the machine you meant."
  verdict
fi

# ── Mach-O ───────────────────────────────────────────────────────────────────
# A separate reader, because none of the ELF tooling below can read it, and the four
# ELF-specific checks have no Mach-O counterpart. Reporting each of those as "not
# applicable, and here is why" rather than quietly omitting them keeps the output an
# honest account of what was and was not verified.
#
# otool ships with the Command Line Tools and lives in /usr/bin, so it is present on
# every Mac that can compile at all. There is no equivalent of the readelf hunt below.
if [[ $ACTUAL_FMT == macho ]]; then
  if ! command -v otool >/dev/null 2>&1; then
    cat >&2 <<'EOF'
verify-artifact: this is a Mach-O binary and otool was not found.
  Cannot verify it. otool ships with the Xcode Command Line Tools:
         xcode-select --install
EOF
    exit 3
  fi

  # 1. architecture. otool prints the cputype in its own spelling — 'ARM64' where
  #    readelf says 'AArch64' — so the table's value is matched case-insensitively as a
  #    substring, for the same reason the ELF path does: tool versions word it
  #    differently and a table per version is not maintainable. Lowercased with tr
  #    because ${var,,} needs bash 4.
  _macho_cpus=$(otool -hv "$ART" 2>/dev/null \
                | awk '/MH_MAGIC/ {print $2}' | tr '[:upper:]' '[:lower:]' | sort -u)
  _expect_cpu=$("$_ARCH_TABLE" macho-arch "${TARGET_ARCH:-}" 2>/dev/null || true)
  if [[ -z $_macho_cpus ]]; then
    warn "architecture: cannot check — otool printed no Mach header for this file."
  elif [[ -z $_expect_cpu ]]; then
    # Same reasoning as the ELF branch: a skip here would pass an arm64 binary as fit
    # for an x86_64 machine, so it warns and --strict refuses it.
    warn "architecture: cannot check — TARGET_ARCH='${TARGET_ARCH:-<empty>}' has no Mach-O
        spelling in tools/arch-table.sh, so the binary's '$(printf '%s ' $_macho_cpus)' was
        NOT validated against it. Add the macho-arch column for that architecture.
        Known: $("$_ARCH_TABLE" known 2>/dev/null)"
  elif [[ -n $(printf '%s\n' $_macho_cpus | grep -x "$_expect_cpu") ]]; then
    if [[ $(printf '%s\n' $_macho_cpus | wc -l | tr -d ' ') -gt 1 ]]; then
      ok "architecture: $_expect_cpu (universal binary, also contains: $(printf '%s ' $_macho_cpus))"
    else
      ok "architecture: $_expect_cpu"
    fi
  else
    err "architecture mismatch: binary is '$(printf '%s ' $_macho_cpus)', target expects
        '$_expect_cpu' (TARGET_ARCH=$TARGET_ARCH).
        This binary cannot execute on the target at all."
  fi

  # 2-4. the three ELF-only checks, reported as inapplicable rather than omitted.
  skip "interpreter: n/a — Mach-O records no interpreter path; dyld is chosen by the kernel"
  skip "libc symbol versions: n/a — Mach-O has no symbol versioning, so there is no
        ceiling to compare. The equivalent guard is the SDK/deployment target, which
        the compiler enforces at build time (LC_BUILD_VERSION)."
  skip "libstdc++ ABI: n/a — libc++ on Darwin carries no GLIBCXX_ version tags"

  # 5. rpaths. The Mach-O form of the leaked-build-host-path check, plus one hazard
  #    that has no ELF counterpart.
  _rpaths=$(otool -l "$ART" 2>/dev/null \
            | awk '/^ *cmd LC_RPATH/{f=1;next} f&&/^ *path /{sub(/^ *path /,"");sub(/ \(offset [0-9]+\)$/,"");print;f=0}')
  if [[ -z $_rpaths ]]; then
    ok "LC_RPATH: none set"
  else
    _leaked=""
    while read -r rp; do
      [[ -z $rp ]] && continue
      # THE Mach-O-SPECIFIC HAZARD. ld64 accepts -rpath '$ORIGIN' without complaint and
      # writes it verbatim, but dyld has no such token — it expands @loader_path and
      # @executable_path only. So a description that names the ELF spelling produces a
      # binary that links cleanly, verifies cleanly under any check that only looks for
      # "an rpath is present", and then cannot find the libraries sitting beside it.
      # The ELF branch's mirror image of this is the 'RIGIN' check.
      case $rp in
        *'$ORIGIN'*)
          err "LC_RPATH contains '\$ORIGIN', which dyld does NOT understand.
        That is the ELF spelling. Mach-O's equivalent is '@loader_path', and the
        linker accepts \$ORIGIN silently rather than rejecting it, so nothing fails
        until the program runs and cannot find a library that is right beside it.
        Leave TARGET_RPATH empty to get the correct token for the format, or set
        TARGET_RPATH=@loader_path explicitly."
          continue ;;
      esac
      case $rp in
        @loader_path*|@executable_path*|@rpath*) continue ;;
        /usr/lib|/usr/local/lib|/System/*) continue ;;
        /*) _leaked="$_leaked$rp " ;;
      esac
    done <<< "$_rpaths"
    if [[ -n $_leaked ]]; then
      warn "LC_RPATH contains absolute build-host path(s): $_leaked
        These do not exist on the target. The portable form is @loader_path, which is
        what TARGET_RPATH sets for a Mach-O target."
    else
      ok "LC_RPATH: $(printf '%s ' $_rpaths)"
    fi
  fi

  # 6. what it needs, and what it calls itself.
  _needed=$(otool -L "$ART" 2>/dev/null | sed -n 's/^[[:space:]]\{1,\}\([^ ]*\).*/\1/p')
  if [[ -n $_needed ]]; then
    printf '  info  needs: %s\n' "$(printf '%s ' $_needed)"
  fi
  # An install name is a dylib's own recorded identity, the exact counterpart of SONAME:
  # whatever links against this copies the string and asks dyld for it at run time.
  #
  # otool -D labels its output, and a UNIVERSAL binary gets one label per architecture:
  #     fat (architecture arm64):
  #     fat (architecture x86_64):
  # An executable has no install name, so for a fat executable the labels are the only
  # output — and taking the second line reported 'fat (architecture arm64):' AS the install
  # name, warning that a file must be deployed under a name that is not a name. Every label
  # ends in ':' and an install name never does, so drop the labels and take what is left.
  _install=$(otool -D "$ART" 2>/dev/null | grep -v ':$' | head -n1)
  if [[ -n $_install ]]; then
    _base=$(basename "$ART")
    case $_install in
      @rpath/"$_base"|@loader_path/"$_base"|@executable_path/"$_base")
        ok "install name: $_install" ;;
      /*)
        warn "install name is the absolute path '$_install'.
        Anything linking against this library records that path and looks there at run
        time, so the bundle is not relocatable. The portable form is @rpath/$_base,
        which is what the shared-library recipe sets." ;;
      *)
        warn "install name is '$_install' but the file is named '$_base'.
        Anything linking against this will ask dyld for '$_install', so the file must
        be deployed under that name." ;;
    esac
  fi

  verdict
fi

# ── ELF ──────────────────────────────────────────────────────────────────────
# ── pick a reader ────────────────────────────────────────────────────────────
# llvm-readelf and GNU readelf both work and print compatible-enough output for
# the fields we need. objdump is a last resort. If none exists we say so rather
# than silently skipping verification — a check you think is running but is not is
# worse than no check.
#
# The triple-prefixed spellings are searched too: a cross-binutils install provides
# aarch64-linux-gnu-readelf and nothing called plain 'readelf', and Homebrew's llvm is
# keg-only so its llvm-readelf is not on PATH by default. Missing those reported "no
# readelf of any kind" on a machine that had three.
# FOUND IS NOT ENOUGH — it must answer the question the ABI checks ask.
#
# All three ceiling checks read `--dyn-syms`, and every call sends stderr to /dev/null and
# treats empty output as "this artifact imports no versioned symbols". That is a legitimate
# result for a static binary, and it is also what an unrecognised option produces. eu-readelf
# (elfutils) is in the candidate list below and spells this `--symbols`, not `--dyn-syms` —
# so on a host where it was chosen, the ABI ceiling checks silently reported ok having read
# nothing. That is the exact failure this whole script exists to prevent, in its own most
# valuable check.
_supports_dynsyms() { "$1" --dyn-syms "$ART" >/dev/null 2>&1; }

READELF=""
_rejected=""
for r in "${TARGET_READELF:-}" llvm-readelf readelf eu-readelf \
         "${TARGET_TRIPLE:-}-readelf" "${TARGET_ARCH:-}-linux-gnu-readelf"; do
  [[ -n $r && $r != -readelf && $r != -linux-gnu-readelf ]] || continue
  command -v "$r" >/dev/null 2>&1 || continue
  if _supports_dynsyms "$r"; then READELF=$r; break; fi
  _rejected="$_rejected $r"
done
if [[ -z $READELF && -n $_rejected ]]; then
  cat >&2 <<EOF
verify-artifact: found a readelf, but it cannot list dynamic symbols:$_rejected
  Every ABI ceiling check here reads --dyn-syms. A reader that does not understand that
  option returns nothing, which is indistinguishable from "this artifact imports no
  versioned symbols" — so accepting it would report PASS having checked nothing.
  Install GNU binutils or LLVM (apt install binutils | brew install llvm).
EOF
  exit 1
fi
if [[ -z $READELF ]]; then
  cat >&2 <<'EOF'
verify-artifact: no readelf found (tried llvm-readelf, readelf, eu-readelf and the
  triple-prefixed spellings).
  Cannot verify this artifact. Install binutils or LLVM, or accept that a wrong
  architecture / interpreter / symbol version will only be discovered on the
  target device.

  On macOS, `brew install llvm` provides llvm-readelf but is keg-only, so add it
  to PATH:  export PATH="$(brew --prefix llvm)/bin:$PATH"
EOF
  exit 3
fi

hdr=$("$READELF" -h "$ART" 2>/dev/null)
if [[ -z $hdr ]]; then
  err "not an ELF file (or unreadable). A cross-build must produce ELF for a Linux target."
  printf '\nRESULT: FAIL\n'
  exit 1
fi

# ── 1. architecture ──────────────────────────────────────────────────────────
machine=$(printf '%s' "$hdr" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*\(.*\)$/\1/p' | head -n1)
elfclass=$(printf '%s' "$hdr" | sed -n 's/^[[:space:]]*Class:[[:space:]]*\(.*\)$/\1/p' | head -n1)

# Map the target arch to the strings readelf prints. Substring matching keeps this
# working across readelf versions, which word things slightly differently
# ("Advanced Micro Devices X86-64" vs "AMD x86-64").
# From the shared table, so this cannot drift from mk/derive.mk's view of the same
# architectures. An unknown arch yields an empty string, which is reported as a WARNING
# below rather than as a silent pass.
_ARCH_TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arch-table.sh"
expect_machine=$("$_ARCH_TABLE" elf-machine "${TARGET_ARCH:-}" 2>/dev/null || true)

if [[ -z $expect_machine ]]; then
  # A skip here is dangerous, not neutral: an unrecognised TARGET_ARCH would silently
  # pass an x86-64 binary as fit for a loongarch64 board. Warn loudly so the gap is
  # visible, and so --strict (CI) refuses it.
  warn "architecture: cannot check — TARGET_ARCH='${TARGET_ARCH:-<empty>}' is not in this
        script's arch table, so the binary's '$machine' was NOT validated against it.
        Add one line to tools/arch-table.sh, or set TARGET_ARCH to a known value.
        Known: $("$_ARCH_TABLE" known 2>/dev/null)"
elif [[ $machine == *"$expect_machine"* ]]; then
  ok "architecture: $machine"
else
  err "architecture mismatch: binary is '$machine', target expects '$expect_machine' (TARGET_ARCH=$TARGET_ARCH).
        This binary cannot execute on the target at all ('Exec format error').
        Most likely TARGET_TRIPLE is wrong, or a native compiler was used for a
        cross target."
fi

# 32/64-bit consistency is implied by the machine check but worth reporting, since
# a 32-bit build for a 64-bit target is a distinct and common mistake.
case "$elfclass:$TARGET_ARCH" in
  ELF32:aarch64|ELF32:x86_64|ELF32:riscv64)
    err "ELF class is $elfclass but the target is 64-bit ($TARGET_ARCH)." ;;
  *) : ;;
esac

# ── 2. ELF interpreter (executables only) ────────────────────────────────────
# A shared library has no PT_INTERP, so its absence is correct and must not be
# reported as a problem.
# The presence of a PT_INTERP entry is itself the test for "is this an executable", so no
# separate ELF Type check is needed. There was one here — is_exec, computed from the header
# and then never read by anything. Dead code in a verifier is worse than dead code elsewhere:
# reading it, you count a check that is not being made.
interp=$("$READELF" -l "$ART" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\)\].*/\1/p' | head -n1)

if [[ -z $interp ]]; then
  skip "interpreter: none recorded (correct for a shared library)"
elif [[ -z ${TARGET_DYNAMIC_LINKER:-} ]]; then
  skip "interpreter: '$interp' (no TARGET_DYNAMIC_LINKER set, so nothing to compare)"
elif [[ $interp == "$TARGET_DYNAMIC_LINKER" ]]; then
  ok "interpreter: $interp"
else
  err "interpreter mismatch:
          binary wants : $interp
          target has   : $TARGET_DYNAMIC_LINKER
        On the target this fails as 'No such file or directory' when running a
        binary that visibly exists — the loader is what is missing, not the file.
        Fix by setting TARGET_DYNAMIC_LINKER in the target description (it is
        already set; the compiler is overriding it or the sysroot disagrees)."
fi

# ── 3. glibc symbol-version ceiling ──────────────────────────────────────────
# The check that catches the "built against a newer libc than the target has"
# class of bug — the one the original design's release-guessing made likely.
#
# Every glibc symbol a binary imports carries a version tag (GLIBC_2.17,
# GLIBC_2.38, ...). The binary can only run where the libc provides every tag it
# references. So: find the highest tag imported, compare against the target's libc
# version, and fail if it is higher.
if [[ ${TARGET_LIBC:-glibc} != glibc ]]; then
  skip "libc symbol versions: TARGET_LIBC=$TARGET_LIBC does not use symbol versioning"
elif [[ -z ${TARGET_LIBC_VERSION:-} ]]; then
  warn "libc symbol versions: TARGET_LIBC_VERSION is empty, so the most valuable
        check available is disabled. Run 'make probe TARGET=<name> SSH=user@host'
        and paste the reported value into the target description."
else
  # --dyn-syms lists dynamic symbols with their version tags in the form
  # "name@GLIBC_2.34". Extract every version and take the maximum.
  versions=$("$READELF" --dyn-syms "$ART" 2>/dev/null \
             | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -u)
  if [[ -z $versions ]]; then
    ok "libc symbol versions: none imported (static, or no glibc dependency)"
  else
    highest=$(printf '%s\n' "$versions" | sort -V | tail -n1)
    # sort -V puts the greater version last; if the target's version sorts last
    # then the target is >= what the binary needs, which is what we require.
    max_of_both=$(printf '%s\n%s\n' "$highest" "$TARGET_LIBC_VERSION" | sort -V | tail -n1)
    if [[ $highest == "$TARGET_LIBC_VERSION" || $max_of_both == "$TARGET_LIBC_VERSION" ]]; then
      ok "libc symbol versions: needs at most GLIBC_$highest, target has $TARGET_LIBC_VERSION"
    else
      err "libc too new: this binary imports GLIBC_$highest but the target has glibc $TARGET_LIBC_VERSION.
        On the target this fails at load time with
            version \`GLIBC_$highest' not found
        The sysroot you built against is newer than the target. Either rebuild the
        sysroot from the actual target (SYSROOT_PROVIDER=ssh-rsync), or if the
        sysroot is right, correct TARGET_LIBC_VERSION.
        All versions imported: $(printf '%s ' $versions)"
    fi
  fi
fi

# ── 4. C++ ABI ceilings ──────────────────────────────────────────────────────
#
# libstdc++ versions its symbols in TWO independent namespaces, and a binary can exceed
# either one:
#     GLIBCXX_3.4.NN   the library's own interface
#     CXXABI_1.3.NN    the Itanium C++ ABI runtime (typeinfo, __cxa_*, guard variables)
# They advance on different schedules, so knowing one tells you nothing about the other.
# This check previously looked only for GLIBCXX_. Measured on a real aarch64 device: it
# provides GLIBCXX_3.4.32 and CXXABI_1.3.14, while two artifacts being shipped to it require
# CXXABI_1.3.9 and CXXABI_1.3.13. Both fit today, and nothing was
# watching the axis. A build against a newer sysroot that pulled in CXXABI_1.3.15 would
# have verified clean and then failed on the board with
#     version `CXXABI_1.3.15' not found
# which is precisely the failure the GLIBCXX_ half exists to prevent.
#
# TARGET_CXXABI_MAX therefore holds one ceiling per namespace, space-separated, each tag
# naming the namespace it belongs to:
#     TARGET_CXXABI_MAX=GLIBCXX_3.4.32 CXXABI_1.3.14
# A value carrying only GLIBCXX_ still means exactly what it always meant, so existing
# descriptions keep working and simply leave the second axis unchecked — reported as such,
# because "not stated" and "checked" must not look alike.
if [[ -z ${TARGET_CXXABI_MAX:-} ]]; then
  # An unset ceiling is only harmless if this artifact does not actually depend on libstdc++.
  # If it DOES import GLIBCXX_/CXXABI_ symbols, the check that would have caught a too-new one
  # is silently off — the exact silent gap this tool exists to prevent. A probe of a target
  # without binutils leaves the ceiling blank (probe-target.sh warns about it), so this is a
  # real, reachable state, not a hypothetical. Distinguish the two: a note when there is
  # nothing to check, a WARNING when there is and it wasn't.
  _imports_cxx=$("$READELF" --dyn-syms "$ART" 2>/dev/null \
                 | grep -oE '(GLIBCXX|CXXABI)_[0-9][0-9.]*' | sort -u)
  if [[ -z $_imports_cxx ]]; then
    skip "libstdc++ ABI: no TARGET_CXXABI_MAX set, and this artifact imports no libstdc++ symbols"
  else
    warn "libstdc++ ABI NOT CHECKED: this artifact imports $(printf '%s ' $_imports_cxx)but
        TARGET_CXXABI_MAX is empty, so the ceiling check is DISABLED. If the sysroot you built
        against is not the target's own libraries, a too-new symbol can reach the device
        undetected. Set TARGET_CXXABI_MAX in the target description (re-probe a target that has
        binutils, or read it by hand). This is a warning; --strict makes it fail."
  fi
else
  _seen_ns=""
  for ceiling in $TARGET_CXXABI_MAX; do
    ns=${ceiling%%_*}_          # GLIBCXX_ or CXXABI_
    _seen_ns="$_seen_ns$ns "
    cxxvers=$("$READELF" --dyn-syms "$ART" 2>/dev/null \
              | grep -o "${ns}[0-9][0-9.]*" | sort -u)
    if [[ -z $cxxvers ]]; then
      ok "libstdc++ ABI (${ns%_}): no dynamic dependency on it (static or C-only)"
      continue
    fi
    highest=$(printf '%s\n' "$cxxvers" | sort -V | tail -n1)
    max_of_both=$(printf '%s\n%s\n' "$highest" "$ceiling" | sort -V | tail -n1)
    if [[ $highest == "$ceiling" || $max_of_both == "$ceiling" ]]; then
      ok "libstdc++ ABI: needs at most $highest, target has $ceiling"
    else
      err "libstdc++ too new: needs $highest but the target has $ceiling.
        Fails on the target as: version \`$highest' not found.
        Options: ship libstdc++.so.6 in the bundle (with TARGET_RPATH=\$\$ORIGIN),
        set COMPONENT_STATIC_CXX=yes for a leaf artifact, or build against a
        sysroot whose libstdc++ matches the target."
    fi
  done
  # Name an unstated axis rather than passing over it in silence. The artifact may well
  # reference it; we simply have no number to compare against.
  for ns in GLIBCXX_ CXXABI_; do
    case $_seen_ns in *"$ns "*) continue ;; esac
    # NOT `| grep -q`. With `set -o pipefail` a quiet grep exits as soon as it matches and
    # closes the pipe, the producer dies of SIGPIPE, and the PIPELINE's status becomes 141 —
    # so a successful match reads as a failure. It only bites when the producer is still
    # writing, which makes it depend on how much the reader printed: measured here as a
    # 19-line match that the `if` treated as no match at all. Capturing the output makes the
    # exit status irrelevant and the test is on the text.
    if [[ -n $("$READELF" --dyn-syms "$ART" 2>/dev/null | grep -o "${ns}[0-9]" | head -n1) ]]; then
      warn "libstdc++ ABI: this artifact references ${ns%_} versions, but
        TARGET_CXXABI_MAX states no ${ns%_} ceiling, so that axis was NOT checked.
        Add one — 'make probe' reports both."
    fi
  done
fi

# ── 5. host paths leaked into the binary ─────────────────────────────────────
# A build-host path in RPATH is a real portability bug and an information leak. It
# happens easily: a stray -Wl,-rpath, a cmake project that adds its build tree, or
# CMAKE_BUILD_WITH_INSTALL_RPATH left off.
#
# The consequence is subtle. On the target the path does not exist so it is
# skipped, and the library is usually found anyway by another means — until the day
# it is not, and then the error names a directory from someone's laptop.
#
# Two expressions rather than one with '\(UN\)\?'. That optional-group syntax is a GNU BRE
# extension: BSD sed reads '\?' as a literal '?', so the pattern matched neither (RPATH)
# nor (RUNPATH) and this variable came back EMPTY on any BSD userland. Every check in this
# section — the empty-entry hazard, the leaked-host-path warning, the mangled-$ORIGIN
# detector — then had nothing to look at, and the verifier printed "RPATH: none set" for a
# binary with an RPATH. A fail-open in the ELF path, reachable from any Mac or BSD host
# cross-building for Linux.
_rpath_raw=$("$READELF" -d "$ART" 2>/dev/null \
             | sed -n -e 's/.*(RPATH).*\[\(.*\)\]/\1/p' \
                      -e 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')

# An EMPTY entry in the RPATH list means "search the current working directory". That
# is a genuine hazard: the program picks up whatever happens to be in the directory it
# was started from. It is easy to introduce (a trailing/leading colon, or a quoting
# accident in a generated toolchain file) and impossible to see in a normal reading of
# the value. Detect it BEFORE stripping empties for display — an earlier version of
# this script deleted them with sed '/^$/d' and therefore reported a binary with
# rpath [:$ORIGIN] as "ok".
if [[ -n $_rpath_raw ]]; then
  # Test the three shapes that yield an empty entry, and ONLY those:
  #   leading  ":foo"      an empty first entry
  #   trailing "foo:"      an empty last entry
  #   interior "foo::bar"  an empty middle entry
  # Wrapping the value in colons before matching (an earlier attempt) is wrong: it
  # turns every single-entry RPATH into ":foo:" and reports a false positive on every
  # correctly-built binary.
  if [[ $_rpath_raw == :* || $_rpath_raw == *: || $_rpath_raw == *::* ]]; then
    err "RPATH contains an EMPTY entry: '[$_rpath_raw]'
        An empty entry means 'search the current working directory', so this binary
        loads libraries from wherever it happens to be started. Usually caused by a
        stray leading/trailing ':' or by quotes being lost while flags were assembled."
  fi
fi

rpaths=$(printf '%s' "$_rpath_raw" | tr ':' '\n' | sed '/^$/d')
if [[ -z $rpaths ]]; then
  ok "RPATH: none set"
else
  leaked=""
  while read -r rp; do
    # 'RIGIN' (or similar) is the fingerprint of a single-'$' mistake in a description:
    # Make expanded '$O' to nothing. The result is a plausible-looking relative path
    # that resolves to nothing on the target.
    # Match the mangled form only: 'RIGIN' or a path ending '/RIGIN'. A plain
    # '*RIGIN' glob also matches the CORRECT '$ORIGIN', which would warn on every
    # properly-built binary — a false positive that trains people to ignore warnings.
    case $rp in
      RIGIN|*/RIGIN) warn "RPATH entry '$rp' looks like a mangled \$ORIGIN.
        A single '\$' in a description is expanded by Make ('\$O' -> nothing), leaving
        'RIGIN'. Write \$\$ORIGIN in the target description." ;;
    esac
    # $ORIGIN-relative entries are the correct, portable form and are what
    # TARGET_RPATH produces.
    [[ $rp == *'$ORIGIN'* ]] && continue
    # Anything absolute that is not a normal system directory is suspect.
    case $rp in
      /lib|/lib64|/usr/lib|/usr/lib64|/usr/local/lib) continue ;;
      /*) leaked+="$rp " ;;
    esac
  done <<< "$rpaths"
  if [[ -n $leaked ]]; then
    warn "RPATH contains absolute build-host path(s): $leaked
        These do not exist on the target. Portable form is \$ORIGIN, which is what
        TARGET_RPATH sets. Check for a stray -Wl,-rpath in COMPONENT_LDFLAGS, or a
        cmake project that adds its build tree (set CMAKE_BUILD_WITH_INSTALL_RPATH)."
  else
    ok "RPATH: $(printf '%s ' $rpaths)"
  fi
fi

# ── 6. what it needs at runtime ──────────────────────────────────────────────
# Informational, but the most useful single line for planning a bundle: every
# NEEDED entry must be satisfiable on the target, from the bundle or from the
# target's own libraries.
needed=$("$READELF" -d "$ART" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
if [[ -n $needed ]]; then
  printf '  info  needs: %s\n' "$(printf '%s ' $needed)"
fi

# ── the project's own symbols, left undefined ─────────────────────────────────
# A component that omits one of its own sources still links: a shared object may leave any
# symbol undefined and hope the loader finds it. So this used to pass a library whose
# session constructor was simply missing, and the failure appeared at dlopen on another
# machine instead.
#
# Undefined system symbols are ordinary. Undefined symbols in the project's OWN namespace
# are only legitimate when a sibling library provides them — which is what the hwhs backend
# does with its session — so the test is not "are there undefined project symbols" but
# "are there any, with no library OF THIS PROJECT to satisfy them".
#
# The membership test asks whether a DT_NEEDED entry is one of ours, rather than whether it
# is absent from a list of system libraries. Allowlisting system libraries looks equivalent
# and is not: hipcc always links libamdhip64, which no such list would name, so every
# HIP-linked artifact counted as having a sibling and nothing was ever reported.
_undef=$("$READELF" --dyn-syms "$ART" 2>/dev/null \
         | awk '$7 == "UND" { print $8 }' | grep -E '^_Z.*[0-9]catalyst' | sort -u)
if [[ -n $_undef ]]; then
  _sibling=""
  for _n in $needed; do
    case $_n in
      # This project's own libraries, by the prefixes its components produce. A vtable or
      # typeinfo left to a sibling is normal; left to libc is not.
      libcatalyst_*|librt_*|librtd_*|libsteane_*|libecho_*|libhwhs_*|libfpga_*|libgpu_*|\
      libtransport_*|libgreet*|libumm*)
        _sibling="$_sibling $_n" ;;
    esac
  done
  _n_undef=$(printf '%s\n' "$_undef" | wc -l | tr -d ' ')
  if [[ -n $_sibling ]]; then
    printf '  info  %s undefined project symbol(s), expected from:%s\n' "$_n_undef" "$_sibling"
  else
    warn "leaves $_n_undef symbol(s) of this project undefined, and needs no library of this
        project that could provide them. The first is:
          $(printf '%s\n' "$_undef" | head -1)
        A component that omits one of its own sources links exactly like this and then fails
        at dlopen. Check COMPONENT_SOURCES against the upstream build, and COMPONENT_DEPENDS
        if a sibling is meant to provide them."
  fi
fi

soname=$("$READELF" -d "$ART" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
if [[ -n $soname ]]; then
  base=$(basename "$ART")
  if [[ $soname == "$base" ]]; then
    ok "SONAME: $soname"
  else
    warn "SONAME is '$soname' but the file is named '$base'.
        Anything linking against this will record '$soname' and look for that name
        at runtime, so the file must be deployed under it (or symlinked)."
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────
verdict
