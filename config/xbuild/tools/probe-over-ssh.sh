#!/usr/bin/env bash
#
# probe-over-ssh.sh — run the target probe on a remote machine and write a target
# description from what it reports.
#
# This is the single most useful command in the tree for a new machine, because it
# removes guessing from the three values that must not be guessed:
#
#   glibc version        wrong -> binary links here, dies there with a symbol error
#   C++ ABI level        wrong -> same
#   ELF interpreter      wrong -> "No such file or directory" on a file that exists
#
# It is non-interactive and scriptable, which the design this replaces was not: its
# probe was driven from a whiptail TUI, so obtaining information about a REMOTE
# machine required a TUI toolkit on the BUILD host, and a headless CI runner could
# not do it at all.
#
# USAGE
#   probe-over-ssh.sh <root-dir> <target-name> <user@host> [port]

set -uo pipefail

ROOT=${1:?usage: probe-over-ssh.sh <root> <target> <user@host> [port]}
TARGET=${2:?usage: probe-over-ssh.sh <root> <target> <user@host> [port]}
SSH_TARGET=${3:?usage: probe-over-ssh.sh <root> <target> <user@host> [port]}
PORT=${4:-22}

# FRESH=1 regenerates the description instead of updating the facts in it. Read from the
# environment because the positional interface above is documented and stable.
FRESH=${FRESH:-}
case $FRESH in
  ''|1|yes) ;;
  *) printf 'ERROR: FRESH=%s is not understood. Use FRESH=1 to regenerate the description
       from scratch, or leave it unset to update the facts in the existing one.\n' "$FRESH" >&2
     exit 1 ;;
esac

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

command -v ssh >/dev/null || die "ssh is not installed on this build host."

PROBE="$ROOT/sysroot/probe/probe-target.sh"
[[ -r $PROBE ]] || die "probe script missing: $PROBE"

OUT="$ROOT/targets/$TARGET.conf"

# Refuse to clobber. A description often carries hand-tuned values (a deliberate
# TARGET_CPU, extra flags, a custom provider); silently overwriting that would
# discard work with no way back.
if [[ -e $OUT ]]; then
  BACKUP="$OUT.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$OUT" "$BACKUP"
  log "note: targets/$TARGET.conf exists; backed up to $(basename "$BACKUP")"
fi

log ""
log "═══ probing $SSH_TARGET (port $PORT) ═══"
log ""

# One authenticated connection for both operations, so a password-authenticated
# target prompts once rather than twice.
CTL=$(mktemp -u "${TMPDIR:-/tmp}/crossbuild-probe-XXXXXX")
SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60
          -o StrictHostKeyChecking=accept-new -p "$PORT")
cleanup() { ssh -O exit -o ControlPath="$CTL" "$SSH_TARGET" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" true \
  || die "cannot ssh to '$SSH_TARGET' on port $PORT.
       Check the host is up and reachable and that your key or password works:
           ssh -p $PORT $SSH_TARGET"

# Pipe the script in over stdin rather than scp'ing it. Nothing is written to the
# target's filesystem, which matters on a read-only rootfs or a device with a
# nearly-full flash — both common on embedded hardware.
TMPOUT=$(mktemp)
TMPERR=$(mktemp)
cleanup2() { rm -f "$TMPOUT" "$TMPERR"; }
trap 'cleanup; cleanup2' EXIT

log "running the probe (nothing is written on the target)"
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sh -s -- --name=$TARGET" < "$PROBE" \
        > "$TMPOUT" 2> "$TMPERR"; then
  cat "$TMPERR" >&2
  die "the probe failed on the target. It needs only 'sh' and coreutils, so this is
       usually a login-shell problem — check that 'ssh $SSH_TARGET sh -c true' works."
fi

[[ -s $TMPOUT ]] || die "the probe produced no output. Nothing was written."

# The probe writes caveats to stderr so its stdout stays clean and pipeable. Show
# them: an empty TARGET_LIBC_VERSION silently disables the most valuable check, and
# the user needs to know that happened.
if [[ -s $TMPERR ]]; then
  printf '\n'
  sed 's/^/  /' "$TMPERR"
fi

# Validate before installing. Writing a description that `make` will later reject
# would be a poor trade — better to fail here, holding the bad output for inspection.
if ! "$ROOT/tools/conf2mk.sh" "$TMPOUT" >/dev/null 2>"$TMPERR.v"; then
  cp "$TMPOUT" "$ROOT/targets/probe-$TARGET.rejected"
  printf '\n'
  sed 's/^/  /' "$TMPERR.v" >&2
  rm -f "$TMPERR.v"
  die "the probe output did not validate; saved for inspection at
         targets/probe-$TARGET.rejected
       This is a bug in the probe — please report it with that file."
fi
rm -f "$TMPERR.v"

# ── record the address that actually WORKED ──────────────────────────────────
#
# The probe runs on the target and can only report what the machine calls itself, so it writes
# host=<user>@<its own hostname> port=22. That is frequently unreachable from here: a
# container reports its container ID, a NAT'd board reports a private name, and anything
# behind a jump host or a forwarded port reports neither. Probing the Docker pseudo-remote
# over root@localhost:2223 produced:
#
#     SYSROOT_PROVIDER_ARGS="host=root@7b7d91ee9104 port=22"
#
# — so the very next command, make sysroot, failed. But we know an address that works: the one
# this script was just invoked with and has been using all along. Write that, and keep what
# the machine calls itself as a comment, since it is genuinely useful for identifying the box
# later.
probe_host=$(sed -n 's/^SYSROOT_PROVIDER_ARGS="host=\([^ "]*\).*/\1/p' "$TMPOUT" | head -1)
{
  if [[ -n $probe_host && $probe_host != "$SSH_TARGET" ]]; then
    printf '# The machine calls itself %s; this is the address that reached it from the\n' "$probe_host"
    printf '# build host, which is what a fetch needs.\n'
  fi
} > "$TMPOUT.args"
printf 'SYSROOT_PROVIDER_ARGS="host=%s port=%s"\n' "$SSH_TARGET" "$PORT" >> "$TMPOUT.args"

# Substitute the line rather than appending: a second assignment of the same key is exactly
# the sort of thing conf2mk rejects, and rightly.
#
# Done with a read loop rather than `awk -v repl="$(cat …)"`. The replacement is MULTI-LINE
# whenever the machine's own name differs from the address that reached it (the comment
# above is emitted then), and BSD awk — /usr/bin/awk on macOS — rejects a -v assignment
# whose value contains a newline. So the substitution silently did not happen on a Mac, and
# the description kept the host= the machine reported about itself, which is the exact
# failure this block exists to prevent.
{
  while IFS= read -r _line || [[ -n $_line ]]; do
    case $_line in
      SYSROOT_PROVIDER_ARGS=*) cat "$TMPOUT.args" ;;
      *)                       printf '%s\n' "$_line" ;;
    esac
  done < "$TMPOUT"
} > "$TMPOUT.final"
mv "$TMPOUT.final" "$TMPOUT"
rm -f "$TMPOUT.args"

# Re-validate: the file just changed, and installing something make would reject is exactly
# what the validation above exists to prevent. --check as well as the exit status, because a
# parse that stops half way through still exits 0 (see tools/conf2mk.sh).
"$ROOT/tools/conf2mk.sh" "$TMPOUT" > "$TMPOUT.gen" 2>/dev/null \
  && "$ROOT/tools/conf2mk.sh" --check "$TMPOUT.gen" >/dev/null 2>&1 \
  || die "rewriting SYSROOT_PROVIDER_ARGS produced a description that cannot be read. This is
       a bug in tools/probe-over-ssh.sh."
rm -f "$TMPOUT.gen"

# ── install: a re-probe updates the FACTS and nothing else ───────────────────
#
# Regenerating an existing description would discard the acquisition policy it carries.
# That is not hypothetical: a board whose PetaLinux rootfs has no headers and no crt
# objects cannot be its own sysroot, its description said SYSROOT_PROVIDER=deb, and a
# re-probe replaced that with the ssh-rsync line every probe emits. The next `make sysroot`
# then copied a tree that can run programs but not link them.
#
# tools/merge-probed-facts.sh owns the split between a probed fact and a human decision.
if [[ -n ${BACKUP:-} ]]; then
  # A plain string, not an array: "${arr[@]:-}" on an EMPTY array expands to one empty
  # argument under bash 3.2, which would reach the merge tool as an unreadable filename.
  # The value here is one of two literals, so word splitting is not a hazard.
  MERGE_OPT=
  log ""
  if [[ -n $FRESH ]]; then
    MERGE_OPT=--fresh
    log "targets/$TARGET.conf exists, and FRESH asked for it to be regenerated:"
  else
    log "targets/$TARGET.conf exists, so only the probed facts are updated:"
  fi
  log ""
  if ! "$ROOT/tools/merge-probed-facts.sh" $MERGE_OPT "$OUT" "$TMPOUT" \
         > "$TMPOUT.merged" 2>"$TMPOUT.report"; then
    sed 's/^/  /' "$TMPOUT.report" >&2
    die "merging the probed facts failed. targets/$TARGET.conf is untouched."
  fi
  if [[ -s $TMPOUT.report ]]; then sed 's/^/  /' "$TMPOUT.report"; else log "  (no fact changed)"; fi
  rm -f "$TMPOUT.report"

  # Validate before installing, exactly as the generated output is validated above: a
  # merge that produced something make would reject must not reach targets/.
  "$ROOT/tools/conf2mk.sh" "$TMPOUT.merged" > "$TMPOUT.gen2" 2>/dev/null \
    && "$ROOT/tools/conf2mk.sh" --check "$TMPOUT.gen2" >/dev/null 2>&1 \
    || die "merging the probed facts produced a description that cannot be read. The
       original is untouched, and the merge is at $TMPOUT.merged. This is a bug in
       tools/merge-probed-facts.sh."
  rm -f "$TMPOUT.gen2"
  cp "$TMPOUT.merged" "$OUT"
  rm -f "$TMPOUT.merged"
  if [[ -n $FRESH ]]; then MERGED=0; else MERGED=1; fi
else
  cp "$TMPOUT" "$OUT"
  MERGED=0
fi

if [[ $MERGED -eq 1 ]]; then
  log ""
  log "  To regenerate this description from scratch instead, discarding the decisions"
  log "  above: make probe TARGET=$TARGET SSH=$SSH_TARGET FRESH=1"
fi

# ── does the preserved provider still match the machine? ─────────────────────
#
# A merge keeps the acquisition policy, which is right until the machine stops being the
# machine that policy was chosen for. The probe already reports whether the rootfs can be
# LINKED against, so a contradiction is nameable here rather than left to surface as a
# link error hours later.
if [[ $MERGED -eq 1 ]]; then
  _cap=$(sed -n 's/^# probe-sysroot-capable: \([a-z]*\).*/\1/p' "$TMPOUT" | head -1)
  _lacks=$(sed -n 's/^# probe-sysroot-capable: no (lacks:\(.*\))$/\1/p' "$TMPOUT" | head -1)
  _prov=$(sed -n 's/^SYSROOT_PROVIDER=//p' "$OUT" | head -1)
  case "$_prov:$_cap" in
    ssh-rsync:no)
      log ""
      log "  WARNING: this description asks for SYSROOT_PROVIDER=ssh-rsync, and this"
      log "  machine cannot serve as its own sysroot. It lacks:$_lacks"
      log "  A copy of it will run programs and not link them, and the build fails much"
      log "  later with 'cannot open Scrt1.o'. Choose deb, dir or tar instead."
      ;;
    deb:yes|dir:yes|tar:yes|debootstrap:yes|oci:yes)
      log ""
      log "  Note: this machine now has its development files, so it could be copied"
      log "  directly (SYSROOT_PROVIDER=ssh-rsync) rather than approximated. The"
      log "  description keeps '$_prov', which is still valid."
      ;;
  esac

  # Same shape, for the GPU. TARGET_GPU_ARCH is a decision and so survived the merge;
  # the marker says what the machine actually reports. Naming a disagreement here beats
  # shipping a bundle whose device code targets a card this machine does not have.
  _mk_gpu=$(sed -n 's/^# probe-gpu-arch: //p' "$TMPOUT" | head -1)
  _kept_gpu=$(sed -n 's/^TARGET_GPU_ARCH=//p' "$OUT" | head -1)
  if [[ -n $_kept_gpu && -n $_mk_gpu && $_mk_gpu != none && $_kept_gpu != "$_mk_gpu" ]]; then
    log ""
    log "  WARNING: this description says TARGET_GPU_ARCH=$_kept_gpu, and the machine"
    log "  reports $_mk_gpu. Kept '$_kept_gpu', because the architecture is a decision and"
    log "  a bundle may target another card on purpose. If that is not what you meant,"
    log "  edit it — device code built for the wrong card fails when it is loaded, not now."
  elif [[ -n $_kept_gpu && $_mk_gpu == none ]]; then
    log ""
    log "  Note: this description says TARGET_GPU_ARCH=$_kept_gpu and the machine reports"
    log "  no GPU. Kept it: building for an absent card is legitimate, and is what"
    log "  --offload-arch is for."
  elif [[ -z $_kept_gpu && -n $_mk_gpu && $_mk_gpu != none ]]; then
    log ""
    log "  Note: the machine reports a $_mk_gpu GPU and this description names none."
    log "  A component compiling device code will refuse until TARGET_GPU_ARCH is set."
  fi
fi

log ""
log "wrote targets/$TARGET.conf"
log ""
sed 's/^/  /' "$OUT"
log ""
log "─────────────────────────────────────────────────────────────"
log "Review it, then:"
log ""
log "    make sysroot TARGET=$TARGET       # copy its libraries over"
log "    make build   TARGET=$TARGET COMPONENT=hello-world"
log "    make verify  TARGET=$TARGET"
log ""
log "Worth checking before you build:"
log ""
if [[ $MERGED -eq 1 ]]; then
  log "  * SYSROOT_PROVIDER and SYSROOT_PROVIDER_ARGS are whatever this description"
  log "    already said. A probe does not choose them. If the machine's address has"
  log "    changed, it is '$SSH_TARGET' that worked just now."
else
  log "  * SYSROOT_PROVIDER_ARGS host= : the probe guessed it from the machine's own"
  log "    hostname, which may not be how you reach it. It should be '$SSH_TARGET'"
  log "    if that is what worked just now."
fi
log "  * TARGET_CPU is intentionally empty. Leave it that way unless the whole"
log "    fleet is this exact part, since a tuned binary SIGILLs on older chips."
log ""
# The file just written is TRACKED. .gitignore covers targets/probe-*.conf, but a successful
# probe writes targets/<name>.conf — the same namespace as the committed hand-written target
# descriptions, so no pattern can hide one without hiding the other. That makes this notice
# the only thing between a machine's hostname and a public commit, which is why it is here
# and not only in a document nobody reads at this moment.
log "Before you commit it:"
log ""
log "  targets/$TARGET.conf is a TRACKED file — .gitignore cannot exclude it without also"
log "  excluding the target descriptions that are meant to be committed. It now contains"
log "  this machine's hostname and the username you connected as:"
log ""
grep -n 'host=\|user=\|@' "$OUT" 2>/dev/null | sed 's/^/      /' || true
log ""
log "  Replace them with a placeholder if this repository is shared."
