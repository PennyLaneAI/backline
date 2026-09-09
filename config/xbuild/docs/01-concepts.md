# 1. Concepts — what cross-compiling actually requires

Read this once. It is the mental model the rest of the tree assumes, and it is
short. If you already know what a sysroot is and why `$ORIGIN` matters, skip to
`02-adding-a-target.md`.

## The problem

You want a binary that runs on machine B, but you are sitting at machine A.
Machine B might be an ARM board, a server you cannot log into interactively, or a
device with 512 MB of RAM that could not compile this in a week.

The naive approach — compile on A, copy to B — fails, and it fails in four
distinct ways that are worth being able to tell apart, because each has a different
fix and only the first is obvious.

### Failure 1: wrong instruction set, or wrong binary format

A binary compiled for x86-64 contains x86-64 machine code. An ARM CPU cannot
execute it — and the coarser version of the same failure is a whole file format the
kernel does not recognise: a Linux ELF binary loads on no Mac, and a Mach-O binary
on no Linux box.

    ./myprogram
    -bash: ./myprogram: cannot execute binary file: Exec format error

That wording is Linux's, and this is the one failure in the four that a Mac can
*hide*. An Apple Silicon machine with Rosetta 2 installed will quietly run an
x86-64 Mach-O binary — measured on one: an executable built with `-arch x86_64`
ran to completion and exited 0. So on a Mac the wrong architecture may produce no
symptom at all on the build host and fail only on the machine you were building
for, which is the strongest argument in this file for checking the artifact rather
than trying it.

**Fix:** tell the compiler what to emit — `--target=aarch64-linux-gnu`. In this
tree that is `TARGET_TRIPLE`, and the format follows from the OS named in it —
`tools/arch-table.sh` maps `linux` to `elf` and `darwin` to `macho`, which the rest
of the tree reads as `TARGET_BINFMT`. `make sysroot-info` prints it.

This one is easy because it fails immediately and unambiguously — and `make
verify` gets there first, comparing the artifact's first four bytes against the
format the triple implies, so neither half of this reaches the target machine.

### Failure 2: wrong headers and libraries

Your program `#include`s `<stdio.h>` and links against `libc`. Compiling on A
reads *A's* `stdio.h` and links *A's* libc — which is the wrong architecture, and
possibly a different libc implementation entirely.

**Fix:** a **sysroot** — a copy of B's filesystem, or at least its `/usr/include`
and its libraries. You point the compiler at it with `--sysroot=`, and it looks
there instead of at `/`.

This is the single most important idea in cross-compilation, and it is where most
of this build system's machinery lives.

### Failure 3: wrong loader path (an ELF mechanism)

Every dynamically-linked **ELF** executable contains the *absolute path* of the
program that loads it — the ELF interpreter — and that path varies by distro and by
board. On Debian x86-64 it is `/lib64/ld-linux-x86-64.so.2`; on a Yocto-derived
embedded ARM root it is usually `/lib/ld-linux-aarch64.so.1`.

If the path baked in does not exist on B, you get:

    ./myprogram
    -bash: ./myprogram: No such file or directory

The file is right there. You can `ls` it. The message is about the **loader**
named inside the binary, not about the binary. This wastes an afternoon the first
time you meet it, and it is why this tree has `TARGET_DYNAMIC_LINKER` and checks
it before you deploy.

Mach-O has nothing here to get wrong: its loader is the platform constant
`/usr/lib/dyld`, the same on every Mac, not a per-target choice. So
`TARGET_DYNAMIC_LINKER` applies to ELF targets only, and `make verify` reports the
check as `n/a` on a Darwin target rather than dropping it.

### Failure 4: symbol versions (glibc) — the silent one

glibc tags every exported symbol with the version that introduced it. A binary
built against glibc 2.39 may reference `GLIBC_2.38` symbols. Copy it to a machine
with glibc 2.31 and:

    ./myprogram: /lib/libc.so.6: version `GLIBC_2.38' not found

This links perfectly on A. It only fails on B. Worse, if A and B have the *same*
architecture, a build that accidentally used A's libraries produces a binary that
looks correct, loads, runs — and is subtly wrong.

**Fix:** know B's libc version and check every artifact against it before shipping.
That is `TARGET_LIBC_VERSION` plus `make verify`. This check is the reason the
build system asks you for a version number that feels like bureaucracy.

Symbol versioning is a glibc mechanism, so this failure — and the field — belong to
glibc targets. Darwin has none, and leaves `TARGET_LIBC_VERSION` empty. The
equivalent guarantee there comes from the SDK you compiled against and the
deployment target the compiler records in the binary as `LC_BUILD_VERSION`:
enforced while building rather than checked afterwards, which is the one place
Mach-O has the easier story.

## The pieces, and what each one solves

| piece | solves | in this tree |
|---|---|---|
| target triple | failure 1 | `TARGET_TRIPLE` |
| binary format | failure 1, coarsely | `TARGET_BINFMT`, derived from the triple |
| sysroot | failure 2 | `SYSROOT_PROVIDER`, `sysroot/` |
| interpreter path (ELF only) | failure 3 | `TARGET_DYNAMIC_LINKER` |
| libc version ceiling (glibc only) | failure 4 | `TARGET_LIBC_VERSION` + `make verify` |

## What a sysroot is, concretely

Just a directory. For a Linux target, a slice of the device's own root:

    build/sysroots/my-board/
      usr/include/        stdio.h, stdlib.h, and everything else
      usr/lib/            libc.so.6, libstdc++.so.6, libm.so.6, ...
      lib/                the ELF interpreter, more libraries

Pass `--sysroot=build/sysroots/my-board` and the compiler treats that directory as
`/`. `#include <stdio.h>` reads `build/sysroots/my-board/usr/include/stdio.h`.

A macOS SDK is the same idea with different contents:

    build/sysroots/example-native/ -> /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
      usr/include/            stdio.h, stdlib.h, and everything else
      usr/include/c++/v1/     the libc++ headers — v1 is an ABI version, not a
                              compiler version, so there is nothing to choose
      usr/lib/libSystem.tbd   the C library, as a text stub rather than a library

The stub is the part worth knowing. Since Big Sur the system libraries have no
on-disk files at all — they live only inside the dyld shared cache — so there is no
`libSystem.dylib` anywhere to link against, and the SDK ships `.tbd` text files in
their place: ASCII, starting `--- !tapi-tbd`, declaring an
`install-name: '/usr/lib/libSystem.B.dylib'` for a path that exists on no Mac,
followed by the symbols that library exports. That is all a linker needs, since its
job is only to establish that a symbol will be there.

It is also why the sysroot of a native target cannot simply be written down as `/`:
native is a target whose sysroot is *discovered* from the host — `/` on Linux, the
SDK that `xcrun --show-sdk-path` reports on macOS. See `04-sysroot-providers.md`.

### Where a sysroot comes from — and why this tree makes it pluggable

Four honest options, best first:

1. **Copy it off the real device.** No guessing: the libraries you compile against
   are the ones your binary will meet. `SYSROOT_PROVIDER=ssh-rsync`.
2. **Use one someone already produced** — a Yocto SDK, Buildroot staging tree, or
   vendor BSP. `SYSROOT_PROVIDER=dir`.
3. **Extract a container image.** Reproducible to the byte if you pin a digest.
   `SYSROOT_PROVIDER=oci`.
4. **Construct one from a distro archive.** Only works for Debian-family targets, and
   produces an *approximation* — you pick a release and hope its glibc matches. Two ways:
   `SYSROOT_PROVIDER=deb` unpacks named packages and needs no root, no Linux and no `qemu`
   (this is the one the shipped board target uses); `SYSROOT_PROVIDER=debootstrap` bootstraps
   a whole root and needs both.

The design this tree replaces implemented only option 4, which is why it was
structurally unable to target a musl device, a Yocto board, or a Fedora server —
and why it had to guess at glibc versions. Options 1–3 remove the guessing
entirely.

### Why symlinks inside a sysroot need fixing

A rootfs is full of absolute symlinks. `/usr/lib/libfoo.so -> /lib/libfoo.so.1`
is correct on the device. Copied into your sysroot, it now points at **your build
host's** `/lib/libfoo.so.1`.

If your host has no such file: the link dangles and the linker complains about a
library you can see. If your host has one for a different architecture: a confusing
"incompatible file format". If your host has one for the same architecture but a
different version: **it links and the binary is silently wrong.**

`make sysroot` runs `sysroot/normalise/relocate-symlinks.py` to rewrite those links
as sysroot-relative, so the sysroot works at any path on any host. This is not
the same as `symlinks -c`, which resolves against the real root and would walk out
of the sysroot.

## `$ORIGIN` and `@loader_path` — why bundles are self-contained

Your program needs `libmydevice.so` at runtime. The loader searches system
directories; your library is not there.

The usual workaround is `LD_LIBRARY_PATH=/path/to/libs ./myprogram`. It works, and
it is fragile: everyone must remember it, in every service file and cron job.

The better answer is an rpath baked into the binary at link time, holding the token
that means *the directory this file was loaded from*. Both formats have such a
token and they are spelled differently — `$ORIGIN` for ELF, `@loader_path` for
Mach-O — and it is expanded *by the loader*. So a directory containing a program and
its libraries works wherever you put it, with no environment variables:

    scp -r bundle/ board:/tmp/     # anywhere
    ssh board '/tmp/bundle/myprogram'

That is `TARGET_RPATH=$$ORIGIN` (doubled because Make needs an escaped `$`; a single
one leaves the literal string `RIGIN` in the binary). Better still, leave
`TARGET_RPATH` empty and let the format decide, because getting it wrong is not
symmetrical: ld64 *accepts* the ELF spelling and records `$ORIGIN` verbatim, dyld
has no such token, and the result links, verifies under any check that merely asks
whether an rpath is present, and then cannot find the library sitting beside it.
`make verify` treats that one as a hard failure.

One subtlety worth knowing: for an ELF target this tree also passes
`--disable-new-dtags`, which asks for `DT_RPATH` rather than the newer
`DT_RUNPATH`. The difference matters — `DT_RUNPATH` does *not* apply to a
library's own transitive dependencies. With RUNPATH, a bundle where `liba.so`
needs `libb.so` beside it fails; with RPATH it works. Mach-O has neither the
choice to make — `LC_RPATH` already covers transitive loads — nor the flag to
accept it with:

    ld64.lld: error: unknown argument '--disable-new-dtags'

## How this tree is organised

    targets/       machines you build FOR      (data)
    components/    things you build            (data)
    bundles/       sets of things to deploy    (data)
    mk/            the build engine            (code — target-agnostic)
    tools/         helpers                     (code — target-agnostic)
                   ... including arch-table.sh: the one table of architecture
                   facts, so adding an ARCHITECTURE is also just data
    sysroot/       acquiring and normalising sysroots
    docs/          this
    tests/         the regression suite
    build/         everything generated (safe to delete)

The rule: **data files name machines, code files never do.** Adding a board means
writing one file in `targets/`. If you find yourself editing `mk/` or `tools/` to
add hardware, that is a bug in this tree, not a thing you were supposed to do.

### Why that rule, and not the obvious alternative

The obvious way to support a second machine is to copy the recipe you have and change
the parts that differ. It works, and for two machines it is genuinely cheaper than any
abstraction. The cost is not visible until later, and it is arithmetic rather than
carelessness: a build that names its targets in its *code* couples every component to
every target, so the work of adding one more of either grows with the product of the two,
not the sum.

What that looks like in practice, for a tree building 8 artifacts across 3 targets:

| | names targets in code | names targets in data |
|---|---|---|
| files containing a target's name | 9 | 1 per target — its own description |
| hand-written per-target recipes | ~15 | 0; 3 generic ones, one per component *kind* |
| cmake toolchain files | 3, hand-written | 1 per target, generated |
| bundling scripts | 1 per machine | 1, data-driven |
| **files to edit to add a target** | **9–11** | **1** |

The failure mode of the left column is not that it breaks. It is that coverage goes
ragged: a flag gets fixed for one target and not the others, two files state the same
constant and drift, and the third machine quietly gets a slightly different build from
the first two. Nothing announces this. You find it when a binary behaves differently on
one device.

The right column is why every architecture fact lives in `tools/arch-table.sh` and every
machine fact in one `targets/*.conf` — so that "add a machine" and "add an architecture"
are both *data* edits, and there is no per-target code for them to drift out of.

## Next

- `02-adding-a-target.md` — walk through adding a real machine
- `03-how-flags-are-derived.md` — where every compiler flag comes from
- `04-sysroot-providers.md` — choosing and writing a provider
- `05-troubleshooting.md` — indexed by the error message you saw
