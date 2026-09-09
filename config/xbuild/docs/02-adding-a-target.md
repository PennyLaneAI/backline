# 2. Adding a target

Adding a machine means writing **one file**. This walks through it twice: the easy
way (the machine exists and you can reach it) and the manual way (it does not yet).

## The easy way — let the machine tell you

If you can `ssh` to it:

    make probe TARGET=my-board SSH=user@192.168.1.50

That copies a small POSIX-shell script to the board, runs it, brings the answers
back, and writes `targets/my-board.conf`. It reads, in particular, the three values
you must not guess:

* **glibc version** — wrong value means a binary that links here and dies there.
* **C++ ABI level** — same.
* **ELF interpreter path** — wrong value means "No such file or directory" on a
  file that visibly exists.

Then:

    make sysroot TARGET=my-board      # copies its libraries over
    make build   TARGET=my-board      # builds every component
    make verify  TARGET=my-board      # checks each artifact against that ABI
    make bundle  TARGET=my-board BUNDLE=example-minimal

The probe needs only `sh` and coreutils on the target — no bash, no python, no
compiler. It works on busybox.

## The manual way

    make new-target TARGET=my-board
    $EDITOR targets/my-board.conf

Only two fields are mandatory. Everything else has a defensible default, and
`make show-target TARGET=my-board` prints what the defaults became.

### Minimum viable description

```sh
TARGET_NAME=my-board
TARGET_TRIPLE=aarch64-linux-gnu
SYSROOT_PROVIDER=ssh-rsync
SYSROOT_PROVIDER_ARGS="host=root@192.168.1.50"
```

That builds. It just does not *verify* much, because with no ABI fields the checks
have nothing to compare against — `make show-target` says so explicitly rather
than letting you believe you are protected.

### Filling in the ABI fields by hand

Run these on the target:

```sh
# glibc version  -> TARGET_LIBC_VERSION
getconf GNU_LIBC_VERSION            # e.g. "glibc 2.39"  -> 2.39
ldd --version | head -1             # fallback

# C++ ABI ceiling -> TARGET_CXXABI_MAX
strings /usr/lib/*/libstdc++.so.6 | grep '^GLIBCXX_' | sort -V | tail -1

# ELF interpreter -> TARGET_DYNAMIC_LINKER
readelf -l /bin/sh | grep interpreter
# no readelf on the board? try:
strings /bin/sh | grep '^/lib.*ld-'
```

If `ldd --version` says "musl", set `TARGET_LIBC=musl` and leave
`TARGET_LIBC_VERSION` empty — musl does not use symbol versioning, and the
verifier skips that check automatically rather than reporting a false problem.

For a **Darwin** target none of those three probes has an answer — `getconf`
replies "no such configuration parameter", and there is no `ldd` and no `readelf`
— because none of the three fields means anything there: no glibc symbol
versioning, no `GLIBCXX_` ABI level, and Mach-O records no interpreter path at
all, dyld being chosen by the kernel. Leave
`TARGET_LIBC_VERSION`, `TARGET_CXXABI_MAX` and `TARGET_DYNAMIC_LINKER` empty;
`make verify` then reports each of those three as `n/a` and says why, rather than
quietly running one fewer check.

## Choosing values that will not bite you

`TARGET_LIBC`, `TARGET_STDLIB`, `TARGET_LINKER` and `TARGET_RPATH` all follow the
target's **binary format** when left blank, so blank is the portable answer and a
value commits the description to one format — which is why
`targets/example-native.conf` leaves all four empty and works unchanged on Linux
and macOS. `make show-target` prints what each one resolved to.

### `TARGET_CPU` — leave it empty

Setting `TARGET_CPU=cortex-a72` lets the compiler emit instructions that only
exist on that core. The binary then **SIGILLs** on an older chip in the same
family, and the crash looks like memory corruption rather than a wrong flag.

Empty means "generic for the architecture", which runs on every chip of that
family. Set a CPU only when the whole fleet is that exact part *and* you have
measured a benefit. Note that `make probe` deliberately leaves it empty even though
it knows the CPU model — that is a decision for a human.

### `TARGET_CPU_FLAG` — architecture-dependent, and a hard error if wrong

ARM uses `-mcpu=`; x86 and RISC-V use `-march=`. clang **rejects** `-mcpu=` for
x86 outright. The default is picked per-architecture, so you rarely set this.

### `TARGET_RPATH` — leave it empty, or keep `$$ORIGIN` for an ELF target

An rpath of "look next to me" is what makes a bundle work wherever it is
unpacked, with no `LD_LIBRARY_PATH`. Empty resolves to the token that means that
in the target's format: `$$ORIGIN` for ELF, `@loader_path` for Mach-O. If you do
write the ELF form out, the doubled `$$` is Make escaping for one literal `$`;
the compiler receives `$ORIGIN`. See `01-concepts.md`.

Do not carry `$$ORIGIN` over to a Darwin target; leaving it blank is the whole point.
`docs/01-concepts.md` explains why that particular mistake survives the link.

### `TARGET_STDLIB` — empty, or `libstdc++` for a glibc target

Empty gives `libstdc++` where the format is ELF and `libc++` where it is Mach-O.
`libstdc++` is right for a glibc target; musl toolchains commonly pair with
`libc++`; macOS ships no libstdc++ **at all**, so naming it there produces
`clang++: warning: include path for libstdc++ headers not found` and then
`ld: library 'stdc++' not found`. Getting it wrong produces missing-header or
missing-symbol errors at link time — loud, at least.

## Verify your description before a long build

    make show-target TARGET=my-board

Read the output. It prints every resolved value and — at the bottom — the exact
compiler and linker command-line fragments every component will receive. If
something looks wrong there, it is wrong; nothing downstream adds
target-specific flags.

Then check the sysroot is what you expect:

    make sysroot-info TARGET=my-board

This reports the binary format it deduced from the triple, the library directory
it found, the libc it found there (`libc.so*` for ELF, `libSystem.tbd` and
friends for Mach-O), the C++ header version it will use (an SDK reports none —
libc++'s headers live unversioned at `usr/include/c++/v1`), and — for an ELF
target — which interpreters exist in the tree. If that interpreter list does not include
your `TARGET_DYNAMIC_LINKER`, fix it now rather than discovering it on the device.
For a Mach-O target there is no such path to get wrong, and the last line says so:

    interp  : n/a (Mach-O names no interpreter; dyld is chosen by the kernel)

## Bring-up order that saves time

On a new board, build `hello-world` first:

    make build TARGET=my-board COMPONENT=hello-world
    make verify TARGET=my-board

It has no external dependencies, so if it compiles, links and verifies, then your
toolchain, sysroot, triple, interpreter path and ABI settings are all correct. Any
later failure is then about the application, not the cross-build setup. Debugging
those two things simultaneously is what makes bring-up miserable.

Copy it to the board and run it — it prints which target it was built for, which
is a decisive end-to-end confirmation:

    scp build/my-board/components/hello-world/hello-world board:/tmp/
    ssh board /tmp/hello-world

## Common first-time problems

**"sysroot exists but contains no C library"** — the provider copied the wrong
directory. A sysroot's root contains `usr/` and `lib/`, not a nested subdirectory.
For the `tar` provider, try `strip=1`. The message lists the filenames it looked
for, chosen for the target's format, so read that list before assuming a bad copy.

On macOS the same message can be literally true of a perfectly healthy machine.
With `SYSROOT_PROVIDER=dir` and `path=/` you get

    ERROR: '/' exists but contains no C library, so it cannot be a sysroot.

because since Big Sur the system libraries have no on-disk files at all — they
live only in the dyld shared cache, and what you link against is the SDK's `.tbd`
stubs. Use `SYSROOT_PROVIDER=native`, which asks `xcrun --show-sdk-path` where
that SDK is.

**"bits/c++config.h: No such file"** — the sysroot has C++ headers but not the
architecture-specific ones. Usually a partial copy; check `make sysroot-info`
reports a C++ header version.

**Everything builds but `make verify` reports "libc too new"** — your sysroot is
newer than the target. If the sysroot came from the device, then
`TARGET_LIBC_VERSION` is wrong; re-run `make probe`. If it came from
`debootstrap`, you picked the wrong release — this is exactly the guessing problem
that `ssh-rsync` avoids.

More in `05-troubleshooting.md`, indexed by the message you actually saw.

## Adding a target does not touch anything else

Worth stating plainly, because it is the whole design goal: you did not edit a
Makefile, write a cmake toolchain file, add a build rule, or modify any component.
Every component builds for your new machine already, because no component knows
what a machine is.
