# 4. Sysroot providers — where the target's libraries come from

A **provider** is an executable that fills a directory with a target's filesystem.
Which one runs is chosen per target by `SYSROOT_PROVIDER`.

Why this is pluggable at all is argued in `sysroot/README.md`; the short version is
that the design being generalised had exactly one strategy (`debootstrap`), and that
one choice imposed four unrelated requirements — Debian-family target, root on the
build host, `binfmt_misc` for cross-arch, and a glibc version you had to guess.

## Choosing one

The deciding question is whether the machine exists yet.

| situation | provider | why |
|---|---|---|
| The machine exists and you can reach it | **`ssh-rsync`** | Copies the real libraries. No guessing, no approximation. **Start here.** |
| It exists but is unreachable from the build host | `tar` | One `tar` on the device; move the file by any means. |
| A build system already produced a staging tree | `dir` | Consume a Yocto SDK / Buildroot output / vendor BSP where it lies. |
| The target *is* this machine | `native` | Where a machine keeps its headers differs per platform — `/` on Linux, the SDK `xcrun` reports on macOS — and a description cannot run a command to find out. |
| The target is defined by a container image | `oci` | Pin a digest and every build for years is byte-identical. |
| It exists, but you cannot reach it from this build host — and it is Debian-family | **`deb`** | Assembles a matching root from distribution packages. No root, no Linux, no `qemu`. |
| It does not exist yet, and will be Debian-family | `debootstrap` | Same idea as `deb`, but needs root and a Linux host. Prefer `deb` unless you need a full bootstrap. |
| Managed entirely outside this build system | `none` | Declares "do not touch this tree". |

## `ssh-rsync` — the recommended default

```sh
SYSROOT_PROVIDER=ssh-rsync
SYSROOT_PROVIDER_ARGS="host=user@my-board.local port=22"
```

Optional: `paths=/lib,/usr/lib,/usr/include,/opt/vendor` (comma-separated, since the argument string is split on whitespace), `exclude="pattern,…"`,
`sudo=yes` (for root-only-readable files; needs passwordless sudo on the target).

Copies only what a compile needs — libraries, the interpreter, headers — and
excludes kernel modules, firmware, locales, docs and debug symbols. Copying all of
`/` would be slow, large, and would pull target data (possibly credentials) onto
the build host for no benefit.

Requires `rsync` on both sides. If the target has only `tar`, use the `tar`
provider; the error message says so.

The progress display is optional: this provider and `dir`'s `mode=copy` probe for
`--info=progress2` (rsync 3.1+) and drop it when absent, because macOS 15 replaced
Samba rsync with openrsync (protocol 29), which rejects the flag outright — and a
sysroot fetch failing over a progress bar is the wrong trade.

## `tar`

```sh
SYSROOT_PROVIDER=tar
SYSROOT_PROVIDER_ARGS="path=/mnt/share/board-rootfs.tar.gz sha256=ab12…"
```

Also accepts `url=` (fetched with curl or wget) and `strip=N`.

To produce the archive, on the target:

```sh
tar -czf /tmp/sysroot.tar.gz -C / \
    --exclude='lib/modules' --exclude='lib/firmware' \
    lib lib64 usr/lib usr/lib64 usr/include 2>/dev/null
```

Supply `sha256=` when you can. A sysroot truncated in transit produces
missing-symbol errors at link time that look like source bugs; one hash turns that
into an immediate, unambiguous failure.

## `dir`

```sh
SYSROOT_PROVIDER=dir
SYSROOT_PROVIDER_ARGS="path=/opt/poky/3.1/sysroots/aarch64-poky-linux mode=reference"
```

`mode=reference` (default) symlinks — instant, no disk, and does not modify the
source tree. `mode=copy` takes a snapshot; use it when the source may change under
you, or when symlink normalisation must run and the source must stay untouched.

For a Yocto SDK the sysroot is usually a few levels down, not the SDK root.

## `native`

```sh
SYSROOT_PROVIDER=native
```

Optional: `path=<dir>`, which overrides the discovery entirely. It is an escape
hatch and is rarely needed — the point of this provider is that it asks.

Discovers where *this* machine keeps the headers and libraries you compile
against, which is a question with a different answer per platform and one a
description cannot answer, since descriptions are inert data.

On Linux it is `/`. On macOS it is the SDK from `xcrun --show-sdk-path`:
since Big Sur the system libraries have no on-disk files at all — they live only
in the dyld shared cache — and what you compile against is a set of `.tbd` text
stubs. So a description saying `dir` with `path=/` is correct on one platform and
wrong on the other, and the wrongness is not subtle:

```
ERROR: '/' exists but contains no C library, so it cannot be a sysroot.
```

on a Mac whose C library works perfectly. Asking a tool where the sysroot is,
rather than encoding a path, is the same rule `tools/detect-host.sh` already
applies to the toolchain.

Symlinks, never copies — like `dir` in its default mode, so no disk goes on
duplicating a tree that is already here.

Requires `xcrun` on macOS, from the Command Line Tools (`xcode-select --install`);
nothing at all elsewhere. `targets/example-native.conf` uses it, which is what
lets that one description work unchanged on both platforms.

## `oci`

```sh
SYSROOT_PROVIDER=oci
SYSROOT_PROVIDER_ARGS="image=arm64v8/debian:12 platform=linux/arm64"
```

Prefers `skopeo` (daemonless, rootless), falling back to `podman` or `docker`.

Pin a digest (`image@sha256:…`) for genuine reproducibility. Use a build/dev image,
not a slim runtime one — a distroless image has no headers, and the resulting error
names a header rather than the image. The provider warns when `usr/include` is
absent, where the cause is still visible.

## `debootstrap`

```sh
SYSROOT_PROVIDER=debootstrap
SYSROOT_PROVIDER_ARGS="release=bookworm arch=arm64 packages=libibverbs-dev"
```

Kept, and honest about its constraints: needs root, needs a network, produces only
Debian-family glibc roots, and cross-architecture needs `qemu-user-static` with
`binfmt_misc` registered on the host kernel.

It refuses outright if the target declares `TARGET_LIBC=musl`, rather than producing
a glibc root for a musl target.

It also `chown`s the finished tree back to you, so the build that follows — and
`make clean` — need no root. The original design required a separate sudo-using
clean target because of exactly this.

Remember what it fundamentally is: you pick a release codename and hope its glibc
matches the target's. If the target exists, `ssh-rsync` removes that gamble.

## `deb`

```sh
SYSROOT_PROVIDER=deb
SYSROOT_PROVIDER_ARGS="suite=noble arch=arm64 add=libibverbs-dev,libibverbs1"
```

This is the provider most readers meet first: it is what the board target shipped in this
repository uses, and therefore what the walkthrough in the top-level `INSTALL.md` invokes.

It is `debootstrap`'s idea without `debootstrap`'s requirements. It resolves a fixed package
list against a distribution archive, downloads the `.deb` files, and unpacks their payloads
into the sysroot. A `.deb` is an `ar` archive containing `data.tar.*`, so all it needs is
`curl`, `ar`, `tar` and (for modern payloads) `zstd`.

| | |
|---|---|
| root | not needed |
| Linux | not needed — works the same on macOS |
| `qemu` / `binfmt_misc` | not needed; nothing foreign is ever executed |
| network | yes, once per fetch |

Arguments:

| arg | meaning |
|---|---|
| `suite=` | **required, no default.** The suite decides the glibc and libstdc++ versions you will link against; guessing it is how a sysroot ends up describing a different machine. |
| `arch=` | Debian architecture. Derived from `TARGET_TRIPLE` if omitted. |
| `mirror=` | archive URL, if you have a local or pinned one. |
| `packages=` | replaces the default base set entirely. |
| `add=` | comma-separated additions to the base set. Use it when a component links something outside the base set — a component declaring `COMPONENT_LIBS=ibverbs`, for instance, needs `libibverbs-dev` added here or the build stops naming that library. |

Every package version it resolved is written to `.crossbuild-deb-packages` in the sysroot.
Read that as a **record, not a lock**: nothing reads it back, and there is no pin argument, so
a re-fetch resolves against whatever the archive serves that day. Its value is telling you
what changed between a build that worked and one that does not.

It has the same fundamental caveat as `debootstrap`: you are picking a distribution whose
ABI you *hope* matches the target's. A typical outcome is a suite that matches on glibc and
is one version high on both C++ ABI axes — which is exactly why `TARGET_CXXABI_MAX` exists
and why `make verify` is not optional when you use this provider. Any target description
using it should carry both ceilings, read off the real machine with `make probe`. If the
machine exists and you can reach it, `ssh-rsync` removes the gamble entirely.

If a fetch fails partway with `could not unpack the data archive from <package>`, run it
again — a truncated download is the usual cause, the archive is re-fetched from scratch, and
the error now includes what `tar` actually said so you can tell that from a full disk.

## `none`

```sh
SYSROOT_PROVIDER=none
SYSROOT_DIR=/opt/vendor-bsp/sysroot
```

Asserts the sysroot is managed elsewhere. Nothing is fetched, copied, or
normalised. Use it for a shared, read-only, or expensively-produced sysroot where
you want a guarantee the build will not touch it.

## What happens after a provider runs

`tools/get-sysroot.sh` always does the same three things, whichever provider ran:

1. **Normalise symlinks** (`sysroot/normalise/relocate-symlinks.py`) so the tree
   works at any path on any host. Skipped for `none` and for a referenced tree,
   because those belong to someone else.
2. **Validate** — confirm a libc is actually present, and report the layout it
   found.
3. **Write a provenance marker** recording which provider ran, with what arguments
   and when, so "where did this sysroot come from?" is answerable weeks later.

Because these are here rather than in each provider, a new provider inherits all
three for free.

## Writing your own

The whole contract:

    providers/<name> <destination-dir> <args-string> <target-conf-file>

Fill the directory. Exit non-zero with a message naming what was missing. Be
idempotent. Do not require root. Do not write outside the destination.

Do **not** normalise symlinks, strip, or set flags — that is handled for you.

    cp sysroot/providers/dir sysroot/providers/my-store
    $EDITOR sysroot/providers/my-store
    chmod +x sysroot/providers/my-store

Then `SYSROOT_PROVIDER=my-store`. There is no registry to update: the filename is
the registration.
