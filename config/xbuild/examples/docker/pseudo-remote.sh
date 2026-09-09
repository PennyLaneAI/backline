#!/usr/bin/env bash
#
# pseudo-remote.sh — start/stop an aarch64 "remote machine" in Docker, for learning the
# workflow on a laptop with no board attached.
#
# It exists so the docker details are not something you have to get right while also learning
# how sysroots work. Everything it does is ordinary docker; read it if you want to know how.
#
# USAGE
#   pseudo-remote.sh up        build the image and start it (prints the next command to run)
#   pseudo-remote.sh down      stop and remove the container
#   pseudo-remote.sh status    is it running, and on what port
#   pseudo-remote.sh ssh       open a shell on it, to see for yourself what a target is
#
# ENVIRONMENT
#   PORT       host port to publish sshd on (default 2222)
#   PLATFORM   docker platform (default linux/arm64 — a genuinely different architecture)
#   NAME       container name (default crossbuild-pseudo-remote)
#   IMAGE      image tag to build/run (default crossbuild-pseudo-remote:latest). Override it
#              together with NAME when running more than one box at once, so concurrent
#              `docker build`s do not fight over one tag.
#   SSH_KEY    public key to authorise (default: the first ~/.ssh/id_*.pub)

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PORT=${PORT:-2222}
PLATFORM=${PLATFORM:-linux/arm64}
NAME=${NAME:-crossbuild-pseudo-remote}
IMAGE=${IMAGE:-crossbuild-pseudo-remote:latest}

die() { printf '\n[pseudo-remote] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[pseudo-remote] %s\n' "$*"; }

command -v docker >/dev/null || die "no 'docker' command found. This stand-in needs a
       container engine, which the repository does not ship. It is optional scaffolding for
       practising probe/sysroot/deploy with no hardware — with the real target, skip it.
       To use it, install an engine first: on macOS 'brew install colima && colima start',
       or Docker Desktop; on Linux your distro's docker/podman package."

pick_key() {
  if [[ -n ${SSH_KEY:-} ]]; then
    [[ -r $SSH_KEY ]] || die "SSH_KEY='$SSH_KEY' is not readable."
    cat "$SSH_KEY"; return
  fi
  local k
  for k in "$HOME"/.ssh/id_*.pub; do
    [[ -r $k ]] && { cat "$k"; return; }
  done
  die "no public key found matching ~/.ssh/id_*.pub.
       Generate one (ssh-keygen -t ed25519) or point SSH_KEY at an existing one. Key-only
       login is deliberate: a container with a password you did not choose is worse."
}

case ${1:-status} in
up)
  # The CLI installing without a running daemon is the normal state on a Mac, and every
  # command below then fails with a socket path — which names neither docker nor this script.
  if ! docker info >/dev/null 2>&1; then
    # A CLI with no engine behind it. Naming a runtime to INSTALL matters here: the earlier
    # message assumed one was already installed and only stopped, which left a from-zero Mac
    # user — the exact reader this scaffolding is for — with three 'start it' suggestions and
    # nothing to start. Say plainly that installing an engine is the step.
    _hint="colima (brew install colima && colima start) or Docker Desktop"
    case "$(uname -s)" in
      Linux) _hint="your distro's docker/podman package, then 'sudo systemctl start docker'" ;;
    esac
    die "the 'docker' CLI is here but no engine is running behind it.

       You need a container ENGINE, not just the CLI — installing one is a real setup step
       this repository cannot do for you. On this host: $_hint.
       Then 'docker info' should succeed and this command will work.

       Reminder: pseudo-remote is only a hardware-free rehearsal. With the real target in
       hand, skip it — nothing else in the build needs Docker."
  fi

  # A FOREIGN architecture only works if the kernel knows how to run its binaries. The word
  # doing the work is "foreign", and this check used to ignore it: it asked
  # /proc/sys/fs/binfmt_misc/ — a path that exists only on Linux — so on any Mac the test
  # could not succeed and `make pseudo-remote` always died, telling an Apple Silicon laptop
  # "this host cannot run aarch64 binaries" when aarch64 is its NATIVE architecture and no
  # emulation is involved at all. The suggested fix could not have helped either: nothing
  # docker does creates /proc on a Mac. That made the repo's only hardware-free rehearsal of
  # the deploy step unreachable on a platform INSTALL.md opens by promising to support.
  #
  # So: only ask about emulation when the container really is foreign to this host, and only
  # where the answer is knowable.
  host_arch=$(uname -m)
  want_arm=0
  case $PLATFORM in *arm64*|*aarch64*) want_arm=1 ;; esac
  host_arm=0
  case $host_arch in arm64|aarch64) host_arm=1 ;; esac

  if [[ $want_arm -eq 1 && $host_arm -eq 0 ]]; then
    # Genuinely foreign. On Linux we can check; elsewhere Docker Desktop bundles its own
    # emulation and there is no host-visible register to inspect, so let docker report it.
    if [[ -d /proc/sys/fs/binfmt_misc ]]; then
      if ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q qemu-aarch64; then
        die "this host is $host_arch and cannot run aarch64 binaries, so an aarch64 container
       will not start. Register the emulators:
         docker run --privileged --rm tonistiigi/binfmt --install arm64
       Or use a same-architecture box instead (faster, teaches less):
         PLATFORM=linux/amd64 $0 up"
      fi
    fi
  fi

  log "building $IMAGE for $PLATFORM"
  docker build --platform "$PLATFORM" \
    --build-arg "PLATFORM=$PLATFORM" \
    --build-arg "SSH_PUBKEY=$(pick_key)" \
    -t "$IMAGE" "$HERE" || die "docker build failed (see above)."

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "starting $NAME on port $PORT"
  docker run -d --platform "$PLATFORM" --name "$NAME" -p "$PORT:22" "$IMAGE" >/dev/null \
    || die "docker run failed. Is port $PORT already in use? Try PORT=2223 $0 up"

  # sshd inside an emulated container takes a moment; polling beats telling people to
  # "wait a bit", and a clear timeout beats a confusing connection refused later.
  log "waiting for sshd"
  for _ in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=2 \
           -p "$PORT" root@localhost true 2>/dev/null; then
      ok=1; break
    fi
    sleep 1
  done
  [[ ${ok:-0} == 1 ]] || die "sshd did not become reachable on port $PORT within 60s.
       Look at why:  docker logs $NAME"

  arch=$(ssh -o BatchMode=yes -p "$PORT" root@localhost uname -m 2>/dev/null)
  printf '\n'
  log "ready: root@localhost port $PORT, architecture $arch"
  # The teardown hint must carry BOTH overrides this box was started with. It used to print
  # only PORT=, so anyone who set a custom NAME (needed to run more than one box, or to avoid
  # clobbering someone else's) was handed a command that removes the DEFAULT-named container —
  # deleting the wrong box and leaving theirs running. Echo back exactly what removes THIS one.
  if [[ $NAME != crossbuild-pseudo-remote || $PORT != 2222 ]]; then
    _DOWN_HINT="NAME=$NAME PORT=$PORT make pseudo-remote-down"
  else
    _DOWN_HINT="make pseudo-remote-down"
  fi
  cat <<EOF

Treat it exactly as you would a board on your desk:

  1. let it describe itself   make probe TARGET=demo-box SSH=root@localhost PORT=$PORT
  2. copy its libraries       make sysroot TARGET=demo-box
  3. build something for it   make build TARGET=demo-box COMPONENT=hello-world
  4. prove it is deployable   make verify TARGET=demo-box
  5. ship it                  make bundle TARGET=demo-box BUNDLE=example-hello
  6. run it THERE             make deploy TARGET=demo-box BUNDLE=example-hello \\
                                  SSH=root@localhost PORT=$PORT

Stop it with:  ${_DOWN_HINT}
EOF
  ;;

down)
  docker rm -f "$NAME" >/dev/null 2>&1 && log "removed $NAME" || log "$NAME was not running"
  ;;

status)
  if out=$(docker ps --filter "name=^${NAME}$" --format '{{.Status}}  {{.Ports}}' 2>/dev/null) \
     && [[ -n $out ]]; then
    log "$NAME: $out"
  else
    log "$NAME is not running. Start it with:  $0 up"
  fi
  ;;

ssh)
  exec ssh -o StrictHostKeyChecking=accept-new -p "$PORT" root@localhost
  ;;

*)
  echo "usage: $0 {up|down|status|ssh}" >&2
  exit 2
  ;;
esac
