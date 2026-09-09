#!/usr/bin/env bash
#
# get-sysroot.sh — run the target's chosen sysroot provider, then normalise the
# result.
#
# This is the whole of the "acquire a sysroot" logic, and it is deliberately small:
# dispatch to a plugin, then post-process. Everything that varies between
# acquisition strategies lives in the plugin; everything that must be true of every
# sysroot regardless of origin lives here.
#
# That split is what makes a new provider cheap. Write one script that fills a
# directory; it inherits symlink relocation, validation, and the ready-marker
# without knowing they exist.
#
# USAGE
#   get-sysroot.sh <root-dir> <target-name> <sysroot-dir>

set -uo pipefail

ROOT=${1:?usage: get-sysroot.sh <root> <target> <sysroot-dir> [triple]}
TARGET=${2:?usage: get-sysroot.sh <root> <target> <sysroot-dir> [triple]}
SYSROOT=${3:?usage: get-sysroot.sh <root> <target> <sysroot-dir> [triple]}
# The RESOLVED triple, passed in by the Makefile. It must come from Make rather
# than being re-read from the description, because a description may legitimately
# leave TARGET_TRIPLE blank for a native target — mk/derive.mk fills it in from the
# host compiler. Re-reading the file here would yield an empty triple, and the
# sysroot layout probe would then look in "usr/lib/" (with a trailing slash) and
# report a perfectly good sysroot as having no C library.
TRIPLE_ARG=${4:-}

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

CONF="$ROOT/targets/$TARGET.conf"
[[ -r $CONF ]] || die "no target description at $CONF"

SYSROOT_PROVIDER=none
SYSROOT_PROVIDER_ARGS=""
TARGET_TRIPLE=""
# Via load_conf, so a multi-word SYSROOT_PROVIDER_ARGS survives intact rather than
# having its second word executed as a command.
# shellcheck source=/dev/null
. "$ROOT/tools/load-conf.sh"
load_conf "$CONF" || exit 1

# ── one-off overrides from the command line ──────────────────────────────────
#
# Exported by the top-level Makefile when the user passed SYSROOT_PROVIDER=,
# SYSROOT_PROVIDER_ARGS= or PORT= to `make sysroot`. Env vars rather than more
# positional parameters, so that adding the next override does not renumber $4.
#
# Applied AFTER load_conf so they outrank the description, and the source of each
# value is printed in the banner below: an override that takes effect invisibly is how
# someone spends an afternoon editing a file that is not being read.
PROVIDER_SRC="targets/$TARGET.conf"
ARGS_SRC="targets/$TARGET.conf"
if [[ -n ${SYSROOT_PROVIDER_OVERRIDE:-} ]]; then
  SYSROOT_PROVIDER=$SYSROOT_PROVIDER_OVERRIDE
  PROVIDER_SRC="command line"
fi
if [[ -n ${SYSROOT_PROVIDER_ARGS_OVERRIDE:-} ]]; then
  SYSROOT_PROVIDER_ARGS=$SYSROOT_PROVIDER_ARGS_OVERRIDE
  ARGS_SRC="command line"
fi

# Prefer the resolved value from Make; fall back to the file's own for direct calls.
if [[ -n $TRIPLE_ARG ]]; then TARGET_TRIPLE=$TRIPLE_ARG; fi
if [[ -z ${TARGET_TRIPLE:-} ]]; then
  TARGET_TRIPLE=$("$ROOT/tools/detect-host.sh" triple 2>/dev/null || echo "")
fi

PROVIDER_BIN="$ROOT/sysroot/providers/$SYSROOT_PROVIDER"
if [[ ! -x $PROVIDER_BIN ]]; then
  avail=$(cd "$ROOT/sysroot/providers" && ls -1 2>/dev/null | tr '\n' ' ')
  die "SYSROOT_PROVIDER='$SYSROOT_PROVIDER' has no executable at
         sysroot/providers/$SYSROOT_PROVIDER

  Available providers: $avail

  A provider is just an executable that fills a directory — adding one is a
  single file, no registration needed. See sysroot/README.md."
fi

printf '\n'
printf '═══ obtaining sysroot for %s ═══\n' "$TARGET"
printf 'provider : %-24s (from %s)\n' "$SYSROOT_PROVIDER" "$PROVIDER_SRC"
printf 'args     : %-24s (from %s)\n' "${SYSROOT_PROVIDER_ARGS:-<none>}" "$ARGS_SRC"
printf 'into     : %s\n' "$SYSROOT"
printf '\n'

# The provider's whole contract: fill this directory, exit non-zero with a reason.
#
# TARGET_TRIPLE is exported because it is the one target fact a provider may legitimately
# need in order to fetch anything at all — the `deb` provider derives the Debian
# architecture from it, and asking the user to repeat it in SYSROOT_PROVIDER_ARGS would be
# a second copy of a fact the description already states. It is exported rather than passed
# as a fourth argument so that the provider contract (dest, args, conf) stays as it is
# documented in sysroot/README.md and every existing provider keeps working untouched.
#
# The RESOLVED value, not the description's: a native target leaves it blank and
# mk/derive.mk fills it from the host compiler.
export TARGET_TRIPLE
"$PROVIDER_BIN" "$SYSROOT" "$SYSROOT_PROVIDER_ARGS" "$CONF" \
  || die "provider '$SYSROOT_PROVIDER' failed (see above)."

# ── normalisation, applied to every provider's output ────────────────────────
#
# Skipped for an externally-managed sysroot: 'none' means "do not touch this
# tree", and rewriting symlinks in a shared or read-only SDK would violate that.
if [[ $SYSROOT_PROVIDER != none ]]; then
  printf '\n─── normalising ───\n'
  if [[ -L $SYSROOT ]]; then
    # A referenced tree (dir provider, mode=reference) belongs to someone else.
    # Rewriting their symlinks would be a surprising side effect of a build.
    printf 'symlinks : skipped (this is a reference to an external tree)\n'
    printf '           If you hit link errors mentioning absolute host paths, switch\n'
    printf '           the provider to mode=copy so normalisation can apply.\n'
  elif command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/sysroot/normalise/relocate-symlinks.py" "$SYSROOT" --quiet \
      || die "symlink normalisation failed"
  else
    printf 'symlinks : SKIPPED — python3 not found.\n'
    printf '           Absolute symlinks inside the sysroot will resolve against THIS\n'
    printf '           host, which can silently link the wrong libraries. Install\n'
    printf '           python3, or verify your links by hand.\n'
  fi
fi

# ── validate ─────────────────────────────────────────────────────────────────
printf '\n─── validating ───\n'
"$ROOT/tools/sysroot-inspect.sh" probe "$SYSROOT" "$TARGET_TRIPLE" || exit 1

# The marker is written HERE, after the probe has passed and before the report runs. Order
# matters in both directions: after the probe, so the marker only ever means "fetched and
# validated"; before the report, because the report's integrity check reads the marker and
# would otherwise announce that this very fetch had not finished.
#
# A marker also records provenance — "where did this sysroot come from?" is otherwise
# unanswerable weeks later, and it matters when a build starts behaving unexpectedly.
if [[ ! -L $SYSROOT ]]; then
  {
    echo "# crossbuild sysroot marker"
    echo "target=$TARGET"
    echo "provider=$SYSROOT_PROVIDER"
    echo "args=$SYSROOT_PROVIDER_ARGS"
    echo "obtained=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "by=$(id -un 2>/dev/null)@$(hostname 2>/dev/null)"
  } > "$SYSROOT/.crossbuild-sysroot-ready" 2>/dev/null || true
fi

# Upstream's post-fetch summary of what the sysroot actually contains — kept.
"$ROOT/tools/sysroot-inspect.sh" report "$SYSROOT" "$TARGET_TRIPLE"

# A bare `make build TARGET=<t>` builds EVERY described component and ends in Error 1 the
# moment one of them lacks a source root — which is why INSTALL.md and AGENTS.md both warn
# against it. This line used to suggest exactly that command, so the tool contradicted the
# documentation at the one moment the reader was deciding what to type next.
printf '\nsysroot ready. Next, name what to build:\n\n'
printf '    make build TARGET=%s COMPONENT=<name>\n' "$TARGET"
printf '    make list-components                 # what can be built, and what each needs\n\n'
