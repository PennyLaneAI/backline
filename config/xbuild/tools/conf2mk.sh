#!/usr/bin/env bash
#
# conf2mk.sh — turn a target description (targets/<name>.conf) into an includable
# Makefile fragment, validating it on the way through.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# The target files must be readable by two very different consumers:
#
#   * shell scripts  (sysroot providers, the verifier, the bundler) — they `source` it
#   * GNU Make       (the build engine)                             — it `include`s it
#
# A file cannot be both without help, because the two languages disagree about
# almost everything: Make expands `$X` where shell wants `$X` to survive, Make
# treats `#` inside a value as a comment, and shell tolerates `A=b c` while Make
# reads it as a variable named `A` with value `b c`.
#
# The alternative — maintaining the same facts in a .conf AND a .mk — is exactly
# the failure mode this redesign exists to remove. The old tree had a comment
# reading "KEEP IN SYNC" above two copies of the CPU flag. A comment asking a
# human to maintain an invariant is a latent bug with a politeness veneer.
#
# So: the .conf is the single source of truth, shell reads it directly, and this
# script mechanically derives the Make view. Derived files live under build/ and
# are never edited or committed.
#
# WHAT IT GUARANTEES
# ------------------
#   1. Syntax is strict KEY=value. Anything else is a hard error with a line number.
#   2. No command substitution, backticks, or shell metacharacters that would let a
#      .conf file execute code when sourced. A target description is data; if it
#      can run commands it is a program, and then it can also be a security problem.
#   3. Only keys documented in targets/SCHEMA.md are accepted. A typo like
#      TARGET_TRIPPLE= would otherwise sit there silently doing nothing, and you
#      would debug the resulting default for an hour.
#   4. `$ORIGIN` survives into Make correctly (as $$ORIGIN).
#
# TWO OUTPUT MODES
# ----------------
#   (default)  emit GNU Make assignments      -> build/generated/.../NAME.mk
#   --shell    emit POSIX shell assignments   -> build/generated/.../NAME.sh
#
# The --shell mode exists because shell tools MUST NOT source a .conf directly.
# A description may legitimately contain a multi-word value:
#
#     BUNDLE_COMPONENTS=app lib helper
#
# Make reads that correctly as three words. Shell reads it as "set
# BUNDLE_COMPONENTS=app, then RUN THE COMMAND lib with argument helper" — which
# fails with "lib: command not found" and, worse, leaves the variable holding only
# the first word. A description that is valid for one consumer must not be silently
# wrong for the other, so both views are generated from the one file and each is
# correct by construction.
#
# USAGE
#   tools/conf2mk.sh targets/foo.conf            > build/generated/targets/foo.mk
#   tools/conf2mk.sh --shell targets/foo.conf    > build/generated/targets/foo.sh
#   tools/conf2mk.sh --check build/generated/targets/foo.mk   # is that output whole?
#
# Every consumer runs --check on what it just generated. Checking the exit status alone
# is not sufficient; the block emitting the marker at the end of this file says why.

set -euo pipefail

die() { printf 'conf2mk: %s\n' "$*" >&2; exit 1; }

# The completion marker, written as the last line of every generated view and
# verified through `--check` below. Declared here, once: consumers ask this script
# whether its own output is whole instead of each grepping for a literal string, so
# the producer and the checker cannot drift apart. (See the block that emits it, at
# the end of this file, for why a marker is needed at all when the exit status is
# already checked.)
CONF2MK_COMPLETE='# conf2mk: complete'

# ── --check <generated-file> ──────────────────────────────────────────────────
# Answers one question: did a previous run of this script finish? Kept in this file
# because the marker's spelling and the test for it belong together.
if [[ ${1:-} == --check ]]; then
  shift
  [[ $# -eq 1 ]] || die "usage: conf2mk.sh --check <generated-file>"
  [[ -r $1 ]] || die "--check: cannot read '$1'"
  [[ $(tail -n 1 "$1") == "$CONF2MK_COMPLETE" ]] && exit 0
  cat >&2 <<EOF
conf2mk: generation stopped part-way through — '$1' is TRUNCATED.

  The settings that WERE written are valid; the ones after the point of failure are
  missing entirely, so they would silently fall back to their defaults. Any error
  printed above this line is the cause.

  This is checked separately from the exit status because a shell can abort in the
  middle of a file and still exit 0 — a bash expansion error does that, and is not
  caught by 'set -e'. Known trigger: running the build system with a bash older than
  4.2 (macOS ships 3.2.57 as /bin/bash). 'make doctor' reports the bash in use.
EOF
  exit 1
fi

MODE_SHELL=0
if [[ ${1:-} == --shell ]]; then MODE_SHELL=1; shift; fi

[[ $# -eq 1 ]] || die "usage: conf2mk.sh [--shell|--check] <file>"
CONF=$1
[[ -r $CONF ]] || die "cannot read '$CONF'"

# ── The sets of legal keys. Kept here rather than in a separate list so that the
#    validator and the documentation cannot drift apart without someone noticing:
#    if you add a key to a SCHEMA.md and forget this array, your key is rejected at
#    once with a clear message, rather than being silently ignored.
#
# Three description kinds share this one validator, because the syntax rules and
# the security rules are identical for all three and duplicating the parser would
# be the same mistake this tree exists to remove.
TARGET_KEYS=(
  TARGET_NAME TARGET_DESC
  TARGET_TRIPLE TARGET_ARCH TARGET_CPU TARGET_CPU_FLAG
  TARGET_LIBC TARGET_LIBC_VERSION TARGET_CXXABI_MAX
  TARGET_DYNAMIC_LINKER TARGET_ENDIAN
  SYSROOT_PROVIDER SYSROOT_PROVIDER_ARGS SYSROOT_DIR SYSROOT_PROBE_FILE
  TOOLCHAIN_KIND TOOLCHAIN_ROOT TOOLCHAIN_PREFIX TARGET_LINKER TARGET_STDLIB
  TARGET_CFLAGS TARGET_CXXFLAGS TARGET_LDFLAGS TARGET_CXX_STANDARD
  TARGET_SYSROOT_GCC_VERSION
  TARGET_RPATH TARGET_DEPLOY_DIR
  TARGET_GPU_ARCH
)

COMPONENT_KEYS=(
  COMPONENT_NAME COMPONENT_DESC COMPONENT_KIND COMPONENT_OUTPUT
  COMPONENT_SOURCES COMPONENT_INCLUDES
  COMPONENT_CFLAGS COMPONENT_CXXFLAGS COMPONENT_LDFLAGS COMPONENT_LIBS
  COMPONENT_DEPENDS COMPONENT_SOURCE_ROOTS COMPONENT_SONAME
  COMPONENT_CMAKE_SOURCE_DIR COMPONENT_CMAKE_ARGS COMPONENT_CMAKE_TARGET
  COMPONENT_REQUIRES_NATIVE COMPONENT_REQUIRES_GPU_ARCH
  COMPONENT_STATIC_CXX COMPONENT_OPTIONAL
  COMPONENT_CXX_OVERRIDE COMPONENT_CC_OVERRIDE
)

BUNDLE_KEYS=(
  BUNDLE_NAME BUNDLE_DESC BUNDLE_COMPONENTS BUNDLE_OPTIONAL_COMPONENTS
  BUNDLE_EXTRA_FILES BUNDLE_SYSROOT_LIBS BUNDLE_STRIP BUNDLE_README
)

# Which kind is this file? Decided by the directory it lives in, so a file cannot
# accidentally be validated against the wrong schema.
parent=$(basename "$(cd "$(dirname "$CONF")" && pwd)")
case $parent in
  targets)    KIND=target;    NAME_KEY=TARGET_NAME;    LEGAL=("${TARGET_KEYS[@]}") ;;
  components) KIND=component; NAME_KEY=COMPONENT_NAME; LEGAL=("${COMPONENT_KEYS[@]}") ;;
  bundles)    KIND=bundle;    NAME_KEY=BUNDLE_NAME;    LEGAL=("${BUNDLE_KEYS[@]}") ;;
  *)
    # The file is outside the three convention directories — a test fixture, or a
    # probe result written to /tmp. Infer the kind from the *_NAME key it actually
    # contains, so validation still uses the right schema and the right required
    # key. Guessing "target" here would reject a perfectly good bundle fixture for
    # lacking TARGET_NAME.
    #
    # Syntax and safety checks apply either way; only the name-matches-filename
    # rule is relaxed, since outside those directories there is no convention to
    # check against.
    if grep -qE '^COMPONENT_NAME=' "$CONF" 2>/dev/null; then
      KIND=component; NAME_KEY=COMPONENT_NAME; LEGAL=("${COMPONENT_KEYS[@]}")
    elif grep -qE '^BUNDLE_NAME=' "$CONF" 2>/dev/null; then
      KIND=bundle;    NAME_KEY=BUNDLE_NAME;    LEGAL=("${BUNDLE_KEYS[@]}")
    else
      KIND=target;    NAME_KEY=TARGET_NAME;    LEGAL=("${TARGET_KEYS[@]}")
    fi
    RELAXED_NAME_CHECK=1 ;;
esac
RELAXED_NAME_CHECK=${RELAXED_NAME_CHECK:-0}

is_legal_key() {
  local k=$1 legal
  for legal in "${LEGAL[@]}"; do
    [[ $k == "$legal" ]] && return 0
  done
  return 1
}

base=$(basename "$CONF" .conf)

printf '# Generated by tools/conf2mk.sh from %s — DO NOT EDIT.\n' "$CONF"
printf '# Edit the .conf and re-run make; this file is regenerated automatically.\n\n'
if [[ $MODE_SHELL -eq 1 ]]; then
  # Every value is emitted single-quoted, so spaces, globs and '$' are inert. This
  # is what makes multi-word values safe to source.
  printf '# Shell view: all values single-quoted so multi-word values stay intact.\n\n'
fi

seen_name=""
lineno=0
lines_seen=0
# Track keys to reject duplicates. The two views disagree about which wins — Make's
# '?=' takes the FIRST assignment, shell's plain '=' takes the LAST — so a duplicated
# key means the compiler and the verifier/bundler use DIFFERENT values for the same
# setting, with nothing to indicate it. Rejecting is the only safe answer.
_seen_keys=" "
while IFS= read -r line || [[ -n $line ]]; do
  lineno=$((lineno + 1))
  lines_seen=$((lines_seen + 1))

  case $line in
    ''|\#*) continue ;;
  esac

  # Strip a trailing comment.
  #
  # This MUST happen, and it must happen for both views. Make strips ' # ...' from a
  # value itself, but shell does not — so without this, a line like
  #     TARGET_LIBC=glibc   # confirmed on the board
  # reaches Make as "glibc" and reaches shell as "glibc   # confirmed on the board".
  # verify-artifact.sh then compares that against "glibc", takes the "not glibc"
  # branch, and SKIPS the symbol-version ceiling check — silently disabling the most
  # valuable check in the system because someone annotated a line.
  #
  # Only ' #' (hash preceded by whitespace) counts, so a '#' inside a real value —
  # e.g. a -D flag or a URL fragment — is preserved.
  case $line in
    *[[:space:]]\#*)
      line=$(printf '%s' "$line" | sed 's/[[:space:]]\{1,\}#.*$//')
      ;;
  esac
  # Trim trailing whitespace left by the strip (or present originally): a value with a
  # trailing space is not what anyone means, and it changes shell string comparisons.
  line=${line%%"${line##*[![:space:]]}"}
  [[ -z $line ]] && continue

  # Reject anything that is not a bare assignment before we look at the value.
  if [[ ! $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    die "$CONF:$lineno: not a KEY=value assignment: $line
     Target descriptions are pure data. Shell constructs (if, export, loops,
     function calls) are not allowed — see targets/SCHEMA.md."
  fi

  key=${BASH_REMATCH[1]}
  val=${BASH_REMATCH[2]}

  is_legal_key "$key" || die "$CONF:$lineno: unknown key '$key' for a $KIND description.
     Legal keys are documented in ${KIND}s/SCHEMA.md. This is rejected rather than
     ignored so a typo cannot silently leave a default in place."

  # ── Reject code execution ──────────────────────────────────────────────────
  #
  # Backticks are never legitimate in any description, in any position.
  case $val in
    *'`'*) die "$CONF:$lineno: backticks are not allowed in a description." ;;
  esac

  # Make treats ${NAME} and $(NAME) as the SAME construct, so ${shell ...} executes a
  # command exactly like $(shell ...) does. Checking only for '$(' is a validation
  # bypass: a target description containing
  #     TARGET_CFLAGS=${shell touch /tmp/PWNED}
  # passed validation and then executed on the next `make show-target`. Normalise the
  # brace form to the paren form before validating, so one set of rules covers both.
  _norm=$val
  while [[ $_norm == *'${'* ]]; do
    _pre=${_norm%%'${'*}
    _rest=${_norm#*'${'}
    _inner=${_rest%%'}'*}
    _post=${_rest#*'}'}
    # If there is no closing brace, treat the remainder as the reference so it is
    # still validated rather than slipping through unexamined.
    if [[ $_rest != *'}'* ]]; then _inner=$_rest; _post=""; fi
    _norm="$_pre\$($_inner)$_post"
  done

  # '$(...)' needs a per-kind rule, because the two description kinds have
  # genuinely different consumers and therefore different threat models:
  #
  #   TARGET descriptions are SOURCED BY SHELL (the sysroot providers read
  #     SYSROOT_PROVIDER_ARGS and TARGET_LIBC directly out of the file). In shell,
  #     $(foo) executes foo. So any '$(' in a target description is a potential
  #     command execution and is refused outright.
  #
  #   COMPONENT and BUNDLE descriptions are consumed ONLY by Make, never sourced by
  #     shell. There, $(CATALYST) is a variable reference and is the intended way to
  #     name an external source root. Refusing it would make components unable to
  #     reference source trees at all.
  #
  # So components may use a *bare variable reference* — $(NAME) where NAME is an
  # identifier — and nothing more. '$(shell ...)', '$(wildcard ...)' and any form
  # containing a space or a slash are refused, because those would let a
  # description run commands at Make-expansion time and reintroduce exactly the
  # problem this check exists to prevent.
  if [[ $_norm == *'$('* ]]; then
    if [[ $KIND == target ]]; then
      die "$CONF:$lineno: '\$(...)' is not allowed in a TARGET description.
     Target descriptions are read directly by shell (the sysroot providers source
     them), where \$(...) executes a command. If a value must be computed, compute
     it in the provider or pass it on the make command line.
     (Component descriptions MAY use \$(VAR) — they are only ever read by Make.)"
    fi
    # Validate every occurrence, not just the first: one good reference must not
    # launder a bad one later in the same value.
    remainder=$_norm
    while [[ $remainder == *'$('* ]]; do
      remainder=${remainder#*'$('}
      # An unterminated reference must not be treated as a well-formed one: without
      # this, '$(FOO' yields the rest of the line as 'ref' and passes or fails only by
      # accident of its contents.
      if [[ $remainder != *')'* ]]; then
        die "$CONF:$lineno: unterminated variable reference '\$($remainder'.
     Every \$( must have a matching ). An unbalanced one is almost always a typo, and
     Make would expand it in a way you did not intend."
      fi
      ref=${remainder%%')'*}
      if [[ ! $ref =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        die "$CONF:$lineno: '\$($ref)' is not a plain variable reference.
     Only \$(NAME) is permitted — a bare identifier naming a source root or a
     build variable. Function calls such as \$(shell ...) or \$(wildcard ...) are
     refused so that a description cannot execute code during expansion.
     Declare source roots in COMPONENT_SOURCE_ROOTS and pass them on the command
     line, e.g.:  make build TARGET=<name> CATALYST=/path/to/tree"
      fi
    done
  fi

  # A single '$' that is neither '$$' nor a '$(' reference is almost certainly a
  # mistake, and a silent one. The canonical example: TARGET_RPATH=$ORIGIN. Make
  # expands '$O' (an undefined single-character variable) to nothing, so the value
  # becomes 'RIGIN' — and the binary gets an RPATH of 'RIGIN', which verify then
  # cheerfully reports as ok. Doubling is required and is easy to forget, so say so.
  _scan=${val//'$$'/}          # remove legitimate escaped dollars
  _scan=${_scan//'$('/}        # remove legitimate references (already validated above)
  _scan=${_scan//'${'/}
  if [[ $_scan == *'$'* ]]; then
    die "$CONF:$lineno: a lone '\$' in '$val'.
     Make expands a single \$ followed by one character as a variable, so '\$ORIGIN'
     silently becomes 'RIGIN'. Write '\$\$ORIGIN' to pass a literal \$ORIGIN through to
     the linker (this is what targets/SCHEMA.md means by the doubled form), or
     '\$(NAME)' for a real variable reference."
  fi

  # Strip one layer of matching quotes: shell would remove them on source, so Make
  # must see the same value. Without this, TARGET_CFLAGS="-O2 -g" reaches the
  # compiler as the literal characters "-O2 -g" including quotes, which fails in a
  # way that is genuinely hard to read in a compiler error.
  #
  # The length is written out as ${#val}-2 rather than as the shorter ${val:1:-1}.
  # A NEGATIVE substring length needs bash 4.2, and macOS still ships bash 3.2.57 as
  # /bin/bash, where the short form aborts the read loop with
  #     conf2mk.sh: line 298: -1: substring expression < 0
  # having emitted only the keys before the first quoted value — and then exits 0, so
  # every consumer accepted the truncation as a valid description. See the completion
  # marker at the end of this file for the structural guard against that class of bug.
  if [[ ${#val} -ge 2 && ${val:0:1} == '"' && ${val: -1} == '"' ]]; then
    val=${val:1:${#val}-2}
  elif [[ ${#val} -ge 2 && ${val:0:1} == "'" && ${val: -1} == "'" ]]; then
    val=${val:1:${#val}-2}
  fi

  case $_seen_keys in
    *" $key "*)
      die "$CONF:$lineno: '$key' is assigned more than once.
     This is rejected because the Make view and the shell view resolve duplicates
     differently (first-wins vs last-wins), so the compiler and the verifier would
     silently use different values. Keep one assignment." ;;
  esac
  _seen_keys="$_seen_keys$key "

  [[ $key == "$NAME_KEY" ]] && seen_name=$val

  # Values may legitimately contain '$(VAR)' references to source roots — that is
  # how a component names its sources. Make expands them later, which is exactly
  # what we want, so unlike shell command substitution these are allowed through.

  if [[ $MODE_SHELL -eq 1 ]]; then
    # Single-quote, escaping any embedded single quote by the standard
    # '"'"' dance. Result is always one shell word, whatever the value contains.
    esc=${val//\'/\'\"\'\"\'}
    printf "%s='%s'\n" "$key" "$esc"
  else
    # Emit with ?= so that a value passed on the make command line wins. Make's
    # command-line variables already override plain '=', but ?= makes the intent
    # explicit and keeps behaviour identical if this fragment is ever included with
    # different flags.
    printf '%s ?= %s\n' "$key" "$val"
  fi
done < "$CONF"
# ── did the loop actually finish? ────────────────────────────────────────────
#
# THIS MUST BE THE FIRST STATEMENT AFTER `done`, because it reads $?.
#
# A bash expansion error inside a `while read ... done < file` loop does something
# genuinely surprising: it abandons the LOOP and resumes at the next statement, with the
# shell still alive and `set -e` never firing. So everything below here — the required-name
# check, the receipt, the completion marker — ran happily on a half-parsed file and the
# script exited 0. Measured on bash 3.2.57 with a three-line input: one line emitted, the
# post-loop code all executed, exit status 0.
#
# That is why the completion marker alone is not enough, and why this check is not
# decoration. Two independent things are asserted:
#
#   * the loop's own status. Measured as 1 after an abort and 0 after a clean run.
#   * that every line of the file was read. This catches whatever the status does not — a
#     signal, an OOM kill, a truncated read — and it is a COUNT, so it does not
#     re-implement any part of the parsing above and cannot drift from it.
_loop_rc=$?
_lines_total=$(awk 'END{print NR}' "$CONF" 2>/dev/null || echo 0)
if [[ $_loop_rc -ne 0 || $lines_seen -ne ${_lines_total:-0} ]]; then
  die "$CONF: parsing stopped after line $lineno of ${_lines_total:-?} — the output is TRUNCATED.
     The shell abandoned the read loop (status $_loop_rc). Any message above names the
     cause; a bash older than 4.2 running a construct that needs it is the known one.
     Nothing is emitted for a partial parse, because the settings that DID parse are
     individually valid and would silently replace the rest with their defaults."
fi

[[ -n $seen_name ]] || die "$CONF: $NAME_KEY is required (see ${KIND}s/SCHEMA.md)."
if [[ $RELAXED_NAME_CHECK -eq 0 && $seen_name != "$base" ]]; then
  die "$CONF: $NAME_KEY='$seen_name' does not match the filename '$base'.
     They must agree, because build directories, sysroot paths and bundle names are
     derived from one of them and looked up by the other. A mismatch produces
     artifacts in a directory you are not looking at."
fi

printf '\n# Record the description this came from, for the build receipt.\n'
if [[ $MODE_SHELL -eq 1 ]]; then
  printf "CONF_FILE='%s'\n" "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
else
  case $KIND in
    component) printf 'COMPONENT_CONF_FILE ?= %s\n' "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")" ;;
    bundle)    printf 'BUNDLE_CONF_FILE ?= %s\n'    "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")" ;;
    *)         printf 'TARGET_CONF_FILE ?= %s\n'    "$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")" ;;
  esac
fi

# ── the completion marker ────────────────────────────────────────────────────
#
# The LAST line written, in both views, and the thing every consumer must check.
#
# WHY THE EXIT STATUS IS NOT ENOUGH. Every consumer already tested it — the guards in
# mk/component.mk and the top-level Makefile end in '&& echo ok' precisely so a
# validation failure cannot be mistaken for success. That defends against this script
# calling die(). It does NOT defend against the shell itself giving up in the middle:
# a bash expansion error aborts the enclosing loop and resumes after it, is not caught
# by 'set -e', and leaves the exit status at 0. Observed on macOS bash 3.2.57, where
# one negative substring length produced a file holding a single key, a status of 0, and
# a build that silently used defaults for everything else while reporting the
# description's own path as their source.
#
# A marker turns "the output is truncated" into a testable property rather than an
# invisible one, and it does so for ANY future cause — an OOM kill, a full disk, a
# signal — not only for the bash version that revealed it.
#
# It is a comment in both languages, so it is inert in Make and inert when sourced.
printf '\n%s\n' "$CONF2MK_COMPLETE"
