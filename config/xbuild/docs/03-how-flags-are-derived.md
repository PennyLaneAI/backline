# 3. How flags are derived — the single source of truth

Every compiler and linker flag any component receives is computed in exactly one
file: `mk/derive.mk`. This page traces the path from a data field to a command line,
so that when a flag surprises you, you know where to look.

## The pipeline

    targets/my-board.conf                        you write this (data)
              |
              |  tools/conf2mk.sh   validate, then emit a Make view
              v
    build/generated/targets/my-board.mk          generated, never edited
              |
              |  mk/derive.mk       fill defaults, compose flags
              v
    TARGET_CXX_FLAGS, TARGET_LINK_FLAGS, ...     the only flag variables that exist
              |
              +---> mk/rules.mk ------------> direct compiler invocation
              |
              +---> tools/gen-cmake-toolchain.sh --> build/<t>/toolchain.cmake --> cmake

Note the join at the bottom: **both** consumers read the same variables. The cmake
toolchain file is generated, not written. That is the structural fix for the old
design's two hand-maintained copies of the CPU flag and interpreter path, which
carried a comment reading `KEEP IN SYNC`.

## See it for yourself

    make show-target TARGET=example-vpk120

The last two lines are the literal flags. Nothing downstream of `derive.mk` adds
anything target-specific, so what you see there is what the compiler gets.

Run it for two targets whose platforms differ and the tails of the link lines diverge.
Machine-selection and sysroot flags elided; `show-target` also strips the single quotes
it really passes around the rpath value:

    example-vpk120  … -Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1 -Wl,-rpath,$ORIGIN -Wl,--disable-new-dtags
    example-native  … -Wl,-rpath,@loader_path

The first line is the same on every build host, because that target names its machine.
The second is what `example-native` resolves to **on a Mac**; run it on Linux and you get
the `$ORIGIN` tail instead, from the same unchanged description. That is the point of the
example rather than a caveat about it.

For one component's full command line, including its own flags:

    make show-component TARGET=example-vpk120 COMPONENT=example-runtime-capi

## The target's binary format

`TARGET_BINFMT` is what separates those two tails. It is `elf` or `macho`, it is a
*derived* fact rather than a description field, and `mk/derive.mk` gets it from the
`binfmt` query of `tools/arch-table.sh` — keyed on the OS token of the triple and not on
the machine, because the format is a property of the platform:

    aarch64-linux-gnu         -> elf
    arm64-apple-darwin25.5.0  -> macho

`make sysroot-info TARGET=<t>` reports the resolved one as `format  : macho`.

Deriving it, rather than trusting a description to state it, matters because of the one
flag whose wrong spelling does *not* break loudly. Most ELF spellings are refused by
name — `ld64.lld: error: unknown argument '--disable-new-dtags'` — but ld64 *accepts* an
rpath of `$ORIGIN` and records it in `LC_RPATH` verbatim, where dyld never expands it.
That binary links, verifies, and then cannot find the libraries sitting beside it.

An OS the table does not list defaults to `elf`, which is the opposite of how the
architecture lookup behaves, deliberately. A wrong *architecture* yields a binary that
verifies clean and cannot execute, so `elf-machine` prints nothing rather than guessing.
A wrong *format* is rejected by name at the linker, so the cost of guessing there is a
build-time error, never a wrong binary.

## Field to flag, exhaustively

| description field | becomes | notes |
|---|---|---|
| `TARGET_TRIPLE` | `--target=<triple>` | LLVM only. A prefixed GCC has its target built in, and passing `--target=` to it is an error. |
| `TARGET_CPU` + `TARGET_CPU_FLAG` | `-mcpu=<cpu>` or `-march=<cpu>` | Nothing emitted when `TARGET_CPU` is empty. |
| `SYSROOT_DIR` | `--sysroot=<dir>` | Computed from the target name unless overridden. |
| `TARGET_LINKER` | `-fuse-ld=<linker>` | `lld`, `bfd`, `gold`, `mold`, or `default`, which emits nothing and lets the compiler driver pick. Any other value is a hard error. |
| `TARGET_STDLIB=libc++` | `-stdlib=libc++` | For `libstdc++`, nothing is emitted; the sysroot's GCC paths are added instead (below). |
| `TARGET_CXX_STANDARD` | `-std=gnu++<n>` | Defaults to `20`, which is also a floor: a description asking for `17` or older is raised to `20` with a note. |
| `TARGET_DYNAMIC_LINKER` | `-Wl,--dynamic-linker=<path>` | ELF executables only; a GNU-ld spelling. A shared library has no interpreter, and Mach-O records none at all — dyld is chosen by the kernel — so leave this blank on Darwin. |
| `TARGET_RPATH` | `-Wl,-rpath,'<v>'`, plus `-Wl,--disable-new-dtags` on ELF | The value differs by format too: `$$ORIGIN` against `@loader_path`. See the RPATH note below. |
| `TARGET_CFLAGS` / `CXXFLAGS` / `LDFLAGS` | appended verbatim | Last, so a target can override a default chosen here. |

Discovered from the sysroot at build time by `tools/sysroot-inspect.sh`, not
written in any description:

| discovered | becomes | when |
|---|---|---|
| C++ header version | `-isystem <sysroot>/usr/include/c++/<ver>` and the arch-specific sibling | `TARGET_STDLIB=libstdc++` |
| the sysroot's GCC dir | `-B<sysroot>/usr/lib/gcc/<triple>/<ver>` | `TARGET_STDLIB=libstdc++` |
| the library directory | `-L<libdir>` | both formats |
| the library directory | `-Wl,-rpath-link,<libdir>` | ELF |

The first two are GCC-shaped, and libc++ needs neither: its headers are *unversioned*,
at `usr/include/c++/v1`, where `v1` is an ABI version and not a compiler version — so
the search for a numeric directory correctly finds nothing and adds nothing.
`-rpath-link` is GNU-ld only (`ld64.lld: error: unknown argument '-rpath-link'`), and
Mach-O wants no equivalent: a dylib records the install name of everything it links, so
the linker follows those instead of searching a supplied path.

Two more spellings are nobody's description field, and both depend on the format, so
`derive.mk` owns them too:

* **a shared library's own name.** ELF records a `SONAME`; Mach-O records an install
  name and does not accept that spelling (`ld64.lld: error: unknown argument
  '-soname'`). `mk/rules.mk` asks for `$(call TARGET_SONAME_FLAG,<name>)` and receives
  `-Wl,-soname,<name>` or `-Wl,-install_name,@rpath/<name>`. The `@rpath/` prefix is
  what makes a bundle relocatable: without it the name recorded is the build
  directory's absolute path, which is the Mach-O form of a leaked host path.
* **`-shared`**, which needs no branch: clang already maps it to `-dynamiclib` for a
  Mach-O target.

## Precedence, stated once

Lowest to highest:

1. `mk/derive.mk` defaults — properties of the machine class
2. the target description's `TARGET_*FLAGS` — properties of that machine
3. the component's `COMPONENT_*FLAGS` — properties of that code

Later wins, because later is more specific. This ordering is written down here
rather than being an emergent property of how each recipe concatenated its
variables, which is what it was before.

## Two flags worth understanding properly

### `-rpath` versus `-rpath-link`

They look similar and do entirely different things.

* **`-rpath`** is written *into* the binary. The loader uses it at runtime. This is
  where `$ORIGIN` — or `@loader_path` — goes, and it must contain no build-host paths;
  a host path here is both a portability bug and an information leak.
* **`-rpath-link`** is used *only by the linker*, at build time, to find transitive
  dependencies so it can validate the link. It is **not** recorded in the output. So
  pointing it at your sysroot is correct and cannot leak.

`make verify` warns about absolute non-system paths in `-rpath` for exactly this
reason.

### `--disable-new-dtags`

Asks for `DT_RPATH` instead of the newer `DT_RUNPATH`. The difference is not
cosmetic: **`DT_RUNPATH` does not apply to a library's own transitive
dependencies.** So a bundle where `liba.so` needs `libb.so` beside it resolves
under RPATH and fails under RUNPATH.

This is the most common cause of "my bundle works on my machine but a library is
missing on the target", and it is why this flag is not optional here.

Mach-O needs no equivalent, so there is none to hunt for: `LC_RPATH` already applies to
transitive loads the way `DT_RPATH` does, and the Mach-O branch simply omits the flag.

## Defaults, and why each is the safe choice

A default should be the choice that fails least badly when nobody thought about it.

**`TARGET_CPU` empty.** A generic binary runs on every chip of the architecture. A
tuned one SIGILLs on older parts, and the crash does not look like a compiler flag.

**`TARGET_CPU_FLAG` per-architecture.** ARM wants `-mcpu`, x86 wants `-march`, and
clang *rejects* `-mcpu` for x86. Wrong here is a hard error, so it is derived.

**`TARGET_LINKER=lld`** for LLVM. Cross-links without a per-target binutils, which
is the property that makes one toolchain serve every target. It is `default` for a
Mach-O target instead: Apple's Command Line Tools ship `ld` (ld64) and no `ld.lld`, so
naming lld would mean a stock Mac could not build until somebody installed LLVM
separately — a hidden prerequisite for no gain, since ld64 is the linker Apple tests.

**`TARGET_LIBC` and `TARGET_STDLIB` follow the format.** `glibc`/`libstdc++` for ELF,
`libSystem`/`libc++` for Mach-O: on Darwin the ELF answers do not merely differ, they do
not exist — there is no `libc.so` anywhere and no libstdc++ at all. Asking for libstdc++
there is not refused, which is what makes it worth a default: clang implements the name,
accepts the flag, finds nothing, and the failure surfaces as
`fatal error: 'string' file not found` after a warning about the include path.

**`TARGET_RPATH=$$ORIGIN`**, or `@loader_path` on Mach-O. Makes a deployed directory
self-contained. The alternative — `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH` — must be
remembered by every caller forever.

**`TOOLCHAIN_ROOT` autodetected** via `clang -print-resource-dir`. Hardcoding
`/usr/lib/llvm-18` — as the old design did — silently restricts the build system to
Debian-family hosts.

**GCC version discovered, not pinned.** Pinning 13 broke every sysroot that had 12
or 14, with an error mentioning neither GCC nor a version.

## Platform facts live in one file

Four things need to know about architectures: which CPU flag to use (`-mcpu` vs
`-march`), what name `readelf` prints for a machine type, what Debian calls it, and what
`otool` prints for the same machine. All four are fields of one line per architecture in
`tools/arch-table.sh`:

    aarch64|mcpu|AArch64|arm64|arm64
    x86_64|march|X86-64|amd64|x86_64
    riscv64|march|RISC-V|riscv64|

`otool` says `arm64` where `readelf` says `AArch64`, which is why there are two columns
and not one; the verifier lowercases what the tool printed before comparing. The empty
fifth field on `riscv64` is not an omission — that architecture has no Mach-O form, so
`macho-arch` prints nothing. An empty answer means "cannot check", never "checked": the
verifier turns it into a WARNING naming the architecture it could not validate, and
`--strict` refuses the artifact. That is the same contract `elf-machine` has, and the
reason neither is allowed to return a guess.

A second, shorter table in the same file maps the OS token of a triple to a binary format
(`darwin|macho`, `linux|elf`, and the same for the BSDs and Solaris), and that is what
`binfmt` reads. The fact lives here rather than in `derive.mk` because *which format a
platform uses* is a property of the platform, in the same class as which flag selects a
CPU; *which flags follow from it* is the separate question, and stays in `derive.mk`.

`mk/derive.mk`, `tools/verify-artifact.sh`, `tools/sysroot-inspect.sh`,
`tools/make-bundle.sh`, `tools/doctor.sh` and the `debootstrap` provider all read it. So
adding an architecture — or a platform — is also a data change, one line, not an edit to
each engine file that needs the answer.

This was not originally the case, and the consequence was worse than duplication:
the verifier's private copy **failed open**. An architecture missing from its table
produced `-- architecture: no expectation` and the artifact **passed**, so an
x86-64 binary could verify clean against a target it could never run on. It now
warns explicitly, names the table to edit, and fails under `--strict`.

The general lesson, which is the same one the `KEEP IN SYNC` comment taught: a
lookup table duplicated across consumers will diverge, and the dangerous case is
the copy that treats "not found" as "fine".

## Adding a new derived flag

If you need a flag that is a property of *machines* (not of one project), the
change is confined:

1. Add the field to `targets/SCHEMA.md` with its rationale.
2. Add it to `TARGET_KEYS` in `tools/conf2mk.sh` — otherwise it is rejected as
   unknown, which is the intended behaviour for a key nobody documented.
3. Compose it in `mk/derive.mk`. If the spelling depends on the binary format, branch
   on `TARGET_BINFMT` there — and if the branch needs a new *fact* rather than a new
   flag (a name a tool prints, the format a platform uses), the fact belongs in
   `tools/arch-table.sh` and `derive.mk` reads it. Branching on a derived format is
   fine; branching on a platform *name* is the thing this tree does not do.
4. If cmake needs it too, add it to `tools/gen-cmake-toolchain.sh` — reading it from
   the same variable, never re-deriving it. `--disable-new-dtags` was once composed in
   both places, and only `derive.mk` learned that ld64 rejects it; every cmake-project
   component then failed at cmake's compiler probe with `ld: unknown options:
   --disable-new-dtags` (`05-troubleshooting.md` has the full account).
5. Add a test in `tests/run-tests.sh`.

You do not touch any component. That is the point.
