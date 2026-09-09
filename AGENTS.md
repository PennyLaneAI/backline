# Working in this repository — instructions for AI agents

Humans: this is also a fair summary. [`INSTALL.md`](INSTALL.md) is the fuller version.

## What this is

Accompanying material for a manuscript, and the machinery to reproduce its measurements: a
QEC decode offloaded from a controller to a coprocessor over an RDMA fabric.

**Every artifact that ships targets Linux.** The controller is a Xilinx VPK120 (aarch64,
PetaLinux); the coprocessor is an x86-64 host with an AMD GPU. Nothing deployed is meant to
run on the machine you build on — macOS support exists only so a laptop can *drive* the build.

The one exception is deliberate and you will meet it first: `TARGET=example-native` builds
for whatever host you are on, and on a Mac that is a Mach-O binary you run locally. It exists
to prove the build machinery works before Catalyst, a sysroot or a board can be blamed, and
`verify-artifact.sh` and the arch table have first-class Mach-O paths for it. Nothing about
the shipped stack goes through that route.

## How to build

Do not derive this; it is written down and every command has been run as given:

* [`INSTALL.md`](INSTALL.md) — fresh machine to a built stack, in four hardware tiers.
* [`demos/README.md`](demos/README.md) — running the demos, assuming that install.
* [`benchmarks/README.md`](benchmarks/README.md) — running the benchmarks, and what the numbers mean.
* `config/xbuild/README.md` — the build system's own design and every make goal.
* `config/xbuild/docs/05-troubleshooting.md` — indexed by the error message actually seen.

The shortest useful thing to run, which needs no hardware and no Catalyst:

```bash
cd config/xbuild && make doctor TARGET=example-native && make sysroot TARGET=example-native \
  && make build TARGET=example-native COMPONENT=hello-world && make verify TARGET=example-native
```

## The shape of this repository

| path | what | may you edit it |
|---|---|---|
| `config/xbuild/{targets,components,bundles}/` | inert `KEY=value` descriptions | yes — this is where work happens |
| `config/xbuild/{mk,tools,sysroot}/` | the generic engine | rarely, and read `config/xbuild/AGENTS.md` first |
| `demos/`, `benchmarks/`, `data/`, `paper/` | the experiments and their results | as asked |
| `scripts/` | helpers for running the above | as asked |
| `config/xbuild/build/` | generated | **never** — `rm -rf build` must stay a complete reset |

Adding a machine is one file in `targets/`. Adding something to build is one file in
`components/`. If a change makes either require editing the engine, the change is the bug.

## Things that will waste your time if you do not know them

Each of these was met in practice, and each fails in a way that points somewhere else.

* **Catalyst is NOT in this repository** and should not be added. It is a separately released
  upstream project, passed in as `CATALYST=~/catalyst` or set once in the git-ignored
  `config/xbuild/config.mk`. A component declares what it needs via `COMPONENT_SOURCE_ROOTS`,
  and `CATALYST` is the only external root the real deliverables declare. `grep
  COMPONENT_SOURCE_ROOTS components/*.conf` gives `CATALYST` alone seventeen times and
  `CATALYST FPGA_HWHS` twice — those two are *example* components, and `FPGA_HWHS` is a root
  only they use.
  PennyLane and pennylane-lightning are upstream projects this work depends on, but the build
  system never reads them: they are Catalyst's own Python-side dependencies, installed into
  Catalyst's venv by the recipe in `INSTALL.md`. Do not add roots for them.
* **`make build TARGET=vpk120` with no `COMPONENT=` ends in `Error 1`** even when everything
  wanted succeeded, because it also builds `example-executor`, which needs a cross-built LLVM.
  Name the component.
* **Verification refuses to run rather than passing silently.** On macOS the only `readelf`
  is Homebrew's keg-only llvm: `export PATH="$(brew --prefix llvm)/bin:$PATH"`.
* **The FPGA device sources live in Catalyst, not here.** They moved to
  `runtime/lib/transport/rdma/{fpga_verbs,fpga_hwhs,vendor}/`, so the `hwhs-*` and `swhs-*`
  components declare `CATALYST` and nothing else. Do not re-add a `devices/` tree.

  `rdma/vendor/infiniband/` there is a PATCHED copy of the system verbs headers. The single
  difference is one extra member, `void *(*_compat_reg_mr_ex)(void)`, in
  `struct ibv_context_ops` — a function-pointer table, so that field shifts the offset of
  every slot after it. Compile against the stock copy and the calls go through the wrong
  slots: clean build, wrong function at run time. Catalyst's own CMake puts that directory
  first with `SYSTEM BEFORE`, and `vendor/VendorVerbsCheck.cpp` fails the build if the stock
  header wins instead, so the invariant is enforced rather than documented. Those headers
  also carry a `.clang-format` setting `DisableFormat`, because they are upstream's to style.
* **`COMPONENT_OUTPUT` is an interface, not a name.** Transport plugins all export the same
  factory symbol and are selected by filename, so
  `libcatalyst_transport_hwhs_controller.so` cannot be renamed to match its component.
* **The `example-*` components are illustrations, not templates.** Several omit sources or
  flags that the real components need. Transcribe from the real descriptions —
  `components/rt-transport.conf`, `components/rt-capi.conf`, `components/hwhs-*.conf`. Their
  header comments cite `rdma_dev/…/Makefile` as the origin; that tree is frozen and is **not
  in or beside this repository**, so those citations are provenance, not somewhere to look.
  The descriptions here are the only copy.

## Before you say a change works

```bash
cd config/xbuild
make check              # every description parses; every reference resolves — seconds
make test               # the build system's own suite; SKIPs naming a reason are expected
```

`make test` takes about a minute and prints nothing until it finishes, so a silent
terminal is not a hung one. It passes with or without a `config.mk` — two of its cases assert
on the message you get when `CATALYST` is unset, and they clear it explicitly rather than
inheriting whatever you have configured. If you add a case in that family, do the same:
without `CATALYST=` on the command line, one of them silently launches a real hour-long LLVM
cross-build into the external Catalyst checkout instead of asserting anything.

Both must pass, and report the real counts including failures and skips. If you changed
anything under `config/xbuild/{mk,tools,sysroot}/`, add a test naming the failure it prevents
— `config/xbuild/AGENTS.md` states that contract and the invariants behind it.

For anything you can settle by running something — `make show-target`, `make show-component`,
`make sysroot-info`, `readelf`, `otool` — run it and quote the output rather than reasoning
about it in prose.

## Safety

* Do not commit, push or amend unless asked. Never commit to `main` directly.
* `make probe SSH=…` and `make deploy SSH=…` reach a real machine over ssh and the first
  writes a description containing hostnames and usernames. Only ever point them at a host
  named in the conversation.
* Do not commit `config/xbuild/build/`, `config/xbuild/config.mk`, or probe output.
