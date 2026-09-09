#!/usr/bin/env bash
#
# quickstart.sh — a guided first build that explains each step as it runs.
#
# Aimed at someone who has just been handed this tree and does not yet know what a
# sysroot is or why cross-compiling needs one. It builds the smallest real thing —
# a hello-world for THIS machine, treated as a target like any other — so that the
# mechanics are visible without needing hardware, a network, or a vendor SDK.
#
# Building for the host first is a genuinely useful habit: if the native path fails,
# the problem is the build system or your tools, not the cross-compilation. That
# isolation saves a lot of time on a new board.
#
# USAGE
#   quickstart.sh [root-dir]

set -uo pipefail

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
B=""; N=""
if [[ -t 1 ]]; then B=$'\033[1m'; N=$'\033[0m'; fi

# Pick a demo target whose toolchain this host actually has.
#
# example-native defaults to TOOLCHAIN_KIND=llvm, which is the right default for a
# cross-building tree — but a host with only GCC would then see the tour fail at the
# first compile, which teaches the wrong lesson (that the tree is broken, rather than
# that clang is not installed). Choosing a working target keeps the tour about the
# CONCEPTS; `make doctor` is the place to learn what is missing.
#
# The GCC fallback is only offered on a host it can actually work on. It points at
# targets/test-native-gcc.conf, which is not native everywhere despite the name: it names
# x86_64, glibc, a triple-prefixed gcc, the bfd linker and an ELF interpreter path. Offering
# it on an arm64 laptop or a Mac replaced "no clang" with a wall of unrelated failures, which
# teaches the wrong lesson twice over. So the fallback requires that the host match it.
DEMO_TARGET=example-native
if ! command -v clang >/dev/null 2>&1; then
  _qs_arch=$(uname -m)
  _qs_fmt=$("$ROOT/tools/arch-table.sh" binfmt "$("$ROOT/tools/detect-host.sh" triple 2>/dev/null)" 2>/dev/null || echo elf)
  if [[ -e $ROOT/targets/test-native-gcc.conf ]] \
     && command -v x86_64-linux-gnu-g++ >/dev/null 2>&1 \
     && [[ $_qs_fmt == elf && ( $_qs_arch == x86_64 || $_qs_arch == amd64 ) ]]; then
    DEMO_TARGET=test-native-gcc
    printf '\nnote: no clang on this host, so the tour uses the GCC target\n'
    printf '      (targets/%s.conf). Everything shown applies identically;\n' "$DEMO_TARGET"
    printf '      only TOOLCHAIN_KIND differs. Run "make doctor" for details.\n'
  else
    printf '\nnote: no clang on this host. The tour still explains everything, but the\n'
    printf '      build step will fail until a compiler is installed — that is a missing\n'
    printf '      tool, not a broken tree. Run "make doctor" for the exact command.\n'
  fi
fi

pause() {
  # Interactive when a human is watching, non-blocking in CI. A guided tour that
  # hangs a pipeline is worse than one that just prints.
  if [[ -t 0 ]]; then
    printf '\n    [Enter to continue, Ctrl-C to stop] '
    read -r _ || true
    printf '\n'
  else
    printf '\n'
  fi
}

step() { printf '\n%s━━━ %s ━━━%s\n\n' "$B" "$1" "$N"; }

cat <<EOF

${B}crossbuild quickstart${N}

You are going to build a small program for a "target" machine, using this tree's
normal pipeline. The target we will use is ${B}this machine${N} — because a native
build exercises every step (description, sysroot, flags, verification, bundling)
without needing hardware or a network.

That is not a special case in this build system. "Native" is just a target whose
sysroot is discovered from the host rather than fetched, which is why there is no
separate native code path. On Linux that discovery answers /; on macOS it answers
the SDK, because there the system libraries are not files on disk at all.

Four ideas, and then we will run them:

  ${B}target${N}      a machine you want binaries for, described in one data file
  ${B}sysroot${N}     a copy of that machine's headers and libraries, so the
              compiler reads ITS libc instead of this host's
  ${B}component${N}   one thing to build, described without naming any machine
  ${B}bundle${N}      a set of built things, gathered and made deployable

EOF
pause

step "STEP 1 — what machines are described?"
cat <<'EOF'
Each of these is one file in targets/. They contain no build logic — only facts
about a machine. Adding hardware means writing one of these and nothing else.

EOF
make -C "$ROOT" --no-print-directory list-targets
pause

step "STEP 2 — the fully-resolved view of one target"
cat <<'EOF'
A description is deliberately terse; most fields have defaults. This shows what
those defaults became, and — at the bottom — the EXACT compiler and linker flags
every component will get.

Those flags are derived in one place (mk/derive.mk). Nothing else in the tree adds
target-specific flags, which is what stops two components from drifting apart.

EOF
make -C "$ROOT" --no-print-directory show-target TARGET=$DEMO_TARGET
pause

step "STEP 3 — obtain the sysroot"
cat <<'EOF'
Cross-compiling means the compiler must read the TARGET's headers and link the
TARGET's libraries. A sysroot is that copy.

For this native target, the sysroot is "/" — nothing to fetch. For real hardware,
SYSROOT_PROVIDER in the description decides how it is obtained; the best option is
usually ssh-rsync, which copies the real libraries off the real device so there is
no version to guess.

EOF
make -C "$ROOT" --no-print-directory sysroot TARGET=$DEMO_TARGET || {
  echo "(sysroot step failed — see above; the rest of the tour still applies)"
}
pause

step "STEP 4 — what can be built?"
cat <<'EOF'
Components describe sources and dependencies. Note that none of them mentions a
target: the same component description builds for every machine, which is why
adding a board requires no component edits.

Most of the examples need an external source checkout (they are stand-ins for real
project code), so we will build the one that is self-contained.

EOF
make -C "$ROOT" --no-print-directory list-components
pause

step "STEP 5 — build a self-contained component"
cat <<'EOF'
`hello-world` has its sources inside this tree, so it needs no external checkout.
Watch the compiler line: every flag on it came from the target description via
mk/derive.mk.

EOF
if make -C "$ROOT" --no-print-directory build TARGET=$DEMO_TARGET COMPONENT=hello-world; then
  ok=1
else
  ok=0
  cat <<'EOF'

That failed. Run `make doctor` — it names any missing tool and the package to
install. The most common cause is no clang; you can also switch the target to GCC
by setting TOOLCHAIN_KIND=gcc in its target description.
EOF
fi
pause

if [[ ${ok:-0} -eq 1 ]]; then
  step "STEP 6 — verify before you ship"
  cat <<'EOF'
This reads the built binary's ELF headers and checks it against the target's
declared ABI: right architecture, right ELF interpreter, and no symbol newer than
the target's libc provides.

This check is why the build system asks for TARGET_LIBC_VERSION. Without it, a
binary built against a newer libc than the target has will link successfully and
then die on the device with "version `GLIBC_2.38' not found" — a failure that
costs far more to diagnose there than here.

EOF
  make -C "$ROOT" --no-print-directory verify TARGET=$DEMO_TARGET || true
  pause

  step "STEP 7 — bundle it"
  cat <<'EOF'
A bundle gathers artifacts, verifies each one, works out whether every library they
need will be resolvable on the target, and writes a deploy script plus a receipt of
what went in.

EOF
  make -C "$ROOT" --no-print-directory bundle TARGET=$DEMO_TARGET BUNDLE=example-hello || true
fi

cat <<EOF

${B}━━━ done ━━━${N}

What you just did, in four commands:

    make sysroot TARGET=<t>
    make build   TARGET=<t>
    make verify  TARGET=<t>
    make bundle  TARGET=<t> BUNDLE=<b>

${B}To do this for real hardware:${N}

  1. Describe it — let the machine tell you, rather than guessing:
         make probe TARGET=my-board SSH=user@my-board
     This reads the glibc version, C++ ABI level and ELF interpreter path off the
     device. Those are the three values that must not be guessed.

  2. Fetch its libraries:
         make sysroot TARGET=my-board

  3. Build, passing any external source trees the components need:
         make build TARGET=my-board CATALYST=/path/to/checkout

  4. Bundle and deploy:
         make bundle TARGET=my-board BUNDLE=example-minimal
         build/my-board/bundles/example-minimal/deploy.sh user@my-board

${B}Where to read more${N}
    docs/01-concepts.md                       what a sysroot is and why
    docs/02-adding-a-target.md                the walkthrough
    docs/03-how-flags-are-derived.md          where every flag comes from
    docs/04-sysroot-providers.md              choosing and writing providers
    docs/05-troubleshooting.md                errors, by the message you saw

EOF
