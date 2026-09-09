# The sysroot layer

A **sysroot** is a copy of the target machine's root filesystem — enough of it to
compile against. When you cross-compile, the compiler must read the *target's*
headers and link against the *target's* libraries, not the build machine's. Get
this wrong and the binary links fine and then dies on the device with a message
about a symbol version.

This directory contains three things, and the separation between them is the point:

| subdir | responsibility | knows about |
|---|---|---|
| `providers/` | **acquire** a sysroot from somewhere | one source each (ssh, tar, oci, this machine, …) |
| `normalise/` | **make it relocatable and safe to compile against** | nothing about where it came from |
| `probe/` | **ask a live target what it is**, so you can write its description | nothing about sysroots |

## Why this is split into providers

The design being generalised had exactly one way to get a sysroot: run
`debootstrap` to construct an approximation of the target from a Debian/Ubuntu
archive. That single choice imposed four unrelated requirements on anyone using
the build system:

1. **The target had to be Debian-family.** `debootstrap` cannot produce a Yocto,
   Buildroot, Alpine, Fedora, or vendor-BSP root. A Yocto-derived board root gets
   approximated with an Ubuntu suite because their glibc versions happen to
   coincide — a coincidence, load-bearing and usually undocumented.
2. **The build host needed root.** `debootstrap` and `chroot` require it. That
   rules out shared CI runners, unprivileged containers, and any environment where
   you cannot `sudo`.
3. **The build host had to be Linux/x86_64 with `binfmt_misc`** to run the
   foreign-architecture `apt` inside the chroot via `qemu-user-static`.
4. **You had to know the target's distro codename**, and get it right. The
   installer asked for it, guessed from a glibc-to-codename lookup table hardcoded
   in two separate files, and warned you if they disagreed — a warning you could
   click through into a subtly broken build.

None of those four are inherent to cross-compilation. They are consequences of one
acquisition strategy. Making acquisition a plugin removes all four at once, and
makes the *best* strategy available: copy the actual filesystem off the actual
device, where there is nothing to approximate and no version to guess.

`debootstrap` remains available as one provider among several, for the case where
it genuinely fits (you are targeting a Debian machine that does not exist yet).

## The provider contract

A provider is any executable in `providers/`. It is invoked as:

    providers/<name> <destination-dir> <args-string> <target-conf-file>

and must obey five rules:

1. **Populate `<destination-dir>` with a filesystem tree.** Create it if needed.
2. **Be idempotent.** Running twice must not corrupt anything. Prefer updating
   in place (`rsync`) over delete-and-refetch, because refetching a rootfs over a
   slow link is a coffee break.
3. **Exit non-zero with a message on stderr naming what was missing.** "Could not
   reach host X" is useful; `exit 1` is not.
4. **Not require root.** If a provider cannot avoid it, it must say so in its
   `--help` and fail with that explanation rather than a permissions error.
5. **Not write anywhere except `<destination-dir>`** and a temp dir.

Providers must NOT normalise symlinks, strip anything, or set flags. That is
`normalise/`'s job, and it runs after every provider — so a new provider gets
correct relocatable behaviour for free rather than having to reimplement it.

## Adding a provider

Write one executable, make it exit 0. That is the whole checklist. There is no
registry to update: `make sysroot` looks for `providers/$SYSROOT_PROVIDER` and
runs it, so the filename *is* the registration.

    cp providers/dir providers/my-artifact-store
    $EDITOR providers/my-artifact-store
    chmod +x providers/my-artifact-store
    # then in a target description:
    #   SYSROOT_PROVIDER=my-artifact-store
    #   SYSROOT_PROVIDER_ARGS="bucket=… key=…"

## Which provider should I use?

Decide by asking whether the machine exists yet.

**The machine exists and you can reach it** → `ssh-rsync`. This is the best
option and should be your default. You get the true libc, the true library
versions, and the true interpreter path, with no guessing. Combine it with
`make probe` to fill in the ABI fields of the target description automatically.

**The machine exists but is not reachable from the build host** (airgapped lab,
different network) → `tar`. Someone runs one `tar` command on the device, moves
the file by whatever means work, and you point the provider at it.

**A build system already produced a staging tree** (Yocto SDK, Buildroot output,
vendor BSP) → `dir`. Do not copy it; consume it where it lies.

**The target is this machine** → `native`. It discovers where this host keeps its
headers and libraries — `/` on Linux, the SDK `xcrun --show-sdk-path` reports on
macOS, where there is no `libSystem.dylib` under `/usr/lib` to link against — because
that answer differs per platform and a description cannot run a command to find out.
Symlinks, never copies.

**The target is defined by a container image** → `oci`. Extracts image layers with
no daemon and no root, via `skopeo`/`umoci` if present.

**The machine does not exist yet and will be Debian-family** → `debootstrap`.
The original strategy, kept honest about its requirements: it needs root, needs a
network, and can only produce Debian-family roots.

**Someone else's problem** → `none`, plus `SYSROOT_DIR=/path/to/tree`.
