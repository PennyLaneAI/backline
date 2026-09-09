# A "remote machine" you can reach over ssh, running on your laptop — and running aarch64,
# so nothing about it is a simulation.
#
# TEACHING PURPOSE
# The hard part of cross-compiling is not the compiler flags. It is that the target is
# somewhere else, and everything you assume about it is a guess until you look. This image
# exists so you can practise the real workflow — probe it, copy its sysroot, build against
# that sysroot, deploy back to it — without owning a board.
#
# Because it is genuinely aarch64 (via qemu binfmt on an x86-64 host), the compiler really
# cross-compiles and a mistake really does produce "Exec format error" exactly as it would on
# hardware. Override PLATFORM to get a same-architecture box instead, which is faster but
# teaches you less:
#
#     docker build --build-arg PLATFORM=linux/amd64 ...
#
# NOT a production base image: it runs sshd as root with a key you supply, and is meant to be
# thrown away. If what you actually want is to build against an image rather than a machine,
# see the `oci` provider in ../../docs/04-sysroot-providers.md.

ARG PLATFORM=linux/arm64
FROM --platform=${PLATFORM} ubuntu:24.04

# Two groups of packages, for two different reasons.
#
# openssh-server + rsync are what the ssh-rsync sysroot provider needs on the FAR side: it
# copies the real libraries off the running machine rather than reconstructing an approximation
# of them.
#
# Everything ending in -dev is the actual lesson. A running system needs only libc.so.6, but
# LINKING against it needs libc.so, the crt*.o startup objects and the headers — which ship
# separately. A rootfs copied from a machine without them produces a sysroot that can run
# programs and not build them; `make sysroot-info TARGET=<t>` says exactly that, and without
# the check you would instead meet "fatal error: 'cstdio' file not found" and conclude your
# compiler was broken.
#
#   libc6-dev         headers + libc.so + Scrt1.o/crti.o/crtn.o
#   libstdc++-14-dev  the C++ headers, and libstdc++.so under usr/lib/gcc/<triple>/14
#   zlib1g-dev        zlib.h + libz.so   (example-executor's LLVM references ZLIB::ZLIB)
#   libibverbs-dev    infiniband/verbs.h + libibverbs.so  (example-transport-session)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server \
      rsync \
      libc6-dev \
      libstdc++-14-dev \
      zlib1g-dev \
      libibverbs-dev \
 && rm -rf /var/lib/apt/lists/*

# Key-only login. The key is passed in at build time rather than baked into the repo, so this
# file stays committable and nobody inherits anybody else's trust.
ARG SSH_PUBKEY
RUN test -n "$SSH_PUBKEY" || (echo "SSH_PUBKEY build arg is required" >&2; exit 1) \
 && mkdir -p /root/.ssh /run/sshd \
 && printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys \
 && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
