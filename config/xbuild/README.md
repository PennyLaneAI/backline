# xbuild — build binaries for a machine that is not this one

A cross-compilation build system with each deployment machine specified.

Adding hardware requires adding to a single file. Once updated, this should propagate to
all relevant toolchain/builds.

```
targets/<name>.conf      a machine you want binaries for      \
components/<name>.conf   a thing you want built                | you write these
bundles/<name>.conf      a set of things to deploy together   /

mk/  tools/  sysroot/    the engine — target-agnostic
```

[`../../INSTALL.md`](../../INSTALL.md) names the targets, components and bundles this project's
demos need and has been run end to end. This page documents the build system itself.

## Why this needs more than a `--target` flag

A compiler can emits aarch64 code trivially. The hard part is that every fact about the other machine
is a guess until you look, and a wrong guess does not fail at build time. It fails on the device,
hours later, with a message pointing somewhere else. Which guess bites depends on the target's
binary format:

| format | what you got wrong | what you see, on the target, much later |
|---|---|---|
| ELF | its glibc is older than yours | ``version `GLIBC_2.38' not found`` |
| ELF | its libstdc++ is older | ``GLIBCXX_3.4.32 not found`` |
| ELF | its loader lives elsewhere | `No such file or directory`, for a file that is right there |
| Mach-O | you used ELF's rpath spelling `$ORIGIN` | nothing at link time: `ld64` accepts it and records it verbatim, `dyld` has no such token, and a library sitting beside the binary is not found |
| both | you linked *your* libraries | works on your desk, crashes on the device |

Hence the shape of the workflow: let the machine describe itself (`make probe`), copy its real
libraries (`make sysroot`), build against those, and check the artifact before deploying
(`make verify`). Each step converts a remote mystery into a local, specific error.

## Commands

```bash
make doctor        # can this host cross-compile? what is missing, and how to install it
make list-targets  # which machines are already described
make list-bundles  # what can be deployed, deliverables listed separately from examples
make quickstart    # a guided first build that explains each step as it runs
make help          # every command
```

**Run `make list-targets` first.** A target that is listed is a machine somebody has already
described, and you skip straight to building. Re-probing a described machine costs a network round
trip, a second redundant description, and — if the machine is not reachable from where you are
sitting — a failure that looks like the build system's fault.

## Two paths to a first build

Neither requires hardware. Path 1 builds for this machine; path 2 builds for a real aarch64
machine that happens to be a container on your laptop.

### Path 1 — this machine

Two minutes, and it installs nothing. `example-native` describes whatever host you are on: it
names no triple, libc or linker, and discovers all three. Native is not a special case here, but a
target whose sysroot is this machine — `/` on Linux, the SDK `xcrun` reports on macOS — found by
the `native` provider rather than written into the description. Same recipes, same verifier, same
bundler.

```bash
cd config/xbuild
make doctor  TARGET=example-native
make sysroot TARGET=example-native
make build   TARGET=example-native COMPONENT=hello-world
make verify  TARGET=example-native
./build/example-native/components/hello-world/hello-world
```

This prints `hello from crossbuild` and the target it was built for. If that works the machinery is
sound, and anything that fails later is about Catalyst, the sysroot or the board.

Pass `TARGET=` to `doctor` here. Without one it grades this host against *every* target described
in the tree, including the board, so a Mac carrying only the Xcode command line tools is told it is
missing `readelf` and exits non-zero. That is true of the VPK120 and irrelevant to this test, which
never touches `readelf`.

`make quickstart` covers the same ground interactively and ends at a bundle. Then read
[`targets/example-native.conf`](targets/example-native.conf), where every field says why it holds
the value it does.

### Path 2 — a real aarch64 machine

The container runs aarch64 through qemu binfmt, so nothing is simulated: the compiler genuinely
cross-compiles, and a mistake genuinely produces `Exec format error`.

This requires a container **engine** running, not only the `docker` CLI. On a fresh Mac,
`brew install colima && colima start`, or Docker Desktop; the repository does not ship one. This
path builds ELF and verifies it, so it also requires `readelf` or `llvm-readelf` on `PATH`, which
is what `make doctor` reports.

```bash
make doctor                         # what this host is missing
make pseudo-remote                  # aarch64 box on ssh port 2222
make pseudo-remote PORT=2223        # ...or another port, if 2222 is taken
```

That builds [`examples/docker/Dockerfile`](examples/docker/Dockerfile), authorises your
`~/.ssh/*.pub`, waits for sshd and prints the next commands. From there, treat it exactly as a
board on your desk:

```bash
# 1. let the machine describe itself
make probe TARGET=demo-box SSH=root@localhost PORT=2222

# 2. copy its headers and libraries
make sysroot TARGET=demo-box

# 3. build, and check the artifact before it leaves the build host
make build  TARGET=demo-box COMPONENT=hello-world
make verify TARGET=demo-box

# 4. ship it and run it there
make bundle TARGET=demo-box BUNDLE=example-hello
make deploy TARGET=demo-box BUNDLE=example-hello SSH=root@localhost PORT=2222
ssh -p 2222 root@localhost 'cd /root/workspace && ./hello-world'
```

The last line prints `triple: aarch64-linux-gnu` from a binary your laptop cross-built. Tear it
down with `make pseudo-remote-down`.

Look at what the probe wrote in `targets/demo-box.conf`: the glibc version, the ELF interpreter
path and the C++ ABI level. Those are the three values never to guess.

## The normal flow

```bash
# 1. only if the machine is not in `make list-targets`: describe it.
#    You need its address and a login, not its CPU, libc, or loader path.
make probe TARGET=my-board SSH=user@my-board

# 2. get its headers and libraries
make sysroot TARGET=my-board

# 3. prove the toolchain works before building anything real
make build TARGET=my-board COMPONENT=hello-world
make verify TARGET=my-board

# 4. build what you want. `make list-components` shows what exists and which
#    external source trees each one needs. COMPONENT= takes several, space separated,
#    and dependencies are resolved across the whole list.
make build TARGET=my-board COMPONENT="<name> <name>" CATALYST=~/catalyst

# 5. gather, verify and deploy
make bundle TARGET=my-board BUNDLE=<name>
make deploy TARGET=my-board BUNDLE=<name> SSH=user@my-board
```

Without a board to rehearse on, `make pseudo-remote` starts an aarch64 container on ssh port 2222
that you can `probe`, `sysroot` and `deploy` against. It requires a container engine running, not
only the `docker` CLI: on a fresh Mac, `brew install colima && colima start`, or Docker Desktop.

## Why `make probe` rather than writing the file by hand

Three values carry the failures listed at the top of this page: the glibc version, the C++ ABI
level, and the ELF interpreter path. `make probe` reads all three off the machine, so none of them
is guessed. It requires only `sh` and coreutils on the target, so it works on busybox.

`TARGET_GPU_ARCH` is filled in the same way but treated as a decision rather than a probed fact: a
re-probe leaves it alone, because a bundle may target a card the probed machine does not hold. Its
spelling selects the vendor — `gfx<n>` for AMD, `sm_<n>` for NVIDIA — and a value matching neither
is refused by name. `GPU_ARCH=<arch>` on the make line overrides it for one build.

## What `make verify` checks

It reads each artifact's own headers — ELF with `readelf`, Mach-O with `otool` — and refuses to
deploy something the target cannot run:

* binary format versus the target's → catches an ELF artifact aimed at a Darwin target, and a
  Mach-O one aimed at Linux
* architecture, and ELF class → catches `Exec format error` on the build host
* ELF interpreter path → catches the `No such file or directory` mystery
* glibc symbol-version ceiling → catches ``GLIBC_2.38 not found``
* libstdc++ ABI ceiling → catches ``GLIBCXX_3.4.32 not found``
* undefined symbols from the project's own libraries → catches a component whose source list is
  missing a translation unit
* build-host paths leaked into `RPATH`/`LC_RPATH`, and an `LC_RPATH` of `$ORIGIN` (the ELF
  spelling, which ld64 accepts silently and dyld cannot expand)
* `SONAME`, or a dylib's install name, versus filename

The interpreter, glibc and libstdc++ checks are ELF-only. On a Mach-O artifact each is reported as
`n/a` with the reason rather than omitted, because a check you believe ran and did not is worse
than an absent one.

`make bundle` runs all of that on everything it gathers, cross-checks that every library an
artifact names will be resolvable on the target, and writes a receipt plus a generated deploy
script.

## Sysroots

A sysroot is a copy of the target's headers and libraries. Where it comes from is pluggable, chosen
per target:

| provider | use when |
|---|---|
| `ssh-rsync` | **the machine exists and you can reach it** — copies the real libraries |
| `deb` | it exists but you cannot reach it, and it is Debian-family — assembles a matching root from distribution packages, without root, Linux or `qemu` |
| `tar` | it exists but is unreachable (airgapped lab, customer site) |
| `dir` | a Yocto SDK, Buildroot staging tree or vendor BSP already exists |
| `oci` | the target is defined by a container image (pin a digest for reproducibility) |
| `debootstrap` | the machine does not exist yet and will be Debian-family (requires root and a Linux host) |
| `native` | the target is this machine — `/` on Linux, the SDK `xcrun` reports on macOS |
| `none` | the sysroot is managed entirely outside this build system |

Adding a provider is one executable in `sysroot/providers/`; the filename is the registration.
Symlink normalisation, validation and provenance recording are applied to every provider's output.

Nothing here is glibc-specific, Debian-specific, Linux-distro-aware or ELF-specific. A musl
Buildroot device, an Ubuntu server and a Mac are all descriptions: `targets/example-native.conf`
names no triple, libc, C++ library or rpath token, and is correct on Linux and macOS unchanged.

### A runtime rootfs is not a development sysroot

This is the trap that costs the most time. A *running* system needs `libc.so.6`. *Linking* against
it needs `libc.so`, the `crt*.o` startup objects and the headers, which ship in separate `-dev`
packages. Copy a rootfs from a machine that lacks them and you get a sysroot that can run programs
but not build them, and the error blames your compiler:

```text
fatal error: 'cstdio' file not found
ld.lld: error: cannot open Scrt1.o
ld.lld: error: unable to find library -lc
```

Ask before concluding the toolchain is broken:

```bash
make sysroot-info TARGET=demo-box
```

It warns `looks like a RUNTIME rootfs, not a development sysroot — it can RUN but not LINK`, and it
reports per format, because this trap is ELF's. A macOS SDK is development files by definition, so
on a Mach-O target the check looks for the headers and names `xcode-select --install` instead.

After installing packages on a target, re-run `make sysroot`. The copy is a snapshot, and nothing
watches that machine for changes.

## Things that bite

| | |
|---|---|
| **`make deploy` does not empty the target directory.** | Two bundles deployed to one board leave the union of both, while each receipt describes only its own half. |
| **A bundle that fails verification refuses to deploy.** | It writes `VERIFICATION-FAILED.txt`, and both `make deploy` and the bundle's own `deploy.sh` refuse while that file exists. Fix the mismatch and re-bundle. |
| **`build/` is disposable and not in git.** | A tree obtained by any means other than a fresh `git clone` may carry somebody else's artifacts *and their sysroot*. `make doctor` then reports `sysroot ready` before you have assembled one. `rm -rf build` is a complete reset and costs only rebuild time. |
| **`make test` takes about a minute** | and prints nothing until it finishes. Silent is not hung. |
| **`make bundle` gathers rather than builds.** | Build the components a bundle names first. |

## What the board additionally requires

The build ends with `vpk-bundle`'s libraries verified on the board. Running them requires things
this repository does not ship: `/dev/xib0`, a character device from an out-of-tree kernel module,
and `/dev/mem`, which requires root. The ERNIC™ modules must be loaded before anything connects,
which on the board is `modprobe xilinx_kmm && modprobe xilinx_ib`, and the FPGA must carry a
bitstream new enough to have the handshake registers. `make deploy` installs none of that.

The executor loads more than the transport stack. `librt_capi.so` and `librtd_null_qubit.so`, from
`rt-capi` and `rtd-null-qubit`, are the Catalyst runtime C API and the null-qubit device runtime,
and the executor `dlopen`s both by absolute path inside its workspace. A bundle without them starts
and then reports:

    dlopen(.../librt_capi.so) failed: cannot open shared object file: No such file or directory

Both are in `vpk-bundle` and in `threadripper-bundle` for that reason.

## When something fails

```bash
make doctor                     # host-side: missing tools, with the install command
make sysroot-info TARGET=t      # what the sysroot contains, and what it cannot do
make show-target  TARGET=t      # every resolved setting, and the exact compiler flags
make list-components            # what can be built, and which source trees each needs
make test                       # is the build system itself sane?
```

[`docs/05-troubleshooting.md`](docs/05-troubleshooting.md) is indexed by the message you actually
saw, including the failures that produce no message at all.

## Layout

| path | what |
|---|---|
| `targets/` | machine descriptions + `SCHEMA.md` |
| `components/` | build descriptions + `SCHEMA.md` |
| `bundles/` | deployment sets + `SCHEMA.md` |
| `mk/` | the build engine: `derive.mk` (data → flags), `rules.mk` (three generic recipes) |
| `tools/` | validation, sysroot inspection, ABI verification, bundling, doctor, quickstart |
| `tools/arch-table.sh` | the one table of architecture facts, and of which binary format an OS uses |
| `sysroot/providers/` | acquisition plugins |
| `sysroot/normalise/` | makes a sysroot relocatable |
| `sysroot/probe/` | the target-side probe (POSIX sh) |
| `cmake/` | cmake modules for cmake-driven components |
| `recipes/` | build recipes for artifacts whose sources live in an external checkout |
| `examples/` | self-contained source used by `quickstart` and the tests |
| `examples/docker/` | a throwaway aarch64 machine for learning the workflow without hardware |
| `tests/` | `run-tests.sh` — the regression suite for the build system itself |
| `docs/` | the documentation, below |
| `build/` | everything generated; safe to delete at any time |

## Documentation

Read in order, or jump to what you need:

1. [`docs/01-concepts.md`](docs/01-concepts.md) — what cross-compiling requires, and the four
   distinct ways the naive approach fails. Start here if "sysroot" is new to you.
2. [`docs/02-adding-a-target.md`](docs/02-adding-a-target.md) — the walkthrough, with the values
   that bite.
3. [`docs/03-how-flags-are-derived.md`](docs/03-how-flags-are-derived.md) — where every compiler
   flag comes from, and the precedence rules.
4. [`docs/04-sysroot-providers.md`](docs/04-sysroot-providers.md) — choosing one, and writing your
   own.
5. [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md) — indexed by the error message you
   saw, including the failures that produce *no* message.

## Requirements

Linux and macOS are both supported build hosts: a native build on either, and cross-building from
either to a Linux target once you have that target's sysroot.

**Required:** GNU Make and a C++ compiler, clang for preference, since one clang cross-compiles to
every architecture. Verification also requires a reader for the formats you build: `readelf`, from
binutils or LLVM, for ELF targets, and `otool`, from the Xcode Command Line Tools, for Mach-O.

Make 3.81 and `bash` 3.2 are what macOS ships and both are enough; a BSD userland works as well as
a GNU one. The test suite enforces this by scanning the engine for constructs that require newer
versions.

**Recommended:** `lld` (cross-links ELF without per-target binutils), `python3` (sysroot symlink
normalisation), `cmake` and `ninja` for cmake-driven components.

**Per provider, only if you use it:** `rsync` and `ssh`, `skopeo`/`podman`/`docker`,
`debootstrap`.

`make doctor` checks all of this, including which of the two readers the targets you have described
actually need, and prints the install command for anything missing.

## Testing the build system itself

```bash
make check                  # every description parses and every reference resolves
make test                   # the build system's own suite
make test VERBOSE=1         # with output
```

The suite covers description validation and rejection including attempted code-execution bypasses;
multi-word values; sysroot layout discovery across Debian multiarch, `lib64`, musl, a device rootfs
with no static libraries, and the macOS SDK whose C library is a set of `.tbd` stubs; symlink
relocation; every ABI check in both directions for whichever format this host compiles natively;
host portability, by scanning the engine for bash-4-only and GNU-only constructs; rebuild-on-change
for all three component kinds; topological build ordering and dependency-cycle detection; and a
full end-to-end build → verify → bundle → run-the-relocated-bundle cycle.

A build system's bugs do not look like build system bugs — they look like your code being broken.
Each test names the failure it prevents.
