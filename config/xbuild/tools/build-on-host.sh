#!/usr/bin/env bash
# Build one component on TARGET_BUILD_HOST over ssh and copy the artifact back. Called by mk/rules.mk.
#
#   build-on-host.sh <root> <target> <component> <host> <out-dir> "<NAME=path...>" "<dir...>" "<VAR=value...>"
#
# The host keeps everything under ~/.cache/xbuild/<target>: this tree in xbuild/, each source root's
# directories in src/<NAME>/, and the compiler's TMPDIR in tmp/.

set -euo pipefail

ROOT=${1:?usage: build-on-host.sh <root> <target> <component> <host> <out-dir> <roots> <dirs> <vars>}
TARGET=${2:?} COMPONENT=${3:?} HOST=${4:?} OUT=${5:?}
ROOTS=${6:-} DIRS=${7:-} VARS=${8:-}
DIR=.cache/xbuild/$TARGET

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s/%s] %s\n' "$TARGET" "$COMPONENT" "$*"; }

command -v ssh   >/dev/null || die "ssh not found on this build host."
command -v rsync >/dev/null || die "rsync not found on this build host."

case $OUT in "$ROOT"/*) ;; *) die "output directory $OUT is outside $ROOT." ;; esac

# Every directory the build reads must be in this tree or under one of the source roots.
for d in $DIRS; do
  case $d in "$ROOT" | "$ROOT"/*) continue ;; esac
  found=""
  for kv in $ROOTS; do
    p=${kv#*=}
    case $d in "$p" | "$p"/*) found=1 ;; esac
  done
  [[ -n $found ]] || die "component '$COMPONENT' reads $d, which is under no source root, so it cannot be copied to $HOST."
done

mkdirs="$DIR/tmp"
remote_roots=""
for kv in $ROOTS; do
  mkdirs="$mkdirs $DIR/src/${kv%%=*}"
  remote_roots="$remote_roots ${kv%%=*}=\$R/src/${kv%%=*}"
done

log "copying sources to $HOST:$DIR"
ssh "$HOST" "mkdir -p $mkdirs"
rsync -a --delete --exclude /build/ --exclude /config.mk "$ROOT/" "$HOST:$DIR/xbuild/"
for kv in $ROOTS; do
  name=${kv%%=*} p=${kv#*=}
  rels=()
  for d in $DIRS; do
    case $d in
      "$p") rels+=(.) ;;
      "$p"/*) rels+=("${d#"$p"/}") ;;
    esac
  done
  [[ ${#rels[@]} -gt 0 ]] || continue
  (cd "$p" && rsync -aR --delete "${rels[@]}" "$HOST:$DIR/src/$name/")
done

# TARGET_BUILD_HOST= keeps the host from handing the build on again.
log "building on $HOST"
ssh "$HOST" "set -e
cd $DIR; R=\$(pwd); export TMPDIR=\$R/tmp; cd xbuild
test -e build/sysroots/$TARGET || make --no-print-directory sysroot TARGET=$TARGET SYSROOT_PROVIDER=dir SYSROOT_PROVIDER_ARGS=path=/
for c in \$(tools/order-components.sh \$PWD --with-deps $COMPONENT); do
  make --no-print-directory -f mk/component.mk ROOT_DIR=\$PWD TARGET=$TARGET COMPONENT=\$c TARGET_BUILD_HOST= $remote_roots $VARS component
done"

log "copying the artifact back"
rsync -a "$HOST:$DIR/xbuild/${OUT#"$ROOT"/}/" "$OUT/"
