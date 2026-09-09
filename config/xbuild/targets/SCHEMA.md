# The target description — the central interface of this build system

A **target** is a *description of a machine you do not have in front of you*. It is a plain
file of `KEY=value` lines. It contains **no build logic**, no commands, no target-specific
`Makefile`. Everything else in this tree — flag construction, cmake toolchain files, sysroot
acquisition, ABI verification, bundling — is a *function of* one of these files.

That is the whole design in one sentence:

    target description  (data, you write this)
              |
              v
      generic machinery  (code, already written, you don't touch it)
              |
              v
    binaries that run on that machine

If you find yourself editing anything under `mk/` or `tools/` to add a board, the design has
failed and that is a bug worth reporting. Adding a board should mean writing one file in
`targets/` and nothing else.

## Why a file and not Make variables

A build system can encode the target as a *make goal* instead: `make my-board`. Every
component `Makefile` then needs its own `my-board:` rule, so the machine's name appears in
as many files as you have components, and adding a second machine means copy-pasting every
one of those recipes. Worse, facts needed by more than one consumer — the CPU flag and the
dynamic-linker path are needed by both the direct-compiler path and by cmake — end up
written twice, under a comment reading `KEEP IN SYNC`. A comment asking a human to maintain
an invariant is a defect, not a design.

Data files fix this because data can be *read by more than one consumer*. These files are
simultaneously valid POSIX shell and (after a mechanical transform) valid Make, so the shell
tools and the Make engine both read the same bytes. No sync required, no duplication possible.

## Format rules

* Strict POSIX shell assignment syntax: `KEY=value`, no spaces around `=`.
* Quote any value containing spaces: `TARGET_CFLAGS="-O2 -g"`.
* Comments start with `#`. Blank lines are fine.
* **No command substitution, no `$(...)`, no backticks.** These files are sourced by shell
  *and* transformed into Make; keep them inert. `tools/conf2mk.sh` rejects violations.
* Unset and empty mean the same thing: "not specified, use the default".

## Fields

Only `TARGET_NAME` and `TARGET_TRIPLE` are mandatory. Everything else has a defensible
default, and `make show-target TARGET=<name>` prints the fully-resolved set so you can see
what the defaults became.

Several of those defaults follow the target's **binary format** — ELF or Mach-O — rather
than being fixed, and the rows below say so. That format is *derived*, not described:
`tools/arch-table.sh binfmt <triple>` maps the OS field of the triple to `elf` or `macho`,
and `mk/derive.mk` exports the answer as `TARGET_BINFMT`. There is deliberately no
`TARGET_BINFMT` key to write here — a description that could contradict its own triple
would compose flags for one format and emit a binary in the other.

### Identity

| key | meaning |
|---|---|
| `TARGET_NAME` | **required.** Short tag. Names the build dir, the sysroot dir, the bundle. Must match the filename (`targets/foo.conf` → `foo`). Keep it `[a-z0-9_-]`. |
| `TARGET_DESC` | Free text for humans and `make list-targets`. |

### Machine and ABI

| key | meaning | default |
|---|---|---|
| `TARGET_TRIPLE` | **required.** What the compiler is told to emit, e.g. `aarch64-linux-gnu`, `x86_64-linux-musl`. This is a *compiler* concept and need not match any directory name on the target. | — |
| `TARGET_ARCH` | The target's `uname -m`. Used to pick sensible defaults and to sanity-check the sysroot. | first field of the triple |
| `TARGET_CPU` | Microarchitecture to tune/require, e.g. `cortex-a72`, `znver3`. Empty means "generic for the architecture", which is the safe choice: a generic binary runs on every chip of that family. | empty |
| `TARGET_CPU_FLAG` | Which flag carries `TARGET_CPU`: `mcpu` (ARM), `march` (x86, RISC-V), `mtune` (tune only, no new instructions), or empty to pass nothing. Getting this wrong is a hard error on some architectures — `-mcpu=` is not accepted by clang for x86. | `mcpu` for arm/aarch64, `march` otherwise |
| `TARGET_LIBC` | `glibc`, `musl`, `libSystem` (Darwin), or `other`. Selects which symbol-version families the ABI check looks at, and which sysroot layout is expected. Only glibc versions its symbols, so the `TARGET_LIBC_VERSION` ceiling below applies to it alone; the others skip that check by name. Leave it blank unless the answer is `musl` or `other` — the default follows the format, and there is no `libc.so` on macOS at all. | blank: `glibc` for ELF, `libSystem` for Mach-O |
| `TARGET_LIBC_VERSION` | The libc version *actually on the target*, e.g. `2.39`. This is the single most valuable field in the file: `make verify TARGET=…` refuses to ship a binary that references a newer symbol than this. Empty disables that check. | empty (check skipped, with a warning) |
| `TARGET_CXXABI_MAX` | The target's C++ ABI ceilings — one tag per namespace, space-separated, e.g. `GLIBCXX_3.4.32 CXXABI_1.3.14`. libstdc++ versions its symbols in **two** independent namespaces (`GLIBCXX_` for its own interface, `CXXABI_` for the Itanium C++ ABI runtime) which advance on different schedules, so a binary can exceed either. Each tag names the namespace it belongs to, so order does not matter and a value carrying only `GLIBCXX_` still means what it always did — the other axis is then reported as unchecked rather than passed. `make probe` reads both off the target's `libstdc++.so.6` **if the target has `strings` or `tr`** (busybox has `tr`); a minimal rootfs with neither leaves this blank and the probe warns loudly, because an empty ceiling disables the check. Only meaningful if you dynamically link libstdc++; empty skips (and `make verify` warns when the artifact actually imports libstdc++ symbols). | empty |
| `TARGET_DYNAMIC_LINKER` | Absolute path *on the target* of the ELF interpreter, e.g. `/lib/ld-linux-aarch64.so.1`. Set this when the target's path differs from what your sysroot implies — a very common cross-build failure, and one that only shows up as "No such file or directory" when running a binary that plainly exists. Empty lets the compiler decide from the sysroot. ELF only: a Mach-O binary records no interpreter (dyld is chosen by the kernel, and `make verify` reports that check as `n/a`), so leave it blank for a Darwin target — a value there is passed on as `-Wl,--dynamic-linker=…` and the link fails with `ld: unknown options: --dynamic-linker=…`. | empty |
| `TARGET_ENDIAN` | `little` or `big`. Informational; recorded in the build receipt. | `little` |

### Sysroot acquisition

| key | meaning | default |
|---|---|---|
| `SYSROOT_PROVIDER` | Which plugin under `sysroot/providers/` materialises the sysroot: `ssh-rsync`, `tar`, `dir`, `native`, `oci`, `debootstrap`, or `none`. `native` is the one to use for a build of this machine: it asks the host where its own headers and libraries are — `/` on Linux, the SDK from `xcrun --show-sdk-path` on macOS — instead of the description naming a path that is right on only one of them. See `docs/04-sysroot-providers.md`. | `none` |
| `SYSROOT_PROVIDER_ARGS` | Provider-specific string. Each provider documents its own format at the top of its script and validates it. | empty |
| `SYSROOT_DIR` | Override where the sysroot tree lives. Normally left empty so it lands in `build/sysroots/<TARGET_NAME>`. | empty |
| `SYSROOT_PROBE_FILE` | A path *inside* the sysroot that must exist for the sysroot to count as usable. Leave empty: `tools/sysroot-inspect.sh` discovers a suitable libc and uses that. Set it only if autodetection is wrong for an unusual layout. | autodetected |

`SYSROOT_PROVIDER=none` is legitimate and means "the sysroot is not this system's problem" —
you point `SYSROOT_DIR` at a tree that some other process produced (a Yocto SDK, a vendor BSP,
a CI cache). Generality includes the option of not participating.

### Toolchain selection

| key | meaning | default |
|---|---|---|
| `TOOLCHAIN_KIND` | `llvm` or `gcc`. `llvm` needs one clang that can emit every target (clang is a cross-compiler by construction). `gcc` needs a per-target prefixed GCC. | `llvm` |
| `TOOLCHAIN_ROOT` | Install prefix of the toolchain, i.e. the directory holding `bin/clang`. Empty autodetects from `PATH`. | autodetect |
| `TOOLCHAIN_PREFIX` | For `TOOLCHAIN_KIND=gcc`, the binary prefix, e.g. `aarch64-linux-gnu-`. | `$TARGET_TRIPLE-` |
| `TARGET_LINKER` | `lld`, `bfd`, `gold`, `mold`, or `default` — the last meaning "pass no `-fuse-ld` at all; let the compiler driver choose". `lld` cross-links ELF without a per-target binutils, which is why it is the default there. `default` is the default for a Mach-O target: ld64 ships with the Command Line Tools and is the configuration Apple tests, while naming `lld` would mean a stock Mac could not build until someone installed LLVM separately. Any other value is refused by name. | `bfd` for gcc; otherwise `default` for Mach-O and `lld` for ELF |
| `TARGET_STDLIB` | `libstdc++` or `libc++`. Which C++ runtime to compile and link against. Leave it blank: the default follows the format, and macOS ships no libstdc++ at all, so naming one there fails at the link with `ld: library 'stdc++' not found`. | blank: `libstdc++` for ELF, `libc++` for Mach-O |

### Compilation defaults

These are appended to every component built for this target, *after* the component's own
flags, so a component can still override. Keep them to things that are genuinely properties
of the machine, not of the code.

| key | meaning |
|---|---|
| `TARGET_CFLAGS` | Extra C flags. |
| `TARGET_CXXFLAGS` | Extra C++ flags. |
| `TARGET_LDFLAGS` | Extra link flags. |
| `TARGET_CXX_STANDARD` | e.g. `20`. Default **and minimum** `20`; anything older (`17`, `14`, …) is raised to `20` with a note, because Catalyst's headers use C++20 concepts and compiling them as C++17 fails with `unknown type name 'concept'` inside a vendor header. Newer values (`23`, `26`) pass through untouched. The floor lives in `mk/derive.mk`, not in these files, so regenerating a description with `make probe` cannot undo it. |
| `TARGET_SYSROOT_GCC_VERSION` | Pin the GCC version whose headers/libs inside the sysroot get used, when the sysroot ships several. Empty means "pick the newest present", which is what you want; the original design hardcoded `13` and silently produced a broken build on any sysroot without exactly that version. |

### Runtime layout on the target

| key | meaning | default |
|---|---|---|
| `TARGET_RPATH` | Run-time library search path to bake into shared objects and executables — the token meaning "next to me", which is what makes a bundle relocatable. **Leave it blank** and the format decides: `$$ORIGIN` for ELF, `@loader_path` for Mach-O. It is the one field where naming a value yourself risks a binary that links and then cannot find its own libraries, because the Mach-O linker accepts the ELF spelling without complaint — see `docs/01-concepts.md`. If you do write the ELF form, the `$` must be doubled: Make emits one `$` per `$$`, and a single one leaves the literal string `RIGIN` in the binary. | blank: `$$ORIGIN` for ELF, `@loader_path` for Mach-O |
| `TARGET_DEPLOY_DIR` | Where the bundle is expected to be unpacked on the target. Documentation and deploy-script input only; never compiled in. | `/tmp/<TARGET_NAME>` |
| `TARGET_GPU_ARCH` | The GPU this machine's device code is compiled for, e.g. `gfx90a` (MI210) or `sm_80` (A100). Read by components that set `COMPONENT_REQUIRES_GPU_ARCH=yes`, which refuse to build without it. **The spelling selects the vendor**, and with it every flag the device compiler is given: `gfx<n>` is AMD, `sm_<n>` is NVIDIA. A value matching neither is refused by name rather than compiled for the driver's default card. Like `TARGET_CPU` and `SYSROOT_PROVIDER` this is a **decision**, so `make probe` fills it in on a fresh description and a re-probe leaves it alone; the probe also records what the machine actually reports as a `# probe-gpu-arch:` comment, and says so when the two disagree. `GPU_ARCH=<arch>` on the make command line overrides it for one build. It is deliberately never detected from the build host: that machine need not hold the target's card, or any card. | empty |

## Worked example

`targets/example-vpk120.conf` is a fully-specified embedded board expressed purely as data:
every value a build needs, and not one line of code anywhere that knows it exists. (It is an
illustration; the real, probed board this project ships is `targets/vpk120.conf`.)

`targets/example-native.conf` is the opposite extreme: every field the triple and the format
can decide for themselves is left blank, which is what lets one description describe this
machine whether it is a Linux box or a Mac.
