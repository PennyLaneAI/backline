# The component description — what to build, never where to build it for

A **component** is one buildable artifact: an executable or a shared library. Like
a target, it is described by a `KEY=value` file and contains no build logic.

The rule that makes the whole tree work:

> **A component describes its own sources and dependencies. It never mentions a
> target.**

There is no `my-board:` rule in a component, no `ifeq ($(TARGET_NAME),…)`, no
per-board source list. If a component needs to know which machine it is being
built for, that need is a design smell and there is almost always a better
expression of it (see "conditional components" below).

## Why this is worth being strict about

The alternative is to express the relationship the other way round, with each component
enumerating the targets it supports: three near-identical 12-line recipes in one component,
one apiece in the next, and — for the components nobody got back to — only the single target
they were first written for.

That has a multiplicative cost. With C components and T targets you maintain
C × T recipes, and adding one target means editing C files. It also *silently
drifts*: in the original tree `rtd-null-qubit` linked with `-static-libstdc++
-Wl,--exclude-libs,ALL` while `rt-capi`, built from the same source tree for the
same board, did not. Nothing documented the difference and it is not obvious it
was intended.

Inverting the dependency makes it C + T files, and — more importantly — makes the
drift impossible rather than merely discouraged, because the flags come from one
place that no component can locally override by copy-paste.

## Format

Same rules as target descriptions: strict `KEY=value`, no command substitution,
`#` comments. Validated by `tools/conf2mk.sh`, which rejects unknown keys.

## Fields

| key | meaning |
|---|---|
| `COMPONENT_NAME` | **required.** Must match the filename. |
| `COMPONENT_DESC` | Free text; shown by `make list-components`. |
| `COMPONENT_KIND` | **required.** `executable`, `shared-library`, or `cmake-project`. Determines which recipe in `mk/rules.mk` runs. |
| `COMPONENT_OUTPUT` | The artifact filename, e.g. `librt_capi.so`, `catalyst-executor`. |
| `COMPONENT_SOURCES` | Space-separated source paths. May use `$(VAR)` references to source roots (see below). |
| `COMPONENT_INCLUDES` | Space-separated include directories, *without* `-I`. The recipe adds the flag, so a path containing a space cannot break the command line. |
| `COMPONENT_CFLAGS` / `COMPONENT_CXXFLAGS` | Extra compile flags specific to this component's code. |
| `COMPONENT_LDFLAGS` | Extra link flags. |
| `COMPONENT_LIBS` | Libraries to link, without `-l`: `pthread dl rt ibverbs`. |
| `COMPONENT_DEPENDS` | Other components that must be built first, by name. Used for link order and for build ordering. |
| `COMPONENT_SOURCE_ROOTS` | Names of required external source trees, e.g. `CATALYST LIGHTNING`. The build fails early, by name, if one is unset — instead of failing later with a path that has an empty prefix. |
| `COMPONENT_SONAME` | Override the `-soname`. Defaults to `COMPONENT_OUTPUT`, which is what you want. |
| `COMPONENT_CMAKE_SOURCE_DIR` | For `cmake-project`: where the `CMakeLists.txt` lives. |
| `COMPONENT_CMAKE_ARGS` | For `cmake-project`: extra `-D` arguments. |
| `COMPONENT_CMAKE_TARGET` | For `cmake-project`: the specific cmake target to build. |
| `COMPONENT_REQUIRES_NATIVE` | `yes` if this component cannot be cross-compiled (see below). Default `no`. |
| `COMPONENT_REQUIRES_GPU_ARCH` | `yes` if this component compiles device code and so needs the target's `TARGET_GPU_ARCH`. The build refuses by name when the target names none, or names one matching no vendor, rather than handing the vendor compiler an empty architecture. Put `$(TARGET_GPU_ARCH_FLAG)` in `COMPONENT_CXXFLAGS` and `$(TARGET_GPU_ORIGIN_FLAG)` in `COMPONENT_LDFLAGS`: both are already spelled for the vendor the target's arch selects, so one description serves an AMD and an NVIDIA card. Setting `yes` also switches this component's C++ standard and soname flags to that vendor's spelling, and supplies the environment its driver needs. Default `no`. |
| `COMPONENT_CXX_OVERRIDE` / `COMPONENT_CC_OVERRIDE` | Compile this one component with a different compiler, e.g. `hipcc`. Everything else — sysroot, include handling, verification, bundling — stays on the common path. Defaults to the target's toolchain, which is what you want unless a vendor compiler is genuinely required; see "components that cannot be cross-compiled" below. |
| `COMPONENT_STATIC_CXX` | `yes` to bundle libstdc++/libgcc into the artifact. Read the note below before setting it. |
| `COMPONENT_OPTIONAL` | `yes` means a build failure is reported but does not fail the whole run. For components that depend on hardware SDKs not everyone has. |

## Source roots

External source trees are referenced by name, not by path:

    COMPONENT_SOURCE_ROOTS=CATALYST
    COMPONENT_SOURCES=$(CATALYST)/runtime/lib/capi/RuntimeCAPI.cpp

The user supplies the path once on the command line or in `config.mk`:

    make build TARGET=my-board CATALYST=$HOME/catalyst

Declaring the root means an unset one is caught before compiling, with a message
naming the variable and the component that wanted it. The old tree checked this
per-Makefile with a hand-written `ifeq`/`$(error)` block repeated in each
component, and the checks were inconsistent — some validated that the tree looked
right, most only that the variable was non-empty.

## Declare only the roots you actually need

`COMPONENT_SOURCE_ROOTS` is a hard requirement list: an unset root fails the build
before anything compiles. That makes over-declaring genuinely harmful, not merely
untidy — it converts "I do not have that tree" into "I cannot build this component",
even when the component's sources do not come from it.

The examples shipped here got this wrong at first and it is worth showing why:

* `example-transport-session` — an RDMA transport whose sources are **entirely** in
  `CATALYST` (the shared `transport/common/*` plumbing plus the CPU-verbs
  implementation). Declares `CATALYST`. Builds for anyone.
* `example-fpga-session` — the *same kind* of thing for an FPGA device whose driver
  sources live in a separate tree. Declares `CATALYST FPGA_HWHS`.

Originally there was one component doing both jobs, declaring the vendor root
unconditionally. The effect was that the software-only transport could not be built
without pointing at hardware sources you may not have — a dependency invented by the
description, not by the code.

The rule: **an optional dependency belongs to the component that genuinely needs it,
not to the category it happens to sit in.** If two variants differ only in where
their sources come from, they are two components, and the choice between them belongs
in a bundle.

A useful check on any component you write: could someone with only `CATALYST` build
this? If yes, it must not declare anything else.

## `COMPONENT_STATIC_CXX` — the honest version

Setting this to `yes` adds `-static-libstdc++ -static-libgcc
-Wl,--exclude-libs,ALL`. It is tempting because it makes a library "just work" on
a target with an older libstdc++.

It is also how you get two copies of the C++ runtime in one process. If your
executable links libstdc++ dynamically and then `dlopen`s a plugin with its own
static copy, you have two `std::` allocators, two sets of type_info, and two
exception-handling personalities. Exceptions thrown across that boundary do not
get caught; `dynamic_cast` returns null for a type that is plainly correct.
Debugging it is unpleasant because every symbol resolves and no tool complains.

Use it for a **leaf** artifact that exchanges only C types across its boundary.
Do not use it for something that passes `std::string` or throws across a
`dlopen` boundary. If you need a newer C++ runtime on an old target, prefer
shipping `libstdc++.so.6` in the bundle, which the default rpath — `$ORIGIN` for
an ELF target — already finds beside the binaries.

The whole question is ELF-only: all three flags are GCC/GNU-ld spellings, and Darwin
ships no static libc++ to link in. `mk/rules.mk` therefore refuses the option by name
for a Mach-O target, naming the description field that asked for it, instead of
passing the flags through and producing three driver errors that name only the flags.
Set `COMPONENT_STATIC_CXX=no` for such a target, or leave the component out of its
bundle.

## Components that cannot be cross-compiled

Some code can only be built natively — HIP/CUDA device code needs the vendor
compiler, and vendor compilers are not cross-compilers. Set:

    COMPONENT_REQUIRES_NATIVE=yes

The build then requires the selected target to be native (same triple as the
host) and fails with a clear explanation otherwise, rather than invoking `hipcc`
with `--target=aarch64-linux-gnu` and emitting several hundred lines of errors.

Such a component is also not given the target's machine flags or its sysroot's
include and library paths: both describe a machine being built for, and this one
is built for the host. It keeps the C++ standard, which describes the source.

This is how the original tree's GPU library is expressed. There, it was a
separate hand-written Makefile with its own conventions and no verification;
here it is the same component pipeline with one field set, so it gets the same
ABI checks and the same bundling.

## Conditional components

"This library only exists for boards with an FPGA" is a real requirement. Express
it in the **bundle**, not in the component: a bundle lists the components it
contains, so a target with no FPGA simply has a bundle that does not list the
FPGA library. See `bundles/SCHEMA.md`.

That keeps the component honest — it describes how to build itself and nothing
else — and puts the per-machine decision in the file that is already per-machine.
