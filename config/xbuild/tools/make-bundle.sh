#!/usr/bin/env bash
#
# make-bundle.sh — gather built artifacts into a deployable directory, verify each
# one against the target, and generate a deploy script.
#
# WHY THIS IS DATA-DRIVEN
# The obvious alternative is one bundling script per machine, each holding an array
# of relative paths like
#   "libs/<component>/build/<target>/lib<name>.so"
# Every such path encodes four separate things at once — the component's directory,
# the build-dir convention, the target's name and the output filename — so adding a
# machine means writing a new script, and renaming a build directory means editing
# every script that exists.
#
# Here there is one gatherer, and the per-machine part is a data file.
#
# WHAT IT ADDS
# Three things the originals did not do, each of which turns a deploy-time surprise
# into a build-time message:
#   1. Verifies every artifact against the target's ABI before bundling it.
#   2. Cross-checks that each artifact's NEEDED libraries are either in the bundle
#      or expected from the target, and lists the ones that are neither.
#   3. Writes a receipt recording exactly what went in and how it was built.
#
# USAGE
#   make-bundle.sh <root-dir> <target-name> <bundle-name>
#
# Invoked by `make bundle TARGET=… BUNDLE=…`.

set -uo pipefail

ROOT=${1:?usage: make-bundle.sh <root> <target> <bundle> [triple]}
TARGET=${2:?usage: make-bundle.sh <root> <target> <bundle> [triple]}
BUNDLE=${3:?usage: make-bundle.sh <root> <target> <bundle> [triple]}
# The RESOLVED triple from Make. A native target may leave TARGET_TRIPLE blank in
# its description (derive.mk fills it from the host compiler), so re-reading the
# file here would give an empty value and the sysroot library search below would
# look in the wrong directories.
TRIPLE_ARG=${4:-}
# The RESOLVED rpath token, for the same reason as the triple. TARGET_RPATH is legitimately
# blank in a portable description — derive.mk fills it with $$ORIGIN for ELF and
# @loader_path for Mach-O — so reading the file here got an empty value, and the deploy
# script and receipt then fell back to a hardcoded $ORIGIN. That told a macOS user their
# bundle relied on a token their loader does not implement.
RPATH_ARG=${5:-}
# The RESOLVED sysroot, for the third time and the same reason. SYSROOT_DIR is usually absent
# from a description — derive.mk defaults it to build/sysroots/<target> — but it can be set
# there, or overridden on the command line to build against a sysroot somebody else fetched.
# Re-deriving the default here meant two things went wrong quietly: BUNDLE_SYSROOT_LIBS
# searched a directory that was not the one compiled against, so a library that exists was
# reported missing; and BUNDLE-RECEIPT.txt recorded a sysroot path that had not been used —
# in the one file whose entire purpose is to say what went into the bundle.
SYSROOT_ARG=${6:-}

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

TARGET_CONF="$ROOT/targets/$TARGET.conf"
BUNDLE_CONF="$ROOT/bundles/$BUNDLE.conf"
[[ -r $TARGET_CONF ]] || die "no such target '$TARGET' (expected $TARGET_CONF).
       Available: $(cd "$ROOT/targets" && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')"
[[ -r $BUNDLE_CONF ]] || die "no such bundle '$BUNDLE' (expected $BUNDLE_CONF).
       Available: $(cd "$ROOT/bundles" && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')"

# Read both descriptions through load_conf, never by sourcing the .conf directly.
# BUNDLE_COMPONENTS is a multi-word value, and sourcing raw would execute its second
# word as a command and silently keep only the first — quietly bundling one file
# where three were asked for. See tools/load-conf.sh.
# shellcheck source=/dev/null
. "$ROOT/tools/load-conf.sh"

TARGET_NAME="" TARGET_DEPLOY_DIR="" TARGET_TRIPLE="" TARGET_ARCH=""
TARGET_RPATH="" SYSROOT_DIR="" TARGET_LIBC_VERSION="" TARGET_STRIP=""
load_conf "$TARGET_CONF" || exit 1

BUNDLE_NAME="" BUNDLE_DESC="" BUNDLE_COMPONENTS="" BUNDLE_OPTIONAL_COMPONENTS=""
BUNDLE_SYSROOT_LIBS="" BUNDLE_EXTRA_FILES="" BUNDLE_STRIP=no BUNDLE_README=""
load_conf "$BUNDLE_CONF" || exit 1

if [[ -n $TRIPLE_ARG ]]; then TARGET_TRIPLE=$TRIPLE_ARG; fi
# After load_conf, so the resolved values win over the description's blanks.
if [[ -n $RPATH_ARG ]]; then TARGET_RPATH=$RPATH_ARG; fi
if [[ -n $SYSROOT_ARG ]]; then SYSROOT_DIR=$SYSROOT_ARG; fi
if [[ -z ${TARGET_TRIPLE:-} ]]; then
  TARGET_TRIPLE=$("$ROOT/tools/detect-host.sh" triple 2>/dev/null || echo "")
fi

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

# TARGET_RPATH is written as $$ORIGIN in the description, because Make needs the
# doubled '$' to emit a literal one. Shell does not, so un-double it for display and
# for the generated deploy script. Without this, human-facing output reads
# "$$ORIGIN", which looks like a bug in the build system and invites someone to
# "fix" a value that is correct.
TARGET_RPATH_DISPLAY=${TARGET_RPATH//\$\$/\$}

# A second form, for EMBEDDING in the generated deploy script rather than printing here. That
# script is written from an expanding heredoc, so a literal '$' passed through unescaped
# becomes a variable reference in the OUTPUT — and deploy.sh runs with 'set -eu', so it copied
# the bundle successfully and then died with "ORIGIN: parameter not set". The failure landed
# after the useful work, which is the most confusing place for one to land.
TARGET_RPATH_EMBED=${TARGET_RPATH_DISPLAY//\$/\\\$}
COMPONENTS_DIR="$BUILD_DIR/$TARGET/components"
DEST="$BUILD_DIR/$TARGET/bundles/$BUNDLE"
: "${SYSROOT_DIR:=$BUILD_DIR/sysroots/$TARGET}"
: "${TARGET_DEPLOY_DIR:=/tmp/$TARGET}"

rm -rf "$DEST"
mkdir -p "$DEST" || die "cannot create $DEST"

log ""
log "bundling '$BUNDLE' for target '$TARGET'"
log "  -> $DEST"
log ""

# ── gather components ────────────────────────────────────────────────────────
gathered=()
missing_required=()
skipped_optional=()
built_with=""        # "<artifact>|<compiler path>|<version>" per line, stamped at BUILD time
unresolved_deps=""   # NEEDED libraries found in neither the bundle nor the sysroot

gather_one() {
  local name=$1 required=$2
  local out src
  out=$("$ROOT/tools/component-output.sh" "$ROOT" "$name" 2>/dev/null) || {
    [[ $required == yes ]] && missing_required+=("$name (no such component)")
    return 1
  }
  src="$COMPONENTS_DIR/$name/$out"
  if [[ ! -e $src ]]; then
    if [[ $required == yes ]]; then
      missing_required+=("$name -> $out")
    else
      skipped_optional+=("$name")
    fi
    return 1
  fi
  cp -f "$src" "$DEST/$out" || die "cannot copy $src"
  gathered+=("$out")
  # Collect the compiler that actually BUILT this artifact, stamped beside it at build time
  # (mk/rules.mk:_STAMP_COMPILER). Bundling copies rather than builds, so asking the current
  # environment would answer a different question — see the receipt section below.
  if [[ -r "$COMPONENTS_DIR/$name/.crossbuild-built-with" ]]; then
    _bw=$(sed -n 's/^version=//p' "$COMPONENTS_DIR/$name/.crossbuild-built-with" 2>/dev/null)
    _bp=$(sed -n 's/^compiler=//p' "$COMPONENTS_DIR/$name/.crossbuild-built-with" 2>/dev/null)
    _bl=$(sed -n 's/^linker_bin=//p' "$COMPONENTS_DIR/$name/.crossbuild-built-with" 2>/dev/null)
    [[ -n $_bp ]] && built_with="$built_with$out|$_bp|$_bw|$_bl"$'\n'
  else
    built_with="$built_with$out|(not recorded — built before this was stamped, or by hand)||"$'\n'
  fi
  printf '  added     %s\n' "$out"
  return 0
}

for c in $BUNDLE_COMPONENTS;          do gather_one "$c" yes || true; done
for c in $BUNDLE_OPTIONAL_COMPONENTS; do gather_one "$c" no  || true; done

if [[ ${#missing_required[@]} -gt 0 ]]; then
  log ""
  die "required component(s) not built:
$(printf '         %s\n' ${missing_required[@]+"${missing_required[@]}"})

  Build them first — name them, one per line, do NOT build everything:
$(for _m in ${missing_required[@]+"${missing_required[@]}"}; do printf '         make build TARGET=%s COMPONENT=%s\n' "$TARGET" "${_m%% *}"; done)
  This script only gathers; it never builds, so that a bundle always reflects a
  build you actually ran rather than triggering a silent one. A bare
  'make build TARGET=$TARGET' with no COMPONENT= builds every described component,
  including ones that need a cross-built LLVM you may not have, and fails as a whole."
fi

for s in ${skipped_optional[@]+"${skipped_optional[@]}"}; do
  printf '  skipped   %s (optional, not built)\n' "$s"
done

# ── copy runtime libraries out of the SYSROOT ────────────────────────────────
# From the sysroot, never the build host: the point is to ship the library the
# artifacts were linked against.
for lib in $BUNDLE_SYSROOT_LIBS; do
  found=""
  # Follow the symlink chain to the real file, then install it under the SONAME
  # the binaries actually reference. Copying the symlink itself would produce a
  # dangling link in the bundle.
  for d in "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE" "$SYSROOT_DIR/usr/lib64" \
           "$SYSROOT_DIR/usr/lib" "$SYSROOT_DIR/lib/$TARGET_TRIPLE" \
           "$SYSROOT_DIR/lib64" "$SYSROOT_DIR/lib"; do
    if [[ -e "$d/$lib" ]]; then
      found=$(readlink -f "$d/$lib" 2>/dev/null || echo "$d/$lib")
      break
    fi
  done
  if [[ -z $found ]]; then
    log "  WARNING   $lib requested by BUNDLE_SYSROOT_LIBS but not found in the sysroot"
    log "            searched under $SYSROOT_DIR. Check the name, or remove it."
    continue
  fi
  cp -fL "$found" "$DEST/$lib" || die "cannot copy $found"
  gathered+=("$lib")
  printf '  added     %s (from sysroot: %s)\n' "$lib" "${found#"$SYSROOT_DIR"}"
done

# ── extra files ──────────────────────────────────────────────────────────────
for spec in $BUNDLE_EXTRA_FILES; do
  src=${spec%%:*}
  dst=${spec##*:}
  [[ $src == "$spec" ]] && dst=$(basename "$src")
  # Allow paths relative to the tree root, which is the natural way to write them.
  [[ $src != /* ]] && src="$ROOT/$src"
  [[ -e $src ]] || die "BUNDLE_EXTRA_FILES: no such file '$src'"
  # Create the destination subdirectory if the spec asks for one (src:sub/dir/name).
  # Without this, cp fails with a bare "No such file or directory" naming the whole
  # path, which reads as though the SOURCE were missing.
  mkdir -p "$(dirname "$DEST/$dst")" || die "cannot create directory for '$dst'"
  cp -f "$src" "$DEST/$dst" || die "cannot copy $src"
  printf '  added     %s (extra)\n' "$dst"
done

[[ -n $BUNDLE_README && -r $ROOT/$BUNDLE_README ]] && cp -f "$ROOT/$BUNDLE_README" "$DEST/README.md"

# ── strip ────────────────────────────────────────────────────────────────────
# Done AFTER gathering and BEFORE verification, so what we verify is what deploys.
# Stripping first and verifying second is the only correct order: verifying the
# unstripped file and shipping the stripped one means the check did not cover the
# artifact you deployed.
if [[ $BUNDLE_STRIP == yes ]]; then
  STRIP_BIN=""
  # TARGET_STRIP is DERIVED in mk/derive.mk, not a description key, so it arrives via
  # the environment (the Makefile exports it). Falling back to the generic names keeps
  # this working when the script is run by hand.
  for s in "${TARGET_STRIP:-}" llvm-strip strip; do
    [[ -n $s ]] && command -v "$s" >/dev/null 2>&1 && { STRIP_BIN=$s; break; }
  done
  if [[ -n $STRIP_BIN ]]; then
    log ""
    for f in ${gathered[@]+"${gathered[@]}"}; do
      # --strip-unneeded keeps the dynamic symbol table, which a shared library
      # needs to be linkable and dlopen-able. Plain --strip-all on a .so removes
      # symbols the loader requires.
      "$STRIP_BIN" --strip-unneeded "$DEST/$f" 2>/dev/null \
        && printf '  stripped  %s\n' "$f" \
        || log "  WARNING   could not strip $f"
    done
  else
    log "  WARNING   BUNDLE_STRIP=yes but no strip tool found; shipping unstripped"
  fi
fi

# ── nothing to ship is not a success ─────────────────────────────────────────
# Every check below is a loop over $gathered, and a loop over nothing passes. With a bundle
# whose components are all optional and none built, the verify loop ran zero times,
# verify_failed stayed 0, the dependency check reported "every needed library is in the
# bundle or in the sysroot" having examined nothing, and the run printed "bundle ready" and
# exited 0 — a receipt with an empty Contents and a deploy.sh that would scp itself to a
# board. No bundle in this tree can reach that state today (each has at least one required
# component, so the missing-required check fires first), which is exactly why it is worth
# guarding: it is one edited .conf away, and it fails by declaring success.
if [[ ${#gathered[@]} -eq 0 ]]; then
  die "bundle '$BUNDLE' gathered no artifacts, so there is nothing to verify or ship.
       Every component in it is optional and none of them is built. Build them first:
         make build TARGET=$TARGET COMPONENT=<name>
       or list what this bundle expects with:
         make show-bundle TARGET=$TARGET BUNDLE=$BUNDLE"
fi

# ── verify every artifact ────────────────────────────────────────────────────
log ""
log "verifying artifacts against target '$TARGET'"
verify_failed=0
for f in ${gathered[@]+"${gathered[@]}"}; do
  # Pass the RESOLVED triple through. Without it the verifier re-reads the description
  # and sees the blank a native target legitimately leaves there, which disables its
  # architecture check and leaves it unable to tell which binary format was wanted.
  # STRICT= is forwarded so warnings can fail a BUNDLE, not only a bare `make verify`.
  # Without it "architecture: cannot check" — the case where the artifact's architecture was
  # never validated at all — counted as ok(1 warn) and the run still printed "bundle ready".
  if ! "$ROOT/tools/verify-artifact.sh" "$DEST/$f" --target-conf "$TARGET_CONF" \
       ${STRICT:+--strict} \
       ${TRIPLE_ARG:+--triple "$TRIPLE_ARG"} >"$DEST/.verify-$f.log" 2>&1; then
    verify_failed=1
    printf '  FAIL      %s\n' "$f"
    sed 's/^/            /' "$DEST/.verify-$f.log"
  else
    # grep -c prints 0 and exits 1 when there are no matches, so the `|| echo 0`
    # idiom appends a SECOND line and the arithmetic test then sees "0\n0".
    # Counting lines from grep's stdout avoids the exit-status branch entirely.
    warns=$(grep '^  WARN' "$DEST/.verify-$f.log" 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${warns:-0} -gt 0 ]]; then
      printf '  ok(%s warn) %s\n' "$warns" "$f"
      grep '^  WARN' "$DEST/.verify-$f.log" | sed 's/^/          /'
    else
      printf '  ok        %s\n' "$f"
    fi
  fi
  rm -f "$DEST/.verify-$f.log"
done

# ── dependency cross-check ───────────────────────────────────────────────────
# For each artifact, list what it needs at load time and say where that will come
# from. This is the single most useful output of the whole bundling step, because an
# unsatisfied NEEDED entry is the most common reason a bundle that "looks right"
# fails on the target.
log ""
log "runtime dependency check"

# Which reader can answer "what does this need"? The question is the same for both
# formats; the tool and the spelling of the answer are not. Skipping the check entirely
# on a Mach-O host — which is what happened while this only knew readelf — turned the
# most useful output of the bundling step off on a whole class of build machine.
BINFMT=$("$ROOT/tools/arch-table.sh" binfmt "${TRIPLE_ARG:-${TARGET_TRIPLE:-}}" 2>/dev/null || echo elf)
READER=""
if [[ $BINFMT == macho ]]; then
  command -v otool >/dev/null 2>&1 && READER=otool
else
  for r in "${TARGET_READELF:-}" llvm-readelf readelf; do
    [[ -n $r ]] && command -v "$r" >/dev/null 2>&1 && { READER=$r; break; }
  done
fi

# Prints one dependency per line, as the name the loader will look for.
needed_of() {
  local file=$1
  if [[ $BINFMT == macho ]]; then
    # otool -L prints the artifact's own path first, then one tab-indented line per
    # dependency with trailing version information to drop.
    otool -L "$file" 2>/dev/null | sed -n 's/^[[:space:]]\{1,\}\([^ ]*\).*/\1/p'
  else
    "$READER" -d "$file" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
  fi
}

declare -a unresolved=()
if [[ -n $READER ]]; then
  for f in ${gathered[@]+"${gathered[@]}"}; do
    needed=$(needed_of "$DEST/$f")
    for n in $needed; do
      # A Mach-O dependency carries its search rule in the name. @rpath, @loader_path and
      # @executable_path all resolve next to the artifact for a bundle built by this tree,
      # so what matters is whether the basename is IN the bundle. An ELF NEEDED entry is a
      # bare soname, so the same basename test covers both.
      base=${n##*/}
      if [[ -e "$DEST/$base" ]]; then
        continue                      # satisfied from inside the bundle
      fi
      # Libraries the operating system always provides. On Darwin these have no files on
      # disk to find — they live in the dyld shared cache — so a path test would report
      # libSystem as missing on every Mac.
      if [[ $BINFMT == macho ]]; then
        case $n in
          /usr/lib/*|/System/Library/*) continue ;;
        esac
      fi
      # Present in the sysroot means the target has it, so it will resolve there.
      insysroot=0
      for d in "$SYSROOT_DIR/usr/lib/$TARGET_TRIPLE" "$SYSROOT_DIR/usr/lib64" \
               "$SYSROOT_DIR/usr/lib" "$SYSROOT_DIR/lib/$TARGET_TRIPLE" \
               "$SYSROOT_DIR/lib64" "$SYSROOT_DIR/lib"; do
        [[ -e "$d/$base" ]] && { insysroot=1; break; }
      done
      if [[ $insysroot -eq 0 ]]; then
        unresolved+=("$f needs $n")
      fi
    done
  done

  if [[ ${#unresolved[@]} -eq 0 ]]; then
    # "in the sysroot", not "on the target" — those are the same claim only when the
    # sysroot was copied off the target itself. It often is not: a distribution sysroot is
    # an APPROXIMATION, and a library can be present there because somebody added it to the
    # package list while the real machine has never had it. Saying "on the target" turned an
    # assumption into a reassurance, in the one message whose job is to stop a bundle that
    # loads on the build host and fails on the device.
    log "  ok        every needed library is in the bundle or in the sysroot"
    log "            (a library resolved from the sysroot is ASSUMED present on the target;"
    log "             that assumption is only as good as where the sysroot came from)"
  else
    log "  WARNING   these dependencies are in neither the bundle nor the sysroot:"
    printf '            %s\n' ${unresolved[@]+"${unresolved[@]}"}
    log "            They will fail to load on the target unless it happens to have"
    log "            them. Add the component to BUNDLE_COMPONENTS, or the library to"
    log "            BUNDLE_SYSROOT_LIBS."
    # Remembered, because the generated deploy script used to state the exact opposite in
    # the same run — "no library-path variable is needed" — and that script is what travels
    # with the bundle. Of the two files written seconds apart, the reassuring one is the one
    # the operator reads on the far end.
    unresolved_deps="${unresolved[*]}"
  fi
elif [[ $BINFMT == macho ]]; then
  log "  --        otool not found; skipped (xcode-select --install provides it)"
else
  log "  --        no readelf available; skipped"
fi

# Which gathered artifact, if any, can actually be RUN. The closing hint in the generated
# deploy script used to name the first entry unconditionally, so a bundle of three shared
# libraries told the reader to execute
#     ./libsomething.so
# — advice that produces a permission error, on a bundle that is entirely correct. Judged by
# name because that is enough here: an output is either lib<x>.so / .dylib or a plain
# executable name, and guessing wrong only costs the hint, never the bundle.
first_exe=""
for f in ${gathered[@]+"${gathered[@]}"}; do
  case $f in
    *.so|*.so.*|*.dylib|*.a) continue ;;
    *) first_exe=$f; break ;;
  esac
done

# ── verification failure marker ──────────────────────────────────────────────
# A failed verification used to exist only as an exit code and some scrollback: deploy.sh and
# the receipt were both written BEFORE the die below, neither recorded the failure, and
# `make deploy` re-checks nothing. So the directory left on disk was a complete, working,
# self-describing deployable bundle that had failed the check whose entire purpose is to stop
# it reaching a board. A second terminal, a CI step that ignores exit status, or anyone who
# runs ./deploy.sh directly would ship it.
#
# The artifacts are still left in place — inspecting them is exactly what you want to do
# next. What is closed is the deploy path.
if [[ $verify_failed -ne 0 ]]; then
  {
    echo "This bundle FAILED artifact verification when it was assembled."
    echo "target: $TARGET   bundle: $BUNDLE"
    echo
    echo "Do not deploy it. Re-run to see the failures:"
    echo "    make bundle TARGET=$TARGET BUNDLE=$BUNDLE"
    echo
    echo "Delete this file only if you intend to ship something that did not verify."
  } > "$DEST/VERIFICATION-FAILED.txt"
  printf '  added     VERIFICATION-FAILED.txt\n'
fi

# ── deploy script ────────────────────────────────────────────────────────────
# Generated, so it can never disagree with the file list or the deploy directory.
cat > "$DEST/deploy.sh" <<DEPLOY
#!/usr/bin/env sh
# GENERATED by make-bundle.sh — do not edit; regenerate with
#   make bundle TARGET=$TARGET BUNDLE=$BUNDLE
#
# Copies this bundle to the target and makes it runnable.
#
# Usage:  ./deploy.sh user@host [port]
set -eu

# Refuse if the bundle beside this script did not verify. This script travels with the
# bundle, so it must carry the refusal too — the exit code of the run that built it is long
# gone by the time anyone reads this.
if [ -f "\$(dirname "\$0")/VERIFICATION-FAILED.txt" ]; then
  echo "REFUSING: this bundle failed artifact verification when it was assembled." >&2
  echo >&2
  sed 's/^/  /' "\$(dirname "\$0")/VERIFICATION-FAILED.txt" >&2
  exit 1
fi

[ \$# -ge 1 ] || { echo "usage: \$0 user@host [port]" >&2; exit 2; }
HOST=\$1
PORT=\${2:-22}
DIR="$TARGET_DEPLOY_DIR"
SRC=\$(cd "\$(dirname "\$0")" && pwd)

echo "creating \$DIR on \$HOST"
ssh -p "\$PORT" "\$HOST" "mkdir -p '\$DIR'"

echo "copying \$(ls -1 "\$SRC" | wc -l | tr -d ' ') file(s)"   # everything here, including this script and the receipt
# -p preserves the executable bit; without it the executor arrives non-executable
# and the failure ("permission denied") looks like a target problem.
scp -p -P "\$PORT" "\$SRC"/* "\$HOST:\$DIR/"

echo
echo "deployed to \$HOST:\$DIR"
echo
echo "The artifacts were built with an rpath of '${TARGET_RPATH_EMBED:-<none>}', so libraries"
echo "resolve from beside the binaries and no library-path variable is needed."
$(if [[ -n ${unresolved_deps:-} ]]; then
     printf 'echo\n'
     printf 'echo "EXCEPT these, which are in neither the bundle nor the sysroot and will"\n'
     printf 'echo "fail to load unless the target happens to have them:"\n'
     printf 'echo "  %s"\n' "$unresolved_deps"
   fi)
echo
$(if [[ -n ${first_exe:-} ]]; then
     # $PORT/$HOST/$DIR are left UNESCAPED so deploy.sh expands them when it runs. They were
     # escaped, so this line printed a literal "ssh -p $PORT $HOST 'cd $DIR && ./greet-app'"
     # — the one line whose entire job is to be copied and pasted, and the only one where the
     # values are already known. (Command substitution output is not re-scanned by the
     # heredoc, so a bare $ here reaches the file intact.)
     printf 'echo "  ssh -p $PORT $HOST '"'"'cd $DIR && ./%s'"'"'"' "$first_exe"
   else
     printf 'echo "This bundle contains no executable — it is libraries for something else to load."'
   fi)
DEPLOY
chmod +x "$DEST/deploy.sh"
printf '  added     deploy.sh (generated)\n'

# ── receipt ──────────────────────────────────────────────────────────────────
# A record of what was built and how. Cheap to write, and it answers the question
# "is this bundle stale?" — which otherwise requires trusting a memory. Mixed
# vintages inside one bundle are a real hazard: an ABI change between two
# artifacts built weeks apart does not fail loudly, it returns wrong answers.
{
  echo "# Bundle receipt — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "bundle:        $BUNDLE"
  # The verification verdict belongs IN the receipt. It used to live only in the exit status
  # and the scrollback of the run that produced it, so a receipt could describe a bundle that
  # had failed the check whose job is to stop it from being shipped.
  if [[ $verify_failed -ne 0 ]]; then
    echo "!! VERIFICATION FAILED — DO NOT DEPLOY. See VERIFICATION-FAILED.txt !!"
    echo
  fi
  echo "description:   $BUNDLE_DESC"
  echo "target:        $TARGET  ($TARGET_TRIPLE)"
  echo "target libc:   ${TARGET_LIBC:-glibc} ${TARGET_LIBC_VERSION:-unspecified}"
  echo "deploy dir:    $TARGET_DEPLOY_DIR"
  echo "rpath:         ${TARGET_RPATH_DISPLAY:-none}"
  echo "sysroot:       $SYSROOT_DIR"
  echo "built on:      $(uname -srm) ($(hostname 2>/dev/null))"
  echo
  # WHICH COMPILER BUILT EACH ARTIFACT — read from the stamp written beside it at build time,
  # not resolved now. The documented fix for a missing readelf on macOS is
  # `export PATH="$(brew --prefix llvm)/bin:$PATH"`, and that one line also replaces the
  # compiler: Apple clang becomes Homebrew clang, same command, no warning. That is precisely
  # the swap this section exists to expose. An earlier version printed $TARGET_CXX as resolved
  # during BUNDLING — but bundling copies and never builds, so following the documented order
  # (build, hit the readelf error, export, bundle) recorded the compiler that did NOT build
  # the artifacts. The receipt reported a clean toolchain for a mixed one.
  echo "## Built with"
  _seen_compilers=""
  _seen_linkers=""
  while IFS='|' read -r _f _path _ver _lnk; do
    [[ -z $_f ]] && continue
    printf '  %-46s %s\n' "$_f" "${_ver:-$_path}"
    [[ -n $_lnk ]] && printf '  %-46s linked by %s\n' "" "$_lnk"
    case "$_seen_compilers" in *"[$_path]"*) ;; *) _seen_compilers="$_seen_compilers[$_path]" ;; esac
    [[ -n $_lnk ]] && case "$_seen_linkers" in *"[$_lnk]"*) ;; *) _seen_linkers="$_seen_linkers[$_lnk]" ;; esac
  done <<< "${built_with:-}"
  # More than one compiler — or one linker — across a bundle is the mixed-vintage hazard this
  # file warns about, made concrete. It does not fail the bundle (it may be deliberate) but it
  # is the first thing worth knowing when two artifacts disagree at run time. The linker is
  # tracked as well as the compiler because `-fuse-ld=lld` resolves `ld.lld` off PATH, so an
  # unrelated LLVM checkout can silently supply it.
  if [[ $(printf '%s' "$_seen_compilers" | tr -cd '[' | wc -c | tr -d ' ') -gt 1 ]]; then
    echo
    echo "  WARNING: these artifacts were not all built by the same compiler."
    echo "           Rebuild them together: make clean-target TARGET=$TARGET && make build ..."
  fi
  if [[ $(printf '%s' "$_seen_linkers" | tr -cd '[' | wc -c | tr -d ' ') -gt 1 ]]; then
    echo
    echo "  WARNING: these artifacts were not all linked by the same ld.lld binary."
    echo "           Check PATH order (an LLVM checkout can shadow the intended linker)."
  fi
  echo
  echo "## Contents"
  # SCOPE, stated. `deploy` copies into the target directory and does not empty it, so a
  # machine that has had two bundles deployed to it holds the union of both while each
  # receipt describes only its own half. Whoever reads this file on the far end has no other
  # way to know that, and the natural reading — "this lists what is in this directory" — is
  # then wrong.
  echo "  (what this bundle shipped. The deploy directory is not emptied first, so anything"
  echo "   an earlier bundle left there is still present and is not listed below.)"
  echo
  for f in ${gathered[@]+"${gathered[@]}"}; do
    size=$(wc -c < "$DEST/$f" | tr -d ' ')
    printf '  %-48s %10s bytes\n' "$f" "$size"
  done
  [[ ${#skipped_optional[@]} -gt 0 ]] && {
    echo
    echo "## Omitted (optional, not built)"
    printf '  %s\n' ${skipped_optional[@]+"${skipped_optional[@]}"}
  }
  echo
  echo "## Notes"
  echo "All artifacts in one bundle should come from the same build. A mix of"
  echo "vintages does not fail loudly — an ABI change between two artifacts built"
  echo "at different times produces wrong behaviour rather than an error. If in"
  echo "doubt, rebuild the whole bundle:"
  echo "    make clean-target TARGET=$TARGET && make bundle TARGET=$TARGET BUNDLE=$BUNDLE"
} > "$DEST/BUNDLE-RECEIPT.txt"
printf '  added     BUNDLE-RECEIPT.txt\n'

log ""
if [[ $verify_failed -ne 0 ]]; then
  die "bundle assembled at $DEST but one or more artifacts FAILED verification.
       Do not deploy it. The failures are listed above; each names the specific
       mismatch and how to fix it."
fi

# Re-emit the mixed-toolchain warnings to the TERMINAL, not just into the receipt. They live
# in BUNDLE-RECEIPT.txt (a mix of compilers or ld.lld binaries across one bundle is a
# wrong-answers-on-the-target hazard), but the receipt is a file, and the person most likely
# to produce a mixed set — swap toolchains mid-run, rebuild one library — is the least likely
# to open it. Left there alone, "bundle ready:" was the last word on screen and read as clean.
if grep -q '^  WARNING' "$DEST/BUNDLE-RECEIPT.txt" 2>/dev/null; then
  log ""
  grep '^  WARNING' "$DEST/BUNDLE-RECEIPT.txt" | while IFS= read -r _w; do log "$_w"; done
  log "  (details in BUNDLE-RECEIPT.txt under '## Built with')"
fi

log ""
log "bundle ready: $DEST"
log ""
log "deploy it:"
log "    make deploy TARGET=$TARGET BUNDLE=$BUNDLE SSH=user@host [PORT=22]"
